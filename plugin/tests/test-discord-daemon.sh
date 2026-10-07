#!/usr/bin/env bash
# 분리 B: discord 봇은 대시보드가 아니라 discord 가 스스로 띄운다 — 훅·명령이 ensure_daemon(떠 있으면 그대로, 없을 때만 하나)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
fail() { echo "FAIL: $*"; exit 1; }
unset MARINA_DISCORD_DAEMON
python3 -c "import time; time.sleep(60)" marina_session.py daemon & DUMMY=$!
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$DUMMY" <<'PY'
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
os.environ["MARINA_DISCORD_SUPERVISED"] = "launchd"
check("MARINA_DISCORD_SUPERVISED" not in ms._daemon_env(), "launchd 자식 표식은 떼어 띄운 데몬에 물려주지 않는다(핸드오프가 아무도 안 띄우게 된다)")
del os.environ["MARINA_DISCORD_SUPERVISED"]
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
# ── LaunchAgent 주인 규칙(스펙 §3.2~3.4) — 가짜 launchctl 만 ──
LC="$TMPROOT/lc"; mkdir -p "$LC" "$MARINA_HOME/bin" "$TMPROOT/bin"
cat > "$TMPROOT/bin/fake-launchctl" <<SH
#!/bin/sh
echo "\$*" >> "$LC/log"
case "\$1" in
  print) [ -f "$LC/loaded" ] || exit 113; echo "state = \$(cat "$LC/state" 2>/dev/null || echo running)" ;;
  bootstrap) [ -e "$LC/fail_bootstrap" ] && exit 5; touch "$LC/loaded" ;;
  bootout) rm -f "$LC/loaded" ;;
  kickstart) echo running > "$LC/state" ;;
esac
SH
chmod +x "$TMPROOT/bin/fake-launchctl"
printf '#!/bin/sh\nexit 0\n' > "$MARINA_HOME/bin/marina-session-hook"; chmod +x "$MARINA_HOME/bin/marina-session-hook"
export MARINA_LAUNCH_AGENTS_DIR="$MARINA_HOME/LaunchAgents" LC
PYTHONPATH="$DSCRIPTS:$SCRIPTS" FAKE="$TMPROOT/bin/fake-launchctl" python3 - <<'PY'
import os, sys, threading
from pathlib import Path
import marina_session as ms
import marina_discord_launchd as ld
fails = []
def check(c, m):
    if not c: fails.append(m)
