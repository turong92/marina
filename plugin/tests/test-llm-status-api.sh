#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""; cleanup(){ [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
echo '{"llmProvider":"codex"}' > "$MARINA_HOME/config.json"
PORT=39740; b="http://127.0.0.1:$PORT"; H=(-H "Origin: http://127.0.0.1:$PORT")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 50); do curl -sf "${H[@]}" "$b/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done
curl -s "${H[@]}" "$b/api/llm-status" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert 'providers' in r and isinstance(r['providers'],list);assert r['pinned']=='codex', r" \
  || { echo "FAIL: llm-status"; exit 1; }
echo "PASS test-llm-status-api"
