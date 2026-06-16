#!/usr/bin/env bash
# POST /api/set-autoupdate {harness:claude} — writes settings.json autoUpdate, preserves other keys
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export CLAUDE_CONFIG_DIR="$TMP/claude"; mkdir -p "$CLAUDE_CONFIG_DIR"
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{"theme":"dark","extraKnownMarketplaces":{"marina-dev":{"source":{"source":"github","repo":"turong92/marina"}}}}
JSON
PORT=39732; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
MARINA_HOME="$TMP/home" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" -d '{"harness":"claude"}' "$base/api/set-autoupdate" | python3 -c "import json,sys; assert json.load(sys.stdin).get('ok') is True" \
  || { echo "FAIL: set-autoupdate response"; exit 1; }
python3 -c "
import json
s=json.load(open('$CLAUDE_CONFIG_DIR/settings.json'))
assert s['extraKnownMarketplaces']['marina-dev']['autoUpdate'] is True, s
assert s['theme']=='dark', s          # 타 키 보존
assert s['extraKnownMarketplaces']['marina-dev']['source']['repo']=='turong92/marina', s
" || { echo "FAIL: settings.json not updated correctly"; exit 1; }

# 마켓플레이스 항목 없으면 4xx (날조 안 함)
echo '{}' > "$CLAUDE_CONFIG_DIR/settings.json"
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -d '{"harness":"claude"}' "$base/api/set-autoupdate")"
[[ "$code" == 4* ]] || { echo "FAIL: missing marketplace expected 4xx, got $code"; exit 1; }

echo "PASS test-set-autoupdate"
