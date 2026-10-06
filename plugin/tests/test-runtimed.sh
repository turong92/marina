#!/usr/bin/env bash
# 청소 상주 프로그램 marina-runtimed(분리 A, 스펙 5장) — 대시보드 없이도 게이트웨이 갱신·도커/워크트리 GC·리퍼가 돈다.
#  - 게이트웨이는 5초, GC 는 부팅 60초 뒤부터 600초마다. 한 홈에 하나만(flock)
#  - 자동 삭제는 **실제 홈에서만**(MARINA_RUNTIMED_PRIMARY=1 — 격리 프리뷰가 실 도커 9.2GB 를 지운 사고)
#  - 대시보드 데몬은 더 이상 청소 루프를 안 돈다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
fail() { echo "FAIL: $*"; exit 1; }
PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import sys
import marina_runtimed as rd
fails = []
def check(c, m):
    if not c: fails.append(m)
calls = []
lp = rd.Loop(gateway=lambda: calls.append("gw"), docker_gc=lambda primary: calls.append(("dgc", primary)),
             worktree_gc=lambda primary: calls.append(("wgc", primary)), primary=False, gateway_on=True,
             update=lambda primary: calls.append(("upd", primary)))
t0 = 1000.0
check(lp.step(t0) is True and calls == ["gw"], f"첫 바퀴는 게이트웨이만(GC 는 부팅 60초 뒤): {calls}")
calls.clear(); lp.step(t0 + 3)
check(calls == [], f"5초 안엔 아무것도: {calls}")
calls.clear(); lp.step(t0 + 61)
check(calls == ["gw", ("upd", False), ("dgc", False), ("wgc", False)],
      f"60초 뒤 GC·업데이트 확인 — 격리 홈이면 primary=False 로 넘겨 지우지도 받지도 않게: {calls}")
calls.clear(); lp.step(t0 + 120)
check(("dgc", False) not in calls, f"GC 는 600초마다: {calls}")
calls.clear(); lp.step(t0 + 662)
check(("dgc", False) in calls, f"600초 뒤 다시: {calls}")
off = rd.Loop(gateway=lambda: calls.append("gw2"), docker_gc=lambda p: None, worktree_gc=lambda p: None, primary=False, gateway_on=False)
calls.clear(); off.step(t0)
check("gw2" not in calls, "게이트웨이 꺼져 있으면 안 부름")
other = rd.Loop(gateway=lambda: None, docker_gc=lambda p: None, worktree_gc=lambda p: None, primary=False, gateway_on=True)
check(other.step(t0) is False, "한 홈에 하나만(flock)")
# 업데이트 뒤 옛 코드로 계속 돌면 안 된다 — 설치 경로가 바뀌면 스스로 끝내고(launchd KeepAlive 가 새 코드로 다시 띄움)
from pathlib import Path
check(rd.stale_code(Path("/x/old/scripts"), Path("/x/new/scripts")) is True, "설치 경로가 바뀌면 옛 코드")
check(rd.stale_code(Path("/x/new/scripts"), Path("/x/new/scripts")) is False, "같으면 계속")
check(rd.stale_code(Path("/x/dev/scripts"), None) is False, "설치 기록 없음(개발 실행)이면 계속")
import os
os.environ.pop("MARINA_RUNTIMED_PRIMARY", None)
check(rd.is_primary() is False, "표식 없으면 primary 아님")
os.environ["MARINA_RUNTIMED_PRIMARY"] = "1"
check(rd.is_primary() is True, "표식 있으면 primary")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
! grep -n "_gc_loop\|_gw_loop\|marina_reaper\.run_forever" "$SCRIPTS/marina_handler.py" || fail "대시보드 데몬에 청소 루프가 남아 있다"
grep -q "marina-runtimed.sh" "$SCRIPTS/marina_handler.py" || fail "대시보드가 runtimed 를 띄워 주지 않는다(업데이트만으로 생겨야 함)"
# 시작·상태·정지 — 격리 홈 + nohup(테스트는 launchd 를 건드리지 않음) + 루프는 아무것도 안 함
export MARINA_RUNTIMED_SUPERVISOR=nohup MARINA_RUNTIMED_NOOP=1
bash "$SCRIPTS/marina-runtimed.sh" start >/dev/null
for _ in $(seq 30); do bash "$SCRIPTS/marina-runtimed.sh" status | grep -q running && break; sleep 0.2; done
bash "$SCRIPTS/marina-runtimed.sh" status | grep -q running || fail "start → running"
bash "$SCRIPTS/marina-runtimed.sh" ensure | grep -q "already" || fail "ensure 는 떠 있으면 그대로"
bash "$SCRIPTS/marina-runtimed.sh" stop >/dev/null
bash "$SCRIPTS/marina-runtimed.sh" status | grep -q stopped || fail "stop → stopped"
LA="$HOME/Library/LaunchAgents/marina.runtimed.plist"
if [ -f "$LA" ] && grep -q "$MARINA_HOME" "$LA"; then fail "테스트가 실제 로그인 항목을 건드렸다"; fi
# 리뷰 I3: 업데이트 감지로 0 종료 → systemd 도 다시 띄워야(on-failure 는 0 이면 안 띄움)
grep -q "Restart=always" "$SCRIPTS/marina-runtimed.sh" || fail "I3: systemd 유닛이 Restart=always 가 아니다"
# 리뷰 M8: 다른 인스턴스가 잠금을 쥐면 끝내지 말고 기다린다(끝내면 launchd 가 10초마다 다시 띄워 로그가 쌓인다)
PYTHONPATH="$SCRIPTS" python3 - <<'PY2'
import threading, time
import marina_runtimed as rd
a = rd.Loop(gateway=lambda: None, docker_gc=lambda p: None, worktree_gc=lambda p: None, primary=False, gateway_on=False)
assert a.own()
b = rd.Loop(gateway=lambda: None, docker_gc=lambda p: None, worktree_gc=lambda p: None, primary=False, gateway_on=False)
got = []
t = threading.Thread(target=lambda: got.append(b.own(wait=True)), daemon=True); t.start()
time.sleep(0.5); assert not got, "쥔 동안엔 기다린다"
a.lockf.close(); a.lockf = None
t.join(5); assert got == [True], "풀리면 이어받는다"

