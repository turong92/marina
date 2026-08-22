#!/usr/bin/env bash
# 형이 **써서 보낸 답**이 첫 번째 선택지로 바뀌어 가면 안 된다 — 형: "작성이 아니라 맨 위꺼
# 선택돼서 간거같다".
#
# **실증(2026-08-22, homeserver/mcp 워크트리 트랜스크립트).** 형이 직접 쓴 답을 보냈는데
# 기록에는 이렇게 남았다:
#   "\"부동산mcp\"로 만들고 싶은 게 정확히 뭔가요?"="부동산 데이터 MCP 서버"   ← 1번 옵션
# 마리나가 AskUserQuestion 셀렉터에 **글자를 그냥 타이핑하고 Enter** 를 쳤기 때문이다.
# 목록 셀렉터는 글자를 먹지 않고, Enter 는 커서가 놓인 **첫 옵션**을 확정한다. 형의 문장은
# 통째로 버려지고 엉뚱한 답이 에이전트에게 갔다 — 조용히 틀리는 종류라 제일 나쁘다.
#
# **실물 셀렉터 계약(2026-08-22, PTY 관찰).** 목록 맨 끝에 자유 입력 항목이 따로 있다:
#     ❯ 1. 빨강   2. 파랑   3. 초록   4. Type something.   5. Chat about this
#        Enter to select · ↑/↓ to navigate · Esc to cancel
# 그 줄로 **내려가면 그 자리에서 입력칸이 열린다**(하단 힌트가 "ctrl+g to edit in Vim" 으로
# 바뀐다). 그러니 자유 입력은 ↓×(옵션 수) → 타이핑 → Enter 다. 커서를 옮기지 않고 타이핑하면
# 글자는 버려지고 Enter 가 1번 옵션을 확정한다 — 그게 형이 겪은 그 일이다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path

import marina_mobile as mm

키입력: list[tuple[str, str]] = []
보낸것: list[dict] = []

mm.term_input = lambda tid, data: 키입력.append((tid, data))
mm._live_agent_tid = lambda root, source, sid: "tid-1"
mm._agent_input_pause = lambda: None
mm.safe_root = lambda text: Path("/wt")
mm.mobile_send = lambda body: (보낸것.append(body), {"delivery": "sent"})[1]
mm._clear_pending_question = lambda sid: None
mm.mobile_pending_question = lambda source, sid: {"questions": [{"question": "뭐 만들래?",
                                                                 "options": [{"label": "A"}, {"label": "B"}]}]}

몸통 = {"root": "/wt", "target": {"type": "agent", "source": "claude", "sid": "s1"},
        "text": "직접 쓴 답이다"}

# ① 자유 입력 줄로 **내려간 뒤** 타이핑한다 — 옵션이 2개면 ↓ 두 번.
mm._question_state_token = lambda sid: "tok:1"
mm._await_answer_settled = lambda sid, before, questions=1: True
결과 = mm.mobile_answer(dict(몸통))
보낸키 = "".join(data for _, data in 키입력)
assert 보낸키.startswith("\x1b[B\x1b[B"), f"자유 입력 줄로 안 내려간다(옵션 2개 → ↓ 2번): {보낸키!r}"
assert 보낸키.index("직접 쓴 답이다") > 보낸키.index("\x1b[B"), f"내려가기 전에 타이핑한다: {보낸키!r}"
assert 보낸키.endswith("\r"), f"확정 Enter 가 없다: {보낸키!r}"
assert not 보낸것, f"셀렉터가 살아있는데 메시지로 보냈다: {보낸것}"
assert 결과.get("settled") is True, 결과

# ② 옵션 수는 **훅이 잡아둔 질문 원본**에서 읽는다. 클라이언트가 개수를 주장하게 두면 화면과
#    어긋나는 순간 엉뚱한 줄에 글자가 떨어진다.
읽은것 = []
원래 = mm.mobile_pending_question
mm.mobile_pending_question = lambda source, sid: (읽은것.append(sid), 원래(source, sid))[1]
키입력.clear()
mm.mobile_answer(dict(몸통))
assert 읽은것, "질문 원본을 안 읽는다 — 옵션 수를 어디서 아나"

# ③ 옵션 수를 모르면 **찍어서 내려가지 않는다** — 엉뚱한 줄 위에서 Enter 를 치면 그게 또
#    오답이다. 그럴 땐 셀렉터를 건드리지 않고 글로 보낸다.
키입력.clear(); 보낸것.clear()
mm.mobile_pending_question = lambda source, sid: {"questions": []}
결과 = mm.mobile_answer(dict(몸통))
assert not 키입력, f"옵션 수를 모르는데 셀렉터를 건드린다: {키입력}"
assert 보낸것 and 보낸것[-1].get("text") == "직접 쓴 답이다", 보낸것
mm.mobile_pending_question = 원래

# ④ 살아있는 PTY 가 없으면 예전처럼 글로 이어받는다(그 길은 원래 옳다).
키입력.clear(); 보낸것.clear()
mm._live_agent_tid = lambda root, source, sid: ""
결과 = mm.mobile_answer(dict(몸통))
assert 보낸것 and 보낸것[-1].get("text") == "직접 쓴 답이다", 보낸것
print("ok 직접 쓴 답: 자유 입력 줄로 내려가서 친다(1번 확정 안 함)")
PY

echo "PASS test-answer-freetext"
