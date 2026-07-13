#!/usr/bin/env bash
# A4 — POST /api/worktree-create: 등록 프로젝트 root 에서 `marina worktree create <branch>` CLI 재사용.
# 성공 시 .claude/worktrees/ 에 실제로 생기고 /api/worktrees payload 에 등장. 잘못된 입력(브랜치 문자·미등록 root·중복)은 4xx.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"; CTRL="$SCR/marina-control.py"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"   # macOS /var → /private/var 심링크 정렬(서버는 resolve() 를 쓴다)
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"

P="$TMP/proj"; mkdir -p "$P"
git -C "$P" init -q
git -C "$P" config user.email "t@example.invalid"
git -C "$P" config user.name "Marina Test"
printf 'ok\n' > "$P/r"; git -C "$P" add r; git -C "$P" commit -qm init

printf '{"projects":[{"id":"proj","root":"%s","subrepos":[],"worktreeGlobs":[".claude/worktrees/*"]}],"schemaVersion":1}\n' "$P" > "$MARINA_HOME/projects.json"

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
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-worktree-create-api (localhost bind unavailable)"; exit 0; }; exit "$code"; }
cleanup(){ kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
b="http://127.0.0.1:$PORT"; H=(-H "Origin: $b" -H "content-type: application/json")
for _ in $(seq 1 50); do curl -s -o /dev/null "$b/api/worktrees" && break; sleep 0.1; done

# 성공: 등록 root 에서 브랜치 지정 워크트리 생성
body="$(python3 -c 'import json,sys; print(json.dumps({"projectRoot": sys.argv[1], "branch": "feature/foo"}))' "$P")"
out="$(curl -s "${H[@]}" -d "$body" "$b/api/worktree-create")"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok') is True, d; assert d['root'].endswith('/.claude/worktrees/feature-foo'), d" \
  || { echo "FAIL: worktree-create ok/root: $out"; exit 1; }

wt="$P/.claude/worktrees/feature-foo"
[[ -d "$wt" ]] || { echo "FAIL: 워크트리 디렉토리 없음 ($wt)"; exit 1; }
[[ "$(git -C "$wt" branch --show-current)" == "feature/foo" ]] || { echo "FAIL: 워크트리 브랜치 != feature/foo"; exit 1; }

# /api/worktrees payload 에 등장 (refresh=1 로 즉시 반영 확인)
curl -s "${H[@]}" "$b/api/worktrees?refresh=1" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); assert any(w['root']=='$wt' for w in d['worktrees']), d" \
  || { echo "FAIL: 새 워크트리가 /api/worktrees 에 없음"; exit 1; }

# 잘못된 브랜치명 — '..' 포함
code="$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"projectRoot": sys.argv[1], "branch": "../x"}))' "$P")" \
  "$b/api/worktree-create")"
[[ "$code" == 4* ]] || { echo "FAIL: 브랜치 '../x' expected 4xx, got $code"; exit 1; }

# 잘못된 브랜치명 — 공백 포함
code="$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"projectRoot": sys.argv[1], "branch": "with space"}))' "$P")" \
  "$b/api/worktree-create")"
[[ "$code" == 4* ]] || { echo "FAIL: 브랜치 'with space' expected 4xx, got $code"; exit 1; }

# 미등록 root
UNREG="$TMP/not-a-project"; mkdir -p "$UNREG"
code="$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"projectRoot": sys.argv[1], "branch": "feature/bar"}))' "$UNREG")" \
  "$b/api/worktree-create")"
[[ "$code" == 4* ]] || { echo "FAIL: 미등록 root expected 4xx, got $code"; exit 1; }

# 중복 생성 — 이미 존재하는 브랜치/워크트리
code="$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -d "$body" "$b/api/worktree-create")"
[[ "$code" == 4* ]] || { echo "FAIL: 중복 생성 expected 4xx, got $code"; exit 1; }

# 문법 검사 — 신규 프론트 파일
if command -v node >/dev/null 2>&1; then
  node --check "$SCR/marina-web/app-5d-worktree-create.js" || { echo "FAIL: 문법 오류 app-5d-worktree-create.js"; exit 1; }
fi

echo "PASS test-worktree-create-api"
