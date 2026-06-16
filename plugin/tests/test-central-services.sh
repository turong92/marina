#!/usr/bin/env bash
# central service definitions: ~/.marina/services/<id>.json resolves when project root has no marina-services.json
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"           # NO marina-services.json in the project root
bash "$SH" add "$P" >/dev/null
id="$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
mkdir -p "$MARINA_HOME/services"
cat > "$MARINA_HOME/services/$id.json" <<'JSON'
{"services":[{"name":"central","portBase":4400,"cwd":".","run":"{python} -m http.server {port}"}]}
JSON

# Python resolves central
MARINA_HOME="$MARINA_HOME" python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: python central resolve"; exit 1; }
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
root = Path(sys.argv[2])
assert mc.services_for(root) == ("central",), mc.services_for(root)
assert mc.port_base_for(root) == {"central": 4400}, mc.port_base_for(root)
PY

# launcher resolves central (print-command substitutes the central service's run)
cmd="$(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" print-command central 2>/dev/null)" \
  || { echo "FAIL: marina.sh print-command central (launcher central fallback missing)"; exit 1; }
case "$cmd" in *"http.server"*) ;; *) echo "FAIL: central run not resolved by launcher: $cmd"; exit 1;; esac

# root file still wins when present (regression)
echo '{"services":[{"name":"local","portBase":4500}]}' > "$P/marina-services.json"
MARINA_HOME="$MARINA_HOME" python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: root precedence"; exit 1; }
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
assert mc.services_for(Path(sys.argv[2])) == ("local",), mc.services_for(Path(sys.argv[2]))
PY
echo "PASS test-central-services"
