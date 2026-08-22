#!/usr/bin/env bash
# 질문을 **접을 길**이 있어야 한다 — 형: "질문 취소는? 취소버튼 이런것도 없잖아".
#
# 지금은 카드가 뜨면 답하거나 방치하거나 둘뿐이다. 방치하면 에이전트는 계속 기다린다.
# CLI 화면엔 원래 길이 있다(실물 확인 2026-08-22):
#     ❯ 1. 빨강  2. 파랑  3. 초록  4. Type something.  5. Chat about this
#        Enter to select · ↑/↓ to navigate · Esc to cancel
# 마지막 줄(Chat about this)을 고르면 질문이 닫히고 에이전트는 이렇게 받는다:
#     The user doesn't want to proceed with this tool use. … The user wants to clarify these questions.
# = "이 질문 말고 그냥 얘기하자". Esc(맨 거절)보다 폰에서 쓸 말이라 이쪽을 쓴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path

import marina_mobile as mm

키입력: list[str] = []
보낸것: list[dict] = []
mm.term_input = lambda tid, data: 키입력.append(data)
mm._agent_input_pause = lambda: None
mm.safe_root = lambda text: Path("/wt")
mm._live_agent_tid = lambda root, source, sid: "tid-1"
mm._question_state_token = lambda sid: "tok:1"
mm._await_answer_settled = lambda sid, before, questions=1: True
mm.mobile_send = lambda body: (보낸것.append(body), {"delivery": "sent"})[1]
mm._clear_pending_question = lambda sid: None
mm.mobile_pending_question = lambda source, sid: {"questions": [
    {"question": "뭐 만들래?", "options": [{"label": "A"}, {"label": "B"}, {"label": "C"}]}]}

몸통 = {"root": "/wt", "target": {"type": "agent", "source": "claude", "sid": "s1"}, "dismiss": True}

# ① 옵션 3개면 ↓ 4번(자유입력 줄을 지나 'Chat about this') → Enter.
결과 = mm.mobile_answer(dict(몸통))
assert "".join(키입력) == "\x1b[B" * 4 + "\r", 키입력
assert 결과.get("settled") is True and 결과.get("dismissed") is True, 결과

# ② 옵션 수를 모르면 찍어서 내려가지 않는다 — 엉뚱한 줄에서 Enter 치면 그게 오답이 된다.
키입력.clear()
mm.mobile_pending_question = lambda source, sid: {"questions": []}
try:
    mm.mobile_answer(dict(몸통))
    raise AssertionError("옵션 수도 모르면서 셀렉터를 눌렀다")
except ValueError:
    pass
assert not 키입력, f"거절하면서 키를 보냈다: {키입력}"
print("ok 질문 접기: 'Chat about this' 줄로 내려가서 고른다")
PY

# ③ 화면에 접는 버튼이 있어야 한다 — 카드가 뜨면 답하거나 방치하거나 둘뿐이면 안 된다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY2'
import sys
from pathlib import Path

렌더 = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
assert "data-answer-dismiss" in 렌더, "질문을 접는 버튼이 화면에 없다"

from marina_mobile import render_mobile_html
html = render_mobile_html()
assert "data-answer-dismiss" in html, "모바일 화면에 접는 버튼이 없다"
assert "dismissLiveQuestion" in html, "버튼이 아무 데도 안 이어져 있다"
동작 = html[html.find("async function dismissLiveQuestion"):][:700]
assert "dismiss: true" in 동작, f"서버로 접기 요청을 안 보낸다: {동작[:300]}"
print("ok 화면: 질문을 접는 버튼이 있고 서버로 이어진다")
PY2

echo "PASS test-answer-dismiss"
