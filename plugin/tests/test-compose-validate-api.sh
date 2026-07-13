#!/usr/bin/env bash
# 등록 워크벤치 M5 — POST /api/compose-validate 단독 검증 엔드포인트(marina_handler.py):
# 유효 YAML → ok:true, 무효 YAML(network_mode:host) → ok:false, 워크트리 경로 → 프로젝트 원본으로 승격
# (compose-register/import 와 동일 가드 — source_root_for). docker 미가동이면 SKIP(compose_validate 자체가 docker 의존).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"; CTRL="$SCR/marina-control.py"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-validate-api (docker 미가동)"; exit 0; }

TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
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
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-compose-validate-api (localhost bind unavailable)"; exit 0; }; exit "$code"; }
cleanup(){ kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }; trap cleanup EXIT

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
b="http://127.0.0.1:$PORT"; H=(-H "Origin: $b" -H "content-type: application/json")
for i in $(seq 1 50); do curl -s -o /dev/null "$b/api/sessions" && break; sleep 0.1; done

# ── ① 유효 YAML → ok:true, errors 없음 ──────────────────────────────────────────────
P="$TMP/plain"; mkdir -p "$P"
ok_body=$(python3 -c 'import json,sys; print(json.dumps({"path":sys.argv[1],"yaml":"services:\n  web:\n    image: nginx\n    ports: [\"8080:80\"]\n"}))' "$P")
curl -s "${H[@]}" -d "$ok_body" "$b/api/compose-validate" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'] and not r['errors'], r" || { echo "FAIL: 유효 YAML → ok:true"; exit 1; }

# ── ② 무효 YAML(network_mode: host) → ok:false, errors 에 network_mode 언급 ───────────
bad_body=$(python3 -c 'import json,sys; print(json.dumps({"path":sys.argv[1],"yaml":"services:\n  web:\n    image: nginx\n    network_mode: host\n"}))' "$P")
curl -s "${H[@]}" -d "$bad_body" "$b/api/compose-validate" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert not r['ok'] and any('network_mode' in e for e in r['errors']), r" || { echo "FAIL: 무효 YAML → ok:false"; exit 1; }

# ── ③ 워크트리 경로 → 프로젝트 원본으로 승격(source_root_for) ────────────────────────────
# web/Dockerfile 을 커밋 전(untracked)으로 남겨 — git worktree 는 커밋된 내용만 체크아웃하므로
# 워크트리 쪽엔 Dockerfile 이 없다. 승격이 안 되면(=워크트리 경로 그대로 검증) Dockerfile 누락으로 ok:false 여야 하고,
# 승격되면(=proj 원본으로 검증) Dockerfile 이 있어 ok:true 여야 한다 — 차이로 승격 여부를 증명.
# decoy 프로젝트를 하나 더 등록해 marina_registry.project_for 의 "등록된 프로젝트가 하나뿐이면 무조건 그 프로젝트로
# 본다" 폴백(단일-프로젝트 편의 규칙)이 대조군(무관한 디렉토리) 판정을 오염시키지 않게 한다.
decoy="$TMP/decoy"; mkdir -p "$decoy"; ( cd "$decoy" && git init -q && git commit -q --allow-empty -m init )
"$SCR/marina.sh" project add "$decoy" >/dev/null

proj="$TMP/proj"; mkdir -p "$proj/web"
( cd "$proj" && git init -q && git commit -q --allow-empty -m init )
: > "$proj/web/Dockerfile"   # 의도적으로 커밋 안 함 — 워크트리엔 안 나타남
"$SCR/marina.sh" project add "$proj" >/dev/null
( cd "$proj" && git worktree add -q "$proj/.claude/worktrees/wt-a" -b feat/a )
[[ ! -f "$proj/.claude/worktrees/wt-a/web/Dockerfile" ]] || { echo "FAIL: 테스트 전제 깨짐 — 워크트리에 Dockerfile 이 있으면 안 됨"; exit 1; }

# 대조군: 승격 대상이 아닌(decoy·proj 어느 쪽 하위도 아닌) 독립 디렉토리로 같은 build 서비스를 검증하면
# Dockerfile 없어 ok:false — compose_validate 가 Dockerfile 누락을 실제로 잡는다는 사실을 먼저 확인(승격 증명의 기준선).
standalone="$TMP/standalone/web"; mkdir -p "$standalone"
build_body=$(python3 -c 'import json,sys; print(json.dumps({"path":sys.argv[1],"yaml":"services:\n  web:\n    build: ./web\n"}))' "$TMP/standalone")
curl -s "${H[@]}" -d "$build_body" "$b/api/compose-validate" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert not r['ok'] and any('Dockerfile' in e for e in r['errors']), r" || { echo "FAIL: 기준선(Dockerfile 없음 → ok:false)"; exit 1; }

# 본 테스트: 워크트리 경로로 검증 → proj 원본으로 승격돼 Dockerfile 을 찾아 ok:true 여야 함
wt_body=$(python3 -c 'import json,sys; print(json.dumps({"path":sys.argv[1],"yaml":"services:\n  web:\n    build: ./web\n"}))' "$proj/.claude/worktrees/wt-a")
curl -s "${H[@]}" -d "$wt_body" "$b/api/compose-validate" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'], r" || { echo "FAIL: 워크트리 경로 → 프로젝트 원본 승격 안 됨(compose-register 와 동일 가드 기대)"; exit 1; }

echo "PASS test-compose-validate-api"
