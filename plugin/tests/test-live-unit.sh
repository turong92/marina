#!/usr/bin/env bash
# 부팅 지속성 유닛 — 내용 생성은 순수 함수. 등록(launchctl/systemctl)은 MARINA_HOME 이
# 실제 ~/.marina 일 때만 하므로(marina-dashboard.sh install_login_plist 와 같은 가드)
# 이 테스트는 형의 기계에 유닛을 등록하지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

python3 - "$SCRIPTS" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import marina_live as L

plist = L.plist_body("ovation", "/usr/local/bin/marina")

# 1) 재로그인·재부팅을 넘기려면 RunAtLoad 가 있어야 한다
assert "<key>RunAtLoad</key>" in plist and "<true/>" in plist, plist

# 2) 같은 명령을 재실행한다 — 유닛이 로직을 복제하면 두 경로가 갈라진다
assert "<string>live</string>" in plist and "<string>up</string>" in plist, plist
assert "<string>ovation</string>" in plist, plist

# 3) 도커 데몬이 아직 안 떴을 수 있으므로 KeepAlive 로 재시도한다
assert "<key>KeepAlive</key>" in plist, plist
assert "<key>ThrottleInterval</key>" in plist, "재시도 간격이 없으면 부팅 직후 폭주한다"

# 4) launchd 는 최소 PATH(/usr/bin:/bin:...)만 준다 — docker 를 못 찾으면 조용히 실패한다
assert "<key>PATH</key>" in plist, plist
assert "<key>MARINA_HOME</key>" in plist, "MARINA_HOME 이 안 넘어가면 다른 홈을 본다"

# 5) 로그 경로가 ~/.marina 안이다 (워크트리가 아니라 — 워크트리는 지워진다)
assert str(L.live_root("ovation")) in plist, plist

# systemd ini 는 인용이 없으면 공백에서 값을 쪼갠다 — PATH 에 공백이 있는 기계에서
# 유닛이 **로드되지 않아** 자동 기동이 조용히 사라진다(설치 시점 PATH 를 그대로 굽는다)
import os as _os
_os.environ["PATH"] = "/usr/local/bin:/Users/x/My Tools/bin:/usr/bin"
svc_spaced = L.systemd_body("ovation", "/usr/local/bin/marina")
assert 'Environment="PATH=' in svc_spaced, svc_spaced
assert 'Environment="MARINA_HOME=' in svc_spaced, svc_spaced

svc = L.systemd_body("ovation", "/usr/local/bin/marina")
assert "Restart=" in svc and "WantedBy=default.target" in svc, svc
assert "ovation" in svc, svc
assert 'Environment="PATH=' in svc, svc
assert "After=docker.service" in svc, svc
print("ok")
PY

echo "--- 유닛 스크립트"
# 6) install 이 멱등이다 — 두 번 돌려도 파일이 하나고 내용이 같다
bash "$SCRIPTS/marina-live-unit.sh" install ovation >/dev/null
f1="$(find "$MARINA_HOME/ovation/live" -name 'unit.*' | head -1)"
[ -n "$f1" ] || { echo "FAIL: 유닛 파일이 안 생겼다"; exit 1; }
sum1="$(shasum "$f1" | cut -d' ' -f1)"
bash "$SCRIPTS/marina-live-unit.sh" install ovation >/dev/null
n="$(find "$MARINA_HOME/ovation/live" -name 'unit.*' | wc -l | tr -d ' ')"
[ "$n" = "1" ] || { echo "FAIL: 유닛 파일이 $n 개"; exit 1; }
sum2="$(shasum "$f1" | cut -d' ' -f1)"
[ "$sum1" = "$sum2" ] || { echo "FAIL: 두 번째 install 이 내용을 바꿨다"; exit 1; }

# 7) 테스트 MARINA_HOME 에서는 기계에 등록하지 않는다
out="$(bash "$SCRIPTS/marina-live-unit.sh" install ovation 2>&1)"
case "$out" in *"등록 생략"*) ;; *) echo "FAIL: 등록 생략을 알리지 않는다: $out"; exit 1 ;; esac
[ ! -e "$HOME/Library/LaunchAgents/dev.marina.live.ovation.plist" ] || { echo "FAIL: 실제 LaunchAgents 를 건드렸다"; exit 1; }

# 8) **유닛 파일이 있다는 것만으로 "등록됨" 이라고 하지 않는다.**
#    파일은 marina 가 방금 썼다 — 그것을 신호로 쓰면 launchctl 등록이 실패해도 초록불이
#    켜지고, 재부팅하면 서비스가 없다. 설계가 "이 줄이 유일한 신호다" 라고 못 박은 줄이다.
out="$(bash "$SCRIPTS/marina-live-unit.sh" status ovation 2>&1)"
case "$out" in
  *"안 됨"*) ;;
  *) echo "FAIL: 기계에 등록되지 않았는데 '등록됨' 으로 보인다: $out"; exit 1 ;;
