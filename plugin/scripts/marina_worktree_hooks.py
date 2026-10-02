"""marina_worktree_hooks.py — Claude Code WorktreeCreate·WorktreeRemove 훅 (runtime, 분리 A).

**왜.** `claude --worktree`·서브에이전트 `isolation: worktree`·백그라운드 세션이 이 훅을 부른다(실측 2026-10-03,
Claude Code 2.1.287). 마리나 프로젝트면 마리나 워크트리(서브레포·포트 격리)로 만들고, 아니면 Claude 기본과 같게 만든다.
플러그인 훅은 **모든 레포**에 걸리므로 마리나 경로가 어떻게 실패해도 기본 동작으로 떨어져야 한다.

- create: 입력 {name, cwd, session_id, …} → stdout 에 경로 한 줄. 기준 브랜치는 입력에 없어 환경변수 MARINA_BASE 로 받는다
  (claude 를 띄울 때 준 환경변수가 훅에 그대로 온다 — 실측).
- remove: 입력 {worktree_path, …}. Claude 는 변경 없는 워크트리면 `/exit` 때 묻지도 않고 부른다(실측) → 남이 잠근 것
  (Discord 세션 등)은 거절(exit 2)해 워크트리를 지킨다. 훅이 거절하면 워크트리는 남는다(실측).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Optional

HERE = Path(__file__).resolve().parent
LOG = Path(os.environ.get("MARINA_HOME") or "~/.marina").expanduser() / "worktree-hook.log"


def _log(line: str) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as fh:
            fh.write(time.strftime("%m-%d %H:%M:%S ") + line + "\n")
    except OSError:
        pass


def _git(cwd: Path, *args: str, check: bool = True) -> str:
    r = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, timeout=120)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {(r.stderr or r.stdout).strip()[-300:]}")
    return r.stdout.strip()


def _main_checkout(cwd: Path) -> Path:
    """cwd 가 속한 레포의 원본(main) 체크아웃 — 워크트리 안에서 불려도 원본 밑에 만든다."""
    common = Path(_git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    return common.parent if common.name == ".git" else Path(_git(cwd, "rev-parse", "--show-toplevel"))


def _marina_project(main: Path) -> Optional[dict[str, Any]]:
    from marina_registry import load_projects
    for p in load_projects():
        try:
            if Path(str(p.get("root") or "")).expanduser().resolve() == main.resolve():
                return p
        except OSError:
            continue
    return None


def _default_create(name: str, cwd: Path, base: str) -> Path:
    """Claude Code 기본과 같다: <repo>/.claude/worktrees/<name>, 브랜치 worktree-<name>."""
    main = _main_checkout(cwd)
    wt = main / ".claude" / "worktrees" / name
    if (wt / ".git").exists():
        return wt
    wt.parent.mkdir(parents=True, exist_ok=True)
    branch = f"worktree-{name}"
    if subprocess.run(["git", "-C", str(main), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"]).returncode == 0:
        _git(main, "worktree", "add", str(wt), branch)
    else:
        start = base or _git(cwd, "rev-parse", "HEAD")
        _git(main, "worktree", "add", "-b", branch, str(wt), start)
    return wt


def _marina_create(name: str, cwd: Path, base: str) -> Optional[Path]:
    main = _main_checkout(cwd)
    proj = _marina_project(main)
    if not proj:
        return None
    wt = main / ".claude" / "worktrees" / re.sub(r"[/:]", "-", name)
    if (wt / ".git").exists():
        return wt
    # 기준 = MARINA_BASE 또는 띄운 자리의 HEAD — 안 주면 worktree create 가 origin/HEAD 를 fetch 해 거기서 딴다(리뷰 I1:
    # 서브에이전트가 부모 워크트리의 커밋을 못 보고, 띄울 때마다 fetch). 기본 경로와 같은 기준을 쓴다.
    base = base or _git(cwd, "rev-parse", "HEAD")
    args = ["bash", str(HERE / "marina.sh"), "worktree", "create", name, base, "--project", str(proj["id"])]
    r = subprocess.run(args, capture_output=True, text=True, timeout=600, stdin=subprocess.DEVNULL)
    out = (r.stdout or "") + (r.stderr or "")
    m = re.search(r"✓ 워크트리:\s*(.+)", out)
    if r.returncode != 0 or not m:
        raise RuntimeError(f"marina worktree create 실패: {out.strip()[-400:]}")
    return Path(m.group(1).strip())


def create(payload: dict[str, Any], env: Optional[dict[str, str]] = None) -> Path:
    env = os.environ if env is None else env
    name = str(payload.get("name") or "").strip()
    if not name or "/" in name or name.startswith("."):
        raise ValueError(f"워크트리 이름이 이상함: {name!r}")
    cwd = Path(str(payload.get("cwd") or os.getcwd()))
    base = str(env.get("MARINA_BASE") or "")
    try:
        got = _marina_create(name, cwd, base)
        if got is not None:
            _log(f"create marina {name} → {got}")
            return got
    except Exception as exc:                 # 마리나 쪽이 어떻게 실패해도 기본 동작으로(전역 훅)
        _log(f"create marina 실패 → 기본 동작: {exc!r}")
    got = _default_create(name, cwd, base)
    _log(f"create default {name} → {got}")
    return got


def _drop_branch(main: Path, branch: str) -> None:
    """훅이 만든 브랜치 정리 — 머지된 것만(-d). 서브에이전트마다 브랜치가 쌓이지 않게(리뷰 I2)."""
    if branch:
        subprocess.run(["git", "-C", str(main), "branch", "-d", branch], capture_output=True, timeout=30)


def remove(payload: dict[str, Any]) -> tuple[int, str]:
    raw = str(payload.get("worktree_path") or "")
    if not raw:     # cwd 로 대신하지 않는다 — 돌던 워크트리를 지울 수 있다(리뷰 M1)
        return 1, "worktree_path 가 없어 아무것도 지우지 않았습니다"
    path = Path(raw)
    if not path.exists():
        return 0, ""
    from marina_liveness import lock_holds
    held = lock_holds(path, me="claude")
    if held:
        _log(f"remove 거절 {path}: {held['reason']}")
        return 2, f"잠김: {held['reason']} — 쓰는 중이라 워크트리를 남깁니다"
    main = _main_checkout(path)
    branch = _git(path, "branch", "--show-current", check=False)
    proj = None
    try:
        proj = _marina_project(main)
    except Exception:
        proj = None
    if proj:
        # Claude 는 루트만 보고 '변경 없음'이면 묻지 않고 부른다 — 서브레포의 미커밋은 못 본다(리뷰 C1).
        # 루트가 더러우면 Claude 가 이미 사람에게 물었으므로 지운다.
        import marina_worktrees
        status = marina_worktrees.worktree_status(path)
        dirty = [r for r in (status.get("repos") or [])[1:] if r.get("dirty")]
        if dirty:
            names = ", ".join(str(r.get("name")) for r in dirty)
            _log(f"remove 거절 {path}: 서브레포 미커밋 {names}")
            return 2, f"서브레포에 커밋 안 한 변경이 있어 남깁니다: {names}"
        try:
            from marina_lifecycle import remove_worktree
            remove_worktree(path, force=True, keep_images=False)
            _drop_branch(main, branch)
            _drop_sub_branches(main, proj, branch)
            _log(f"remove marina {path}")
            return 0, ""
        except Exception as exc:
            _log(f"remove marina 실패 → git 으로: {exc!r}")
    subprocess.run(["git", "-C", str(main), "worktree", "unlock", str(path)], capture_output=True, timeout=10)
    _git(main, "worktree", "remove", "--force", str(path))
    _drop_branch(main, branch)
    if proj:
        _drop_sub_branches(main, proj, branch)
    _log(f"remove default {path}")
    return 0, ""


def _drop_sub_branches(main: Path, proj: dict[str, Any], branch: str) -> None:
    """서브레포에도 같은 이름 브랜치가 생긴다(attach 가 브랜치를 미러, 실측 homeserver) — 같이 정리(-d).
    루트 폴더와 함께 사라진 서브레포 워크트리 등록이 남아 있으면 브랜치가 '체크아웃 중'으로 막히므로 prune 먼저."""
    for sub in (proj.get("subrepos") or []):
        repo = main / str(sub)
        if (repo / ".git").exists():
            subprocess.run(["git", "-C", str(repo), "worktree", "prune"], capture_output=True, timeout=30)
            _drop_branch(repo, branch)


def main(argv: list[str]) -> int:
    ev = argv[0] if argv else ""
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}
    sys.path.insert(0, str(HERE))
    try:
        if ev == "create":
            print(create(payload))
            return 0
        if ev == "remove":
            code, msg = remove(payload)
            if msg:
                print(msg, file=sys.stderr)
            return code
    except Exception as exc:
        _log(f"{ev} 실패: {exc!r}")
        print(f"marina worktree hook: {exc}", file=sys.stderr)
        return 1
    print(f"marina worktree hook: 모르는 이벤트 {ev!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
