#!/usr/bin/env bash
# 방 이름 줄이기 — 목록은 한 줄이고 폰은 좁다.
#
# 실제 데이터(2026-08-18): 별칭을 안 붙인 방은 형이 처음 친 말이 통째로 이름이다.
#   "야 너 슬랙 분석 할 수 있지"  /  "너는 CRABs 결제 도메인의 시니어 엔지니어다.  목..."
# 목록에서 이게 두 줄 세 줄로 흐르면 무엇이 무엇인지 못 알아본다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_rooms import short_name

# ① 첫 줄만 쓴다 — 프롬프트는 여러 줄인 경우가 많다.
assert short_name("슬랙 분석 해줘\n조건은 아래와 같다\n- 최근 30일") == "슬랙 분석 해줘"

# ② 말 거는 군더더기는 떼어낸다. 형은 말하듯 시키기 때문에 첫 두어 단어가 거의 항상 같다.
assert short_name("야 너 슬랙 분석 할 수 있지") == "슬랙 분석 할 수 있지"
assert short_name("야 지금 배포 파이프라인 봐줘") == "배포 파이프라인 봐줘"

# ③ 길면 자른다. 자를 때 **단어 중간에서 끊지 않는다** — 뜻이 뭉개진다.
긴것 = "CRABs 결제 도메인의 시니어 엔지니어다. 목표는 환불 정합성 개선"
잘린것 = short_name(긴것)
assert len(잘린것) <= 23, (len(잘린것), 잘린것)
assert 잘린것.endswith("…"), 잘린것
assert not 잘린것[:-1].endswith(" "), f"자른 자리에 공백이 남았다: {잘린것!r}"

# ④ 이미 짧으면 그대로 — 형이 붙인 별칭을 건드리면 안 된다.
assert short_name("ZZe2e") == "ZZe2e"
assert short_name("결제정리") == "결제정리"

# ⑤ 빈 값은 빈 값(호출자가 워크트리 id 로 떨어뜨린다).
assert short_name("") == ""
assert short_name("   \n  ") == ""

# ⑥ 군더더기만 있으면 원문을 지킨다 — 다 떼면 이름이 사라진다.
assert short_name("야 너") == "야 너"
assert short_name("야") == "야"

# ⑦ 줄인 이름도 **방마다 달라야** 쓸모가 있다. 같은 말로 시작하는 두 방이 같은 이름이 되면
# 목록에서 구별이 안 된다 — 그래서 앞이 아니라 뒤를 자른다(앞은 군더더기만 뗀다).
하나 = short_name("야 지금 결제 환불 정합성 고쳐줘")
둘 = short_name("야 지금 결제 쿠폰 계산 고쳐줘")
assert 하나 != 둘, (하나, 둘)
print("ok 이름 줄이기: 첫 줄·군더더기 제거·단어 경계·별칭 보존")
PY

echo "PASS test-room-name"
