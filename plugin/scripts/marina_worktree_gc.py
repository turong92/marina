#!/usr/bin/env python3
"""marina_worktree_gc.py — 유휴 워크트리 판정 + 삭제 전 안전 가드 (+ CLI `marina worktree gc`).

배경(2026-09-14 실측): mdc-main 워크트리 28개 중 22개가 세션·프로세스 0, 마지막 커밋 2~9주
전이었다. 워크트리당 1.5~8GB(node_modules)에 이미지 3~6GB × 서비스 수가 붙고, 감시 파일 수
폭증으로 fseventsd 가 4.5GB·CPU 100% 로 39일을 버텼다. "지워도 되는 것"을 기계가 골라 주고,
지우기 전에 잃을 게 없게 만드는 것이 이 모듈의 일이다.

**유휴 판정** (셋 다 만족해야 유휴):
  ① 붙은 에이전트 세션 0 — 작업중/대기/차단 상태이거나 살아있는 PTY(reachable)가 있는 세션이 없다.
  ② cwd 프로세스 0 — 기존 liveness 규칙 재사용(`ps comm` → lsof cwd → root, argv 파싱 금지).
  ③ 마지막 커밋 **과** 파일 mtime **모두** K일(기본 14) 초과. mtime 은 git 이 아는 파일(tracked +
     non-ignored untracked)만 본다 — node_modules·빌드 산출물의 churn 은 사람의 활동이 아니다.

**안전 가드** (삭제 전):
  (a) 루트 HEAD 가 detached 이고 어느 ref 에서도 닿지 않으면 메인 클론에 `backup/worktree-<name>-<date>` 브랜치.
  (b) 서브레포 클론(부모 기준 untracked 중첩 레포)에 원격 어디에도 없는 커밋이 있으면 메인 클론의 그
      서브레포로 같은 이름의 브랜치로 fetch 해 보존.
  (c) 서브레포 밖의 진짜 untracked/미커밋 파일이 있으면 삭제 대상에서 빼고 사유를 남긴다.
      (서브레포 안의 미커밋도 같은 이유로 뺀다 — remove 는 서브레포를 --force 로 지운다.)

자동 삭제는 없다. CLI 는 판정·가드까지만, 삭제는 대시보드 "유휴 정리"에서 골라서 한 번에.
"""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from marina_state import MARINA_HOME, _env
from marina_registry import discover_all_roots, is_source_checkout, project_label, source_root_for
from marina_paths import read_meta, session_id

GC_DAYS_DEFAULT = int(_env("GC_DAYS", "7"))      # 2026-09-17 형: "7일 사용 안 한 거 자동 gc" (배지·CLI·자동 정리가 같은 기준)
LIVE_AGENT_STATUSES = ("working", "blocked", "waiting")
MTIME_TTL = 600.0          # 파일 mtime 스캔은 stat 수만 번 — 10분 캐시(폴링마다 돌지 않게)
_mtime_cache: dict[str, tuple[float, int]] = {}


def _git(repo: Path, *args: str, timeout: float = 60) -> tuple[int, str]:
    try:
        out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, timeout=timeout)
        return out.returncode, (out.stdout or "").strip() or (out.stderr or "").strip()
    except Exception as exc:
        return 1, str(exc)


def _git_ok(repo: Path, *args: str, timeout: float = 60) -> str:
    code, text = _git(repo, *args, timeout=timeout)
    return text if code == 0 else ""


# (d) gitignore 된 로컬 파일 — git 이 모르니 (a)(b)(c) 어디에도 안 걸리고 백업도 못 만든다. 코드리뷰 Critical + 실측
#     (2026-09-17 mdc-main compaction-skill-control 워크트리의 gitignore 된 tasks/…/research.md·progress.md 과업 노트).
#     다시 만들 수 있는 것은 뺀다: 빌드 산출물·의존성 폴더, 마리나 관리 폴더(.workspace), 로그, 심링크,
#     원본 체크아웃의 같은 경로와 내용이 같은 파일(links copy 로 들어온 .env*.local·*local.yml 등).
_REGENERABLE_DIRS = {"node_modules", ".next", "dist", "build", "out", "target", ".gradle", ".venv", "venv", "__pycache__",
                     ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".turbo", ".cache", "coverage", ".parcel-cache",
                     ".nuxt", ".svelte-kit", ".expo", "DerivedData", "Pods", ".workspace"}
