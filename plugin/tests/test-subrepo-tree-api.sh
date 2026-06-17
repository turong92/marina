#!/usr/bin/env bash
# service_subrepo longest-prefix unit + payload fields (attachedSubrepos, service.subrepo, defaultAttach)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"

# --- unit: service_subrepo longest-prefix (no server) ---
python3 - "$CTRL" <<'PY' || { echo "FAIL: service_subrepo unit"; exit 1; }
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
ss = mc.service_subrepo
assert ss("web-app-monorepo/apps/web", ["ai-api","be-api","web-app-monorepo"]) == "web-app-monorepo", ss("web-app-monorepo/apps/web", ["ai-api","be-api","web-app-monorepo"])
assert ss("projects/react-skeleton/app", ["projects","projects/react-skeleton"]) == "projects/react-skeleton"
assert ss("ai-api/index_api", ["ai-api"]) == "ai-api"
assert ss(".", ["a"]) == ""
assert ss("", ["a"]) == ""
assert ss("unknown/dir", ["a","b"]) == "unknown"   # no match, non-root → first segment
PY

# --- payload: main checkout with services + partial on-disk subrepos ---
PORT=39713; base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")
P="$TMP/proj"; mkdir -p "$P/a/.git" "$P/b/.git"   # a,b attached on disk; c absent
cat > "$P/marina-services.json" <<'JSON'
{"services":[
  {"name":"asvc","portBase":4100,"cwd":"a/sub"},
  {"name":"bsvc","portBase":4200,"cwd":"b"},
  {"name":"rootsvc","portBase":4300,"cwd":"."}
]}
JSON
bash "$HERE/../scripts/marina.sh" project add "$P" --subrepos a,b,c >/dev/null
id="$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
bash "$HERE/../scripts/marina.sh" project default "$id" a,b >/dev/null

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# worktrees: registered root is "main" → attachedSubrepos = all universe; defaultAttach = [a,b]
curl -s "${hdr[@]}" "$base/api/worktrees" | python3 -c "
import json, sys
w = next(x for x in json.load(sys.stdin)['worktrees'] if x['root'].endswith('/proj'))
assert w['isMain'] is True, w
assert sorted(w['attachedSubrepos']) == ['a','b','c'], w['attachedSubrepos']
assert w['defaultAttach'] == ['a','b'], w['defaultAttach']
" || { echo "FAIL: worktree payload"; exit 1; }

# sessions: each service tagged with longest-prefix subrepo
curl -s "${hdr[@]}" "$base/api/sessions" | python3 -c "
import json, sys
s = next(x for x in json.load(sys.stdin)['sessions'] if x['root'].endswith('/proj'))
by = {x['service']: x.get('subrepo') for x in s['services']}
assert by == {'asvc':'a','bsvc':'b','rootsvc':''}, by
" || { echo "FAIL: service subrepo tagging"; exit 1; }

echo "PASS test-subrepo-tree-api"
