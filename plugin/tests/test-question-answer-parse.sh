#!/usr/bin/env bash
# 답한 질문 카드가 **답을 정확히 잘라 보여줘야** 한다 — 형: "첨부처럼 이상하게 들어감".
#
# **실증(2026-08-23).** 질문 2개짜리 폼에서 1번은 직접 입력, 2번은 선택으로 답했다.
# 에이전트에게 간 기록은 멀쩡했다:
#   The user answered: ""그냥 채팅방"을 어느 쪽으로 만들까?"="그냥 채팅이나 코워크는 못열어줘?",
#                      ""공유"는 어떤 걸 뜻해?"="팀원이 같이 대화".
# 그런데 마리나가 그 문자열을 다시 읽어 카드로 그릴 때 1번 답이 이렇게 나왔다:
#   그냥 채팅이나 코워크는 못열어줘?", ""공유"는 어떤 걸 뜻해?"="팀원이 같이 대화
# 답의 끝을 rfind('"') 로 잡아서, **문자열 맨 끝까지** 먹은 것이다. 선택지로만 답할 땐 라벨
# 대조가 이 실수를 가려줬는데(picked 로 그린다), 자유 입력엔 라벨이 없어 그대로 드러났다.
#
# 규칙: 답의 끝은 **다음 질문이 시작하는 자리**다. 마지막 질문만 문자열 끝을 쓴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_sessions import _question_answers

질문들 = [
    {"question": '"그냥 채팅방"을 어느 쪽으로 만들까?',
     "options": [{"label": "잡담 폴더 + CLI 세션"}, {"label": "API 기반 순수 채팅"}]},
    {"question": '"공유"는 어떤 걸 뜻해?',
     "options": [{"label": "팀원이 같이 대화"}, {"label": "읽기 전용 링크"}]},
]
실제 = ('The user answered: ""그냥 채팅방"을 어느 쪽으로 만들까?"="그냥 채팅이나 코워크는 못열어줘?", '
        '""공유"는 어떤 걸 뜻해?"="팀원이 같이 대화". Read the answers carefully — they may request '
        'clarification, changes, or that you not proceed — and follow what they actually say.')

답 = _question_answers(질문들, 실제)
assert 답[0]["text"] == "그냥 채팅이나 코워크는 못열어줘?", 답[0]
assert 답[1]["text"] == "팀원이 같이 대화", 답[1]
assert 답[1]["picked"] == ["팀원이 같이 대화"], 답[1]
assert not 답[0]["picked"], f"자유 입력인데 선택지를 고른 것처럼 보인다: {답[0]}"

# 선택으로만 답한 흔한 경우도 그대로여야 한다.
평범 = ('Your questions have been answered: "A?"="가", "B?"="나". You can now continue with these answers in mind.')
답2 = _question_answers([{"question": "A?", "options": [{"label": "가"}]},
                         {"question": "B?", "options": [{"label": "나"}]}], 평범)
assert [x["text"] for x in 답2] == ["가", "나"], 답2

# 질문 하나짜리 — 끝이 문자열 끝이다.
답3 = _question_answers([{"question": "색?", "options": [{"label": "빨강"}]}],
                        'The user answered: "색?"="형광 노랑이 좋아". Read the answers carefully')
assert 답3[0]["text"] == "형광 노랑이 좋아", 답3
print("ok 답 파싱: 다음 질문 자리에서 끊는다 · 따옴표 섞여도 안 샌다")
PY

echo "PASS test-question-answer-parse"
