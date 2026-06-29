"""marina_sessions.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
from __future__ import annotations
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
import importlib.util as _ilu

from marina_state import CODEX_HOME, PORT, _codex_titles_cache, _env, _session_titles_cache, _status_cache, _total_mem_mb_cache, _worktree_info_cache
from marina_logtext import redact_text
from marina_cache import cache_category_mb, disk_usage_mb
from marina_registry import default_attach_of, discover_all_roots, discover_roots, is_source_checkout, project_for, project_label, root_source, subrepos_of
from marina_paths import ensure_current_log, log_run_payload, read_config, read_meta, session_dir, session_id
from marina_compose_svc import _compose_services, compose_service_names

def git_output(args: list[str], cwd: Path) -> str:
    return subprocess.check_output(["git", *args], cwd=str(cwd), text=True, stderr=subprocess.STDOUT)

def status_lines(repo: Path, ignore_top_level: set[str] | None = None) -> list[str]:
    try:
        output = git_output(["status", "--porcelain", "--untracked-files=all"], repo)
    except Exception as exc:
        return [f"!! git status failed: {exc}"]
    lines: list[str] = []
    for line in output.splitlines():
        path = line[3:] if len(line) > 3 else ""
        top = path.split("/", 1)[0]
        if ignore_top_level and top in ignore_top_level:
            continue
        lines.append(line)
    return lines

def _repo_status_entry(name: str, path: Path, lines: list[str]) -> dict[str, Any]:
    # git status 가 실패(깨진/고아 워크트리 — gitfile dangling 등)하면 status_lines 가 '!! git status failed' 한 줄을 돌려준다.
    # 이건 '미커밋 변경분' 이 아니라 '확인 불가' 다 → dirty 로 세지 않고 broken 으로 구분(폐기할 변경 없음 → 삭제 시 안 겁줌).
    if lines and lines[0].startswith("!! git status failed"):
        return {"name": name, "path": str(path), "broken": True, "dirty": False,
                "changes": ["(git 링크 깨짐 — 고아 워크트리, 폐기할 변경 없음)"],
                "changeCount": 0, "trackedCount": 0, "untrackedCount": 0}
    untracked = sum(1 for ln in lines if ln.startswith("??"))
    # tracked(실제 수정) 와 untracked(주로 .venv·빌드산출물 등 툴링 찌꺼기) 분리 — 칩이 신호/노이즈를 섞지 않게
    return {"name": name, "path": str(path), "broken": False, "dirty": bool(lines),
            "changes": lines[:80], "changeCount": len(lines),
            "trackedCount": len(lines) - untracked, "untrackedCount": untracked}

def worktree_status(root: Path) -> dict[str, Any]:
    repos: list[dict[str, Any]] = []
    subrepos = subrepos_of(root)
    repos.append(_repo_status_entry(project_label(root), root, status_lines(root, {*subrepos, ".workspace"})))
    for repo in subrepos:
        path = root / repo
        if not path.exists():
            repos.append({"name": repo, "path": str(path), "missing": True, "broken": False,
                          "dirty": False, "changes": [], "changeCount": 0, "trackedCount": 0, "untrackedCount": 0})
            continue
        repos.append(_repo_status_entry(repo, path, status_lines(path)))
    dirty = [item for item in repos if item.get("dirty")]
    return {"clean": not dirty, "broken": any(r.get("broken") for r in repos), "repos": repos}

def system_memory() -> dict[str, Any]:
    info: dict[str, Any] = {"totalMb": None, "freePercent": None, "freeMb": None}
    if not _total_mem_mb_cache:
        try:
            total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True, stderr=subprocess.DEVNULL).strip())
            _total_mem_mb_cache.append(total // (1024 * 1024))
        except Exception:
            return info
    info["totalMb"] = _total_mem_mb_cache[0]
    try:
        output = subprocess.check_output(["memory_pressure", "-Q"], text=True, stderr=subprocess.DEVNULL)
        match = re.search(r"free percentage:\s*(\d+)", output)
        if match:
            info["freePercent"] = int(match.group(1))
            info["freeMb"] = info["totalMb"] * info["freePercent"] // 100
    except Exception:
        pass
    return info

def group_rss_mb(snapshot: list[dict[str, Any]], pids: set[int]) -> int:
    # 추적 pid 들이 속한 프로세스 그룹 전체의 RSS 합 (MB)
    if not pids:
        return 0
    pgids = {row["pgid"] for row in snapshot if row["pid"] in pids}
    total_kb = 0
    for row in snapshot:
        if row["pid"] in pids or row["pgid"] in pgids:
            total_kb += row["rssKb"]
    return total_kb // 1024

def worktree_status_cached(root: Path, ttl: float = 15.0) -> dict[str, Any]:
    # dirty 표시는 5초 신선도가 필요 없다 — git status(레포 4개)를 폴링 핫패스에서 떼어냄.
    # 정확성이 필요한 경로(remove 가드·Changes 조회)는 worktree_status 직접 호출.
    key = str(root)
    cached = _status_cache.get(key)
    if cached and time.time() - cached[0] < ttl:
        return cached[1]
    status = worktree_status(root)
    _status_cache[key] = (time.time(), status)
    return status

def log_targets_for(root: Path) -> tuple[str, ...]:
    project = project_for(root)
    if project and project.get("kind") == "compose":
        return (*compose_service_names(root, project), "console")
    return ("console",)

def session_payload(root: Path) -> dict[str, Any]:
    project = project_for(root)
    kind = (project or {}).get("kind", "compose")
    services = _compose_services(root, project) if kind == "compose" else []
    return {
        "id": session_id(root),
        "alias": read_meta(root).get("alias", ""),
        "source": root_source(root),
        "projectId": (project or {}).get("id") or root_source(root),   # 게이트웨이 도메인(<wt>.<proj>.localhost) 계산용 — _gateway_snapshot 과 동일 pid
        "root": str(root),
        "ports": {},
        "kind": kind,
        "config": read_config(root),
        "worktreeStatus": worktree_status_cached(root),
        "services": services,
        "consoleLogRuns": log_run_payload(root, "console"),
    }

def safe_root(root_text: str) -> Path:
    root = Path(root_text).expanduser().resolve()
    allowed = {r.resolve() for r in discover_all_roots()}
    if root not in allowed:
        # 생성 60s 내 새 worktree 가 discover 캐시에 없어 액션이 거부되는 엣지 — 1회 강제 재탐색
        allowed = {r.resolve() for r in discover_all_roots(refresh=True)}
    if root not in allowed:
        raise ValueError("unknown worktree root")
    return root

def safe_service(service: str, root: Path) -> str:
    if service not in log_targets_for(root):
        raise ValueError("unknown service")
    return service

def origin_allowed(origin: str | None, allow_any_local_port: bool) -> bool:
    # Origin 없음(curl·same-origin GET) 은 허용. 그 외에는 localhost 만,
    # 제어 엔드포인트는 대시보드 자신의 포트만 허용 (임의 웹사이트의 CSRF 차단).
    if not origin:
        return True
    try:
        parts = urllib.parse.urlsplit(origin)
    except ValueError:
        return False
    if parts.hostname not in ("127.0.0.1", "localhost", "::1"):
        return False
    if allow_any_local_port:
        return True
    return parts.port == PORT

def root_for_session_id(value: str) -> Path:
    for root in discover_roots():
        if session_id(root) == value:
            return root
    raise ValueError("unknown session")

def append_console_log(payload: dict[str, Any]) -> dict[str, Any]:
    root = root_for_session_id(str(payload.get("session", "")))
    path = ensure_current_log(root, "console")
    path.parent.mkdir(parents=True, exist_ok=True)

    level = str(payload.get("level", "log"))
    url = str(payload.get("url", ""))
    timestamp = str(payload.get("timestamp", ""))
    args = payload.get("args")
    if not isinstance(args, list):
        args = []

    message = " ".join(redact_text(str(item)) for item in args)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"[{timestamp}] [{level}] {url}\n")
        if message:
            handle.write(message + "\n")
        handle.write("\n")

    return {"ok": True}

WORKTREE_INFO_TTL = 600.0

# Claude 데스크톱 앱의 세션 타이틀 — worktree 정체성으로 사용 (LLM 자동생성, 유저 수정 가능).
# CLI(터미널 claude)는 이 파일을 안 만들므로 비어 있으면 headSubject→해시 폴백.
CLAUDE_SESSIONS_DIR = Path(os.environ.get(
    "CLAUDE_DESKTOP_SESSIONS_DIR",
    str(Path.home() / "Library" / "Application Support" / "Claude" / "claude-code-sessions"),
))

SESSION_TITLES_TTL = 20.0

def claude_session_titles(refresh: bool = False) -> dict[str, dict[str, str]]:
    # worktreePath → {"title", "titleSource"}. 데스크톱 앱 세션 메타(local_*.json)에서.
    # 폴링 핫패스 보호: TTL 캐시. 같은 worktree 다중 세션이면 lastActivityAt 최신 채택.
    global _session_titles_cache
    now = time.time()
    if not refresh and now - _session_titles_cache[0] < SESSION_TITLES_TTL:
        return _session_titles_cache[1]
    titles: dict[str, dict[str, str]] = {}
    best_ts: dict[str, float] = {}
    if CLAUDE_SESSIONS_DIR.is_dir():
        for path in glob.iglob(str(CLAUDE_SESSIONS_DIR / "**" / "local_*.json"), recursive=True):
            try:
                data = json.loads(Path(path).read_text(encoding="utf-8"))
            except Exception:
                continue
            wt = data.get("worktreePath")
            title = (data.get("title") or "").strip()
            if not wt or not title:
                continue
            ts = float(data.get("lastActivityAt") or data.get("createdAt") or 0)
            if wt in best_ts and best_ts[wt] >= ts:
                continue
            best_ts[wt] = ts
            titles[wt] = {"title": title, "titleSource": data.get("titleSource") or ""}
    _session_titles_cache = (now, titles)
    return titles

# Codex 세션 타이틀 — codex worktree(detached HEAD)는 브랜치명이 없어 정체성이 특히 약하다.
# 체인: worktree cwd → rollout session_meta(line0 의 cwd+id) → session_index.jsonl 의 thread_name.
CODEX_SESSION_INDEX = CODEX_HOME / "session_index.jsonl"

CODEX_ROLLOUT_DIRS = (CODEX_HOME / "sessions", CODEX_HOME / "archived_sessions")

CODEX_TITLES_TTL = 60.0

CODEX_ROLLOUT_MAX_AGE = 45 * 86400  # 오래된 세션은 스캔 제외 — 히스토리 누적돼도 비용 상한

def codex_session_titles(refresh: bool = False) -> dict[str, str]:
    # worktree cwd(=marina root) → thread_name. rollout 헤더 스캔이 무거워 TTL 60s 캐시 + mtime 필터.
    global _codex_titles_cache
    now = time.time()
    if not refresh and now - _codex_titles_cache[0] < CODEX_TITLES_TTL:
        return _codex_titles_cache[1]
    names: dict[str, str] = {}  # session id → thread_name
    try:
        with CODEX_SESSION_INDEX.open(encoding="utf-8") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                # codex thread_name 은 깔끔한 요약일 때도, raw 첫 메시지(길거나 잡스러움)일 때도 있어 상한만 둔다.
                tid, tn = o.get("id"), (o.get("thread_name") or "").strip()
                if tid and tn:
                    names[tid] = tn[:120]
    except Exception:
        pass
    best: dict[str, tuple[str, str]] = {}  # cwd → (timestamp, session id) 최신
    cutoff = now - CODEX_ROLLOUT_MAX_AGE
    for base in CODEX_ROLLOUT_DIRS:
        if not base.is_dir():
            continue
        for path in glob.iglob(str(base / "**" / "rollout-*.jsonl"), recursive=True):
            try:
                if os.path.getmtime(path) < cutoff:
                    continue
                with open(path, encoding="utf-8") as fh:
                    o = json.loads(fh.readline())
            except Exception:
                continue
            if o.get("type") != "session_meta":
                continue
            p = o.get("payload") or {}
            cwd, sid, ts = p.get("cwd"), p.get("id"), str(p.get("timestamp") or "")
            if not cwd or not sid:
                continue
            cur = best.get(cwd)
            if cur is None or ts > cur[0]:
                best[cwd] = (ts, sid)
    titles = {cwd: names[sid] for cwd, (ts, sid) in best.items() if sid in names}
    _codex_titles_cache = (now, titles)
    return titles

def repo_head_subject(repo: Path) -> str:
    # 최신 커밋 제목 — 세션 타이틀 없을 때(CLI/codex) 카드 식별 폴백.
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "log", "-1", "--format=%s"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return out.strip()
    except Exception:
        return ""

def repo_last_commit_ts(repo: Path) -> int:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "log", "-1", "--format=%ct"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return int(out.strip() or "0")
    except Exception:
        return 0

def repo_branch(repo: Path) -> str:
    # detached HEAD(codex worktree 루트 기본 상태)는 빈 문자열
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "branch", "--show-current"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return out.strip()
    except Exception:
        return ""

def repo_ahead_of_main(repo: Path) -> int | None:
    # 이 worktree 가 "생성된 이후" 쌓은 커밋 수 (= 이 세션의 미머지 작업). main 없으면 None.
    # main..HEAD 는 worktree 생성 시 물려받은 공유 base 까지 세어 모든 카드에 같은 유령이 깔린다 →
    # reflog 기반 fork-point 를 생성 시점 기준으로 삼아 이 세션 커밋만 센다 (실패 시 main..HEAD 폴백).
    try:
        subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "--verify", "main"],
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return None
    base = "main"
    branch = repo_branch(repo)
    if branch and branch != "main":
        try:
            fp = subprocess.check_output(
                ["git", "-C", str(repo), "merge-base", "--fork-point", "main", branch],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()
            if fp:
                base = fp
        except Exception:
            pass
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "rev-list", "--count", f"{base}..HEAD"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return int(out.strip())
    except Exception:
        return None

def worktree_info(root: Path, refresh: bool = False) -> dict[str, Any]:
    key = str(root)
    cached = _worktree_info_cache.get(key)
    if cached and not refresh and time.time() - cached[0] < WORKTREE_INFO_TTL:
        return cached[1]

    is_main = is_source_checkout(root)
    subs = subrepos_of(root)
    # 물리 attach 상태(fs 판정). main 체크아웃은 원본 클론이라 전부 attach 로 본다.
    attached_subrepos = list(subs) if is_main else [s for s in subs if (root / s / ".git").exists()]
    default_explicit = default_attach_of(root)
    status = worktree_status(root)
    last_ts = 0
    ahead: dict[str, int] = {}
    branches: dict[str, str] = {}
    # claude worktree 는 서브레포가 없는 경우가 많아 root 레포도 활동·ahead 에 포함
    repos_to_scan = [(project_label(root), root)] + [(name, root / name) for name in subrepos_of(root)]
    for repo_name, repo in repos_to_scan:
        if not (repo / ".git").exists():
            continue
        last_ts = max(last_ts, repo_last_commit_ts(repo))
        count = repo_ahead_of_main(repo)
        if count is not None:
            ahead[repo_name] = count
        branch = repo_branch(repo)
        if branch:
            branches[repo_name] = branch
    sdir = session_dir(root)
    if sdir.exists():
        try:
            last_ts = max(last_ts, int(sdir.stat().st_mtime))
        except OSError:
            pass

    ahead_total = sum(ahead.values())
    idle_days = round((time.time() - last_ts) / 86400, 1) if last_ts else None
    stale_days = float(_env("STALE_DAYS", "7"))
    if is_main:
        verdict = "main"
    elif not status["clean"]:
        verdict = "dirty"
    elif ahead_total > 0:
        verdict = "has-commits"
    elif idle_days is not None and idle_days >= stale_days:
        verdict = "stale"
    else:
        verdict = "active"

    cache_by_cat = cache_category_mb(root)
    project = project_for(root)
    info = {
        "id": session_id(root),
        "alias": read_meta(root).get("alias", ""),
        # 카드 제목 폴백 — 세션 타이틀(앱) 없을 때 "무슨 작업인지" 식별용 최신 커밋 제목
        "headSubject": repo_head_subject(root),
        "source": root_source(root),
        "root": str(root),
        # 프로젝트 식별 — 대시보드 좌측 패널 그룹핑 키 (멀티프로젝트)
        "projectId": project["id"] if project else project_label(root),
        "projectLabel": project_label(root),
        "projectRoot": str(project["root"]) if project else str(root),
        # 레지스트리에 등록된 subrepos(큐레이션된 집합) — switcher "subrepos 편집" 프리필용. fs 의 universe(infer)와 구분.
        "subrepos": list(project["subrepos"]) if project else [],
        # 이 worktree 에 물리 attach 된 subrepo (fs 판정; main 은 전부). 클라이언트 트리 attach 상태원.
        "attachedSubrepos": attached_subrepos,
        # 전체 기본 attach 집합 — 명시값 없으면 universe(=전부). main 카드 "기본" 토글 프리필.
        "defaultAttach": default_explicit if default_explicit is not None else list(subs),
        "isMain": is_main,
        "clean": status["clean"],
        # main 체크아웃 전체 du 는 수백 GB 라 비싸고 UI 에서도 안 씀 → 스킵
        "diskMb": None if is_main else disk_usage_mb(root),
        # 캐시는 후보 경로 한정 du(실측 ~0.1s) + TTL 600s — main 도 계산해 Clear cache 노출
        "cacheMb": sum(cache_by_cat.values()),
        "cacheCats": cache_by_cat,
        "idleDays": idle_days,
        "ahead": ahead,
        "aheadTotal": ahead_total,
        "branches": branches,
        "verdict": verdict,
    }
    _worktree_info_cache[key] = (time.time(), info)
    return info
