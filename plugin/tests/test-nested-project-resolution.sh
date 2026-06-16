#!/usr/bin/env bash
# 중첩 등록: 부모(parent) 아래 자식(parent/sub)도 등록되면, sub 의 root 는 sub 로 귀속돼야 한다
# (first-match 면 parent 로 잘못 귀속 — startswith 가 parent 에 먼저 걸림).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39713
base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")

PARENT="$TMP/parent"; SUB="$PARENT/sub"
mkdir -p "$SUB"
git -C "$PARENT" init -q; git -C "$SUB" init -q
bash "$SH" add "$PARENT" >/dev/null
bash "$SH" add "$SUB" >/dev/null

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" "$base/api/worktrees" | python3 -c "
import json, sys, os
d = json.load(sys.stdin)
by = {os.path.basename(w['root']): w['projectId'] for w in d['worktrees']}
assert by.get('sub') == 'sub', by      # 자식이 자식으로 귀속 (first-match 면 'parent')
assert by.get('parent') == 'parent', by
" || { echo 'FAIL: nested resolution'; exit 1; }

echo "PASS test-nested-project-resolution"
