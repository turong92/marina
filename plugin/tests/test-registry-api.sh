#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"
SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39711
P="$TMP/proj"; mkdir -p "$P/frontend/.git" "$P/backend/.git" "$P/docs"
reg="$MARINA_HOME/projects.json"
base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# infer-project — returns universe, writes nothing
out="$(curl -s "${hdr[@]}" -d "{\"path\":\"$P\"}" "$base/api/infer-project")"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["subrepos"]==["backend","frontend"],d; assert d["id"]=="proj",d' \
  || { echo "FAIL: infer-project json: $out"; exit 1; }
[[ ! -f "$reg" ]] || { echo "FAIL: infer-project wrote registry"; exit 1; }

# add-project — curated subset
curl -s "${hdr[@]}" -d "{\"path\":\"$P\",\"subrepos\":[\"frontend\"]}" "$base/api/add-project" >/dev/null
python3 -c "import json; p=json.load(open('$reg'))['projects'][0]; assert p['subrepos']==['frontend'],p" \
  || { echo "FAIL: add-project curated"; exit 1; }

# add-project — empty set upserts to monorepo
curl -s "${hdr[@]}" -d "{\"path\":\"$P\",\"subrepos\":[]}" "$base/api/add-project" >/dev/null
python3 -c "import json; d=json.load(open('$reg')); assert len(d['projects'])==1,d; assert d['projects'][0]['subrepos']==[],d" \
  || { echo "FAIL: add-project upsert empty"; exit 1; }

# remove-project
id="$(python3 -c "import json; print(json.load(open('$reg'))['projects'][0]['id'])")"
curl -s "${hdr[@]}" -d "{\"id\":\"$id\"}" "$base/api/remove-project" >/dev/null
python3 -c "import json; assert json.load(open('$reg'))['projects']==[]" \
  || { echo "FAIL: remove-project"; exit 1; }

# bad path → 4xx, no write
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -d "{\"path\":\"$TMP/nope\"}" "$base/api/add-project")"
[[ "$code" == 4* ]] || { echo "FAIL: add-project bad path expected 4xx, got $code"; exit 1; }

echo "PASS test-registry-api"
