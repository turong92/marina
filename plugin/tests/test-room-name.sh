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
# ⑧ **URL·파일경로가 이름인 방이 실제로 있다.** 앞 22자만 남기면 앞이 같은 것들이 전부
# 같은 이름이 된다 — 목록에서 구별이 안 된다. 뒤쪽(마지막 조각)이 실제 구별 정보다.
u1 = short_name("https://github.com/anthropics/claude-code/issues/1234")
u2 = short_name("https://github.com/anthropics/claude-code/pull/9999")
assert u1 != u2, (u1, u2)
p1 = short_name("@/Users/sumin/IdeaProjects/marina/plugin/scripts/a.py")
p2 = short_name("@/Users/sumin/IdeaProjects/marina/plugin/tests/b.sh")
assert p1 != p2, (p1, p2)

# ⑨ 반면 **문장은 깨끗하게 자른다.** 끝 단어를 붙여 구별하는 방법도 해봤는데, 실제 프롬프트의
# 마지막 낱말이 대개 의미 없는 조각이라("…서비스가… Or") 모든 긴 이름이 지저분해졌다.
# 앞이 같은 문장 둘이 실제로 부딪히는 경우는 지금 데이터에 없고, 부딪히면 부제의 프로젝트
# 이름과 ✎ 이름 바꾸기로 푼다 — 흔한 경우를 망치지 않는 쪽을 택했다.
문장 = short_name("너는 CRABs 결제 도메인의 시니어 엔지니어다. 목표는 환불 정합성 개선")
assert 문장.endswith("…") and " " not in 문장[-3:-1], 문장

# ⑩ 경로는 **끝 두 조각**을 남긴다. 사람이 알아보는 건 파일명과 그 부모지 맨 앞의 홈
# 디렉터리가 아니다. 앞이 다 같아도(둘 다 /Users/…) 뒤가 다르면 구별된다.
a1 = short_name("/Users/sumin/IdeaProjects/marina/plugin/scripts/a.py")
a2 = short_name("/Users/sumin/IdeaProjects/marina/plugin/tests/b.sh")
assert a1 != a2, (a1, a2)
assert a1.endswith("scripts/a.py"), a1
# 끝까지 같은 경로는 부딪힌다 — 그건 ✎ 이름 바꾸기로 푼다(모든 경우를 이름으로 풀 수는 없다).

# ⑪ 잘렸으면 **잘렸다고 표시한다.** 앞이 같고 뒤가 긴 한 덩어리(브랜치명)는 표시 없이 자르면
# 잘린 줄도 모른 채 또 부딪힌다.
b1 = short_name("feat/room-screen-redesign-second-pass-implementation")
b2 = short_name("feat/room-screen-redesign-second-pass-security")
assert b1.endswith("…") or b1 != b2, (b1, b2)

# ⑫ 그래도 목록 한 줄은 지킨다 — 길어지면 줄이는 뜻이 없어진다.
for value in (u1, u2, p1, p2, a1, a2, b1, b2, 문장):
    assert len(value) <= 30, (len(value), value)
print("ok 이름 줄이기: 첫 줄·군더더기 제거·단어 경계·별칭 보존·충돌 회피")
PY

echo "PASS test-room-name"
