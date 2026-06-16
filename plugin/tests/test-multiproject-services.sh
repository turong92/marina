#!/usr/bin/env bash
# per-project service state: two projects with different service sets stay isolated.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"

PA="$TMP/alpha"; mkdir -p "$PA"
cat > "$PA/marina-services.json" <<'JSON'
{"services":[{"name":"foo","portBase":4100,"cachePaths":["foo/.cache"],"orphanPattern":"foo-daemon"}]}
JSON
PB="$TMP/beta"; mkdir -p "$PB"
cat > "$PB/marina-services.json" <<'JSON'
{"services":[{"name":"bar","portBase":4200},{"name":"baz","portBase":4300}]}
JSON
bash "$SH" add "$PA" >/dev/null
bash "$SH" add "$PB" >/dev/null

# --- unit: per-project lookups (no server) ---
python3 - "$CTRL" "$PA" "$PB" <<'PY' || { echo "FAIL: per-project lookup unit"; exit 1; }
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
a, b = Path(sys.argv[2]), Path(sys.argv[3])
assert mc.services_for(a) == ("foo",), mc.services_for(a)
assert mc.services_for(b) == ("bar","baz"), mc.services_for(b)
assert mc.port_base_for(a) == {"foo":4100}, mc.port_base_for(a)
assert mc.port_base_for(b) == {"bar":4200,"baz":4300}, mc.port_base_for(b)
assert mc.log_targets_for(a) == ("foo","console"), mc.log_targets_for(a)
assert [n for n,_ in mc.orphan_rules_for(a)] == ["marina","foo"], mc.orphan_rules_for(a)
assert [n for n,_ in mc.orphan_rules_for(b)] == ["marina"], mc.orphan_rules_for(b)
allr = [n for n,_ in mc.orphan_rules_all()]
assert "foo" in allr and allr.count("marina") == 1, allr   # union, marina deduped
assert "baz" not in allr and "bar" not in allr, allr        # orphanPattern 없는 서비스는 제외
PY
echo "PASS test-multiproject-services (unit)"

# --- payload: each project's sessions expose only its own services + ports ---
PORT=39715; b="http://127.0.0.1:$PORT"; H=(-H "Origin: http://127.0.0.1:$PORT")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${H[@]}" "$b/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done
curl -s "${H[@]}" "$b/api/sessions" | python3 -c "
import json, sys
d = json.load(sys.stdin)
svc = {s['root'].split('/')[-1]: sorted(x['service'] for x in s.get('services', [])) for s in d['sessions']}
prt = {s['root'].split('/')[-1]: {x['service']: x.get('port') for x in s.get('services', [])} for s in d['sessions']}
assert svc.get('alpha') == ['foo'], svc
assert svc.get('beta') == ['bar','baz'], svc
assert prt['alpha']['foo'] == '4100', prt['alpha']        # alpha gets its OWN port base, not beta's
assert prt['beta']['bar'] == '4200', prt['beta']
" || { echo 'FAIL: per-project payload/ports'; exit 1; }
echo "PASS test-multiproject-services"