LC = Path(os.environ["LC"]); log = LC / "log"
def calls(): return log.read_text().splitlines() if log.exists() else []
shim = str(ms.marina_home() / "bin" / "marina-session-hook")
spawned = []
ms._spawn_daemon = lambda *a: spawned.append(1) or 4242
ms.daemon_pid_path().unlink(missing_ok=True)
os.environ.pop("MARINA_DISCORD_DAEMON", None)
# 고정 입구가 아니면(작업 트리) 등록하지 않는다
check(ms._launchd_program() is None, "작업 트리에서 돌면 launchd 프로그램 없음")
check(ms._launchd_program([shim]) == [shim, "daemon"], "고정 입구면 [입구, daemon]")
# 격리 홈(주인 = nohup): 지금 그대로 떼어 띄운다
check(ms.ensure_daemon([shim]) == "started" and spawned == [1] and calls() == [], f"nohup 은 예전대로: {spawned} {calls()}")
ms.daemon_pid_path().unlink(missing_ok=True); spawned.clear()
# 주인 = launchd: 떼어 띄우지 않고 등록한다
os.environ.update(MARINA_DISCORD_SUPERVISOR="launchd", MARINA_DISCORD_LAUNCHCTL=os.environ["FAKE"])
check(ms.ensure_daemon([shim]) == "launchd:installed" and spawned == [], f"launchd 에 맡김: {spawned}")
(LC / "state").write_text("not running")
check(ms.ensure_daemon([shim]) == "launchd:kicked" and spawned == [], "죽어 있으면 kickstart — 직접 띄우지 않는다(둘 방지)")
# 작업 트리(입구 아님)에서는 launchd 가 주인이어도 예전대로
check(ms.ensure_daemon() == "started" and spawned == [1], "입구가 아니면 등록 안 하고 예전대로")
ms.daemon_pid_path().unlink(missing_ok=True); spawned.clear()
# 등록 실패 → 예전 방식으로 물러난다(봇이 없는 것보다 낫다)
ld.uninstall(); (LC / "fail_bootstrap").touch()
check(ms.ensure_daemon([shim]) == "started" and spawned == [1], "launchctl 실패면 떼어 띄움")
(LC / "fail_bootstrap").unlink(); ms.daemon_pid_path().unlink(missing_ok=True); spawned.clear()
# off 면 아무것도
log.unlink(missing_ok=True); os.environ["MARINA_DISCORD_DAEMON"] = "off"
check(ms.ensure_daemon([shim]) == "off" and calls() == [] and spawned == [], f"off 면 launchctl 호출 0건: {calls()}")
check(ms._daemon_adopt_launchd() is False and calls() == [], "off 면 자기 이전도 안 함")
del os.environ["MARINA_DISCORD_DAEMON"]
# 동시 ensure 5개 → 등록 한 번
ld.uninstall(); log.unlink(missing_ok=True)
ts = [threading.Thread(target=lambda: ms.ensure_daemon([shim])) for _ in range(5)]
[t.start() for t in ts]; [t.join() for t in ts]
check(sum(c.startswith("bootstrap") for c in calls()) == 1, f"동시 ensure 도 bootstrap 한 번: {calls()}")
# 핸드오프: launchd 자식은 아무것도 띄우지 않고 끝나기만 한다
called = []
real = ms.ensure_daemon
ms.ensure_daemon = lambda *a: called.append(a) or "started"
os.environ["MARINA_DISCORD_SUPERVISED"] = "launchd"
ms._daemon_handoff()
check(called == [], f"launchd 아래 핸드오프는 직접 안 띄운다: {called}")
check(ms._daemon_adopt_launchd() is False, "이미 launchd 자식이면 이전할 것 없음")
del os.environ["MARINA_DISCORD_SUPERVISED"]
ms._daemon_handoff()
check(len(called) == 1, "떼어 뜬 데몬의 핸드오프는 예전대로 다음 데몬을 띄운다")
ms.ensure_daemon = real
# 자기 이전: 떼어 뜬 데몬이 입구로 떴으면 등록하고 물러난다 — 입구가 아니면 그대로 돈다
ld.uninstall()
ms._hook_entry = lambda: [sys.executable, "/x/marina_session.py"]
check(ms._daemon_adopt_launchd() is False, "작업 트리 데몬은 등록하지 않는다(LaunchAgent 가 워크트리를 물면 안 된다)")
ms._hook_entry = lambda: [shim]
import fcntl
held = []
real_ensure = ld.ensure
def probe(program):
    f = open(ms.marina_home() / "discord-daemon.spawn.lock", "w")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB); held.append(False)
    except OSError:
        held.append(True)
    finally:
        f.close()
    return real_ensure(program)
ld.ensure = probe
check(ms._daemon_adopt_launchd() is True and ld.status() != "absent", "입구로 뜬 데몬은 등록하고 물러난다")
ld.ensure = real_ensure
check(held == [True], f"등록하는 동안 spawn 잠금을 쥔다(훅의 ensure_daemon 과 겹치지 않게): {held}")
ld.uninstall(permanent=True)
check(ms.ensure_daemon([shim]) == "off" and ms._daemon_adopt_launchd() is False, "끔 표식이 있으면 등록도 이전도 안 한다")
ld.clear_off()
# 로그 자르기
lp = ms.marina_home() / "discord-daemon.log"
lp.write_bytes(b"x" * ((1 << 20) + 10)); ms._trim_daemon_log()
check(lp.stat().st_size == 0, "1MB 넘으면 비운다")
lp.write_bytes(b"x" * 100); ms._trim_daemon_log()
check(lp.stat().st_size == 100, "작으면 그대로")
check("marina_discord_launchd" in ms._PREFLIGHT_MODULES, "업데이트 사전 검사에 새 모듈")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
kill $DUMMY 2>/dev/null || true
! grep -n "_discord_loop" "$SCRIPTS/marina_handler.py" || fail "대시보드가 아직 봇 루프를 돈다"
echo "PASS test-discord-daemon"