# 새 버전 받기는 따로 스레드에서(루프를 안 막는다) · 겹쳐 돌지 않는다 · 개발 실행은 받지 않는다
import marina_selfupdate as su
gate, ran = threading.Event(), []
def slow_tick(primary):
    ran.append(primary); gate.wait(5); return "installed"
su.tick = slow_tick
assert rd._is_dev(), "이 테스트는 레포에서 돈다"
rd._update(True); time.sleep(0.2)
assert ran == [] and not rd._updating.locked(), "개발 실행은 설치본을 받아 오지 않는다"
rd._is_dev = lambda: False
t0 = time.time(); rd._update(True); took = time.time() - t0
time.sleep(0.2)
assert took < 1 and ran == [True] and rd._updating.locked(), f"바로 돌아오고 뒤에서 돈다: {took} {ran}"
rd._update(True); time.sleep(0.2)
assert ran == [True], "받는 중엔 또 띄우지 않는다"
gate.set(); time.sleep(0.3)
assert not rd._updating.locked(), "끝나면 풀린다"
def boom(primary): raise RuntimeError("x")
su.tick = boom; rd._update(True); time.sleep(0.3)
assert not rd._updating.locked(), "tick 이 터져도 풀린다"
# 갈아타기 전 검증 — 안 뜨는 설치본은 한 시간, 검증을 못 돌린 건 10분 뒤 다시
from pathlib import Path
su.preflight = lambda d: (True, "")
assert rd._new_code_ok(Path("/x")) [0] is True
su.preflight = lambda d: (False, "SyntaxError")
assert rd._new_code_ok(Path("/x")) == (False, rd.RECHECK_BAD_S)
su.preflight = lambda d: (False, su.UNAVAILABLE + "timeout")
assert rd._new_code_ok(Path("/x")) == (False, rd.RECHECK_UNAVAILABLE_S)
PY2
echo "PASS test-runtimed"
