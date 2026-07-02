#!/usr/bin/env bash
# entrypoint(설치 shim 대상)가 marina.sh 그룹 명령을 라우팅하는지 — worktree/gateway/link 누락이
# "설치 shim 은 이 명령 없음" 증상을 만들었던 회귀(도그푸드 발견). 전역 usage 로 떨어지면 실패.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
EP="$HERE/../scripts/marina-entrypoint.sh"

# worktree: 무인자 → marina.sh 의 worktree usage("usage: marina worktree create ...")가 와야 함
out=$(bash "$EP" worktree 2>&1 || true)
echo "$out" | grep -q "worktree create" || { echo "FAIL: worktree 미라우팅 — $out"; exit 1; }
echo "$out" | grep -q "전역 CLI" && { echo "FAIL: worktree 가 전역 usage 로 떨어짐"; exit 1; }

# gateway: status 는 running/stopped 중 하나
out=$(MARINA_HOME="$(mktemp -d)" bash "$EP" gateway status 2>&1 || true)
echo "$out" | grep -qE "running|stopped" || { echo "FAIL: gateway 미라우팅 — $out"; exit 1; }

# link: 등록 안 된 tmp cwd 에서도 전역 usage 가 아닌 marina.sh 응답(성공/무출력/자체 에러)이어야 함
out=$(cd "$(mktemp -d)" && MARINA_HOME="$(mktemp -d)" bash "$EP" link 2>&1 || true)
echo "$out" | grep -q "전역 CLI" && { echo "FAIL: link 가 전역 usage 로 떨어짐"; exit 1; }

echo "PASS test-entrypoint-routing"
