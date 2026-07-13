#!/usr/bin/env bash
# /api/weave-map — 연결 탭(P3) 데이터 소스: 엮기(forward) 최종 맵 + 서비스별 적용분(applied) + 서비스 상태.
# cmd_up 과 동일한 병합(legacy hostForward < 자동 서비스타겟 < 명시(backing.json < x-marina))을
# marina-compose.py 순수 함수 재사용으로 재계산 — docker up/ps 없이 config 해석만(가볍게).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"; CTRL="$HERE/../scripts/marina-control.py"
command -v docker >/dev/null 2>&1 || { echo "SKIP test-weave-map-api (docker CLI 미설치 — config 해석 불가)"; exit 0; }
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
export MARINA_GATEWAY=off
SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# 서비스 2개(app=build, redis=image-only) + x-marina.forward 로 host 백킹(redis) 선언 — 자동타겟(app:8000)과 명시(6379→host) 둘 다 검증
P="$TMP/proj-$$"; mkdir -p "$P/app"; P="$(cd "$P" && pwd -P)"
cat > "$P/app/Dockerfile" <<'DF'
FROM python:3-alpine
CMD ["python","-m","http.server","8000"]
DF
cat > "$P/docker-compose.yml" <<'YML'
services:
  app:
    build: ./app
    ports: ["8000:8000"]
  cache:
    image: redis:alpine
x-marina:
  forward:
    "6379": host
YML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null

PORT=39779; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# ── (a) forward: 자동 서비스타겟(app:8000, expose/ports 로 자동 감지) + 명시 host 타겟(6379) 둘 다 존재 ──
curl -s "${hdr[@]}" "$base/api/weave-map?root=$P" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('ok') is True, d
assert d['forward'].get('8000') == 'app', d['forward']
assert d['forward'].get('6379') == 'host', d['forward']
# applied — build 서비스(app)만, 자기서빙 포트(8000) 제외 + host 타겟(6379) 포함
assert d['applied'].get('app') == [['6379', 'host']], d['applied']
assert 'cache' not in d['applied'], d['applied']   # image-only 서비스는 사이드카 없음
names = sorted(s['service'] for s in d['services'])
assert names == ['app', 'cache'], names
assert isinstance(d.get('warnings'), list), d
assert d.get('appServices') == ['app', 'cache'], d.get('appServices')   # 엮기 사이드카(-bind) 필터용 — 보관 compose 서비스명만
print('ok forward/applied/services', d['forward'], d['applied'])
" || { echo 'FAIL: weave-map ok payload'; exit 1; }

# ── (b) 미등록/미탐색 root → 4xx 또는 ok:false ────────────────────
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "$base/api/weave-map?root=$TMP/never-registered")"
if [[ "$code" == 4* ]]; then
  : # 4xx OK
else
  curl -s "${hdr[@]}" "$base/api/weave-map?root=$TMP/never-registered" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('ok') is False, d
" || { echo "FAIL: unregistered root expected 4xx or ok:false, got $code"; exit 1; }
fi

echo "PASS test-weave-map-api"
