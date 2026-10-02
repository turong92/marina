#!/usr/bin/env bash
# 분리 A: 워크트리 삭제는 git 표준 잠금을 존중한다 — 쓰는 중(남이 잠금)이면 force 없이 안 지운다.
# runtime 은 Discord 코드를 부르지 않는다(채널 정리는 discord 쪽 사후 정리가 맡음, 스펙 R1·3장).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
SRC="$MARINA_HOME/proj"; mkdir -p "$SRC"; git -C "$SRC" init -q -b main
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$SRC/.claude/worktrees"
for wt in wl wd ws; do git -C "$SRC" worktree add -q --detach "$SRC/.claude/worktrees/$wt" HEAD; done
printf '{"projects":[{"id":"proj","root":"%s","subrepos":[],"worktreeGlobs":[".claude/worktrees/*"]}],"schemaVersion":1}\n' "$SRC" > "$MARINA_HOME/projects.json"
git -C "$SRC" worktree lock --reason "marina-session proj/wl" "$SRC/.claude/worktrees/wl"
git -C "$SRC" worktree lock --reason "claude session wd (pid 999999 start x)" "$SRC/.claude/worktrees/wd"
PYTHONPATH="$SCRIPTS" python3 - "$SRC" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
import marina_lifecycle as lc
from marina_registry import discover_all_roots
discover_all_roots(refresh=True)
fails = []
def check(c, m):
    if not c: fails.append(m)
W = lambda n: src / ".claude" / "worktrees" / n
lc.stop_all = lambda root: {"stoppedAll": True}
lc.cleanup_session = lambda root: {"removed": ""}
lc.bootout_session_dashboard = lambda sid: None
try:
    lc.remove_worktree(W("wl"), keep_images=True); check(False, "잠긴 워크트리를 지웠다")
except ValueError as exc:
    check("잠김" in str(exc) and "marina-session" in str(exc), f"이유를 보여 준다: {exc}")
check(W("wl").exists(), "잠긴 워크트리는 남는다")
# 실측(2026-10-03): force 삭제가 중간(stop_all)에 실패하면 잠금만 풀린 채 남았다 — 잠금은 실제로 지우기 직전에 푼다
_stop = lc.stop_all
lc.stop_all = lambda root: (_ for _ in ()).throw(ValueError("stop-all failed"))
try:
    lc.remove_worktree(W("wl"), force=True, keep_images=True)
except ValueError:
    pass
import marina_liveness as lv
check((lv.worktree_lock(W("wl")) or {}).get("owner") == "marina-session", "삭제가 실패하면 잠금은 그대로")
lc.stop_all = _stop
lc.remove_worktree(W("wl"), force=True, keep_images=True)
check(not W("wl").exists(), "force 면 잠금을 풀고 지운다")
lc.remove_worktree(W("wd"), keep_images=True)
check(not W("wd").exists(), "죽은 프로세스의 낡은 잠금은 막지 않는다")
lc.remove_worktree(W("ws"), keep_images=True)
check(not W("ws").exists(), "잠금 없으면 그대로 지운다")
check("marina_session" not in Path(lc.__file__).read_text(), "runtime 은 Discord 코드를 안 부른다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-worktree-remove-lock"