esac
# 왜 안 됐는지도 말한다
case "$out" in *생략*|*등록되지*) ;; *) echo "FAIL: 이유를 말하지 않는다: $out"; exit 1 ;; esac

# 9) 등록이 실패하면 **비0으로 끝낸다** — 호출부가 경고를 흘릴 수 있어야 한다
FAKEBIN="$MARINA_HOME/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh
echo "Load failed: 5" >&2
exit 1
' > "$FAKEBIN/launchctl"
printf '#!/bin/sh
exit 1
' > "$FAKEBIN/systemctl"
chmod +x "$FAKEBIN/launchctl" "$FAKEBIN/systemctl"
REALHOME="$MARINA_HOME/fakehome"; mkdir -p "$REALHOME/.marina"
set +e
out="$(HOME="$REALHOME" MARINA_HOME="$REALHOME/.marina" PATH="$FAKEBIN:$PATH"        bash "$SCRIPTS/marina-live-unit.sh" install ovation 2>&1)"
rc=$?
set -e
[ "$rc" != "0" ] || { echo "FAIL: 등록 실패인데 0 으로 끝났다: $out"; exit 1; }
case "$out" in *경고*) ;; *) echo "FAIL: 등록 실패를 경고하지 않는다: $out"; exit 1 ;; esac
# 등록이 실패했으면 status 도 '안 됨' 이어야 한다 (유닛 파일은 쓰였는데도)
out="$(HOME="$REALHOME" MARINA_HOME="$REALHOME/.marina" PATH="$FAKEBIN:$PATH"        bash "$SCRIPTS/marina-live-unit.sh" status ovation 2>&1)"
case "$out" in *"안 됨"*) ;; *) echo "FAIL: 등록 실패 후에도 '등록됨': $out"; exit 1 ;; esac

# 10) uninstall 이 파일을 지운다
bash "$SCRIPTS/marina-live-unit.sh" uninstall ovation >/dev/null
[ -e "$f1" ] && { echo "FAIL: uninstall 후에도 유닛이 남았다"; exit 1; } || true

# 11) 유닛이 없으면 status 가 "안 됨" 을 보여준다 — 유닛 설치가 실패해도 기동은 유지되므로,
#     그 사실이 계속 보여야 "재부팅했는데 서비스가 없다" 를 막는다
out="$(bash "$SCRIPTS/marina-live-unit.sh" status ovation 2>&1 || true)"
case "$out" in *"안 됨"*) ;; *) echo "FAIL: 유닛 없음을 알리지 않는다: $out"; exit 1 ;; esac

# 12) MARINA_HOME 경로에 공백이 있어도 된다 — eval 로 값을 받으므로 인용이 필요하다
SPACED="$MARINA_HOME/with space"
mkdir -p "$SPACED"
out="$(MARINA_HOME="$SPACED" bash "$SCRIPTS/marina-live-unit.sh" install ovation 2>&1)"
[ -f "$SPACED/ovation/live/unit.plist" ] || [ -f "$SPACED/ovation/live/unit.service" ]   || { echo "FAIL: 공백 경로에서 유닛을 못 만들었다: $out"; exit 1; }
out="$(MARINA_HOME="$SPACED" bash "$SCRIPTS/marina-live-unit.sh" status ovation 2>&1)"
case "$out" in *"자동 기동"*) ;; *) echo "FAIL: 공백 경로 status 실패: $out"; exit 1 ;; esac

# 13) unit.log 가 무한히 자라지 않는다 — 영구 실패 상태에서 10초마다 재시도하므로
#     회전이 없으면 한 달에 수십만 줄이 쌓인다(KeepAlive 는 의도적으로 무한이다)
python3 - "$SCRIPTS" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import marina_live as L
log = L.live_root("ovation") / "unit.log"
log.parent.mkdir(parents=True, exist_ok=True)
log.write_bytes(b"x" * (L.UNIT_LOG_MAX_BYTES + 5000))
L.rotate_unit_log("ovation")
assert log.stat().st_size <= L.UNIT_LOG_MAX_BYTES, log.stat().st_size
old = L.live_root("ovation") / "unit.log.1"
assert old.exists(), "회전본이 없다 — 원인을 보려면 직전 로그가 남아야 한다"
# 작은 로그는 건드리지 않는다
log.write_bytes(b"small")
L.rotate_unit_log("ovation")
assert log.read_bytes() == b"small"
print("ok")
PY

# 14) 알 수 없는 동작은 거부
bash "$SCRIPTS/marina-live-unit.sh" bogus ovation >/dev/null 2>&1 && { echo "FAIL: bogus 통과"; exit 1; } || true
echo "PASS test-live-unit"
