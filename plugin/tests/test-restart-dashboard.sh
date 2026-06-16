#!/usr/bin/env bash
# POST /api/restart-dashboard — dry-run logs the restart command, responds fast
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
PORT=39731; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
MARINA_RESTART_DRY_RUN=1 MARINA_HOME="$MARINA_HOME" MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" -d '{}' "$base/api/restart-dashboard" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('restarting') is True, d" \
  || { echo "FAIL: restart-dashboard response"; exit 1; }
# dry-run 로그에 restart 명령 기록 확인
sleep 0.3
grep -q "marina-dashboard.sh restart" "$MARINA_HOME/restart-dry-run.log" \
  || { echo "FAIL: dry-run did not log restart command"; exit 1; }
# 데몬은 여전히 살아있어야 (dry-run 이라 실제 재시작 안 함)
curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 \
  || { echo "FAIL: daemon died on dry-run restart"; exit 1; }

echo "PASS test-restart-dashboard"
