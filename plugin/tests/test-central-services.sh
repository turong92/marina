#!/usr/bin/env bash
# central service definitions: ~/.marina/services/<id>.json resolves when project root has no marina-services.json
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"           # NO marina-services.json in the project root
bash "$SH" project add "$P" >/dev/null
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

# root file 추가 시 머지 — root(local) ∪ central(central), name 겹침 없으면 둘 다
echo '{"services":[{"name":"local","portBase":4500}]}' > "$P/marina-services.json"
MARINA_HOME="$MARINA_HOME" python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: root+central merge"; exit 1; }
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
root = Path(sys.argv[2])
svcs = set(mc.services_for(root))
assert svcs == {"local", "central"}, svcs
# name 충돌 시 중앙 우선 — local 을 central 에 같은 이름으로 재정의하면 중앙 값이 이긴다
import json
Path(sys.argv[2], "marina-services.json").write_text('{"services":[{"name":"central","portBase":9999}]}')
svcs2 = {s["name"]: s for s in mc.extra_services_for(root)}
assert set(svcs2) == {"central"}, svcs2
assert svcs2["central"]["portBase"] == 4400, svcs2["central"]  # central file wins
assert svcs2["central"]["source"] == "central", svcs2["central"]
PY
echo "PASS test-central-services"
