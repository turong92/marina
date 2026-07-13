"""marina_git.py — 깃 그래프 패널 백엔드.
spec: docs/superpowers/specs/2026-07-02-git-graph-panel-design.md, 2026-07-11-console-phase2-master.md(P2)
서브레포는 git worktree attach 라 main 체크아웃과 객체DB 를 공유 → 커밋 로그는
'레포당 main 체크아웃 하나' 에서 전 브랜치를 얻고, 브랜치/dirty 는 워크트리별로 얻는다.
git_graph/git_diff 는 읽기 전용. git_commit/git_push(P2) 만 실제로 git 상태를 바꾼다 —
둘 다 main 체크아웃 거부(is_source_checkout)·force/amend 없음·저장소 상대경로만 허용."""
from __future__ import annotations
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from marina_registry import discover_all_roots, is_source_checkout, source_root_for, subrepos_of
from marina_sessions import repo_branch, worktree_info, worktree_status

_GRAPH_TTL = 15.0
_graph_cache: dict[str, tuple[float, dict[str, Any]]] = {}
MAX_DIFF_BYTES = 200_000
_HASH_RE = re.compile(r"[0-9a-f]{7,40}")


def _git(args: list[str], cwd: Path, timeout: float = 5.0, ok_codes: tuple[int, ...] = (0,)) -> str:
    proc = subprocess.run(["git", "-C", str(cwd), *args],
                          capture_output=True, text=True, timeout=timeout)
    if proc.returncode not in ok_codes:
        msg = (proc.stderr or proc.stdout).strip().splitlines()
        raise RuntimeError(msg[-1] if msg else f"git {args[0]} failed")
    return proc.stdout


def repo_names_for(main: Path) -> list[str]:
    # '.'(root 레포) + 등록 서브레포. external 은 체크아웃 경로가 달라(.workspace/external) 1단계 제외.
    return ["."] + subrepos_of(main)


def _checkout_of(root: Path, repo: str) -> Path:
    if repo == ".":
        return root
    p = Path(repo)
    # 등록값 방어 — subrepo 명이 절대경로/.. 를 담고 있어도 체크아웃 경계 밖으로 못 나가게
    if p.is_absolute() or ".." in p.parts:
        raise ValueError("bad repo")
    return root / repo


