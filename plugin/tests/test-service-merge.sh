#!/usr/bin/env bash
# root ∪ 중앙 머지, name 겹치면 중앙 우선 + source 태그
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"web","portBase":3000,"cwd":"fe","run":"team-web"},{"name":"api","portBase":8080,"cwd":"be","run":"team-api"}]}
JSON
bash "$SH" add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
mkdir -p "$MARINA_HOME/services"
cat > "$MARINA_HOME/services/$id.json" <<'JSON'
{"services":[{"name":"web","portBase":3000,"cwd":"fe","run":"my-web-override"},{"name":"worker","portBase":9000,"cwd":".","run":"my-worker"}]}
JSON
MARINA_HOME="$MARINA_HOME" python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: merge unit"; exit 1; }
import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mc",sys.argv[1]);mc=importlib.util.module_from_spec(spec);spec.loader.exec_module(mc)
root=Path(sys.argv[2])
svcs={s["name"]:s for s in mc.extra_services_for(root)}
assert set(svcs)=={"web","api","worker"}, set(svcs)
assert svcs["web"]["run"]=="my-web-override", svcs["web"]
assert svcs["web"]["source"]=="central", svcs["web"]
assert svcs["api"]["source"]=="root", svcs["api"]
assert svcs["worker"]["source"]=="central", svcs["worker"]
assert sorted(mc.services_for(root))==["api","web","worker"], mc.services_for(root)
assert mc.service_subrepo_map(root).get("api")!=None
PY
echo "PASS test-service-merge"
