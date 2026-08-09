#!/usr/bin/env bash
# Task 3 (mobile queue/question plan) — robust AskUserQuestion surfacing.
# Part A: marina_question.py PreToolUse capture is best-effort (writes a record even when
#         tool_input.questions is odd-shaped; only skips when there's genuinely nothing).
# Part B: marina_mobile.py's renderQuestionCard never renders an empty .questionCard — it
#         falls back to plain text when header/question/options can't be built.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- Part A: marina_question.py capture hardening ----------
home_ok="$TMP/home-ok"; mkdir -p "$home_ok"
home_odd="$TMP/home-odd"; mkdir -p "$home_odd"
home_bare="$TMP/home-bare"; mkdir -p "$home_bare"
home_empty="$TMP/home-empty"; mkdir -p "$home_empty"

# well-formed: normal question with options.
MARINA_HOME="$home_ok" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-ok-1234", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-1",
 "tool_input": {"questions": [{"header": "Pick one", "question": "Which color?", "options": [{"label": "Red"}, {"label": "Blue"}]}]}}
JSON

# odd-but-nonempty: list of bare strings (no header/options at all).
MARINA_HOME="$home_odd" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-odd-1234", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-2",
 "tool_input": {"questions": ["What's your favorite color?"]}}
JSON

# odd-but-nonempty: a bare dict (not wrapped in a list) with an unrelated key + options only.
MARINA_HOME="$home_bare" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-bare-1234", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-3",
 "tool_input": {"questions": {"options": [{"label": "Yes"}, {"label": "No"}]}}}
JSON

# genuinely empty: missing key, empty list, and empty-dict-only-list should all skip (no file).
MARINA_HOME="$home_empty" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-empty-1234", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-4",
 "tool_input": {}}
JSON
MARINA_HOME="$home_empty" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-empty-5678", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-5",
 "tool_input": {"questions": []}}
JSON
MARINA_HOME="$home_empty" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-empty-9012", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-6",
 "tool_input": {"questions": [{}]}}
JSON