def git_graph(any_root: Path, repo: str, refresh: bool = False) -> dict[str, Any]:
    main = source_root_for(any_root).resolve()
    repos = [r for r in repo_names_for(main) if (_checkout_of(main, r) / ".git").exists()]
    if repo not in repos:
        raise ValueError("unknown repo")
    key = f"{main}::{repo}"
    cached = _graph_cache.get(key)
    if cached and not refresh and time.time() - cached[0] < _GRAPH_TTL:
        return cached[1]

    main_co = _checkout_of(main, repo)
    main_branch = repo_branch(main_co) or "main"

    def _branch_entry(root: Path) -> dict[str, Any] | None:
        # root 당 git subprocess 다발(rev-parse·status·merge-base·info) — 병렬 프리컴퓨트용 워커
        if source_root_for(root).resolve() != main:
            return None
        co = _checkout_of(root, repo)
        if not (co / ".git").exists():
            return None
        try:
            head = _git(["rev-parse", "HEAD"], co).strip()
        except (RuntimeError, subprocess.TimeoutExpired):
            return None   # 깨진/고아 워크트리 — 세션 카드가 broken 을 이미 표시, 그래프에선 제외
        branch = repo_branch(co)
        info = worktree_info(root, refresh)
        status_repo = next((r for r in worktree_status(root)["repos"]
                            if Path(r["path"]).resolve() == co.resolve()), None)
        merged = False
        if branch and branch != main_branch:
            rc = subprocess.run(
                ["git", "-C", str(main_co), "merge-base", "--is-ancestor", head, main_branch],
                capture_output=True, timeout=5).returncode
            merged = rc == 0
        # 원격 상태 — upstream 없음=로컬 전용, 있으면 미푸시(↑)/미당김(↓) 카운트 (local/remote 구분, 형)
        upstream = False
        ahead_r = behind_r = 0
        if branch:
            u = subprocess.run(["git", "-C", str(co), "rev-parse", "--abbrev-ref", "@{u}"],
                               capture_output=True, text=True, timeout=5)
            if u.returncode == 0:
                upstream = True
                try:
                    lr = _git(["rev-list", "--left-right", "--count", "@{u}...HEAD"], co).strip().split()
                    behind_r, ahead_r = int(lr[0]), int(lr[1])
                except Exception:
                    pass
        wt_branches = info.get("branches", {})
        mismatch = ([f"{k}={v}" for k, v in wt_branches.items() if v != branch]
                    if branch and len(set(wt_branches.values())) > 1 else [])
        # attach 됐지만 브랜치 미보고(detached 서브레포)도 불일치 — branches 에 안 잡히므로 fs 로 보강
        if branch:
            for sub in info.get("attachedSubrepos", []):
                if sub not in wt_branches and ((root / sub) / ".git").exists():
                    mismatch.append(f"{sub}=(detached)")
        return {
            "branch": branch or head[:7], "detached": not branch, "head": head,
            "root": str(root), "alias": info.get("alias") or info.get("id"),
            "isMain": root.resolve() == main,
            "dirtyCount": (status_repo or {}).get("changeCount", 0),
            "untrackedCount": (status_repo or {}).get("untrackedCount", 0),
            "merged": merged, "mismatch": mismatch,
            "upstream": upstream, "aheadRemote": ahead_r, "behindRemote": behind_r,
        }

    # root 별 작업은 독립 — 병렬 프리컴퓨트(직렬 ~5s → ~1s 실측), 중복 제거만 원래 순서(main 우선)로 직렬
    roots = sorted(discover_all_roots(refresh), key=lambda r: r.resolve() != main)
    with ThreadPoolExecutor(max_workers=8) as pool:
        entries = list(pool.map(_branch_entry, roots))
    branches: list[dict[str, Any]] = []
    seen: set[str] = set()   # 같은 브랜치를 보는 체크아웃 중복 방지 (main 우선)
    for e in entries:
        if e is None or e["branch"] in seen:
            continue
        seen.add(e["branch"])
        branches.append(e)

    # 원격 브랜치(remote 커밋 가시화 — 형: d&d 푸시 기반). 로컬 브랜치의 origin 카운터파트 + origin/<main>만
    # (전체 origin/* 는 장수 레포에서 수십 개 — 화면 소음). 미푸시/미당김이면 head 가 달라 별도 커밋 행이 생긴다.
    local_names = {b["branch"] for b in branches}
    try:
        refs_out = _git(["for-each-ref", "--format=%(refname:short)\x1f%(objectname)", "refs/remotes/origin"], main_co)
    except (RuntimeError, subprocess.TimeoutExpired):
        refs_out = ""
    for rec in refs_out.strip().splitlines():
        try:
            rname, rhead = rec.split("\x1f")
        except ValueError:
            continue
        short = rname[len("origin/"):]
        if rname == "origin/HEAD" or (short not in local_names and short != main_branch):
            continue
        branches.append({"branch": rname, "remote": True, "detached": False, "head": rhead,
                         "root": str(main), "alias": "", "isMain": False,
                         "dirtyCount": 0, "untrackedCount": 0, "merged": False, "mismatch": [],
                         "upstream": True, "aheadRemote": 0, "behindRemote": 0})

    commits: list[dict[str, Any]] = []
    heads = sorted({b["head"] for b in branches})
    if heads:
        out = _git(["log", "--topo-order", "-n", "200",
                    "--format=%H%x1f%P%x1f%s%x1f%ct%x1f%an%x1e", *heads], main_co, timeout=10.0)
        for rec in out.split("\x1e"):
            rec = rec.strip("\n")
            if not rec:
                continue
            h, parents, subject, ts, author = rec.split("\x1f")
            commits.append({"hash": h, "parents": parents.split(),
                            "subject": subject, "ts": int(ts), "author": author})

    payload = {"repo": repo, "repos": repos, "mainRoot": str(main),
               "mainBranch": main_branch, "branches": branches, "commits": commits}
    _graph_cache[key] = (time.time(), payload)
    return payload


def _invalidate_graph_cache(main: Path) -> None:
    # 커밋/푸시로 브랜치·HEAD·dirty 가 바뀌면 그 main 소속 캐시 전부(레포 탭별) 무효화.
    prefix = f"{main}::"
    for key in [k for k in _graph_cache if k.startswith(prefix)]:
        del _graph_cache[key]


def _resolve_write_checkout(root: Path, repo: str) -> tuple[Path, Path]:
    # commit/push 공용 검증 — repo 존재 확인. (main, co) 반환. main 체크아웃 커밋도 허용(형 확정 2026-07-13 —
    # 브랜치는 그래프에 보이고, 원치 않는 main 직커밋은 팀 규약 영역이지 도구가 막을 일 아님)
    main = source_root_for(root).resolve()
    if repo not in repo_names_for(main):
        raise ValueError("unknown repo")
    co = _checkout_of(root, repo)
    if not (co / ".git").exists():
        raise ValueError("repo not checked out")
    return main, co


