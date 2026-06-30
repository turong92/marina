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

# 6) scope=base set → stored compose 의 x-marina.links(단일 SoT, links.json 미사용). GET 에 source=project.
SC="$MARINA_HOME/proj/docker-compose.yml"
xm_links() { python3 -c "
import importlib.util as u
s=u.spec_from_file_location('mc','$HERE/../scripts/marina-compose.py'); mc=u.module_from_spec(s); s.loader.exec_module(mc)
import json; print(json.dumps((mc.xmarina_for_stored('$SC') or {}).get('links',{})))
"; }
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"dist\",\"op\":\"set\",\"scope\":\"base\",\"rule\":{\"glob\":\"dist\",\"kind\":\"dir\"}}" | grep -q '"ok": true' || { echo "FAIL: base set"; exit 1; }
[[ ! -f "$MARINA_HOME/proj/links.json" ]] || { echo "FAIL: links.json 가 다시 생김(미사용이어야)"; exit 1; }
xm_links | python3 -c "
import json, sys
links = json.load(sys.stdin)
node = links.get('.', links)   # subrepo 없는 set → '.' 또는 전역
assert 'dist' in (node.get('symlink', []) + node.get('copy', [])), links
" || { echo "FAIL: x-marina.links 에 안 들어감"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert m['dist']['source'] == 'project', m   # x-marina base = project source(모든 워크트리 공유)
" || { echo "FAIL: base not project source"; exit 1; }

# 7) subrepo-scoped base 링크 → x-marina.links[<sub>], 해당 subrepo 탭에만 노출
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"web/dist\",\"op\":\"set\",\"scope\":\"base\",\"rule\":{\"glob\":\"webdist\",\"kind\":\"dir\",\"subrepo\":\"web\"}}" | grep -q '"ok": true' || { echo "FAIL: subrepo base set"; exit 1; }
xm_links | python3 -c "
import json, sys
links = json.load(sys.stdin)
assert 'webdist' in (links.get('web',{}).get('symlink',[]) + links.get('web',{}).get('copy',[])), links
" || { echo "FAIL: subrepo glob 이 x-marina.links[web] 에 없음"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web&subrepo=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert 'webdist' in m and m['webdist']['source'] == 'project', m
" || { echo "FAIL: subrepo link missing from own tab"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web&subrepo=api" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert 'webdist' not in m, m
" || { echo "FAIL: subrepo link leaked into another tab"; exit 1; }

# 8) 탐색기 copy mode → x-marina.links[web].copy
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"web/dist-copy\",\"op\":\"set\",\"scope\":\"base\",\"rule\":{\"glob\":\"copyglob\",\"kind\":\"dir\",\"subrepo\":\"web\",\"mode\":\"copy\"}}" | grep -q '"ok": true' || { echo "FAIL: copy mode base set"; exit 1; }
xm_links | python3 -c "
import json, sys
links = json.load(sys.stdin)
assert 'copyglob' in links.get('web',{}).get('copy',[]), links
" || { echo "FAIL: copy mode 가 x-marina copy 에 없음"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web&subrepo=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert m['copyglob']['rule']['mode'] == 'copy', m
" || { echo "FAIL: copy mode not reflected"; exit 1; }

# 9) base clear = x-marina.links 에서 제거 → 탭에서 사라짐
curl -s "${hdr[@]}" -X POST "$base/api/link-set" -H "content-type: application/json" \
  -d "{\"root\":\"$P\",\"service\":\"web\",\"name\":\"copyglob\",\"op\":\"clear\",\"scope\":\"base\",\"subrepo\":\"web\"}" | grep -q '"ok": true' || { echo "FAIL: base clear"; exit 1; }
xm_links | python3 -c "
import json, sys
links = json.load(sys.stdin)
assert 'copyglob' not in links.get('web',{}).get('copy',[]), links
" || { echo "FAIL: base clear 가 x-marina 에서 제거 안 함"; exit 1; }
curl -s "${hdr[@]}" "$base/api/links?$RE&service=web&subrepo=web" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)['links']}
assert 'copyglob' not in m, m
" || { echo "FAIL: base clear 후에도 탭에 남음"; exit 1; }

# 10) link-set 성공 후 워크트리에 즉시 apply(materialize) — 대시보드에서 넣으면 바로 뜨게(main 은 src==dst skip)
HANDLER="$HERE/../scripts/marina_handler.py"
grep -q 'def _apply_now' "$HANDLER" || { echo "FAIL: _apply_now(즉시 materialize) 헬퍼 없음"; exit 1; }
[[ "$(grep -c '_apply_now(root, service)' "$HANDLER")" -ge 2 ]] || { echo "FAIL: link-set base·override 양쪽서 _apply_now 호출해야(즉시 반영)"; exit 1; }
grep -q 'is_source_checkout(root)' "$HANDLER" || { echo "FAIL: main(원본)은 apply 대상 아님(is_source_checkout skip)"; exit 1; }

echo "PASS test-links-api"
