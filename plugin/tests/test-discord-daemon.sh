#!/usr/bin/env bash
# 분리 B: discord 봇은 대시보드가 아니라 discord 가 스스로 띄운다 — 훅·명령이 ensure_daemon(떠 있으면 그대로, 없을 때만 하나)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
fail() { echo "FAIL: $*"; exit 1; }
unset MARINA_DISCORD_DAEMON
python3 -c "import time; time.sleep(60)" marina_session.py daemon & DUMMY=$!
PYTHONPATH="$SCRIPTS" python3 - "$DUMMY" <<'PY'
import sys, time
import marina_session as ms
fails = []
def check(c, m):
    if not c: fails.append(m)
spawned = []
ms._spawn_daemon = lambda: spawned.append(1) or 4242
check(ms.ensure_daemon() == "started" and spawned == [1], f"없으면 띄움: {spawned}")
ms.daemon_pid_path().write_text("4242")          # 기록만 있고 프로세스 없음 → 다시 띄움
check(ms.ensure_daemon() == "started" and len(spawned) == 2, "죽은 기록이면 다시")
ms.daemon_pid_path().write_text(sys.argv[1])     # 살아 있는 데몬
check(ms.ensure_daemon() == "running" and len(spawned) == 2, "떠 있으면 그대로")
import os
os.environ["MARINA_DISCORD_DAEMON"] = "off"
ms.daemon_pid_path().unlink()
check(ms.ensure_daemon() == "off" and len(spawned) == 2, "끄면 안 띄움(테스트)")
del os.environ["MARINA_DISCORD_DAEMON"]
# 훅 진입이 ensure 를 부른다(대시보드가 없어도 첫 훅에서 봇이 뜬다)
calls = []
ms.ensure_daemon = lambda: calls.append("e") or "running"
ms.hook_stop({"cwd": "/nonexistent", "transcript_path": "/nonexistent"})
check(calls, "hook_stop → ensure_daemon")
check(ms._code_updated() is False, "작업 트리에서 돌면 업데이트 감지 안 함(설치본만)")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
kill $DUMMY 2>/dev/null || true
! grep -n "_discord_loop" "$SCRIPTS/marina_handler.py" || fail "대시보드가 아직 봇 루프를 돈다"
echo "PASS test-discord-daemon"
