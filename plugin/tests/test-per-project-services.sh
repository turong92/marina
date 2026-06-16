#!/usr/bin/env bash
# per-project 서비스 해석 — marina-services.json 있는 프로젝트는 자기 서비스만, 없는 프로젝트는 0개.
# (회귀: 전역 EXTRA_SERVICES "첫 프로젝트" 하나가 모든 프로젝트에 누수되던 버그 — homeserver 에 mdc 서비스 노출)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39712
base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT")

# 서비스 있는 프로젝트
PA="$TMP/withsvc"; mkdir -p "$PA"
cat > "$PA/marina-services.json" <<'JSON'
{"services":[{"name":"foo","portBase":4100},{"name":"bar","portBase":4200}]}
JSON
# 서비스 없는 프로젝트 (homeserver 류)
PB="$TMP/nosvc"; mkdir -p "$PB"

bash "$SH" add "$PA" >/dev/null
bash "$SH" add "$PB" >/dev/null

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" "$base/api/sessions" | python3 -c "
import json, sys
d = json.load(sys.stdin)
by = {s['root'].split('/')[-1]: [x['service'] for x in s.get('services', [])] for s in d['sessions']}
assert by.get('withsvc') == ['foo', 'bar'], by
assert by.get('nosvc') == [], by
" || { echo 'FAIL: per-project services'; exit 1; }

echo "PASS test-per-project-services"
