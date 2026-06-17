#!/usr/bin/env bash
# /api/attach-subrepo · /api/detach-subrepo · /api/set-default-attach over a real worktree
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39714; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
post() { curl -s "${hdr[@]}" -d "$2" "$base/api/$1"; }

gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm i; }

# main checkout: a root/container git repo + two nested subrepo clones a,b (mdc-main 과 동일 구조)
SRC="$TMP/src"; gi "$SRC"; gi "$SRC/a"; gi "$SRC/b"
cat > "$SRC/marina-services.json" <<'JSON'
{"services":[{"name":"asvc","portBase":4100,"cwd":"a"},{"name":"bsvc","portBase":4200,"cwd":"b"}]}
JSON
# worktree = real git worktree of the root repo (루트에 .git → discover 됨). 서브레포는 아래 API 로 attach.
WT="$TMP/wt/feature-x"; mkdir -p "$TMP/wt"
git -C "$SRC" worktree add -q --detach "$WT" HEAD
bash "$SH" project add "$SRC" --subrepos a,b >/dev/null
# point worktreeGlobs at our wt dir so it's discovered
python3 - "$MARINA_HOME/projects.json" "$TMP/wt/*" <<'PY'
import json, sys
f, glob = sys.argv[1], sys.argv[2]
d = json.load(open(f)); d["projects"][0]["worktreeGlobs"] = [glob]
json.dump(d, open(f, "w"), ensure_ascii=False, indent=2)
PY

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# set-default-attach on main → registry defaultAttach written
post set-default-attach "{\"root\":\"$SRC\",\"subrepos\":[\"a\"]}" >/dev/null
python3 -c "import json,os; p=json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]; assert p['defaultAttach']==['a'],p" \
  || { echo "FAIL: set-default-attach write"; exit 1; }

# set-default-attach rejects subrepo outside universe → 4xx
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -d "{\"root\":\"$SRC\",\"subrepos\":[\"zzz\"]}" "$base/api/set-default-attach")"
[[ "$code" == 4* ]] || { echo "FAIL: set-default-attach bad subrepo expected 4xx, got $code"; exit 1; }

# attach b into the worktree (idempotent: run twice)
post attach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\"}" >/dev/null
post attach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\"}" >/dev/null
[[ -e "$WT/b/.git" ]] || { echo "FAIL: attach b did not create worktree"; exit 1; }

# main card physical attach is rejected → 4xx
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -d "{\"root\":\"$SRC\",\"subrepo\":\"a\"}" "$base/api/attach-subrepo")"
[[ "$code" == 4* ]] || { echo "FAIL: main attach expected 4xx, got $code"; exit 1; }

# detach clean b → removed, branch preserved
out="$(post detach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\"}")"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('detached')=='b' or 'removed' in d, d" \
  || { echo "FAIL: detach clean b: $out"; exit 1; }
[[ ! -e "$WT/b/.git" ]] || { echo "FAIL: b still attached after detach"; exit 1; }

# dirty detach → needsConfirm, then force
post attach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\"}" >/dev/null
echo dirty > "$WT/b/uncommitted.txt"
out="$(post detach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\"}")"
echo "$out" | python3 -c "import json,sys; assert json.load(sys.stdin).get('needsConfirm') is True" \
  || { echo "FAIL: dirty detach expected needsConfirm: $out"; exit 1; }
post detach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\",\"force\":true}" >/dev/null
[[ ! -e "$WT/b/.git" ]] || { echo "FAIL: force detach did not remove b"; exit 1; }

echo "PASS test-attach-detach-api"
