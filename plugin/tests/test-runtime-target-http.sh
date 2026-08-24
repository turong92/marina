#!/usr/bin/env bash
# 대시보드 API: /api/sessions 가 런타임 타깃을 싣고, POST /api/runtime-target 이 전환한다.
#
# 자리가 **서버 현황(메모리) 영역**인 이유: 원격이면 거기 뜨는 Docker/Host 수치가 이미 박스의 값이라,
# 어느 기계인지 안 밝히면 표시가 거짓말이 된다. 그래서 배지는 그 페이로드에 같이 실린다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SCRIPTS="$HERE/../scripts"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/wt"; mkdir -p "$P" "$MARINA_HOME/proj"
(cd "$P" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)
cat > "$MARINA_HOME/proj/docker-compose.yml" <<'YML'
services:
  web:
    image: nginx
YML
cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"proj","root":"$P","kind":"compose","composeFile":"docker-compose.yml","subrepos":[],"worktreeGlobs":[]}]}
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
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-runtime-target-http (localhost bind unavailable)"; exit 0; }; exit "$code"; }
base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done
fail() { echo "FAIL: $1"; exit 1; }
rt() { curl -s "${hdr[@]}" "$base/api/sessions" | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin).get('runtimeTarget')))"; }
post() { curl -s "${hdr[@]}" -X POST "$base/api/runtime-target" -H "content-type: application/json" -d "$1"; }

# 1) 기본은 로컬이고 페이로드에 실린다
echo "$(rt)" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
assert d is not None, 'runtimeTarget 이 페이로드에 없다'
assert d['kind']=='local' and d['scope']=='default', d
" || fail "기본 로컬 페이로드"

# 2) 전역 원격 전환 → 페이로드 반영
post '{"kind":"remote","host":"ssh://crabs@box","scope":"global"}' | grep -q '"ok": true' || fail "전역 원격 전환"
echo "$(rt)" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
assert d['kind']=='remote' and d['host']=='ssh://crabs@box' and d['scope']=='global', d
" || fail "전역 원격이 페이로드에 안 실림"

# 3) 전역 원격에 주소 없으면 거부 — 성공을 찍고 로컬로 도는 걸 막는다
post '{"kind":"remote","scope":"global"}' | grep -q '"ok": true' && fail "주소 없는 전역 원격이 통과함"

# 4) 세션 override — 이 워크트리만 로컬. scope 가 session 으로 바뀌고 전역은 남는다
post "{\"root\":\"$P\",\"kind\":\"local\",\"scope\":\"session\"}" | grep -q '"ok": true' || fail "세션 override"
curl -s "${hdr[@]}" "$base/api/sessions" | python3 -c "
import json,sys
d=json.load(sys.stdin)['runtimeTarget']
# 상단 배지는 워크트리 무관(전역 관점) — 전역은 여전히 원격이어야 한다
assert d['globalHost']=='ssh://crabs@box', d
" || fail "세션 override 가 전역을 지웠다"
python3 -c "
import json,sys
sys.path.insert(0,'$SCRIPTS')
from marina_runtime_target import describe
from marina_paths import session_dir
from pathlib import Path
d=describe(str(session_dir(Path('$P'))), home='$MARINA_HOME')
assert d['kind']=='local' and d['scope']=='session', d
" || fail "세션 override 가 안 먹음"

# 5) 잘못된 scope 는 거부
post '{"kind":"local","scope":"bogus"}' | grep -q '"ok": true' && fail "잘못된 scope 통과"

echo PASS
