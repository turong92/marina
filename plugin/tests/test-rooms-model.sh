#!/usr/bin/env bash
# 방 모델 — 상태 접기·완료 판정·조립의 순수 계약.
#
# 스펙 §5: 새 어휘를 만들지 않고 지금 캐논 6개를 5개로 **접기만** 한다. 캐논을 그대로 두면
# 상태 판정이 두 벌로 갈라질 일이 없다(지금 겪는 문제가 바로 그것이다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_rooms import ROOM_STATUS_ORDER, room_status

# 그대로 대응되는 것들
assert room_status("working", False) == "작업중"
assert room_status("idle", False) == "대기"
assert room_status("failed", False) == "문제"
# blocked = 권한·질문 대기 → 사람이 답해야 진행된다
assert room_status("blocked", False) == "응답필요"
# waiting = 프로세스가 살아 입력을 기다림. 멤버 관점에선 blocked 와 요구가 같다(스펙 §5)
assert room_status("waiting", False) == "응답필요"

# **completed 는 두 갈래다**(스펙 §4): 바뀐 파일이 있으면 완료, 없으면 대기.
# completed 만으로 완료를 판정하면 질문만 하고 끝난 턴까지 "일 끝났어요"가 된다.
assert room_status("completed", True) == "완료"
assert room_status("completed", False) == "대기"

# 모르는 값은 대기로 — CLI 가 새 어휘를 내놔도 화면이 깨지지 않아야 한다.
assert room_status("", False) == "대기"
assert room_status("무슨상태", False) == "대기"

# 우선순위: 방 목록에서 놓치면 안 되는 순서(스펙 §2)
assert ROOM_STATUS_ORDER == ("문제", "응답필요", "작업중", "완료", "대기"), ROOM_STATUS_ORDER
print("ok 상태 접기: 6개 → 5개, completed 는 변경 유무로 갈린다")
PY

echo "PASS test-rooms-model"