# 중단/거절 정리: PostToolUse 가 영영 안 오는 경로(Esc 로 끄거나 글로 답함)에서도 상태파일이
# 지워져야 한다 — 안 그러면 죽은 질문 카드가 모바일에 남아 탭해도 아무 일이 안 일어난다.
home_cancel="$TMP/home-cancel"; mkdir -p "$home_cancel"
for evt in UserPromptSubmit Stop; do
  MARINA_HOME="$home_cancel" python3 "$SCR/marina_question.py" <<JSON
{"session_id": "sess-cancel-1234", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-c", "tool_input": {"questions": [{"header": "H", "question": "Q?", "options": [{"label": "A"}]}]}}
JSON
  test -f "$home_cancel/agent-questions/claude-sess-cancel-1234.json" || { echo "FAIL: PreToolUse 기록 안 됨"; exit 1; }
  # 정리 이벤트엔 tool_name 이 없다(도구와 무관한 이벤트) — 그래도 지워야 한다.
  MARINA_HOME="$home_cancel" python3 "$SCR/marina_question.py" <<JSON
{"session_id": "sess-cancel-1234", "hook_event_name": "$evt", "cwd": "/tmp"}
JSON
  test -f "$home_cancel/agent-questions/claude-sess-cancel-1234.json" && { echo "FAIL: $evt 로 정리 안 됨 (죽은 질문 카드 문신)"; exit 1; }
done
echo "PASS 중단/거절 정리: UserPromptSubmit·Stop 둘 다 상태파일 제거"

# 훅 등록도 같이 잠근다 — 스크립트만 고치고 hooks.json 에 안 달면 실제로는 안 돈다.
python3 - "$HERE/../hooks/hooks.json" <<'PY'
import json, sys
hooks = json.loads(open(sys.argv[1]).read())["hooks"]
for event in ("UserPromptSubmit", "Stop", "PostToolUse"):
    commands = [h.get("command", "") for group in hooks.get(event, []) for h in group.get("hooks", [])]
    assert any("marina-question-hook.sh" in c for c in commands), f"{event} 에 question 훅 미등록: {commands}"
print("PASS hooks.json: question 훅이 PostToolUse + UserPromptSubmit + Stop 에 등록됨")
PY

python3 - "$home_ok" "$home_odd" "$home_bare" "$home_empty" <<'PY'
import json
import sys
from pathlib import Path

home_ok, home_odd, home_bare, home_empty = (Path(p) for p in sys.argv[1:5])

ok = json.loads((home_ok / "agent-questions" / "claude-sess-ok-1234.json").read_text())
assert ok["questions"][0]["question"] == "Which color?", ok
assert ok["toolUseId"] == "tu-1", ok

odd = json.loads((home_odd / "agent-questions" / "claude-sess-odd-1234.json").read_text())
assert odd["questions"] and odd["questions"][0].get("question") == "What's your favorite color?", odd

bare = json.loads((home_bare / "agent-questions" / "claude-sess-bare-1234.json").read_text())
assert bare["questions"] and isinstance(bare["questions"][0].get("options"), list), bare
assert len(bare["questions"][0]["options"]) == 2, bare

for sid in ("sess-empty-1234", "sess-empty-5678", "sess-empty-9012"):
    assert not (home_empty / "agent-questions" / f"claude-{sid}.json").exists(), sid

print("PASS part A (marina_question.py capture hardening): well-formed + odd(list-of-strings) + odd(bare dict) written, genuinely-empty(3 shapes) skipped")
PY

# ---------- Part B: renderQuestionCard fallback (node vm) ----------
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' | node
# 질문 카드 렌더러는 marina-web/chat-render.js 로 옮겨졌다(웹과 공유). 마커도 같이 따라갔다.
import json
import sys
from pathlib import Path

html = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")

def extract(start_marker, end_marker):
    start = html.find(start_marker)
    end = html.find(end_marker)
    if start < 0 or end < 0 or end <= start:
        raise SystemExit(f"boundaries missing for {start_marker}")
    return html[start:end]

esc_helpers = extract("// ESC_HELPERS_START", "// ESC_HELPERS_END")
question_card = extract("// QUESTION_CARD_START", "// QUESTION_CARD_END")
source = esc_helpers + "\n" + question_card
print("const helperSource = " + json.dumps(source) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");

const context = {};
vm.createContext(context);
vm.runInContext(
  `${helperSource}\nthis.renderQuestionCard = renderQuestionCard; this.questionsFromActivity = questionsFromActivity;`,
  context, {filename: "marina_mobile.py::renderQuestionCard"});
const renderQuestionCard = context.renderQuestionCard;
if (typeof renderQuestionCard !== "function") throw new Error("renderQuestionCard not extracted");

function activityFor(questions) {
  return {name: "AskUserQuestion", status: "pending", detail: JSON.stringify({questions})};
}

// 1) well-formed question -> structured card with header/question text/option buttons.
{
  const item = activityFor([{header: "Pick one", question: "Which color?", options: [{label: "Red"}, {label: "Blue"}]}]);
  const html = renderQuestionCard(item, true);
  assert.ok(html.includes('class="questionCard"'), "expected questionCard wrapper");
  assert.ok(html.includes("Which color?"), `expected question text in structured card: ${html}`);
  assert.ok(html.includes("Red") && html.includes("Blue"), `expected option buttons: ${html}`);
}

// 2) malformed: no header/question/options at all (odd dict) -> text fallback, never empty.
{
  const item = activityFor([{foo: "bar"}]);
  const html = renderQuestionCard(item, true);
  assert.ok(html.includes('class="questionCard"'), "expected questionCard wrapper even for fallback");
  assert.ok(html.trim().length > 0, "fallback card must not be empty");
  assert.ok(!html.includes('<div class="questionOpts">'), `expected plain-text fallback (no opts div): ${html}`);
}

// 3) malformed: bare string (list-of-strings normalized shape from marina_question.py) -> shows question text.
{
  const item = activityFor([{question: "What's your favorite color?"}]);
  const html = renderQuestionCard(item, true);
  assert.ok(html.includes("What&#39;s your favorite color?") || html.includes("What's your favorite color?"),
    `expected question text rendered: ${html}`);
}

// 4) no questions at all -> "" (genuinely nothing to show, not a fallback case).
{
  const item = activityFor([]);
  const html = renderQuestionCard(item, true);
  assert.equal(html, "", `expected empty string when there are no questions: ${html}`);
}

// 5) 질문이 여러 개면 **전부** 그려야 한다 — 예전엔 첫 질문만 그리고 나머지는 안내문 한 줄이었는데,
//    그 상태로 답하면 폼이 2번째 질문에서 계속 대기해 "선택했는데 안 감"이 됐다.
{
  const item = activityFor([
    {header: "A", question: "첫 질문?", options: [{label: "A1"}, {label: "A2"}]},
    {header: "B", question: "둘째 질문?", options: [{label: "B1"}, {label: "B2"}]},
  ]);
  const html = renderQuestionCard(item, true, {choices: [], sending: false, failed: false});
  assert.ok(html.includes("첫 질문?") && html.includes("둘째 질문?"), `both questions must render: ${html}`);
  assert.ok(html.includes("B1") && html.includes("B2"), `second question options must render: ${html}`);
  assert.ok(!html.includes("첫 질문에 응답합니다"), "stale single-question notice must be gone");
  assert.ok(html.includes('data-answer-q="1"'), `second question must be answerable: ${html}`);
  assert.ok(html.includes("data-answer-submit"), "multi-question card needs a submit button");
  assert.ok(/data-answer-submit disabled|data-answer-submit\s+disabled/.test(html),
    `submit must start disabled until every question is answered: ${html}`);
}

// 6) 다 고르면 보내기가 열리고, 고른 게 표시된다.
{
  const item = activityFor([
    {header: "A", question: "첫 질문?", options: [{label: "A1"}, {label: "A2"}]},
    {header: "B", question: "둘째 질문?", options: [{label: "B1"}, {label: "B2"}]},
  ]);
  const html = renderQuestionCard(item, true, {choices: [1, 0], sending: false, failed: false});
  assert.ok(html.includes("보내기 (2/2)"), `submit label must show progress: ${html}`);
  assert.ok(!/data-answer-submit\s+disabled/.test(html), `submit must enable when complete: ${html}`);
  assert.equal((html.match(/questionOpt chosen/g) || []).length, 2, `both picks must be marked: ${html}`);
}

// 7) 안 먹었을 때(settled=false) 카드가 살아있고 경고가 붙는다 — 낙관적으로 지우지 않는다.
{
  const item = activityFor([{header: "A", question: "질문?", options: [{label: "A1"}]}]);
  const html = renderQuestionCard(item, true, {choices: [], sending: false, failed: true});
  assert.ok(html.includes("questionFailed"), `failed answer must surface in the card: ${html}`);
  assert.ok(html.includes("질문?"), "card must survive a failed answer so it can be retried");
}

// 8) 기타(직접 입력): 닫힘 → 버튼, 열림 → **그 줄 자체**가 입력칸. 아래에 줄이 더 생기면 안 된다.
{
  const item = activityFor([{header: "A", question: "질문?", options: [{label: "A1"}]}]);
  // otherOpen/otherText 는 **질문별 맵**이다({qi: ...}) — 폼 전체 스칼라였을 땐 질문이 여럿일 때
  // 어느 질문의 기타인지 못 담아서, 그 김에 기타를 통째로 숨겼었다(형: "모든 질문에 기타 있어야").
  const closed = renderQuestionCard(item, true, {choices: [], otherOpen: {}});
  assert.ok(closed.includes("data-answer-other"), `닫힘 상태엔 기타 버튼: ${closed}`);
  assert.ok(!closed.includes("data-answer-other-input"), "닫힘 상태에 입력칸이 있으면 안 됨");
  assert.ok(!closed.includes("questionOtherRow"), "닫힘 상태에 숨은 행을 미리 만들면 안 됨(재렌더 루프의 원인)");

  const open = renderQuestionCard(item, true, {choices: [], otherOpen: {0: true}, otherText: {0: "직접 쓴 값"}});
  assert.ok(open.includes("data-answer-other-input"), `열림 상태엔 입력칸: ${open}`);
  assert.ok(!/data-answer-other[">\s]/.test(open.replace(/data-answer-other-(input|send)/g, "")),
    `열림 상태엔 기타 버튼이 남지 않아야 함(그 줄이 입력칸으로 바뀐다): ${open}`);
  // 입력값이 템플릿에 실려야 재렌더에도 살아남는다
  assert.ok(open.includes('value="직접 쓴 값"'), `입력값이 템플릿에 실려야 함: ${open}`);
  // 숨김 스타일을 DOM 에 박아두면(예전 방식) 직렬화 DOM 이 템플릿과 영구히 달라져 폴링마다 재빌드된다
  assert.ok(!open.includes('style="display:none"') && !closed.includes('style="display:none"'),
    "인라인 display 숨김은 재렌더 루프를 만든다");
}

// 9) 입력값에 따옴표/HTML 이 들어와도 속성이 깨지거나 실행되면 안 된다.
{
  const item = activityFor([{header: "A", question: "질문?", options: [{label: "A1"}]}]);
  const open = renderQuestionCard(item, true, {choices: [], otherOpen: {0: true}, otherText: {0: '"><script>alert(1)</script>'}});
  assert.ok(!/<script>/.test(open), `입력값이 실행되면 안 됨: ${open}`);
  assert.ok(open.includes("&quot;"), "따옴표가 이스케이프돼야 속성이 안 깨진다");
}

// 10) multiSelect: 체크박스로 그리고, 고른 걸 **여러 개** 표시하고, 즉시 전송하지 않는다.
{
  const item = activityFor([{header: "다중", question: "여러 개?", multiSelect: true,
                             options: [{label: "A"}, {label: "B"}, {label: "C"}]}]);
  const none = renderQuestionCard(item, true, {choices: []});
  assert.ok(!none.includes("questionOptMark"), "선택 표시는 체크박스가 아니라 하이라이트다");
  assert.ok(none.includes("여러 개 고를 수 있어요"), `안내가 필요: ${none}`);
  assert.ok(none.includes("data-answer-submit"), "multiSelect 는 즉시 전송이 아니라 보내기 버튼이 필요");
  // AskUserQuestion 은 내가 준 선택지 뒤에 Other 행을 **항상** 붙인다(그래서 tool_input.options 엔 없다).
  // 여기서 감추면 터미널·앱에선 되는 선택지가 마리나에서만 사라진다 — multiSelect 에도 기타가 있어야 한다.
  assert.ok(none.includes("data-answer-other"), `multiSelect 에도 기타(직접입력)가 있어야 함: ${none}`);

  const some = renderQuestionCard(item, true, {choices: [[0, 2]]});
  assert.equal((some.match(/questionOpt chosen/g) || []).length, 2, `여러 개가 선택 표시돼야 함: ${some}`);
  // 질문이 하나면 '답한 질문 수'(늘 1/1)가 아니라 **고른 개수**를 보여준다 — 형: "0/1 나오는것도 문제".
  assert.ok(some.includes("보내기 (2개 선택)"), `고른 개수를 세야 함: ${some}`);
  assert.ok(!/data-answer-submit\s+disabled/.test(some), "선택이 있으면 보내기 활성");
}

// 11) 단일선택 질문 — 탭 즉시 전송(보내기 버튼 없음).
{
  const item = activityFor([{header: "단일", question: "하나?", options: [{label: "A"}, {label: "B"}]}]);
  const html = renderQuestionCard(item, true, {choices: [[1]]});
  assert.ok(!html.includes("data-answer-submit"), "단일 질문·단일선택은 탭 즉시 전송(보내기 버튼 없음)");
  assert.equal((html.match(/questionOpt chosen/g) || []).length, 1);
}

// 12) 구형 state(정수 choices)도 깨지지 않는다.
{
  const item = activityFor([{header: "단일", question: "하나?", options: [{label: "A"}, {label: "B"}]}]);
  const html = renderQuestionCard(item, true, {choices: [1]});
  assert.equal((html.match(/questionOpt chosen/g) || []).length, 1, `정수 choices 하위호환: ${html}`);
}

console.log("PASS part B (renderQuestionCard): 구조/폴백/다중질문/재시도/기타인라인/XSS + multiSelect 체크박스·다중표시·즉시전송금지 (12/12)");
''')
PY

# ---------- Part C: mobile_answer — 전 질문 확정 + 상태파일로 성공 확인 ----------
PYTHONPATH="$SCR" python3 - <<'PY'
import json
import time
from pathlib import Path

import marina_mobile as mm

SID = "sess-answer-1234"
ROOT = Path("/tmp")
state = mm.AGENT_QUESTIONS_DIR / f"claude-{SID}.json"


def arm(questions=1):
    mm.AGENT_QUESTIONS_DIR.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({
        "sid": SID, "toolUseId": "tu-answer", "ts": time.time(),
        "questions": [{"question": f"q{i}", "options": [{"label": "a"}, {"label": "b"}]}
                      for i in range(questions)],
    }), encoding="utf-8")


sent: list[str] = []
mm.safe_root = lambda value: ROOT                       # 실 worktree 검증 우회
mm._live_agent_tid = lambda root, source, sid: "tid-1"  # PTY 없이 주입 경로만 검사
mm._agent_input_pause = lambda: None
mm._ANSWER_CONFIRM_TIMEOUT_S = 0.4                       # 실패 케이스를 빨리 끝내기
body = {"root": str(ROOT), "target": {"type": "agent", "source": "claude", "sid": SID}}

# ① 셀렉터가 답을 먹으면(=PostToolUse 훅이 상태파일 삭제) settled True.
def consuming_input(tid, data):
    sent.append(data)
    if data == "\r" and sent.count("\r") >= 2:   # 질문 2개 = Enter 2번 후 폼 종료
        state.unlink(missing_ok=True)

arm(questions=2)
sent.clear()
mm.term_input = consuming_input
result = mm.mobile_answer({**body, "optionIndexes": [1, 0]})
assert result["settled"] is True, result
assert sent == ["\x1b[B", "\r", "\r"], sent          # 1번째=아래1칸+확정, 2번째=그대로 확정
assert result["answers"] == [[1], [0]], result   # 응답은 질문별 **목록**이다(multiSelect 때문)

# ② 키를 써도 상태파일이 그대로면 settled False — 모바일이 카드를 되살릴 근거.
arm(questions=1)
sent.clear()
mm.term_input = lambda tid, data: sent.append(data)
result = mm.mobile_answer({**body, "optionIndex": 2})
assert result["settled"] is False, result
assert sent == ["\x1b[B\x1b[B", "\r"], sent
state.unlink(missing_ok=True)

# ③ 예전 단일 optionIndex 계약도 그대로 — 대시보드/트랜스크립트 카드가 아직 쓴다.
arm(questions=1)
sent.clear()
mm.term_input = lambda tid, data: (sent.append(data), state.unlink(missing_ok=True))[0]
result = mm.mobile_answer({**body, "optionIndex": 0})
assert result["settled"] is True and result["optionIndex"] == 0, result

# ④ 범위 밖 인덱스는 거부.
for bad in ({"optionIndex": 999}, {"optionIndexes": [0, -1]}, {"answers": [[]]}, {"answers": [[99]]}):
    try:
        mm.mobile_answer({**body, **bad})
    except ValueError:
        pass
    else:
        raise AssertionError(f"expected rejection for {bad}")

# ⑤ multiSelect — 스페이스로 토글하고 마지막에 Enter. 화살표+Enter 만으로는 여러 개를 표현할 수 없다
#    (형: "ask 여러개 선택하는거 선택이 안되는데"). multiSelect 여부는 훅이 잡아둔 질문 원본에서 읽는다.
def arm_multi():
    mm.AGENT_QUESTIONS_DIR.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({
        "sid": SID, "toolUseId": "tu-multi", "ts": time.time(),
        "questions": [{"question": "여러 개 고르기", "multiSelect": True,
                       "options": [{"label": "a"}, {"label": "b"}, {"label": "c"}, {"label": "d"}]}],
    }), encoding="utf-8")

arm_multi()
sent.clear()
mm.term_input = lambda tid, data: (sent.append(data), state.unlink(missing_ok=True) if data == "\r" else None)[0]
result = mm.mobile_answer({**body, "answers": [[0, 2, 3]]})
assert result["settled"] is True, result
assert sent == [" ", "\x1b[B\x1b[B", " ", "\x1b[B", " ", "\r"], sent
assert result["answers"] == [[0, 2, 3]], result

# 단일선택 질문은 스페이스를 쓰면 안 된다(토글이 아니라 확정이라 동작이 달라진다)
arm(questions=1)
sent.clear()
mm.term_input = lambda tid, data: (sent.append(data), state.unlink(missing_ok=True) if data == "\r" else None)[0]
mm.mobile_answer({**body, "answers": [[2]]})
assert sent == ["\x1b[B\x1b[B", "\r"], sent
assert " " not in sent, "단일선택에 스페이스를 넣으면 안 된다"

# 클라이언트가 multiSelect 라고 우겨도 원본이 단일선택이면 단일선택으로 처리한다
arm(questions=1)
sent.clear()
mm.term_input = lambda tid, data: (sent.append(data), state.unlink(missing_ok=True) if data == "\r" else None)[0]
mm.mobile_answer({**body, "answers": [[1, 3]]})
assert " " not in sent, f"원본이 단일선택인데 토글을 보냈다: {sent}"

# ⑥ 셀렉터가 죽었어도 막지 않는다 — 세션을 이어받아(--resume) **고른 내용을 글로** 전달한다.
#    전송은 원래 인수인계로 뚫고 있었는데 응답만 막는 건 일관성이 없었다(형: "다시 세션 주도권
#    가져와서 고르게 해주면 안되는거야?"). 원래 tool call 은 프로세스와 함께 죽었으니 인덱스가
#    아니라 **라벨**을 보내야 의미가 산다.
arm_multi()
handed = {}
mm._live_agent_tid = lambda r, s, i: ""              # 셀렉터 없음
mm.mobile_send = lambda payload: handed.update(payload) or {"ok": True, "tid": "t-resume", "opened": True}
result = mm.mobile_answer({**body, "answers": [[0, 2]]})
assert result["viaResume"] is True and result["settled"] is True, result
assert "a" in handed["text"] and "c" in handed["text"], handed["text"]
assert "b" not in handed["text"].split("\n")[-1], f"안 고른 라벨이 실렸다: {handed['text']}"
assert handed["target"] == {"type": "agent", "source": "claude", "sid": SID}, handed
assert not state.exists(), "이어받아 전달했으면 질문 카드는 정리돼야 한다(PostToolUse 가 올 수 없다)"

# 자유입력도 같은 경로로 전달된다
arm_multi(); handed.clear()
result = mm.mobile_answer({**body, "text": "직접 쓴 답"})
assert handed["text"] == "직접 쓴 답", handed
assert result["viaResume"] is True

state.unlink(missing_ok=True)
print("PASS part C (mobile_answer): 전 질문 확정 + settled + 구계약 호환 + 범위 + multiSelect 토글 + 죽은 셀렉터 인수인계 (8/8)")
PY

# ---------- Part D: 폴링이 입력을 지우지 못한다 ----------
# 형 신고: "깜빡거리면서 자꾸 초기화되잖아 → 직접 입력 자체가 불가능해".
# 원인은 innerHTML 비교가 **직렬화된 실제 DOM** 과 하는 것이었다: 기타 버튼을 누를 때 JS 가
# style.display 를 바꿔놓으면 그 뒤로 DOM 이 템플릿과 영구히 달라져, 폴링마다 재할당되며 입력칸이 파괴됐다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import sys
from pathlib import Path

from marina_mobile import render_mobile_html

# 질문 카드 마크업은 공유 렌더러(chat-render.js)에, 선택/전송 규칙은 모바일에 있다. 둘 다 서빙되니
# 합쳐서 본다 — 어느 파일에 있는지가 아니라 배선이 살아 있는지가 계약이다.
html = render_mobile_html() + "\n" + (
    Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")

# ① imperative style 조작이 사라졌다(재발 방지 — 이게 루프의 방아쇠였다)
assert "row.style.display" not in html, "style.display 조작이 남아 있으면 재렌더 루프가 돌아온다"
assert 'data-question-other-row style="display:none"' not in html, "숨은 행을 미리 박아두면 안 된다"

# ② 열림/입력값은 state 에 있다 → 템플릿과 DOM 이 일치해 재빌드가 안 일어난다
# 질문별 맵이라 인덱스로 쓴다 — 질문이 여럿일 때 어느 질문의 기타인지 담아야 하기 때문.
assert "liveAnswer.otherOpen[answerQIndex(otherBtn)] = true" in html, "기타 열림이 질문별 state 로 관리되지 않음"
assert "liveAnswer.otherText[answerQIndex(input)] = input.value" in html, "입력값이 질문별 state 에 보관되지 않음"
assert "otherOpen: {}, otherText: {}" in html, "새 질문에서 기타 상태가 초기화되지 않음"

# ③ 입력 중에는 DOM 을 갈아치우지 않고 미뤄둔다 + 포커스 빠질 때 반영
# 가드는 **입력창 타이핑 중에만** 걸려야 한다. 버튼 포커스까지 막으면 옵션을 눌러도 화면이 안 갈려
# 선택이 0/N 으로 남는다(데스크톱은 클릭한 버튼이 activeElement 라 매번 걸렸다 — 형이 맞은 버그).
assert 'active.tagName === "INPUT" || active.tagName === "TEXTAREA"' in html, \
    "재렌더 가드가 입력창으로 좁혀지지 않았다 — 버튼 클릭까지 막아 선택이 반영 안 된다"
assert "if (liveQuestionEl.contains(document.activeElement)) {" not in html, \
    "포커스만 보고 막는 옛 가드가 남아 있다"
assert "liveQuestionPending = html;" in html, "미뤄둔 갱신을 보관하지 않음"
assert 'liveQuestionEl.addEventListener("focusout"' in html, "포커스 빠질 때 flush 가 없음"
guard = html.find("if (liveQuestionEl.contains(document.activeElement)) {")
swap = html.find("if (liveQuestionEl.innerHTML !== html) liveQuestionEl.innerHTML = html;")
assert guard < swap, "가드가 innerHTML 교체보다 뒤에 있으면 입력이 날아간다"

# ④ 엔터로 바로 보내고, Esc 로 접는다
assert 'if (event.key === "Enter") { event.preventDefault(); sendLiveOther(answerQIndex(input)); }' in html, \
    "기타 입력에서 엔터 전송 없음"
assert "liveAnswer.otherOpen[answerQIndex(input)] = false; input.blur();" in html, "Esc 로 접기 없음"
assert "event.isComposing" in html, "한글 조립 중 엔터를 가로채면 마지막 음절이 깨진다"

# multiSelect 는 트랜스크립트 안 폴백 카드에서도 탭 즉시 전송이면 안 된다.
# (그 경로는 answerQuestion({optionIndex}) 로 바로 쏘기 때문에 하나만 고르고 끝나버린다 — 형이 맞은 버그.)
# 대화 안 폴백 카드도 **답할 수 있어야** 한다 — 라이브 카드가 만료되면 형이 보는 유일한 카드가 그거다.
# 단 규칙은 라이브 카드와 공유해야 한다(예전엔 여기서 탭 즉시 전송해 multiSelect 가 깨졌다).
assert "const fallbackState = canAnswer" in html, "폴백 카드가 상태를 공유하지 않는다"
assert "&& fallbackQuestions.length && !session.pendingQuestion);" in html, \
    "라이브 카드가 있을 때만 폴백을 읽기전용으로 둬야 한다"
assert "renderQuestionCard(question, canAnswer, fallbackState)" in html, "폴백 카드에 상태가 안 넘어간다"
assert "if (pickAnswerOption(Number.isNaN(rawQ) ? 0 : rawQ, index)) submitLiveAnswer({answers: [[index]]});\n        else repaintTurns();" in html, \
    "폴백 카드 클릭이 라이브와 다른 규칙을 쓴다"
assert "function pickAnswerOption(qi, index)" in html, "선택 규칙이 한 곳에 모여 있지 않다"
assert "function ensureAnswerState(questions, token)" in html, "상태 시딩이 공용이 아니다"
assert "questionOptMark" not in html, "체크박스 잔재"
# PTY 를 못 쥐어도 고를 수 있어야 한다(이어받아 전달) — controllable 을 조건에 넣으면 안 된다.
assert 'const canAnswer = session.kind === "agent" && sessionSource(session) === "claude";' in html, \
    "controllable 이 없다고 카드를 막으면 안 된다 — 인수인계로 답할 수 있다"
assert "liveAnswer.viaResume = canAnswer && !session.controllable;" in html, "이어받기 안내 플래그가 없다"
assert "고르면 세션을 이어받아 답을 전달해요" in html, "이어받기 안내 문구가 없다"
# 못 고르는 카드는 **이유를 말해야** 한다. 예전 문구("실행 중일 때만")는 세션이 살아 보이는 상황에서 거짓말이었다.
assert "이 세션이 실행 중일 때만 응답할 수 있어요" not in html, "부정확한 안내문이 남아 있다"
assert "questionBlocked" in html, "비활성 사유 배너가 없다"
assert ".questionOpt:disabled { opacity: .45;" in html, "비활성 옵션이 눌리는 것처럼 보인다"

print("PASS part D: 폴링 재렌더가 직접입력을 지우지 못한다(state 보관 + 입력중 가드 + focusout flush + 엔터/Esc)")
PY

echo "PASS test-agent-question-surfacing"
