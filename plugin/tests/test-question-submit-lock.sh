#!/usr/bin/env bash
# 답을 보낸 질문 카드는 **바로 잠긴다** — 형: "애스크 답 보낸거 바로 안사라져서 또 보낼 뻔 했다".
#
# 왜 그랬나: 카드는 서버 상태의 pendingQuestion 으로 그려진다. 보내는 동안엔 잠기지만(sending),
# 전송이 끝나는 순간 다시 멀쩡한 카드로 돌아온다. 서버가 "그 질문 끝났다"를 알려주는 건 다음
# 폴(최대 3초) 뒤라, 그 사이에 한 번 더 눌릴 수 있다 = 같은 질문에 두 번 답한다.
#
# 계약: 보내고 나면 잠긴 채로 "보냈어요"를 보여주고, 서버가 그 질문을 내릴 때까지 안 열린다.
# 단 **영원히 잠그지는 않는다** — 반영이 안 되면(응답이 삼켜졌다면) 다시 누를 수 있어야 한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

js = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
chunk = js[js.find("// ESC_HELPERS_START"):js.find("// ESC_HELPERS_END")] \
        + js[js.find("// QUESTION_CARD_START"):js.find("// QUESTION_CARD_END")]
print("const src = " + json.dumps(chunk) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.renderQuestionCard = renderQuestionCard;`, context, {filename: "chat-render.js::submit-lock"});
const {renderQuestionCard} = context;

const item = {name: "AskUserQuestion", detail: JSON.stringify({questions: [{
  question: "폰으로 알림을 받고 싶은 순간은?", header: "알림",
  options: [{label: "질문했을 때"}, {label: "작업이 끝났을 때"}],
}]})};

// ① 평소: 누를 수 있다.
const open = renderQuestionCard(item, true, {choices: [], otherOpen: {}, otherText: {}});
assert.match(open, /data-answer-option="0"/, "평소엔 선택지를 누를 수 있어야 한다");

// ② 보내는 중: 잠긴다(기존 동작).
const sending = renderQuestionCard(item, true, {choices: [[0]], sending: true, otherOpen: {}, otherText: {}});
assert.doesNotMatch(sending, /data-answer-option=/, "보내는 중엔 안 눌려야 한다");

// ③ **보낸 뒤**: 계속 잠긴 채로 보냈다고 말한다 — 여기가 형이 두 번 누를 뻔한 구멍이다.
const submitted = renderQuestionCard(item, true, {choices: [[0]], submitted: true, otherOpen: {}, otherText: {}});
assert.doesNotMatch(submitted, /data-answer-option=/, "보낸 뒤에 다시 눌리면 같은 질문에 두 번 답한다");
assert.doesNotMatch(submitted, /data-answer-other\b/, "기타 입력도 열리면 안 된다");
assert.match(submitted, /보냈어요/, "보냈다는 것을 말해야 한다 — 사라지지도 잠기지도 않으면 또 누른다");
assert.match(submitted, /questionCard[^"]*submitted/, "잠긴 카드는 눈으로도 구분돼야 한다");
assert.match(submitted, /questionOpt chosen/, "무엇을 골라 보냈는지는 남아야 한다");

// ④ 반영이 안 됐다고 판정되면 다시 열린다 — 영원히 잠그면 답할 방법이 사라진다.
const stale = renderQuestionCard(item, true, {choices: [[0]], failed: true, otherOpen: {}, otherText: {}});
assert.match(stale, /data-answer-option="0"/, "실패 뒤엔 다시 누를 수 있어야 한다");

console.log("ok 답한 카드는 잠기고, 반영 실패면 다시 열린다");
''')
PY

# 모바일 쪽 배선: 전송 성공이 submitted 를 세우고, 새 질문(토큰 변경)이 그것을 푼다.
python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
start, end = src.find("// ANSWER_STATE_START"), src.find("// ANSWER_STATE_END")
if start < 0 or end < 0:
    raise SystemExit("ANSWER_STATE_START/END 경계가 없다")
print("const src = " + json.dumps(src[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {liveAnswer: {token: "", total: 0, choices: [], sending: false, failed: false,
                              submitted: false, otherOpen: {}, otherText: {}}};
vm.createContext(context);
vm.runInContext(`${src}
this.ensureAnswerState = ensureAnswerState;
this.markAnswerSubmitted = markAnswerSubmitted;
this.answerLockExpired = answerLockExpired;`, context, {filename: "marina_mobile::answer-state"});
const {ensureAnswerState, markAnswerSubmitted, answerLockExpired} = context;

const questions = [{question: "?", options: [{label: "a"}]}];
ensureAnswerState(questions, "tok-1");
assert.equal(context.liveAnswer.submitted, false);

// 전송 성공 → 잠금.
markAnswerSubmitted(true, 1000);
assert.equal(context.liveAnswer.submitted, true, "성공했는데 안 잠겼다");
assert.equal(context.liveAnswer.failed, false);

// 같은 질문이 계속 보여도 잠금 유지(서버가 아직 안 내렸을 뿐).
ensureAnswerState(questions, "tok-1");
assert.equal(context.liveAnswer.submitted, true, "같은 질문인데 잠금이 풀렸다 — 두 번 답하게 된다");

// 반영이 오래 안 되면 스스로 풀린다(응답이 삼켜졌을 수 있다 — 답할 길을 막지 않는다).
assert.equal(answerLockExpired(context.liveAnswer, 1000 + 3000), false);
assert.equal(answerLockExpired(context.liveAnswer, 1000 + 20000), true, "영원히 잠기면 답할 방법이 없다");

// 새 질문이 오면 처음부터.
ensureAnswerState(questions, "tok-2");
assert.equal(context.liveAnswer.submitted, false, "새 질문인데 잠긴 채로 뜬다");

// 전송 실패 → 잠그지 않고 실패 표시(다시 누를 수 있어야 한다).
markAnswerSubmitted(false, 2000);
assert.equal(context.liveAnswer.submitted, false);
assert.equal(context.liveAnswer.failed, true);

console.log("ok 잠금은 전송 성공에만 걸리고, 새 질문·오랜 미반영엔 풀린다");
''')
PY

# 질문이 여러 개면 확인 상한도 길어져야 한다 — 셀렉터를 순서대로 확정하느라 그만큼 걸린다.
# 실측(2026-08-17): 고정 3.5초라 3개짜리 폼이 첫 시도에 settled=False 로 떨어졌고, 같은 답으로
# 두 번째에 성공했다. 실패가 아니라 **성급한 판정**이었다.
PYTHONPATH="$SCR" python3 - <<'PY2'
import marina_mobile as mm

one = mm._answer_confirm_timeout(1)
three = mm._answer_confirm_timeout(3)
assert one >= 3.0, one
assert three > one, f"질문이 늘어도 상한이 그대로다: {one} → {three}"
assert three >= one + 3.0, f"3개짜리에 여유가 너무 적다: {three}"
assert mm._answer_confirm_timeout(0) == one, "질문 수가 0/1 이면 같은 상한"
# 질문 사이 간격도 기본 입력 간격보다 넉넉해야 한다(다음 셀렉터가 그려질 틈).
assert mm._ANSWER_NEXT_QUESTION_PAUSE_S > mm.AGENT_INPUT_SETTLE_S, \
    "질문 사이 간격이 기본 입력 간격과 같다 — 다음 셀렉터가 그려지기 전에 키가 들어간다"
print("ok 질문 수에 맞춰 기다린다")
PY2

# 답 카드가 가로로 넘치면 안 된다 — 형: "대답이 우측 화면 넘어간다". 말풍선과 같은 규칙을 쓴다.
PYTHONPATH="$SCR" python3 - <<'PY2'
import re
from marina_mobile import render_mobile_html

html = render_mobile_html()
# 같은 선택자가 여러 규칙에 나온다(.conversationSequence, .activityGroup, .turn 처럼 묶인 것도
# 있다). 하나만 집으면 엉뚱한 걸 본다 — **전부 모아** 검사한다.
def rules_for(selector):
    return [m.group(1) for m in re.finditer(re.escape(selector) + r"\s*\{([^}]*)\}", html)]

assert any("overflow-wrap" in body for body in rules_for(".turn")), \
    "기준으로 삼을 말풍선 줄바꿈 규칙이 없다"
for selector in (".questionCard", ".questionOpt", ".questionOptLabel"):
    bodies = rules_for(selector)
    assert bodies, f"{selector} 규칙이 없다"
    assert any("overflow-wrap" in body for body in bodies), \
        f"{selector} 에 줄바꿈 규칙이 없다 — 긴 글이 화면 밖으로 나간다"
opt = rules_for(".questionOpt")
assert any("max-width" in body and "box-sizing" in body for body in opt), \
    "선택지 버튼이 카드를 밀어낸다(max-width·box-sizing 없음)"
print("ok 답 카드가 화면을 넘지 않는다")
PY2

echo "PASS test-question-submit-lock"