def git_commit(root: Path, repo: str, files: list[str], message: str) -> dict[str, Any]:
    main, co = _resolve_write_checkout(root, repo)
    message = (message or "").strip()
    if not message:
        raise ValueError("커밋 메시지가 필요합니다")
    if not files or not isinstance(files, list):
        raise ValueError("커밋할 파일을 선택하세요")
    base = co.resolve()
    clean: list[str] = []
    for f in files:
        f = str(f)
        p = Path(f)
        if not f or p.is_absolute() or ".." in p.parts:
            raise ValueError(f"bad path: {f}")
        target = (base / f).resolve()
        if target != base and base not in target.parents:
            raise ValueError(f"bad path: {f}")
        clean.append(f)
    _git(["add", "--", *clean], co, timeout=10.0)
    _git(["commit", "-m", message], co, timeout=10.0)   # identity 미설정 등은 stderr 그대로 RuntimeError 로 전달
    h = _git(["rev-parse", "HEAD"], co, timeout=5.0).strip()
    summary = _git(["log", "-1", "--format=%s", h], co, timeout=5.0).strip()
    _invalidate_graph_cache(main)
    return {"ok": True, "hash": h, "summary": summary}


def git_push(root: Path, repo: str, force: bool = False) -> dict[str, Any]:
    main, co = _resolve_write_checkout(root, repo)
    branch = repo_branch(co)
    if not branch:
        raise ValueError("detached HEAD 는 푸시할 수 없습니다")
    has_upstream = subprocess.run(
        ["git", "-C", str(co), "rev-parse", "--abbrev-ref", f"{branch}@{{upstream}}"],
        capture_output=True, text=True, timeout=5.0).returncode == 0
    # refspec 명시 — push.default=matching 등 사용자 설정과 무관하게 "현재 브랜치 하나"만(codex P1)
    args = ["push", "origin", branch] if has_upstream else ["push", "-u", "origin", branch]
    if force:
        args.insert(1, "--force-with-lease")   # 원격이 마지막으로 본 상태일 때만 덮어씀 — 남의 커밋 보호
    proc = subprocess.run(["git", "-C", str(co), *args], capture_output=True, text=True, timeout=30.0)
    tail = "\n".join(((proc.stdout or "") + (proc.stderr or "")).strip().splitlines()[-20:])
    if proc.returncode != 0:
        raise RuntimeError(tail or "git push failed")
    _invalidate_graph_cache(main)
    return {"ok": True, "output": tail}


def git_pull(root: Path, repo: str) -> dict[str, Any]:
    """D&D 당겨오기 — ff-only 만(히스토리 안 꼬임). 갈라졌으면 에러로 안내하고 사람이 결정."""
    main, co = _resolve_write_checkout(root, repo)
    branch = repo_branch(co)
    if not branch:
        raise ValueError("detached HEAD 는 pull 할 수 없습니다")
    proc = subprocess.run(["git", "-C", str(co), "pull", "--ff-only"], capture_output=True, text=True, timeout=30.0)
    tail = "\n".join(((proc.stdout or "") + (proc.stderr or "")).strip().splitlines()[-20:])
    if proc.returncode != 0:
        raise RuntimeError(tail or "git pull --ff-only failed")
    _invalidate_graph_cache(main)
    return {"ok": True, "output": tail}


def git_merge(root: Path, repo: str, branch: str) -> dict[str, Any]:
    """D&D 병합 — root(타깃 브랜치 워크트리)에서 `git merge <branch>`. 충돌이면 자동 abort 후 에러."""
    if not branch or branch.startswith("-") or not re.fullmatch(r"[A-Za-z0-9._/-]+", branch):
        raise ValueError("invalid branch name")
    main, co = _resolve_write_checkout(root, repo)
    target = repo_branch(co)
    if not target:
        raise ValueError("detached HEAD 에는 병합할 수 없습니다")
    def _merging() -> bool:   # 진행 중 병합(충돌 해결 중) 여부
        return subprocess.run(["git", "-C", str(co), "rev-parse", "-q", "--verify", "MERGE_HEAD"],
                              capture_output=True, timeout=5.0).returncode == 0
    if _merging():   # 사용자가 해결 중인 병합을 abort 로 날리면 안 됨(codex P2) — 손대지 않고 거절
        raise ValueError("타깃 워크트리가 이미 병합 진행 중(MERGE_HEAD) — 마무리하거나 중단한 뒤 다시 시도하세요")
    proc = subprocess.run(["git", "-C", str(co), "merge", "--no-edit", branch],
                          capture_output=True, text=True, timeout=30.0)
    tail = "\n".join(((proc.stdout or "") + (proc.stderr or "")).strip().splitlines()[-20:])
    if proc.returncode != 0:
        if _merging():   # 이번 merge 가 만든 충돌 상태만 되돌림 — 다른 실패(dirty 등)는 건드릴 것 없음
            subprocess.run(["git", "-C", str(co), "merge", "--abort"], capture_output=True, text=True, timeout=10.0)
        raise RuntimeError(f"병합 실패 — 자동 되돌림(merge --abort). 충돌은 수동 병합이 필요해요.\n{tail}")
    _invalidate_graph_cache(main)
    return {"ok": True, "output": tail, "target": target}


