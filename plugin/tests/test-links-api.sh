#!/usr/bin/env bash
# 대시보드 링크 API: GET /api/links (effective 링크 노출) + POST /api/link-set (disable/clear/set → overrides.json).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/wt"; mkdir -p "$P" "$TMP/src" "$MARINA_HOME/proj"
mkdir -p "$P/web/dist" "$P/api/dist"
cat > "$MARINA_HOME/proj/docker-compose.yml" <<'YML'
services:
  web:
    image: nginx
YML
cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"proj","root":"$P","kind":"compose","composeFile":"docker-compose.yml","composeEnvVar":"","composeEnvDefault":"local","subrepos":[],"worktreeGlobs":[]}]}
JSON
PORT="$(python3 - <<'PY' || exit $?
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", 0))
except PermissionError:
    sys.exit(42)
print(s.getsockname()[1])
s.close()
PY
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-links-api (localhost bind unavailable)"; exit 0; }; exit "$code"; }
base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")
RE="root=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$P")"
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# 1) GET — 기본 glob 링크 4개가 default·active 로 노출
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web" | python3 -c "
import json, sys
d = json.load(sys.stdin); m = {l['name']: l for l in d['links']}
assert set(m) >= {'node_modules', '.venv', 'local-yml', 'local-env'}, m
assert m['node_modules']['source'] == 'default' and not m['node_modules']['disabled'], m
assert m['node_modules']['category'] == 'deps' and m['local-yml']['category'] == 'config', ('category 노출(Task 4)', m['node_modules'], m['local-yml'])
" || { echo "FAIL: GET defaults"; exit 1; }

# 2) POST disable → GET 에 override·disabled
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"node_modules\",\"op\":\"disable\"}" | grep -q '"ok": true' || { echo "FAIL: disable post"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert m['node_modules']['disabled'] is True and m['node_modules']['source'] == 'override', m
" || { echo "FAIL: disable not reflected"; exit 1; }

# 3) POST set 커스텀 glob dir
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"mybuild\",\"op\":\"set\",\"rule\":{\"glob\":\"dist\",\"kind\":\"dir\"}}" >/dev/null
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert m['mybuild']['rule'] == {'glob': 'dist', 'kind': 'dir'}, m
" || { echo "FAIL: set custom"; exit 1; }

# 4) POST clear node_modules → 기본으로 복귀(default·active)
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"node_modules\",\"op\":\"clear\"}" >/dev/null
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert m['node_modules']['source'] == 'default' and not m['node_modules']['disabled'], m
" || { echo "FAIL: clear didn't revert"; exit 1; }

# 5) 잘못된 op → 4xx
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"x\",\"op\":\"bogus\"}")"
[[ "$code" == 4* ]] || { echo "FAIL: bad op should 4xx (got $code)"; exit 1; }

# 6) scope=base set → central ~/.marina/<id>/links.json (모든 워크트리 공유), GET 에 source=project
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"dist\",\"op\":\"set\",\"scope\":\"base\",\"rule\":{\"glob\":\"dist\",\"kind\":\"dir\"}}" | grep -q '"ok": true' || { echo "FAIL: base set"; exit 1; }
ID="$(python3 -c "import json;print(json.load(open('$MARINA_HOME/projects.json'))['projects'][0]['id'])")"
python3 -c "
import json
d = json.load(open('$MARINA_HOME/$ID/links.json'))
assert d['links']['dist'] == {'glob':'dist','kind':'dir'}, d
" || { echo "FAIL: central links.json not written"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert m['dist']['source'] == 'project', m   # central base = project source(모든 워크트리 공유)
" || { echo "FAIL: base not project source"; exit 1; }

# 7) subrepo-scoped base 링크는 해당 subrepo 탭에만 노출
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"web/dist\",\"op\":\"set\",\"scope\":\"base\",\"rule\":{\"glob\":\"dist\",\"kind\":\"dir\",\"subrepo\":\"web\"}}" | grep -q '"ok": true' || { echo "FAIL: subrepo base set"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web&subrepo=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert m['web/dist']['source'] == 'project' and m['web/dist']['rule']['subrepo'] == 'web', m
" || { echo "FAIL: subrepo link missing from own tab"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web&subrepo=api" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert 'web/dist' not in m, m
" || { echo "FAIL: subrepo link leaked into another tab"; exit 1; }

# 8) 탐색기 copy mode 저장/노출
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"web/dist-copy\",\"op\":\"set\",\"scope\":\"base\",\"rule\":{\"glob\":\"dist\",\"kind\":\"dir\",\"subrepo\":\"web\",\"mode\":\"copy\"}}" | grep -q '"ok": true' || { echo "FAIL: copy mode base set"; exit 1; }
python3 -c "
import json
d = json.load(open('$MARINA_HOME/$ID/links.json'))
assert d['links']['web/dist-copy'] == {'glob':'dist','kind':'dir','mode':'copy','subrepo':'web'}, d
" || { echo "FAIL: copy mode not persisted"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web&subrepo=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert m['web/dist-copy']['rule']['mode'] == 'copy', m
" || { echo "FAIL: copy mode not reflected"; exit 1; }

# 9) base disable = 기본 링크를 프로젝트 전체에서 끔(모든 워크트리 제외) → GET 에 baseOff/disabled
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"node_modules\",\"op\":\"disable\",\"scope\":\"base\"}" | grep -q '"ok": true' || { echo "FAIL: base disable should 200"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?root=$P&service=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert m['node_modules']['baseOff'] is True and m['node_modules']['disabled'] is True, ('base disable 미반영', m['node_modules'])
" || { echo "FAIL: base disable not reflected as baseOff"; exit 1; }
# 9b) base clear = 되돌림(기본 복귀)
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"node_modules\",\"op\":\"clear\",\"scope\":\"base\"}" | grep -q '"ok": true' || { echo "FAIL: base clear"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?root=$P&service=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert m['node_modules']['source'] == 'default' and not m['node_modules'].get('baseOff') and not m['node_modules']['disabled'], ('base clear 후 기본 복귀 실패', m['node_modules'])
" || { echo "FAIL: base clear should restore default"; exit 1; }

echo "PASS test-links-api"
