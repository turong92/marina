#!/usr/bin/env bash
# 질문이 여러 개인 폼에서 **질문마다** 골라도 되고 써도 돼야 한다.
#
# 예전 계약은 자유 입력을 "폼 전체에 텍스트 하나"로만 받았다(_parse_answers 가 정수 배열만
# 읽었다). 그래서 질문 3개짜리 폼에서 2번만 직접 쓰면, 나머지 두 질문의 선택이 통째로 버려졌다.
# 화면 코드에도 그 한계가 주석으로 박혀 있었다("서버 계약을 넓힌 뒤 붙인다").
#
# **실물 계약(2026-08-22 PTY 관찰).** 자유 입력 줄은 옵션 다음 줄이고, 단일선택·다중선택
# 양쪽에 다 있다:
#     단일: ❯ 1. 빨강  2. 파랑  3. 초록  4. Type something.
#     다중: ❯ 1. [ ] 빨강  2. [ ] 파랑  3. [ ] 초록  4. [ ] Type something
# 그 줄로 내려가 치면 단일은 Enter 로 확정, 다중은 친 순간 [✔] 로 체크되고 → Submit 으로 낸다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import marina_mobile as mm

# ① 계약: 질문별로 [정수…] 또는 {"text": "…"} 를 섞어 받는다.
파싱 = mm._parse_answers({"answers": [[0], {"text": "직접 쓴 답"}, [1, 2]]})
assert 파싱 == [[0], {"text": "직접 쓴 답"}, [1, 2]], 파싱
# 예전 형식도 그대로 읽는다.
assert mm._parse_answers({"optionIndex": 2}) == [[2]]
assert mm._parse_answers({"optionIndexes": [0, 1]}) == [[0], [1]]
# 빈 텍스트는 답이 아니다 — 조용히 1번이 확정되면 안 된다.
try:
    mm._parse_answers({"answers": [{"text": "   "}]})
    raise AssertionError("빈 텍스트를 받아준다")
except ValueError:
    pass

# ② 구동: 단일선택 자유 입력 = ↓×(옵션 수) → 타이핑 → Enter.
키 = []
mm.term_input = lambda tid, data: 키.append(data)
mm._agent_input_pause = lambda: None
mm._drive_selector("t", {"text": "노랑"}, False, 3)
assert "".join(키) == "\x1b[B" * 3 + "노랑" + "\r", 키

# ③ **다중선택에는 글로 답할 수 없다.** 자유 입력 줄에 글자를 넣는 것까지는 되는데 입력칸을
#    빠져나와 Submit 으로 가는 키가 없다 — 실 CLI 로 네 순서를 다 돌렸다(→/Tab/Enter 는 제출
#    안 됨, ↑ 는 "답 안 함"으로 닫힘). 반쯤 채운 폼을 남기느니 거절한다.
키.clear()
try:
    mm._drive_selector("t", {"text": "노랑"}, True, 3)
    raise AssertionError("다중선택에 글을 밀어넣는다 — 폼이 반쯤 채워진 채 남는다")
except ValueError:
    pass
assert not 키, f"거절하면서 키를 보냈다: {키}"

# ④ 고르는 경우는 예전 그대로다.
키.clear()
mm._drive_selector("t", [2], False, 3)
assert "".join(키) == "\x1b[B\x1b[B" + "\r", 키
print("ok 질문별로 골라도 되고 써도 된다 · 다중선택 글답은 거절")
PY

# ⑤ 화면: 다중선택 질문에는 기타 입력칸을 아예 안 준다 — 될 것처럼 띄워두면 형은 썼는데
#    안 가는 걸 또 겪는다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY3'
import sys
from pathlib import Path

렌더 = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
블록 = 렌더[렌더.find("const otherOpen"):][:900]
assert "multiSelect" in 렌더[렌더.find("const 다중"):렌더.find("const otherOpen")], "다중선택 판정이 없다"
assert "questionOtherOff" in 블록 or "questionOtherOff" in 렌더, "다중선택에서 기타 칸을 그대로 준다"
print("ok 화면: 다중선택엔 직접 입력칸을 안 준다")
PY3

# ⑥ 화면: 질문별 기타 입력이 폼 전체를 덮어쓰지 않는다.
PYTHONPATH="$SCR" python3 - <<'PY2'
from marina_mobile import render_mobile_html

html = render_mobile_html()
보내기 = html[html.find("function sendLiveOther"):][:1200]
assert "submitLiveAnswer({text})" not in 보내기, \
    f"질문 하나의 기타 입력이 폼 전체 답으로 나간다 — 나머지 질문의 선택이 버려진다: {보내기[:400]}"
assert "answers" in 보내기, f"질문별 답으로 안 보낸다: {보내기[:400]}"
print("ok 화면: 질문별 기타가 다른 질문의 선택을 안 지운다")
PY2

echo "PASS test-answer-mixed"
