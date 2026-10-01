#!/usr/bin/env bash
# 채널 수명 = 워크트리 수명: remove_worktree 가 Discord 세션을 정리하고(실패해도 삭제는 진행),
# 유휴 판정은 살아 있는 Discord 세션의 워크트리를 활동 중으로 본다. sessions.json 이 깨져도 데몬 경로는 무사.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
mkdir -p "$SRC/.claude/worktrees"
for wt in wt-a wt-b; do git -C "$SRC" worktree add -q --detach "$SRC/.claude/worktrees/$wt" HEAD; done

PYTHONPATH="$SCRIPTS" python3 - "$SRC" "$FD" <<'PY'
import json, sys, time
from pathlib import Path
src, fd = Path(sys.argv[1]), Path(sys.argv[2])
import marina_session as ms
import marina_lifecycle
import marina_worktree_gc as gc
from marina_registry import discover_all_roots
discover_all_roots(refresh=True)
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
W = lambda n: src / ".claude" / "worktrees" / n
marina_lifecycle.stop_all = lambda root: {"stoppedAll": True}
marina_lifecycle.cleanup_session = lambda root: {"removed": ""}
marina_lifecycle.bootout_session_dashboard = lambda sid: None

# 1) 실제 teardown_for_root — tmux·채널·상태 폴더·기록이 사라진다
cfg = ms.load_config(); dc = ms.Discord("test-token")
cat = ms.ensure_category(dc, cfg, "proj")
ch = dc.create_text_channel("G1", "wt-a", cat)
sd = ms.state_dir("proj", "wt-a")
ms.write_state_dir(sd, ch, ["U1"], ms.token_file(cfg))
ms.tmux_start("proj-wt-a", W("wt-a"), ms.claude_argv("proj", "wt-a"), {"DISCORD_STATE_DIR": str(sd)})
ms.save_sessions([{"project": "proj", "task": "wt-a", "root": str(W("wt-a")), "channelId": ch,
                   "tmux": "proj-wt-a", "stateDir": str(sd), "rcName": "proj/wt-a", "createdAt": 0}])
check(ms.has_live_session(W("wt-a")), "살아 있는 세션 감지")

# 2) 유휴 판정: 30일 전 커밋이어도 살아 있는 Discord 세션이면 활동 중
info = {"lastCommitTs": time.time() - 30 * 86400}
v = gc.idle_verdict(W("wt-a"), info, [], set(), days=14)
check(v["gcLiveProcess"] is True and v["gcIdle"] is False, f"살아 있는 세션 → 활동 중: {v}")
v2 = gc.idle_verdict(W("wt-b"), info, [], set(), days=14)
check(v2["gcLiveProcess"] is False, f"세션 없는 워크트리는 그대로: {v2}")

# 3) remove_worktree 가 세션을 정리한다
res = marina_lifecycle.remove_worktree(W("wt-a"), keep_images=True)
check(res.get("discordSessions") == [], f"정리 경고 없음: {res.get('discordSessions')}")
check(not ms.tmux_alive("proj-wt-a"), "tmux 종료")
check(not sd.exists(), "상태 폴더 삭제")
check(ms.load_sessions() == [], "기록 삭제")
log = (fd / "log.jsonl").read_text()
check(f'"DELETE", "p": "/channels/{ch}"' in log, "채널 삭제 요청")
check(not W("wt-a").exists(), "워크트리 삭제")

# 4) 세션 정리가 터져도 워크트리 삭제는 진행
_real_teardown = ms.teardown_for_root
ms.teardown_for_root = lambda root: (_ for _ in ()).throw(RuntimeError("boom"))
res = marina_lifecycle.remove_worktree(W("wt-b"), keep_images=True)
check(not W("wt-b").exists(), "정리 실패해도 워크트리 삭제")
check(any("boom" in w for w in res.get("discordSessions") or []), f"실패가 결과에 드러남: {res.get('discordSessions')}")

# 5) sessions.json 이 깨져도 데몬 경로는 예외 없음
ms.teardown_for_root = _real_teardown
ms.sessions_path().write_text("{broken")
check(ms.has_live_session(src) is False, "깨진 기록 → False")
check(ms.teardown_for_root(src) == [], "깨진 기록 → 정리할 것 없음")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-worktree-hooks"
