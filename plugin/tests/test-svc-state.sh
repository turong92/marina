#!/usr/bin/env bash
# 서비스 정규화 state: busyError>busy>degraded>external>health(bad|starting)>running>stopped + reason
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 - "$HERE/../scripts" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import marina_sessions as ms

def st(sv): return ms.svc_state(sv)
assert st({"running":True,"health":"ok"}) == ("running", None)
assert st({"running":True,"health":"starting"}) == ("starting", None)
assert st({"running":True,"health":"bad"}) == ("error", "unhealthy")
assert st({"running":False}) == ("stopped", None)
assert st({"running":True,"health":"ok","external":True}) == ("external", None)
assert st({"running":False,"degraded":True,"degradedReason":"web/Dockerfile 없음"}) == ("degraded", "web/Dockerfile 없음")
assert st({"running":False,"degraded":True}) == ("degraded", "Dockerfile 없음")
assert st({"running":False,"busy":"start"}) == ("starting", None)
assert st({"running":True,"busy":"restart"}) == ("starting", None)
assert st({"running":False,"busyError":"start timed out (1800s)"}) == ("error", "start timed out (1800s)")
# busyError 가 busy·degraded 보다 우선, external 이 health 보다 우선
assert st({"running":True,"health":"bad","external":True})[0] == "external"
# 비정상 종료(크래시·OOM)는 error + 이유, 정상 정지 코드(0/130/143)는 stopped
assert st({"running":False,"exitCode":1}) == ("error", "비정상 종료 (exit 1)")
assert st({"running":False,"exitCode":137}) == ("error", "비정상 종료 (exit 137)")
assert st({"running":False,"exitCode":0}) == ("stopped", None)
assert st({"running":False,"exitCode":143}) == ("stopped", None)
assert st({"running":False,"exitCode":130}) == ("stopped", None)
assert st({"running":True,"health":"ok","exitCode":1}) == ("running", None)   # 실행 중이면 옛 exit 잔재 무시
assert st({"running":False,"busy":"start","exitCode":1}) == ("starting", None)  # 재시도 중엔 기동중이 우선
print("ok svc_state")
PY
echo "PASS test-svc-state"
