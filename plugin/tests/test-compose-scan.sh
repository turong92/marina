#!/usr/bin/env bash
# 비-LLM compose 스캔: POST /api/compose-scan {root} → 서브레포별 Dockerfile(ARG·필수ARG·EXPOSE·아티팩트·설정후보).
# LLM 안 씀 — 헬퍼(_list_dockerfiles·_dockerfile_expose·_detect_injections) 만으로 스캔.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
# 더미 레포: 서브레포 2개, 각 Dockerfile(ARG·필수ARG·EXPOSE·jar 아티팩트)
ROOT="$TMP/proj"
mkdir -p "$ROOT/be-api" "$ROOT/web"
cat > "$ROOT/be-api/Dockerfile" <<'DF'
FROM eclipse-temurin:21
ARG PROFILE
ARG VERSION
RUN [ -z "$PROFILE" ] && exit 1 || true
COPY build/libs/app.jar /app.jar
EXPOSE 8081
DF
cat > "$ROOT/web/Dockerfile" <<'DF'
FROM node:22
ARG BUILD_ENV
EXPOSE 3000
DF

PORT="$(python3 - <<'PY' || exit $?
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", 0))
except PermissionError:
    sys.exit(42)
print(s.getsockname()[1]); s.close()
PY
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-compose-scan (localhost bind unavailable)"; exit 0; }; exit "$code"; }
base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" -X POST "$base/api/compose-scan" -H "content-type: application/json" \
  -d "{\"root\":\"$ROOT\"}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('ok') is True, d
by = {s['subrepo']: s for s in d['subrepos']}
assert {'be-api','web'} <= set(by), ('서브레포 감지', list(by))
be = by['be-api']['dockerfiles']
assert any(df['dockerfile']=='Dockerfile' for df in be), be
df0 = next(df for df in be if df['dockerfile']=='Dockerfile')
assert df0['expose']=='8081', df0
assert set(df0['args']) >= {'PROFILE','VERSION'}, df0['args']
assert 'PROFILE' in df0['requiredArgs'], df0['requiredArgs']            # [ -z \"\$PROFILE\" ] 가드 → 필수
assert any('app.jar' in a for a in df0['artifacts']), df0['artifacts']  # COPY *.jar → 선빌드 아티팩트
web = by['web']['dockerfiles']
assert web and web[0]['expose']=='3000', web
print('ok')
" || { echo "FAIL: compose-scan 구조"; exit 1; }

echo "PASS test-compose-scan"
