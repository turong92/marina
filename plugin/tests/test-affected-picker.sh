#!/usr/bin/env bash
# 테스트 선택기(run-affected)가 **웹 자산 변경을 못 보고 있었다.**
#
# 실측(2026-09-10): `marina-web/app-11-chat.js` 를 고치고 run-affected 를 돌리니
# "직접 0개 실행, 무관 258개 제외 — 돌릴 테스트가 없다". 자산 처리 코드는 있었지만 조건이
# `"/plugin/" in c` 였고, git 은 `plugin/scripts/...` 처럼 **앞에 슬래시 없이** 주므로 절대
# 참이 되지 않았다. 즉 웹 JS·CSS·훅·셸 변경은 `--all` 없이는 사실상 무검증이었다.
#
# 계약: 웹 자산을 고치면 **그 파일 이름을 언급하는 테스트**가 선택된다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 실 레포를 더럽히지 않게 복제본에서 잰다.
git -C "$REPO" worktree list >/dev/null 2>&1 || { echo "SKIP: git 레포가 아니다"; exit 0; }
cp -R "$REPO/plugin" "$TMP/plugin"
cd "$TMP" && git init -q . && git add -A >/dev/null 2>&1 && \
  git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1

# 웹 파일 하나를 건드린다(주석 한 줄).
echo "    // 선택기 확인용" >> "$TMP/plugin/scripts/marina-web/app-11-chat.js"
picked="$(bash "$TMP/plugin/tests/run-affected.sh" --list 2>/dev/null || true)"

echo "$picked" | grep -q . || { echo "FAIL: 웹 자산을 고쳤는데 아무 테스트도 안 골랐다"; exit 1; }
# 그 파일을 실제로 언급하는 테스트가 들어 있어야 한다.
# 자기 자신은 뺀다 — 이 파일도 설명에 그 이름을 적고 있다.
want="$(grep -rl "app-11-chat.js" "$TMP/plugin/tests"/test-*.sh | grep -v affected-picker | head -1 | xargs basename)"
echo "$picked" | grep -qx "$want" || {
  echo "FAIL: '$want' 가 선택되지 않았다"; echo "고른 것:"; echo "$picked" | head -10; exit 1; }

# 반대로, 아무것도 안 바꾸면 웹 테스트가 딸려오면 안 된다(선택기가 헐거워지지 않았는지).
cd "$TMP" && git checkout -- plugin/scripts/marina-web/app-11-chat.js
after="$(bash "$TMP/plugin/tests/run-affected.sh" --list 2>/dev/null || true)"
echo "$after" | grep -qx "$want" && { echo "FAIL: 안 바꿨는데도 선택됐다 — 선택기가 헐겁다"; exit 1; }

echo "PASS: 웹 자산을 고치면 그 파일을 부르는 테스트가 선택된다"
