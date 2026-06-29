#!/usr/bin/env bash
# compose 등록 엔드포인트: detect→validate→register(projects.json kind:compose + 복사). origin-gate.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"; CTRL="$SCR/marina-control.py"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/proj"; mkdir -p "$P/web"; : > "$P/web/Dockerfile"
PORT="$(python3 - <<'PY' || exit $?
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", 0))
except PermissionError:
    sys.exit(42)
print(s.getsockname()[1])
s.close()
PY
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-compose-register-api (localhost bind unavailable)"; exit 0; }; exit "$code"; }
cleanup(){ kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
b="http://127.0.0.1:$PORT"; H=(-H "Origin: $b" -H "content-type: application/json")
for i in $(seq 1 50); do curl -s -o /dev/null "$b/api/sessions" && break; sleep 0.1; done

# origin-gate: 잘못된 Origin → 403 (kept non-LLM validate endpoint)
validate_body=$(python3 -c 'import json,sys; print(json.dumps({"path":sys.argv[1],"yaml":"services:\n  web:\n    image: nginx\n"}))' "$P")
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Origin: http://evil.test" -H "content-type: application/json" -d "$validate_body" "$b/api/compose-validate")
[ "$code" = "403" ] || { echo "FAIL: origin-gate ($code)"; exit 1; }

# detect: 레포에 compose 두면 후보로 잡힘
printf 'services:\n  x:\n    image: alpine\n' > "$P/docker-compose.yml"
curl -s "${H[@]}" "$b/api/compose-detect?path=$P" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'] and any(f['rel']=='docker-compose.yml' for f in r['files']), r" || { echo "FAIL: compose-detect"; exit 1; }

# register: validate(docker 가동 시 실검증)→ projects.json kind:compose + ~/.marina/<id>/ 복사
if docker info >/dev/null 2>&1; then
  body=$(python3 -c 'import json,sys; print(json.dumps({"path":sys.argv[1],"yaml":"services:\n  web:\n    image: nginx\n","envVar":"APP_ENV","envDefault":"local"}))' "$P")
  curl -s "${H[@]}" -d "$body" "$b/api/compose-register" \
    | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'], r" || { echo "FAIL: compose-register"; exit 1; }
  python3 - "$MARINA_HOME" <<'PY' || { echo "FAIL: registry kind:compose"; exit 1; }
import json,sys
from pathlib import Path
home=Path(sys.argv[1])
d=json.loads((home/"projects.json").read_text())
projs=d["projects"]; assert len(projs)==1, projs
p=projs[0]
assert p["kind"]=="compose" and p["composeFile"]=="docker-compose.yml" \
   and p["composeEnvVar"]=="APP_ENV" and p["composeEnvDefault"]=="local", p
assert (home/p["id"]/"docker-compose.yml").exists(), "stored compose missing"
PY
else
  echo "  (docker 미가동 — register 실검증 SKIP)"
fi
echo "PASS test-compose-register-api"
