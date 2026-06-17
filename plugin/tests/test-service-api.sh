#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""; cleanup(){ [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"; bash "$SH" project add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
PORT=39720; b="http://127.0.0.1:$PORT"; H=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 50); do curl -sf "${H[@]}" "$b/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done
curl -s "${H[@]}" -d "{\"root\":\"$P\",\"service\":{\"name\":\"web\",\"portBase\":3000,\"cwd\":\".\",\"run\":\"x\"},\"central\":true}" "$b/api/add-service" >/dev/null
python3 -c "import json;s=json.load(open('$MARINA_HOME/services/$id.json'))['services'];assert s[0]['name']=='web',s" || { echo FAIL: add-service; exit 1; }
curl -s "${H[@]}" -d "{\"root\":\"$P\",\"name\":\"web\",\"central\":true}" "$b/api/remove-service" >/dev/null
python3 -c "import json;s=json.load(open('$MARINA_HOME/services/$id.json'))['services'];assert s==[],s" || { echo FAIL: remove-service; exit 1; }
echo "PASS test-service-api"
