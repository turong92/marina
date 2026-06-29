#!/usr/bin/env bash
# /api/compose-service-profile — build-args.json 에 profile(감지/지정 var) 저장. origin-gate. docker 불요(var 지정).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"; CTRL="$SCR/marina-control.py"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/proj"; mkdir -p "$P/web"; printf 'FROM nginx\nARG PROFILE\n' > "$P/web/Dockerfile"
# 프로젝트 직접 시드(docker 없이 등록) — kind:compose
cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"proj","root":"$P","kind":"compose","composeFile":"docker-compose.yml","subrepos":[],"worktreeGlobs":[]}]}
JSON
PORT="$(python3 - <<'PY' || exit $?
import socket, sys
s = socket.socket()
try: s.bind(("127.0.0.1", 0))
except PermissionError: sys.exit(42)
print(s.getsockname()[1]); s.close()
PY
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-profile-api (bind unavailable)"; exit 0; }; exit "$code"; }
cleanup(){ kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
b="http://127.0.0.1:$PORT"; H=(-H "Origin: $b" -H "content-type: application/json")
for i in $(seq 1 50); do curl -s -o /dev/null "$b/api/sessions" && break; sleep 0.1; done

# 저장: var 지정(UI 처럼) → build-args.json[web].PROFILE=dev
code=$(curl -s "${H[@]}" -o /tmp/pp.json -w "%{http_code}" -d "{\"root\":\"$P\",\"service\":\"web\",\"value\":\"dev\",\"var\":\"PROFILE\"}" "$b/api/compose-service-profile")
[ "$code" = "200" ] || { echo "FAIL: expected 200 got $code"; cat /tmp/pp.json; exit 1; }
python3 -c "import json;d=json.load(open('$MARINA_HOME/proj/build-args.json'));assert d.get('web',{}).get('PROFILE')=='dev',d" || { echo "FAIL: build-args 미반영"; exit 1; }

# 빈 값 → 키 제거
curl -s "${H[@]}" -o /dev/null -d "{\"root\":\"$P\",\"service\":\"web\",\"value\":\"\",\"var\":\"PROFILE\"}" "$b/api/compose-service-profile"
python3 -c "import json;d=json.load(open('$MARINA_HOME/proj/build-args.json'));assert 'PROFILE' not in d.get('web',{}),d" || { echo "FAIL: 빈값 제거 안 됨"; exit 1; }

# 잘못된 입력(service 없음) → 400
bad=$(curl -s "${H[@]}" -o /dev/null -w "%{http_code}" -d "{\"root\":\"$P\"}" "$b/api/compose-service-profile")
[ "$bad" = "400" ] || { echo "FAIL: expected 400 got $bad"; exit 1; }

# origin-gate: 잘못된 Origin → 403
ev=$(curl -s -o /dev/null -w "%{http_code}" -H "Origin: http://evil.test" -H "content-type: application/json" -d "{\"root\":\"$P\",\"service\":\"web\",\"value\":\"x\",\"var\":\"PROFILE\"}" "$b/api/compose-service-profile")
[ "$ev" = "403" ] || { echo "FAIL: origin-gate ($ev)"; exit 1; }

echo "PASS test-profile-api"
