#!/usr/bin/env bash
# git 잠금 판정(스펙 3장 실측 6): Claude Code 는 죽어도 잠금을 남긴다 → pid 가 죽었으면 낡은 잠금, pid 없는 잠금은 주인이 풀 때까지
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
T="$MARINA_HOME/repo"; mkdir -p "$T"; git -C "$T" init -q; git -C "$T" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
for w in w1 w2 w3; do git -C "$T" worktree add -q -b "$w" "$MARINA_HOME/$w"; done
sleep 30 & LIVE=$!
( exit 0 ) & DEAD=$!; wait $DEAD
git -C "$T" worktree lock --reason "claude session w1 (pid $DEAD start x)" "$MARINA_HOME/w1"
git -C "$T" worktree lock --reason "claude session w2 (pid $LIVE start x)" "$MARINA_HOME/w2"
rc=0
PYTHONPATH="$SCRIPTS" python3 - "$MARINA_HOME" <<'PY' || rc=$?
import sys
from pathlib import Path
import marina_liveness as lv
h = Path(sys.argv[1]); fails = []
def check(c, m):
    if not c: fails.append(m)
l1 = lv.worktree_lock(h / "w1"); l2 = lv.worktree_lock(h / "w2")
check(l1 and l1["owner"] == "claude" and l1["stale"] is True, f"죽은 pid → 낡은 잠금: {l1}")
check(l2 and l2["stale"] is False and lv.lock_holds(h / "w2"), f"산 pid → 유효: {l2}")
check(lv.lock_holds(h / "w1") is None, "낡은 잠금은 안 지킨다")
check(lv.worktree_lock(h / "w3") is None, "안 잠김")
lv.lock_worktree(h / "w3", "marina-session", "proj/feat-a")
l3 = lv.worktree_lock(h / "w3")
check(l3 and l3["owner"] == "marina-session" and l3["pid"] is None and l3["stale"] is False, f"pid 없는 잠금은 주인이 풀 때까지: {l3}")
check(lv.lock_holds(h / "w3", me="marina-session") is None and lv.lock_holds(h / "w3"), "자기 잠금은 자기에게 안 막힘")
try:
    lv.lock_worktree(h / "w3", "other", "x"); check(False, "남이 잠근 걸 덮어쓰면 안 됨")
except RuntimeError:
    pass
check(lv.unlock_worktree(h / "w3", "someone-else") is False and lv.worktree_lock(h / "w3"), "남의 잠금은 못 푼다")
check(lv.unlock_worktree(h / "w3", "marina-session") is True and lv.worktree_lock(h / "w3") is None, "자기 잠금은 푼다")
lv.lock_worktree(h / "w1", "marina-session", "x")
check(lv.worktree_lock(h / "w1")["owner"] == "marina-session", "낡은 잠금은 새 주인이 덮는다")
check(lv.root_has_live_agent is not None and lv.live_agent_cwds is not None, "프로세스 판정도 여기")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
kill $LIVE 2>/dev/null || true
[ "$rc" = 0 ] || exit "$rc"
echo "PASS test-liveness-lock"
