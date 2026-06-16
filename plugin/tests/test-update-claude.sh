#!/usr/bin/env bash
# POST /api/update-claude — dry-run logs the update command, returns ok:true
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
export CLAUDE_CONFIG_DIR="$TMP/claude"; mkdir -p "$CLAUDE_CONFIG_DIR"
PORT=39733; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
MARINA_UPDATE_CLAUDE_DRY_RUN=1 MARINA_HOME="$MARINA_HOME" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
  MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 && break; sleep 0.1; done

# dry-run 응답: ok=true, harness=claude, output에 dry-run 마커
curl -s "${hdr[@]}" -d '{}' "$base/api/update-claude" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('ok') is True, d
assert d.get('harness') == 'claude', d
assert '(dry-run)' in (d.get('output') or ''), d
" || { echo "FAIL: update-claude response"; exit 1; }

# dry-run 로그에 claude plugin 명령 기록 확인
sleep 0.2
grep -q "claude plugin marketplace update marina-dev" "$MARINA_HOME/update-claude-dry-run.log" \
  || { echo "FAIL: dry-run did not log claude plugin marketplace update"; exit 1; }
grep -q "claude plugin update marina@marina-dev" "$MARINA_HOME/update-claude-dry-run.log" \
  || { echo "FAIL: dry-run did not log claude plugin update"; exit 1; }

# 데몬은 여전히 살아있어야
curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 \
  || { echo "FAIL: daemon died after dry-run update-claude"; exit 1; }

echo "PASS test-update-claude"
