"""marina_liveness.py — 워크트리를 '누가 쓰는 중인가' (runtime).

두 신호: ① 살아 있는 claude/codex 프로세스의 cwd(ps comm → lsof cwd — argv 파싱 금지, 프롬프트 오염)
② git 표준 잠금(`git worktree lock`). Claude Code 는 자기 세션 워크트리를 'claude session <이름> (pid N …)'
로 잠그고, 죽어도 잠금을 남긴다(실측 2026-10-03) → pid 가 죽었으면 낡은 잠금으로 본다. pid 가 없는 잠금
(예: marina-session)은 주인이 풀 때까지 지킨다.
"""
from __future__ import annotations

import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any, Optional


def _parse_agent_pids(ps_output: str) -> list[str]:
    # ps -axo pid=,comm= 출력(= "<pid> <실행파일경로>", 인자 없음) → claude/codex 프로세스 pid 목록.
    # comm 에는 프롬프트/인자가 절대 안 붙으므로 파싱이 유저 입력에 오염되지 않는다(정석).
    pids: list[str] = []
    for line in ps_output.splitlines():
        head, _, comm = line.strip().partition(" ")
        if not head.isdigit() or not comm.strip():
            continue
        if Path(comm.strip()).name in ("claude", "codex"):
            pids.append(head)
    return pids


_live_cwds_cache: tuple[float, set[Path]] = (0.0, set())


def _live_agent_cwds(refresh: bool = False) -> set[Path]:
    # 살아있는 claude/codex 프로세스들의 cwd(=worktree root) 집합 — 세션 liveness. 5s 캐시(세션마다 ps 방지).
    global _live_cwds_cache
    now = time.time()
    if not refresh and now - _live_cwds_cache[0] < 5.0:
        return _live_cwds_cache[1]
    try:
        result = subprocess.run(["ps", "-axo", "pid=,comm="], check=False,
                                capture_output=True, text=True, timeout=1)
    except (OSError, subprocess.SubprocessError):
        return _live_cwds_cache[1]
    pids = _parse_agent_pids(result.stdout)
    cwds: set[Path] = set()
    if pids:
        try:
            out = subprocess.run(["lsof", "-a", "-d", "cwd", "-p", ",".join(pids), "-Fn"],
                                 check=False, capture_output=True, text=True, timeout=2)
            for l in out.stdout.splitlines():
                if l.startswith("n") and l[1:].strip():
                    try:
                        cwds.add(Path(l[1:].strip()).resolve())
                    except OSError:
                        pass
        except (OSError, subprocess.SubprocessError):
            pass
    _live_cwds_cache = (now, cwds)
    return cwds


def _crosses_nested_worktree(root: Path, cwd: Path) -> bool:
    # root 아래로 내려가는 경로 도중 `.claude/worktrees/` 경계를 넘는지 — marina 워크트리는
    # 물리적으로 메인 루트 밑에 중첩(<main>/.claude/worktrees/<wt>)되므로, 그 경계를 넘은 cwd 는
    # main 이 아니라 그 중첩 워크트리에 속한다(방향: root→cwd 로 내려가며 검사).
    try:
        rel_parts = cwd.relative_to(root).parts
    except ValueError:
        return False
    for i in range(len(rel_parts) - 1):
        if rel_parts[i] == ".claude" and rel_parts[i + 1] == "worktrees":
            return True
    return False


def _root_has_live_agent(root: Path | None, live_cwds: set[Path]) -> bool:
    # root 자체가 어떤 살아있는 agent 의 cwd 이거나, 그 cwd 를 품고 있으면(서브폴더에서 실행) live —
    # 단, 그 cwd 가 root 아래 중첩된 워크트리(.claude/worktrees/...) 안이면 제외한다. 그렇지 않으면
    # 메인 체크아웃 root 가 그 밑 모든 워크트리의 살아있는 세션에 반응해 항상 live 로 오판된다
    # (메인 세션이 실제로 종료돼도 idle 강등이 안 되는 원인).
    if root is None:
        return False
    for cwd in live_cwds:
        if cwd == root:
            return True
        if root in cwd.parents and not _crosses_nested_worktree(root, cwd):
            return True
    return False


live_agent_cwds = _live_agent_cwds
root_has_live_agent = _root_has_live_agent

_PID = re.compile(r"\(pid (\d+)")


def _git_dir(root: Path) -> Optional[Path]:
    try:
        out = subprocess.run(["git", "-C", str(root), "rev-parse", "--absolute-git-dir"],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return Path(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else None


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True          # 권한 없음 = 남의 살아 있는 프로세스
    return True


def worktree_lock(root: Path) -> Optional[dict[str, Any]]:
    """git 잠금 정보. 잠기지 않았거나 git 워크트리가 아니면 None."""
    gd = _git_dir(root)
    if gd is None:
        return None
    try:
        reason = (gd / "locked").read_text(encoding="utf-8").strip()
    except OSError:
        return None
    m = _PID.search(reason)
    pid = int(m.group(1)) if m else None
    return {"reason": reason, "owner": (reason.split() or [""])[0], "pid": pid,
            "stale": bool(pid) and not _alive(pid)}


def lock_holds(root: Path, me: str = "") -> Optional[dict[str, Any]]:
    """지금 유효한 남의 잠금(있으면 그 정보). 낡은 잠금·자기 잠금은 None."""
    lk = worktree_lock(root)
    if not lk or lk["stale"] or (me and lk["owner"] == me):
        return None
    return lk


def lock_worktree(root: Path, owner: str, desc: str) -> None:
    lk = worktree_lock(root)
    if lk and not lk["stale"] and lk["owner"] != owner:
        raise RuntimeError(f"이미 잠김: {lk['reason']}")
    if lk:
        subprocess.run(["git", "-C", str(root), "worktree", "unlock", str(root)], capture_output=True, timeout=10)
    r = subprocess.run(["git", "-C", str(root), "worktree", "lock", "--reason", f"{owner} {desc}", str(root)],
                       capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip())


def unlock_worktree(root: Path, owner: str) -> bool:
    lk = worktree_lock(root)
    if not lk or lk["owner"] != owner:
        return False
    return subprocess.run(["git", "-C", str(root), "worktree", "unlock", str(root)],
                          capture_output=True, timeout=10).returncode == 0
