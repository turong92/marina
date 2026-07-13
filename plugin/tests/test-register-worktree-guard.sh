#!/usr/bin/env bash
# compose-register/import 가 워크트리 경로를 받아도 프로젝트 원본으로 승격 — 워크트리가 신규 프로젝트로 등록되던 버그 가드
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
proj="$TMP/proj"; mkdir -p "$proj"; ( cd "$proj" && git init -q && git commit -q --allow-empty -m init )
"$HERE/../scripts/marina.sh" project add "$proj" >/dev/null
# 워크트리 생성 (프로젝트 루트 하위 — claude 레이아웃)
( cd "$proj" && git worktree add -q "$proj/.claude/worktrees/wt-a" -b feat/a )

PORT=39777
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$HERE/../scripts/marina-control.py" >/dev/null 2>&1 &
SRV=$!; trap 'kill $SRV 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done

# 워크트리 경로로 compose-register → 신규 프로젝트가 생기면 안 되고, 기존 프로젝트의 compose 가 갱신돼야
out="$(curl -s -X POST "http://127.0.0.1:$PORT/api/compose-register" -H 'content-type: application/json' \
  -d "{\"path\":\"$proj/.claude/worktrees/wt-a\",\"yaml\":\"services:\\n  app:\\n    image: alpine\\n\"}")"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok'), d" || { echo "FAIL: register 실패: $out"; exit 1; }
n="$(python3 -c "import json,os; d=json.load(open(os.path.expanduser('$MARINA_HOME/projects.json'))); print(len(d['projects']))")"
[[ "$n" == "1" ]] || { echo "FAIL: 프로젝트 수 $n (워크트리가 신규 등록됨)"; exit 1; }
rid="$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
[[ "$rid" == "proj" ]] || { echo "FAIL: id=$rid (proj 여야)"; exit 1; }
[[ -f "$MARINA_HOME/proj/docker-compose.yml" ]] || { echo "FAIL: 프로젝트 보관 compose 미갱신"; exit 1; }

# 반대 방향 가드: 프로젝트가 1개뿐일 때 무관한 새 레포 등록이 기존 프로젝트로 흡수되면 안 됨
# (project_for 의 단일 등록 폴백을 등록 가드가 쓰면 생기는 사고 — containing_project_for 로 차단)
other="$TMP/other-repo"; mkdir -p "$other"; ( cd "$other" && git init -q )
out2="$(curl -s -X POST "http://127.0.0.1:$PORT/api/compose-register" -H 'content-type: application/json' \
  -d "{\"path\":\"$other\",\"yaml\":\"services:\\n  app:\\n    image: alpine\\n\"}")"
echo "$out2" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok'), d" || { echo "FAIL: 신규 등록 실패: $out2"; exit 1; }
n2="$(python3 -c "import json,os; d=json.load(open(os.path.expanduser('$MARINA_HOME/projects.json'))); print(len(d['projects']))")"
[[ "$n2" == "2" ]] || { echo "FAIL: 프로젝트 수 $n2 (무관 레포가 기존 프로젝트로 흡수됨)"; exit 1; }
echo "PASS test-register-worktree-guard"
