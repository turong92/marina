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
_real_ensure = ms.ensure_daemon
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
calls.clear(); ms.hook_prompt({"prompt": "x", "transcript_path": "/nonexistent"})
check(calls, "리뷰 I3: 지시를 받는 순간(hook_prompt)에도 봇 확인")
check(ms._code_updated() is False, "작업 트리에서 돌면 업데이트 감지 안 함(설치본만)")
# 리뷰 C1: 업데이트하면 installPath 가 새 해시로 바뀌고 옛 캐시 폴더는 남는다 — 옛 데몬은 '설치본인데 최신이 아님'
import json, tempfile
from pathlib import Path
ch = Path(tempfile.mkdtemp()); cache = ch / "plugins" / "cache" / "marina-dev" / "marina"
for v in ("old", "new"):
    (cache / v / "scripts").mkdir(parents=True); (cache / v / "scripts" / "marina_session.py").write_text("")
def inst(v):
    (ch / "plugins" / "installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": {"marina@marina-dev": [
        {"scope": "user", "installPath": str(cache / v), "lastUpdated": "2026-10-03"}]}}))
inst("old")
me = cache / "old" / "scripts" / "marina_session.py"
check(ms._code_updated(me=me, home=ch) is False, "설치본 = 최신이면 계속")
inst("new")
check(ms._code_updated(me=me, home=ch) is True, "업데이트되면 옛 데몬은 끝낸다(installPath 가 바뀌어도)")
# 리뷰 M1: ps 일치는 정확히 'marina_session.py … daemon' 끝 — daemon-ensure·훅 wrapper 는 데몬이 아니다
check(ms._is_daemon_cmd("/usr/bin/python3 /x/scripts/marina_session.py daemon"), "데몬 명령")
check(ms._is_daemon_cmd("/bin/sh /Users/u/.marina/bin/marina-session-hook daemon"), "shim 데몬")
check(not ms._is_daemon_cmd("/usr/bin/python3 /x/scripts/marina_session.py daemon-ensure"), "daemon-ensure 는 아님")
check(not ms._is_daemon_cmd("sh -c /Users/u/.marina/bin/marina-session-hook hook-stop || true"), "훅 wrapper 는 아님")
# 리뷰 I1: 여러 훅이 동시에 ensure 해도 하나만 띄운다
import threading
for f in (ms.daemon_pid_path(),):
    f.unlink(missing_ok=True) if hasattr(f, "unlink") else None
spawned.clear()
def slow_spawn():
    time.sleep(0.2); spawned.append(1); return int(sys.argv[1])     # 살아 있는 pid 를 기록하게
ms._spawn_daemon = slow_spawn
ms._is_daemon_cmd = lambda cmd: True
ts = [threading.Thread(target=_real_ensure) for _ in range(5)]
[t.start() for t in ts]; [t.join() for t in ts]
check(len(spawned) == 1, f"동시 ensure 도 하나만: {len(spawned)}")
# 리뷰 I2: 데몬은 세션 폴더·세션 환경을 물려받지 않는다(고아 리퍼·세션 전용 변수)
os.environ["DISCORD_STATE_DIR"] = "/tmp/some-session"; os.environ["CLAUDECODE"] = "1"
env = ms._daemon_env()
check("DISCORD_STATE_DIR" not in env and "CLAUDECODE" not in env and env.get("MARINA_HOME") == str(ms.marina_home()), f"깨끗한 환경: {sorted(env)}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
kill $DUMMY 2>/dev/null || true
! grep -n "_discord_loop" "$SCRIPTS/marina_handler.py" || fail "대시보드가 아직 봇 루프를 돈다"
echo "PASS test-discord-daemon"
