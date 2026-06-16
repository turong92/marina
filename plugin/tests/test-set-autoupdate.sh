#!/usr/bin/env bash
# POST /api/set-autoupdate — endpoint 제거됨. 404 반환 확인.
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

# autoUpdate 기능 제거 — 엔드포인트가 없으므로 4xx 반환
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -d '{"harness":"claude"}' "$base/api/set-autoupdate")"
[[ "$code" == 4* ]] || { echo "FAIL: set-autoupdate expected 4xx (removed endpoint), got $code"; exit 1; }

echo "PASS test-set-autoupdate"
