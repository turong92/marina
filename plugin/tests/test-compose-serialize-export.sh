#!/usr/bin/env bash
# 위저드 검토/공유: POST /api/compose-serialize (services YAML + x-marina → 합쳐진 compose) ·
# GET /api/compose-export?root= (등록 프로젝트 → unified compose). docker 불요(직렬화만).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
# 등록 프로젝트(export 용) — stored compose + 레거시 forward
PID="proj"; PD="$MARINA_HOME/$PID"; mkdir -p "$PD"
ROOT="$TMP/wt"; mkdir -p "$ROOT"
printf 'services:\n  be:\n    build: ./be\n    expose: ["8081"]\n' > "$PD/docker-compose.yml"
echo '{"forward":{"6379":{"target":"host"}}}' > "$PD/backing.json"
cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"$PID","root":"$ROOT","kind":"compose","composeFile":"docker-compose.yml"}]}
JSON

PORT="$(python3 - <<'PY' || exit $?
import socket, sys
s = socket.socket()
try: s.bind(("127.0.0.1", 0))
except PermissionError: sys.exit(42)
print(s.getsockname()[1]); s.close()
PY
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-compose-serialize-export (bind)"; exit 0; }; exit "$code"; }
base="http://127.0.0.1:$PORT"; H=(-H "Origin: $base" -H "content-type: application/json")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf -H "Origin: $base" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# 1) compose-serialize: services YAML + x-marina(int 키 포함) → 합쳐진 compose, x-marina 키 string
body=$(python3 -c 'import json; print(json.dumps({"yaml":"services:\n  app:\n    build: .\n","xmarina":{"forward":{6379:{"target":"host"}},"links":{"symlink":["node_modules"]}}}))')
curl -s "${H[@]}" -d "$body" "$base/api/compose-serialize" | python3 -c "
import json,sys
r=json.load(sys.stdin); assert r.get('ok'), r
import importlib.util
spec=importlib.util.spec_from_file_location('mc', sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
xm=mc.parse_xmarina(r['yaml'])
assert xm.get('forward')=={'6379':{'target':'host'}}, ('forward 키 string', xm)
assert (xm.get('links') or {}).get('symlink')==['node_modules'], xm
import yaml; assert 'app' in yaml.safe_load(r['yaml'])['services'], r['yaml']
print('serialize ok')
" "$HERE/../scripts/marina-compose.py" || { echo "FAIL: compose-serialize"; exit 1; }

# 2) compose-export: 등록 프로젝트 → unified compose(레거시 backing.json forward 마이그레이션 포함)
RE="root=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$ROOT")"
curl -s -H "Origin: $base" "$base/api/compose-export?$RE" | python3 -c "
import json,sys
r=json.load(sys.stdin); assert r.get('ok'), r
import importlib.util
spec=importlib.util.spec_from_file_location('mc', sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
xm=mc.parse_xmarina(r['yaml'])
assert xm.get('forward')=={'6379':{'target':'host'}}, ('레거시 forward 마이그레이션', xm)
print('export ok')
" "$HERE/../scripts/marina-compose.py" || { echo "FAIL: compose-export"; exit 1; }

echo "PASS test-compose-serialize-export"
