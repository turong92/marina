#!/usr/bin/env bash
# update_state pure fn + /api/update-status shape
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"

# --- unit: update_state ---
python3 - "$CTRL" <<'PY' || { echo "FAIL: update_state unit"; exit 1; }
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
us = mc.update_state
assert us("abc", "abc", "abc") == "current", us("abc","abc","abc")
assert us("abc", "def", "def") == "stale", us("abc","def","def")          # serving<installed, installed==origin
assert us("abc", "abc", "def") == "new", us("abc","abc","def")            # installed<origin
assert us("abc", "def", "ghi") == "new", us("abc","def","ghi")            # both behind → NEW (newer published)
assert us(None, "abc", "def") == "unknown", us(None,"abc","def")          # serving unknown (dev/repo run)
assert us("abc", None, "def") == "unknown", us("abc",None,"def")          # installed unknown
assert us("abc", "abc", None) == "current", us("abc","abc",None)          # origin unknown, serving==installed → no banner
assert us("abc", "def", None) == "stale", us("abc","def",None)            # origin unknown, serving<installed → restart
PY
echo "PASS test-update-status (unit)"

# --- endpoint: /api/update-status with all three SHAs stubbed via env ---
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
cat > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" <<'JSON'
{"plugins":{"marina@marina-dev":[{"installPath":"/x/marina-dev/marina/aaaaaaaaaaaa"}]}}
JSON
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{"extraKnownMarketplaces":{"marina-dev":{"source":{"source":"github","repo":"turong92/marina"}}}}
JSON
PORT=39730; base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")
# serving=bbbb, installed(file)=aaaa, origin(env)=cccc → NEW; autoUpdate claude = false (key absent)
# codex config.toml (marina 설치 기록) → harnesses 에 codex 포함 검증. CODEX_HOME 격리로 결정적.
mkdir -p "$TMP/codex"
printf '[plugins."marina@marina-dev"]\nenabled = true\n' > "$TMP/codex/config.toml"
MARINA_HOME="$TMP/home" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" CODEX_HOME="$TMP/codex" \
  MARINA_SERVING_SHA=bbbbbbbbbbbb MARINA_ORIGIN_SHA=cccccccccccc \
  MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 && break; sleep 0.1; done
curl -s "${hdr[@]}" "$base/api/update-status" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['serving']=='bbbbbbbbbbbb', d
assert d['installed']=='aaaaaaaaaaaa', d
assert d['origin']=='cccccccccccc', d
assert d['state']=='new', d
assert d['autoUpdate']['claude'] is False, d
assert sorted(d['harnesses'])==['claude','codex'], d   # claude=installed_plugins.json, codex=config.toml
" || { echo "FAIL: update-status endpoint"; exit 1; }

echo "PASS test-update-status"