_REGENERABLE_FILES = {".DS_Store"}
_IGNORED_WALK_LIMIT = 400


def _ignored_entries(repo: Path) -> list[str]:
    try:
        out = subprocess.run(["git", "-C", str(repo), "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
                             capture_output=True, text=True, timeout=120)
    except Exception:
        return ["<git ls-files 실패>"]
    if out.returncode != 0:
        return ["<git ls-files 실패>"]
    return [e for e in out.stdout.split("\0") if e]


def _regenerable_path(rel: str) -> bool:
    parts = [p for p in rel.split("/") if p]
    return (not parts or any(p in _REGENERABLE_DIRS for p in parts) or parts[-1] in _REGENERABLE_FILES
            or parts[-1].endswith(".log"))


def _same_file(a: Path, b: Path) -> bool:
    import filecmp
    try:
        return b.is_file() and a.stat().st_size == b.stat().st_size and filecmp.cmp(str(a), str(b), shallow=False)
    except OSError:
        return False


def unrecoverable_ignored(root: Path, limit: int = 20) -> list[str]:
    """워크트리를 지우면 영영 사라지는 gitignore 파일(최대 limit 개 경로). 판단 불가(git 실패·너무 많음)도 항목으로 돌려준다
    — '모르면 안전하지 않다'."""
    try:
        source = source_root_for(root)
    except Exception:
        source = root
    nested = nested_repos(root)
    found: list[str] = []
    for repo_rel in [""] + list(nested):
        repo = root / repo_rel if repo_rel else root
        src_repo = source / repo_rel if repo_rel else source
        for entry in _ignored_entries(repo):
            rel = entry.rstrip("/")
            full = f"{repo_rel}/{rel}" if repo_rel else rel
            if entry.startswith("<"):
                found.append(f"{full or '.'}: 판단 불가")
                continue
            if not repo_rel and any(rel == n or rel.startswith(n + "/") for n in nested):
                continue                                   # 중첩 레포는 자기 차례에 본다
            if _regenerable_path(rel):
                continue
            p = repo / rel
            if p.is_symlink():
                continue
            if p.is_file():
                if not _same_file(p, src_repo / rel):
                    found.append(full)
            elif p.is_dir():
                walked = 0
                for f in sorted(p.rglob("*")):
                    walked += 1
                    if walked > _IGNORED_WALK_LIMIT:
                        found.append(f"{full}/ (파일이 너무 많아 판단 불가)")
                        break
                    frel = f.relative_to(repo).as_posix()
                    if f.is_symlink() or not f.is_file() or _regenerable_path(frel):
                        continue
                    if not _same_file(f, src_repo / frel):
                        found.append(f"{full}/")
                        break
            if len(found) >= limit:
                return found
    return found


def nested_repos(root: Path) -> list[str]:
    from marina_lifecycle import _nested_repos     # 같은 규칙(심링크 제외·등록분 합침) — 두 벌 두지 않는다
    return _nested_repos(root)


# ── ③ 파일 mtime ─────────────────────────────────────────────────────────────

def latest_file_mtime(root: Path, refresh: bool = False) -> int:
    """워크트리(+중첩 레포)의 git 이 아는 파일 중 가장 최근 mtime(epoch s). 없으면 0.

    `git ls-files --cached --others --exclude-standard` 라 ignore 된 node_modules·dist 는 안 본다 —
    그 안은 설치·빌드가 건드리는 것이지 사람이 일한 흔적이 아니다."""
    key = str(root)
    cached = _mtime_cache.get(key)
    if cached and not refresh and time.time() - cached[0] < MTIME_TTL:
        return cached[1]
    latest = 0
    for repo in [root, *(root / name for name in nested_repos(root))]:
        try:
            out = subprocess.run(["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                 capture_output=True, timeout=120)
        except Exception:
            continue
        for rel in out.stdout.split(b"\0"):
            # .workspace/ 는 마리나 자기 폴더(로그·터미널 상태) — 데몬이 쓰는 것이지 사람의 활동이 아니다
            # (세션 폴더의 mtime 은 worktree_info.lastTs 가 따로 반영한다)
            if not rel or rel.startswith(b".workspace/"):
                continue
            try:
                st = os.lstat(repo / os.fsdecode(rel))
            except OSError:
                continue
            if st.st_mtime > latest:
                latest = int(st.st_mtime)
    _mtime_cache[key] = (time.time(), latest)
    return latest


# ── 유휴 판정 ────────────────────────────────────────────────────────────────

def attached_agents(agents: list[dict[str, Any]] | None) -> list[dict[str, Any]]:
    """"붙어 있는" 세션 — 상태가 살아있거나(작업중·대기·차단) 마리나가 그 PTY 를 쥐고 있는 것.
    끝났거나(completed) 프로세스 없는 idle 트랜스크립트는 영원히 남으니 세지 않는다."""
    return [a for a in (agents or []) if a.get("status") in LIVE_AGENT_STATUSES or a.get("reachable")]


def idle_verdict(root: Path, info: dict[str, Any], agents: list[dict[str, Any]] | None,
                 live_cwds: set[Path], days: int | None = None, now: float | None = None) -> dict[str, Any]:
    """카드/CLI 공통 판정. info = worktree_info(root) — 커밋 시각은 lastCommitTs(세션 폴더 mtime 을
    섞은 lastTs 가 아니라). 세션 폴더는 데몬이 부팅 때마다 건드려 "지금"이 되므로 활동 신호가 못 된다
    (실측 2026-09-14: 재시작 후 워크트리 6개 전부 당일 mtime). 세션·프로세스는 ①②가 따로 본다.
    mtime 스캔은 커밋 기준으로 이미 K일을 넘긴 것에만 한다(대부분의 활성 워크트리는 여기서 끝)."""
    from marina_sessions import _root_has_live_agent
    days = GC_DAYS_DEFAULT if days is None else int(days)
    now = time.time() if now is None else now
    attached = attached_agents(agents)
    live_proc = _root_has_live_agent(root, live_cwds or set())
    out: dict[str, Any] = {"gcDays": days, "gcIdle": False, "gcIdleDays": None,
                           "gcAgents": len(attached), "gcLiveProcess": bool(live_proc)}
    last_ts = int(info.get("lastCommitTs") if info.get("lastCommitTs") is not None else (info.get("lastTs") or 0))
    if last_ts:
        out["gcIdleDays"] = round((now - last_ts) / 86400, 1)
    if attached or live_proc:
        return out
    if last_ts and (now - last_ts) / 86400 <= days:
        return out                                   # 커밋/세션이 최근 — 스캔 없이 활성
    file_ts = latest_file_mtime(root)
    last = max(last_ts, file_ts)
    if not last:
        return out                                   # 판정 근거 없음 — 유휴로 부르지 않는다
    idle_days = (now - last) / 86400
    out["gcIdleDays"] = round(idle_days, 1)
    out["gcIdle"] = idle_days > days
    return out


# ── 안전 가드 ────────────────────────────────────────────────────────────────

def backup_branch_name(name: str, date: str | None = None) -> str:
    slug = re.sub(r"[^0-9A-Za-z._-]+", "-", str(name or "")).strip("-.") or "worktree"
    return f"backup/worktree-{slug}-{date or time.strftime('%Y%m%d')}"


def _unique_branch(repo: Path, name: str, sha: str) -> tuple[str, bool]:
    """(이름, 이미 같은 sha 로 있음). 같은 이름이 다른 커밋을 가리키면 시각을 붙인다(남의 백업을 덮지 않는다)."""
    existing = _git_ok(repo, "rev-parse", "--verify", "-q", f"refs/heads/{name}")
    if existing and existing != sha:
        return f"{name}-{time.strftime('%H%M%S')}", False
    return name, bool(existing)


def _reachable_from_any_ref(repo: Path, sha: str) -> bool:
    out = _git_ok(repo, "for-each-ref", f"--contains={sha}", "--format=%(refname)", "refs/heads", "refs/remotes")
    return bool(out)


def _unpushed_count(repo: Path) -> int | None:
    """원격 어디에도 없는 HEAD 쪽 커밋 수. 원격이 하나도 없으면 전부가 그렇다(그게 맞다)."""
    code, text = _git(repo, "rev-list", "--count", "HEAD", "--not", "--remotes")
    if code != 0 or not text.isdigit():
        return None
    return int(text)


def _own_changes(repo: Path) -> tuple[list[str], list[str]]:
    """(미커밋 수정, untracked) — 중첩 레포·마리나 자기 폴더는 뺀다(방 상태 판정과 같은 규칙)."""
    from marina_rooms import own_changed_paths
    try:   # _git 은 strip 을 한다 — porcelain 의 첫 레코드(" M a") 앞 공백이 날아가면 경로가 뭉개진다
        out = subprocess.run(["git", "-C", str(repo), "status", "--porcelain", "-z"], capture_output=True, text=True, timeout=120)
    except Exception:
        return [], []
    if out.returncode != 0:
        return [], []
    text = out.stdout
    own = set(own_changed_paths(text, repo))
    modified: list[str] = []
    untracked: list[str] = []
    records = [r for r in text.split("\0") if r.strip()]
    i = 0
    while i < len(records):
        rec = records[i]
        i += 1
        if rec[:1] in ("R", "C"):
            i += 1
        path = rec[3:] if len(rec) > 3 else ""
        if path not in own:
            continue
        (untracked if rec.startswith("?? ") else modified).append(path)
    return modified, untracked


def _preserve_into(main_repo: Path, src_repo: Path, sha: str, name: str, apply: bool) -> dict[str, Any]:
    """src_repo 의 sha 를 main_repo 의 refs/heads/<name> 으로 보존. 워크트리면 객체를 이미 공유하므로
    `branch` 로 끝나고, 별도 클론이면 fetch 로 가져온다."""
    name, existed = _unique_branch(main_repo, name, sha)
    item = {"repo": str(main_repo), "branch": name, "sha": sha[:12], "created": False, "existed": existed}
    if not apply or existed:
        return item                       # 이미 같은 커밋으로 보존돼 있다 — 다시 만들 것 없음(멱등)
    code, _ = _git(main_repo, "branch", "--no-track", name, sha)
    if code != 0:
        code, err = _git(main_repo, "fetch", "-q", "--no-tags", str(src_repo), f"{sha}:refs/heads/{name}", timeout=300)
        if code != 0:
            item["error"] = err[-200:]
            return item
    item["created"] = True
    return item


def guard_report(root: Path, apply: bool = False, date: str | None = None, strict: bool = False) -> dict[str, Any]:
    """삭제 전 가드 (a)(b)(c). apply=False 면 계획만(쓰기 0). eligible=False 면 삭제 대상에서 뺀다."""
    out: dict[str, Any] = {"eligible": True, "reasons": [], "backups": []}
    try:
        main = source_root_for(root)
    except Exception:
        main = root
    if is_source_checkout(root) or main.resolve() == root.resolve():
        out["eligible"] = False
        out["reasons"].append("원본 체크아웃 — 삭제 대상 아님")
        return out
    name = session_id(root)
    bname = backup_branch_name(name, date)

    # (c) 서브레포 밖 진짜 untracked/미커밋 — 잃을 수 있는 것은 자동으로 지우지 않는다
    modified, untracked = _own_changes(root)
    if untracked:
        out["eligible"] = False
        out["reasons"].append(f"untracked {len(untracked)}개: " + ", ".join(untracked[:3]) + (" …" if len(untracked) > 3 else ""))
    if modified:
        out["eligible"] = False
        out["reasons"].append(f"미커밋 수정 {len(modified)}개: " + ", ".join(modified[:3]) + (" …" if len(modified) > 3 else ""))

    # (d) 다시 못 만드는 gitignore 파일 — strict(자동 정리)면 제외, 아니면(사람이 고를 때) 경고로만 싣는다
    lost = unrecoverable_ignored(root)
    if lost:
        out["ignoredLocal"] = lost
        if strict:
            out["eligible"] = False
            out["reasons"].append(f"gitignore 된 로컬 파일 {len(lost)}개(자동 삭제 제외): " + ", ".join(lost[:3]) + (" …" if len(lost) > 3 else ""))

    # (a) detached HEAD — 어느 ref 에서도 못 닿으면 이름을 붙여 둔다(폴더가 사라지면 sha 를 잃는다)
    head = _git_ok(root, "rev-parse", "--verify", "-q", "HEAD")
    branch = _git_ok(root, "branch", "--show-current")
    if head and not branch and not _reachable_from_any_ref(root, head):
        item = _preserve_into(main, root, head, bname, apply and out["eligible"])
        item["why"] = "detached HEAD — 이름 있는 ref 없음"
        out["backups"].append(item)
        if item.get("error"):
            out["eligible"] = False
            out["reasons"].append(f"루트 백업 실패: {item['error']}")

    # (b) 서브레포 클론 — 원격에 없는 커밋은 메인 클론에 브랜치로
    for repo in nested_repos(root):
        sub = root / repo
        sub_mod, sub_untracked = _own_changes(sub)
        if sub_mod or sub_untracked:
            out["eligible"] = False
            out["reasons"].append(f"{repo}: 미커밋 {len(sub_mod)}·untracked {len(sub_untracked)}")
        unpushed = _unpushed_count(sub)
        if unpushed is None:
            # "확인 불가"를 "안전"으로 읽지 않는다(코드리뷰 지적) — git 실패(락·타임아웃)면 보존 여부를 모르니 뺀다
            out["eligible"] = False
            out["reasons"].append(f"{repo}: 원격 확인 불가(git rev-list 실패) — 보존 여부를 판단할 수 없어 제외")
            continue
        if not unpushed:
            continue
        sub_head = _git_ok(sub, "rev-parse", "--verify", "-q", "HEAD")
        main_sub = main / repo
        if not (main_sub / ".git").exists():
            out["eligible"] = False
            out["reasons"].append(f"{repo}: 원격에 없는 커밋 {unpushed}개인데 메인 클론에 {repo} 가 없어 보존 불가")
            continue
        item = _preserve_into(main_sub, sub, sub_head, bname, apply and out["eligible"])
        item.update({"subrepo": repo, "why": f"원격에 없는 커밋 {unpushed}개"})
        out["backups"].append(item)
        if item.get("error"):
            out["eligible"] = False
            out["reasons"].append(f"{repo} 백업 실패: {item['error']}")
    return out


# ── 계획/실행 ────────────────────────────────────────────────────────────────

def gc_plan(days: int | None = None, roots: list[Path] | None = None, apply: bool = False,
            refresh: bool = False, can_root=None, strict: bool = False) -> list[dict[str, Any]]:
    """유휴 워크트리 목록(가드 포함). apply=True 면 가드 (a)(b) 를 실제로 적용(백업 브랜치 생성).
    삭제는 여기서 하지 않는다."""
    from marina_sessions import _live_agent_cwds, agents_payload, worktree_info
    days = GC_DAYS_DEFAULT if days is None else int(days)
    live = _live_agent_cwds(refresh)
    entries: list[dict[str, Any]] = []
    for root in (roots if roots is not None else discover_all_roots(refresh)):
        if is_source_checkout(root) or (can_root and not can_root(root)):
            continue
        try:
            info = worktree_info(root, refresh)
            agents = agents_payload(root, refresh)
        except Exception as exc:
            entries.append({"root": str(root), "id": session_id(root), "gcIdle": False, "error": str(exc)[-200:]})
            continue
        verdict = idle_verdict(root, info, agents, live, days)
        if not verdict["gcIdle"]:
            continue
        entry = {"root": str(root), "id": session_id(root), "alias": read_meta(root).get("alias", ""),
                 "projectId": info.get("projectId") or project_label(root),
                 "diskMb": info.get("diskMb"), "imageMb": info.get("imageMb"), "cacheMb": info.get("cacheMb"),
                 "aheadTotal": info.get("aheadTotal"), "lastTs": info.get("lastTs"), **verdict}
        entry.update(guard_report(root, apply=apply, strict=strict))
        entries.append(entry)
    return entries


def gc_remove(roots: list[Path], days: int | None = None, volumes: str = "all", strict: bool = False) -> list[dict[str, Any]]:
    """대시보드 일괄 삭제 — 고른 root 마다 **지금** 다시 유휴인지 보고, 가드를 적용한 뒤 지운다.
    하나가 실패해도 나머지는 계속. 결과에 회수 용량(reclaim)을 싣는다."""
    from marina_lifecycle import remove_worktree
    results: list[dict[str, Any]] = []
    plan = {e["root"]: e for e in gc_plan(days, roots=roots, apply=True, refresh=True, strict=strict)}
    for root in roots:
        entry = plan.get(str(root))
        item: dict[str, Any] = {"root": str(root), "id": session_id(root), "removed": False, "freedMb": 0}
        if entry is None:
            item["reason"] = "더는 유휴가 아님(세션·프로세스·최근 변경) — 건너뜀"
            results.append(item)
            continue
        item["backups"] = entry.get("backups", [])
        if not entry.get("eligible"):
            item["reason"] = "; ".join(entry.get("reasons") or ["삭제 부적격"])
            results.append(item)
            continue
        try:
            res = remove_worktree(root, force=False, volumes=volumes)
            root_res = res.get("root") if isinstance(res, dict) else None
            item["removed"] = isinstance(root_res, dict) and ("removed" in root_res or "missing" in root_res)
            item["result"] = res
            reclaim = (res.get("reclaim") or {}) if isinstance(res, dict) else {}
            item["freedMb"] = int(reclaim.get("freedMb") or 0) + int(entry.get("diskMb") or 0)
            if reclaim.get("errors"):
                item["reclaimErrors"] = reclaim["errors"]
            if not item["removed"]:
                item["reason"] = json.dumps(root_res, ensure_ascii=False)[:200]
        except Exception as exc:
            item["reason"] = str(exc)[-300:]
        results.append(item)
    return results


# ── 자동 정리(데몬) ─────────────────────────────────────────────────────────────
# 형(2026-09-17): "워크트리 남은 건 까먹을 것 같다 — 7일 사용 안 한 거 자동 gc". 판정·가드는 대시보드 일괄 정리와 같다
# (세션·프로세스 0 + 커밋·파일 7일↑, 미push 커밋은 backup/ 브랜치로 보존, 진짜 미커밋 파일 있으면 제외).
# 자동이라 다른 점 두 가지: ① 명명 볼륨은 캐시성만 지운다(개발 DB 보존) ② 한 번에 AUTO_MAX 개까지만 — 발견이 잘못돼
# 멀쩡한 워크트리가 한꺼번에 유휴로 보이는 사고의 폭을 제한한다(남은 건 다음 주기에).
AUTO_MAX_PER_RUN = int(_env("WORKTREE_AUTO_MAX", "5"))
AUTO_STATE_FILE = MARINA_HOME / "worktree-gc-state.json"


def _auto_state() -> dict[str, Any]:
    try:
        data = json.loads(AUTO_STATE_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def auto_tick(port: int, now: float | None = None, primary: bool | None = None,
              plan_fn=None, remove_fn=None) -> str:
    """데몬 루프 한 틱. 예외를 밖으로 안 낸다. 도커 GC 와 같은 정책 파일(worktree_auto_days, interval_hours)·같은 '기록된
    데몬만' 규칙을 쓴다 — 격리 프리뷰가 실 워크트리를 지우면 안 된다. plan_fn/remove_fn 은 테스트 이음매."""
    import marina_docker_gc as dgc
    now = time.time() if now is None else now
    try:
        if primary is None:
            recorded = dgc.recorded_daemon_port()
            primary = recorded is not None and recorded == int(port)
        if not primary:
            return "skipped:not-primary"
        policy = dgc.load_policy()
        days = int(policy.get("worktree_auto_days") or 0)
        if not policy.get("enabled", True) or days <= 0:
            return "skipped:off"
        prev = _auto_state()
        last = prev.get("finishedAt")
        if isinstance(last, (int, float)) and now < float(last) + float(policy.get("interval_hours") or 24) * 3600:
            return "skipped:not-due"
        plan_fn = plan_fn or gc_plan
        remove_fn = remove_fn or gc_remove
        eligible = [e for e in plan_fn(days, apply=False, refresh=True, strict=True) if e.get("eligible")]
        eligible.sort(key=lambda e: -(e.get("gcIdleDays") or 0))       # 오래 쉰 것부터
        picked = eligible[:max(0, AUTO_MAX_PER_RUN)]
        when = datetime.fromtimestamp(now, timezone.utc).astimezone().isoformat(timespec="seconds")
        if not prev.get("armedAt"):
            # 첫 실행은 **예고만**(코드리뷰): 켜자마자(배포 60초 뒤) 지우지 않고, 다음 주기에 지울 목록을 기록해 보여준다.
            armed = {"armedAt": now, "finishedAt": now, "days": days, "removed": 0, "freedMb": 0, "eligible": len(eligible),
                     "wouldRemove": [{"id": e.get("id"), "root": e.get("root"), "idleDays": e.get("gcIdleDays")} for e in picked]}
            try:
                dgc._atomic_write_json(AUTO_STATE_FILE, armed)
            except OSError:
                pass
            dgc._append_log(f"{when} worktree  armed — 다음 주기부터 자동 삭제, 지금 기준 대상 {len(picked)}개 "
                            f"[{', '.join(str(e.get('id')) for e in picked) or '-'}]")
            return f"armed:{len(picked)}"
        results = remove_fn([Path(e["root"]) for e in picked], days, volumes="cache", strict=True) if picked else []
        removed = [r for r in results if r.get("removed")]
        freed = sum(int(r.get("freedMb") or 0) for r in removed)
        backups = [b for r in removed for b in (r.get("backups") or [])]
        state = {"armedAt": prev.get("armedAt"), "finishedAt": now, "days": days, "eligible": len(eligible), "removed": len(removed),
                 "deferred": max(0, len(eligible) - len(picked)), "freedMb": freed,
                 "items": [{"id": r.get("id"), "root": r.get("root"), "removed": bool(r.get("removed")),
                            "freedMb": int(r.get("freedMb") or 0), "reason": r.get("reason"),
                            "backups": [f"{b.get('repo')}:{b.get('branch')}" for b in (r.get("backups") or [])],
                            "keptVolumes": ((r.get("result") or {}).get("reclaim") or {}).get("keptVolumes", [])}
                           for r in results]}
        try:
            dgc._atomic_write_json(AUTO_STATE_FILE, state)
        except OSError:
            pass
        names = ", ".join(str(r.get("id")) for r in removed) or "-"
        line = (f"{when} worktree  removed {len(removed)}/{len(eligible)} idle>{days}d  freed {dgc.fmt_mb(freed)}  [{names}]"
                + (f"  backups {len(backups)}" if backups else "") + (f"  deferred {state['deferred']}" if state["deferred"] else ""))
        failed = [r for r in results if not r.get("removed")]
        if failed:
            line += "  SKIPPED " + "; ".join(f"{r.get('id')}: {str(r.get('reason') or '')[:80]}" for r in failed)
        dgc._append_log(line)
        return f"ran:{len(removed)}"
    except Exception as exc:
        try:
            dgc._append_log(f"{datetime.now().astimezone().isoformat(timespec='seconds')} worktree  FAILED {exc}")
        except Exception:
            pass
        return f"failed:{exc}"


# ── CLI ──────────────────────────────────────────────────────────────────────

def _fmt_gb(mb: Any) -> str:
    try:
        return f"{float(mb or 0) / 1024:.1f}GB"
    except (TypeError, ValueError):
        return "?"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="marina worktree gc",
                                 description="유휴 워크트리 판정 + 삭제 전 가드. 삭제는 하지 않는다(대시보드 '유휴 정리'에서 골라서).")
    ap.add_argument("--days", type=int, default=GC_DAYS_DEFAULT, help=f"유휴 기준 일수(기본 {GC_DAYS_DEFAULT})")
    ap.add_argument("--dry-run", action="store_true", help="가드를 적용하지 않고 계획만(백업 브랜치를 만들지 않는다)")
    ap.add_argument("--json", action="store_true", help="JSON 출력")
    args = ap.parse_args(argv)
    entries = gc_plan(args.days, apply=not args.dry_run, refresh=True)
    if args.json:
        print(json.dumps({"days": args.days, "dryRun": bool(args.dry_run), "items": entries}, ensure_ascii=False, indent=2))
        return 0
    if not entries:
        print(f"유휴 워크트리 없음 (기준 {args.days}일)")
        return 0
    print(f"유휴 워크트리 {len(entries)}개 (기준 {args.days}일){' — dry-run: 백업 브랜치 안 만듦' if args.dry_run else ''}")
    total = 0
    for e in entries:
        mark = "✓" if e.get("eligible") else "✗"
        label = e.get("alias") or e.get("id")
        print(f"  {mark} {label}  유휴 {e.get('gcIdleDays')}일 · 디스크 {_fmt_gb(e.get('diskMb'))} · 이미지 {_fmt_gb(e.get('imageMb'))}  {e['root']}")
        for b in e.get("backups") or []:
            state = "생성" if b.get("created") else ("실패: " + b["error"] if b.get("error") else "계획")
            print(f"      ↳ 보존 {b.get('subrepo') or 'root'} → {b['branch']} ({b.get('why')}) [{state}]")
        for r in e.get("reasons") or []:
            print(f"      ✗ {r}")
        if e.get("eligible"):
            total += int(e.get("diskMb") or 0) + int(e.get("imageMb") or 0)
    print(f"삭제 가능 회수 예상 {_fmt_gb(total)} — 삭제는 대시보드 🧹 유휴 정리에서 골라서 한 번에")
    return 0


if __name__ == "__main__":
    sys.exit(main())
