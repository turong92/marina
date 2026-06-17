#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"
bash "$SH" project add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
bash "$SH" service add "$id" '{"name":"web","portBase":3000,"cwd":".","run":"x"}' >/dev/null
f="$MARINA_HOME/services/$id.json"
python3 -c "import json;s=json.load(open('$f'))['services'];assert len(s)==1 and s[0]['name']=='web',s"
bash "$SH" service add "$id" '{"name":"web","portBase":3000,"cwd":".","run":"y"}' >/dev/null
python3 -c "import json;s=json.load(open('$f'))['services'];assert len(s)==1 and s[0]['run']=='y',s"
bash "$SH" service add "$id" '{"name":"api","portBase":8080,"cwd":".","run":"z"}' --root >/dev/null
python3 -c "import json;s=json.load(open('$P/marina-services.json'))['services'];assert s[0]['name']=='api',s"
bash "$SH" service rm "$id" web >/dev/null
python3 -c "import json;s=json.load(open('$f'))['services'];assert s==[],s"
if bash "$SH" service add "$id" '{"portBase":1}' >/dev/null 2>&1; then echo "FAIL: accepted no-name"; exit 1; fi
echo "PASS test-service-writer"
