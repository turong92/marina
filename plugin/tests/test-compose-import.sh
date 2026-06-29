#!/usr/bin/env bash
# 팀원 공유 블록 가져오기: POST /api/compose-import {root, blob} → 등록 + x-marina 동봉(stored compose).
# 잘못된 YAML → 4xx. docker 가동 시 happy path(등록 + stored compose 에 x-marina 보존) 검증.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
ROOT="$TMP/proj"; mkdir -p "$ROOT/be-api"; : > "$ROOT/be-api/Dockerfile"
printf 'FROM alpine\nEXPOSE 8081\n' > "$ROOT/be-api/Dockerfile"

PORT="$(python3 - <<'PY' || exit $?
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", 0))
except PermissionError:
    sys.exit(42)
print(s.getsockname()[1]); s.close()
PY
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-compose-import (localhost bind unavailable)"; exit 0; }; exit "$code"; }
base="http://127.0.0.1:$PORT"; H=(-H "Origin: $base" -H "content-type: application/json")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf -H "Origin: $base" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# 1) 잘못된 YAML → 4xx (docker 불요 — 파싱 단계서 차단)
bad=$(python3 -c 'import json,sys;print(json.dumps({"root":sys.argv[1],"blob":"services: [this: is: not valid"}))' "$ROOT")
code=$(curl -s -o /dev/null -w "%{http_code}" "${H[@]}" -d "$bad" "$base/api/compose-import")
[[ "$code" == 4* ]] || { echo "FAIL: 잘못된 YAML 인데 4xx 아님 ($code)"; exit 1; }

# 2) blob 없음 → 4xx
code=$(curl -s -o /dev/null -w "%{http_code}" "${H[@]}" -d "{\"root\":\"$ROOT\"}" "$base/api/compose-import")
[[ "$code" == 4* ]] || { echo "FAIL: blob 없는데 4xx 아님 ($code)"; exit 1; }

# 3) happy path (docker 가동 시) — 등록 + stored compose 에 x-marina 보존
if docker info >/dev/null 2>&1; then
  blob=$(python3 - "$ROOT" <<'PY'
import json, sys
blob = """services:
  be:
    build: ./be-api
    expose: ["8081"]
x-marina:
  prebuild: {be-api: ./gradlew assemble}
  links: {symlink: [node_modules], copy: ["**/*local.yml"]}
  forward: {"6379": {target: host}}
  gateway: {routes: {be: ["/v1.0"]}}
"""
print(json.dumps({"root": sys.argv[1], "blob": blob}))
PY
)
  resp="$(curl -s "${H[@]}" -d "$blob" "$base/api/compose-import")"
  echo "$resp" | python3 -c "import json,sys;r=json.load(sys.stdin);assert r.get('ok') is True, r;print('id', r['id'])" \
    || { echo "FAIL: import 등록 ($resp)"; exit 1; }
  # stored compose 에 x-marina 동봉 확인 → 런타임이 거기서 forward/prebuild/gateway 읽음
  pid="$(echo "$resp" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
  python3 - "$MARINA_HOME/$pid/docker-compose.yml" "$HERE/../scripts/marina-compose.py" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mc", sys.argv[2]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
xm = mc.xmarina_for_stored(sys.argv[1])
assert xm.get("prebuild")=={"be-api":"./gradlew assemble"}, xm
assert xm.get("forward")=={"6379":{"target":"host"}}, xm
assert (xm.get("gateway") or {}).get("routes")=={"be":["/v1.0"]}, xm
print("x-marina preserved in stored compose")
PY
else
  echo "  (docker 미가동 — happy path SKIP, 4xx 경로만 검증)"
fi

echo "PASS test-compose-import"
