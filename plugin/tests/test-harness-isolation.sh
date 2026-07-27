#!/usr/bin/env bash
# 테스트는 형의 실 ~/.marina 를 절대 읽거나 쓰면 안 된다.
# 격리를 파일마다 손으로 챙기니 77/163 이 빠져 있었고, 그게 형 머신에서만 나는 실패의 원인이었다.
# 이 테스트가 규칙을 강제한다 — 새 테스트가 빠뜨리면 여기서 걸린다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/lib/harness.sh"

missing=""
for t in "$HERE"/test-*.sh; do
  name="$(basename "$t" .sh)"
  [ "$name" = "test-harness-isolation" ] && continue
  # 반드시 공통 하네스를 source 해야 한다. 스스로 MARINA_HOME 만 잡는 걸로는 부족하다 —
  # 상속된 MARINA_CONTROL_HOST/PORT 같은 나머지 환경이 그대로 새기 때문이다.
  grep -qE 'lib/harness\.sh' "$t" || missing="$missing $name"
done
if [ -n "$missing" ]; then
  echo "FAIL: MARINA_HOME 을 격리하지 않는 테스트 —$missing"
  echo "  lib/harness.sh 를 source 하면 된다."
  exit 1
fi

# 하네스가 실제로 실 홈에서 떼어놓는지 — 값만 바꾸는 게 아니라 경로가 실제로 달라야 한다.
[ -n "${MARINA_HOME:-}" ] || { echo "FAIL: 하네스가 MARINA_HOME 을 설정하지 않았다"; exit 1; }
case "$MARINA_HOME" in
  "$HOME"/.marina|"$HOME"/.marina/*) echo "FAIL: 하네스가 실 홈을 가리킨다 — $MARINA_HOME"; exit 1;;
esac
[ -d "$MARINA_HOME" ] || { echo "FAIL: 격리 홈이 만들어지지 않았다 — $MARINA_HOME"; exit 1; }

# 반복 실행에도 임시 디렉터리가 쌓이면 안 된다(고정 경로 + 시작 시 비우기).
touch "$MARINA_HOME/leftover"
before="$MARINA_HOME"
( . "$HERE/lib/harness.sh" >/dev/null 2>&1; [ "$MARINA_HOME" = "$before" ] ) \
  || { echo "FAIL: 같은 테스트가 실행마다 다른 홈을 만든다(누적)"; exit 1; }
[ -e "$before/leftover" ] && { echo "FAIL: 재실행 때 이전 상태가 남았다"; exit 1; }

# marina 터미널 안에서 돌리면 셸이 데몬 환경을 물려받는다 — 하네스가 그걸 다 씻어야 한다.
# (MARINA_CONTROL_HOST/PORT 상속이 test-dashboard-launch 의 "bind 리셋" 오진의 원인이었다.)
leaked="$(bash -c '
  export MARINA_CONTROL_HOST=0.0.0.0 MARINA_CONTROL_PORT=44444 MARINA_TERM=1 MARINA_GATEWAY_PORT=9999
  export MARINA_HOME=/definitely/not/isolated
  . "$1/lib/harness.sh"
  env | grep "^MARINA_" | grep -v "^MARINA_HOME=" || true
' _ "$HERE")"
[ -z "$leaked" ] || { echo "FAIL: 하네스가 상속된 MARINA_* 를 남겼다 — $leaked"; exit 1; }

# 진짜 격리 확인: marina_state 가 굳히는 값이 실 홈이 아니어야 한다.
got="$(PYTHONPATH="$HERE/../scripts" python3 -c 'from marina_state import MARINA_HOME; print(MARINA_HOME)')"
[ "$got" = "$MARINA_HOME" ] || { echo "FAIL: marina_state 가 다른 홈을 봤다 — $got"; exit 1; }

echo "PASS test-harness-isolation"
