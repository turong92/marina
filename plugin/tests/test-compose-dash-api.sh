#!/usr/bin/env bash
# /api/sessions 가 compose 서비스를 native shape 로 돌려주고, /api/start·/api/stop 가 compose 를 구동한다. 데몬 없으면 SKIP.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"; CTRL="$HERE/../scripts/marina-control.py"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-dash-api (docker 데몬 미가용)"; exit 0; }
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
P="$TMP/proj-$$"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"   # 고유 basename — 실제 'proj' 프로젝트(-p proj-main)와 충돌 방지
cat > "$P/docker-compose.yml" <<'YML'
services:
  web: { image: "python:3-alpine", command: ["python","-m","http.server","8000"], ports: ["8000:8000"] }
YML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" start --all >/dev/null)
PORT=39713
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
cleanup(){ kill "$SRV" 2>/dev/null||true; (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" stop --all >/dev/null 2>&1)||true; rm -rf "$TMP"; }
trap cleanup EXIT
H="-H Origin:http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do curl -sf $H "http://127.0.0.1:$PORT/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done
# NOTE: `curl | python3 - <<PY` 는 heredoc 이 stdin 을 덮어 깨진다 → JSON 캡처 후 python3 -c (stdin=파이프).
printf '%s' "$(curl -sf $H "http://127.0.0.1:$PORT/api/sessions")" | python3 -c '
import json,sys
d=json.load(sys.stdin)
cs=[s for s in d["sessions"] if s.get("kind")=="compose"]
assert cs, "no compose session"
web=next((sv for s in cs for sv in s["services"] if sv["service"]=="web"), None)
assert web and str(web["port"]).isdigit() and web["running"] and web["health"]=="ok", web
print("ok sessions web", web["port"])
'
# /api/start 가 compose 서비스명 수락 (unknown service 400 아님)
code="$(curl -s -o /dev/null -w '%{http_code}' $H -X POST -H 'Content-Type: application/json' \
  -d "{\"root\":\"$P\",\"service\":\"web\"}" "http://127.0.0.1:$PORT/api/start")"
[[ "$code" != "400" ]] || { echo "FAIL: /api/start rejected compose service (log_targets_for)"; exit 1; }
echo "ok start accepted ($code)"
# /api/stop 가 실제로 compose 컨테이너를 내린다 (native no-op 아님 — Task 1.6)
scode="$(curl -s -o /dev/null -w '%{http_code}' $H -X POST -H 'Content-Type: application/json' \
  -d "{\"root\":\"$P\",\"service\":\"web\"}" "http://127.0.0.1:$PORT/api/stop")"
[[ "$scode" == "200" ]] || { echo "FAIL: /api/stop status $scode"; exit 1; }
printf '%s' "$(curl -sf $H "http://127.0.0.1:$PORT/api/sessions")" | python3 -c '
import json,sys
d=json.load(sys.stdin)
web=next((sv for s in d["sessions"] if s.get("kind")=="compose" for sv in s["services"] if sv["service"]=="web"), None)
assert web is not None and web["running"] is False, f"web should be stopped after /api/stop: {web}"
print("ok /api/stop drove compose down")
'
echo "PASS test-compose-dash-api"