def git_wip_stat(root: Path, repo: str) -> dict[str, Any]:
    """WIP 상세 패널용 — 워크트리(그 root 자체)의 파일별 +/-(numstat, staged+unstaged) + untracked 목록."""
    co = _checkout_of(root, repo)
    if not (co / ".git").exists():
        raise ValueError("repo not checked out")
    files: list[dict[str, Any]] = []
    for ln in _git(["diff", "--numstat", "HEAD"], co, timeout=10.0).strip().splitlines():
        parts = ln.split("\t")
        if len(parts) == 3:
            files.append({"add": parts[0], "del": parts[1], "name": parts[2], "untracked": False})
    for ln in _git(["ls-files", "--others", "--exclude-standard"], co, timeout=10.0).strip().splitlines():
        if ln:
            files.append({"add": "", "del": "", "name": ln, "untracked": True})
    return {"files": files}


def git_commit_info(any_root: Path, repo: str, commit: str) -> dict[str, Any]:
    """우측 상세 패널용 커밋 메타 — 작성자·시각·전체 메시지·파일별 +/- (numstat). diff 본문은 안 실음(가벼움)."""
    if not re.fullmatch(r"[0-9a-f]{7,40}", commit or ""):
        raise ValueError("bad commit")
    main = source_root_for(any_root).resolve()
    co = _checkout_of(main, repo)
    meta = _git(["show", "-s", "--format=%H%x1f%an%x1f%ct%x1f%B", commit], co)
    h, author, ct, body = meta.split("\x1f", 3)
    files = []
    for ln in _git(["show", "--numstat", "--format=", commit], co, timeout=10.0).strip().splitlines():
        parts = ln.split("\t")
        if len(parts) == 3:
            files.append({"add": parts[0], "del": parts[1], "name": parts[2]})
    return {"hash": h.strip(), "author": author, "ts": int(ct), "body": body.strip(), "files": files}


def git_diff(root: Path, repo: str, file: str = "", commit: str = "") -> dict[str, Any]:
    main = source_root_for(root).resolve()
    if repo not in repo_names_for(main):
        raise ValueError("unknown repo")
    co = _checkout_of(root, repo)
    if not (co / ".git").exists():
        raise ValueError("repo not checked out")
    if file:
        base = co.resolve()
        target = (base / file).resolve()
        if target != base and base not in target.parents:
            raise ValueError("bad path")
    # --no-ext-diff/--no-textconv — repo/global diff 설정의 외부 명령 실행 차단 (읽기 전용 보장)
    harden = ["--no-ext-diff", "--no-textconv"]
    if commit:
        if not _HASH_RE.fullmatch(commit):
            raise ValueError("bad commit")
        text = _git(["show", *harden, commit, *(["--", file] if file else [])], co, timeout=10.0)
    elif file and not _git(["ls-files", "--", file], co).strip():
        # untracked — diff HEAD 에 안 나옴 → /dev/null 대비 (no-index 는 차이 있으면 rc=1 이 정상).
        # 단 status 가 ?? 로 보고하는 파일만 — ignored(.env 등)·.git 내부는 API 로 안 보여줌
        st = _git(["status", "--porcelain", "--untracked-files=all", "--", file], co).strip()
        if not st.startswith("??"):
            raise ValueError("not an untracked file")
        text = _git(["diff", "--no-index", *harden, "--", "/dev/null", file], co, timeout=10.0, ok_codes=(0, 1))
    else:
        text = _git(["diff", *harden, "HEAD", *(["--", file] if file else [])], co, timeout=10.0)
    raw = text.encode("utf-8")
    if len(raw) > MAX_DIFF_BYTES:
        return {"text": raw[:MAX_DIFF_BYTES].decode("utf-8", "ignore"), "truncated": True}
    return {"text": text, "truncated": False}
