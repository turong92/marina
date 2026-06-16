#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39714
base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")

B="$TMP/browse"; mkdir -p "$B/alpha/.git" "$B/beta" "$B/.hidden"
touch "$B/afile.txt"

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" "$base/api/browse?path=$B" | python3 -c "
import json, sys
d = json.load(sys.stdin)
names = {e['name']: e for e in d['entries']}
assert set(names) == {'alpha', 'beta'}, names    # 디렉토리만, dotfile·파일 제외
assert names['alpha']['isGitRepo'] is True, names # .git 있으면 표시
assert names['beta']['isGitRepo'] is False, names
assert d['parent'], d                              # 상위로 올라갈 경로 제공
" || { echo 'FAIL: browse'; exit 1; }

# bad path → 4xx
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "$base/api/browse?path=$B/afile.txt")"
[[ "$code" == 4* ]] || { echo "FAIL: browse non-dir expected 4xx, got $code"; exit 1; }

echo "PASS test-browse-api"
