#!/usr/bin/env bash
# 질문·답은 대화다 — 형: "AskUserQuestion 하는거 너가 질문한거랑 내가 답변한거 왜 안보여줘?"
#
# **왜 안 보였나.** 답을 마친 AskUserQuestion 은 kind:"activity" 로 나가 접힌 "작업" 서랍의 도구
# 한 줄이 됐다. 질문 전문도 고른 답도 detail/result 안에 다 있었지만 대화엔 안 나왔다.
# 이제 서버가 kind:"question" 으로 내보내고, 공유 렌더러가 물은 것과 고른 것을 그린다.
#
# **답 파싱의 함정.** 결과 문구는 `"<질문>"="<답>"` 인데 **질문 안에 따옴표가 들어간다**(실제 사례:
# `""새 대화 시작하면 밖으로 나가진다" — 어느 화면 얘기야?"`). 따옴표로 쪼개면 그 자리에서 어긋난다.
# 그래서 질문 원문으로 자리를 잡고 아는 선택지 라벨과 대조한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import json
import sys

import marina_sessions as ms

QUOTED = '"새 대화 시작하면 밖으로 나가진다" — 어느 화면 얘기야?'
rows = []
def row(index, obj): rows.append((index, obj))

row(0, {"type": "assistant", "message": {"content": [{
    "type": "tool_use", "id": "toolu_q1", "name": "AskUserQuestion",
    "input": {"questions": [
        {"question": QUOTED, "header": "화면", "multiSelect": False,
         "options": [{"label": "웹 대시보드", "description": "카드의 ＋CC"},
                     {"label": "모바일 (세션 목록의 ＋)", "description": "런치 직후"},
                     {"label": "둘 다", "description": "통일"}]},
        {"question": "무엇을 고칠까?", "header": "범위", "multiSelect": True,
         "options": [{"label": "탭"}, {"label": "히스토리"}]},
    ]},
}]}})
row(1, {"type": "user", "message": {"content": [{
    "type": "tool_result", "tool_use_id": "toolu_q1",
    "content": f'Your questions have been answered: "{QUOTED}"="모바일 (세션 목록의 ＋)", '
               '"무엇을 고칠까?"="탭, 히스토리". You can now continue with these answers in mind.',
}]}})

timeline = ms._transcript_timeline(rows, "claude")
questions = [item for item in timeline if item.get("kind") == "question"]
assert len(questions) == 1, timeline
item = questions[0]
assert item["status"] == "completed", item
assert not item.get("result"), "질문 카드에 결과 원문을 실으면 대화에 도구 찌꺼기가 샌다"

# ① 활동 서랍에 남으면 안 된다 — 그게 안 보이던 원인 그 자체다.
assert not [i for i in timeline if i.get("kind") == "activity"], timeline

# ② 물은 것: 질문문·헤더·선택지가 구조로 남는다(화면이 다시 파싱하지 않게).
first = item["questions"][0]
assert first["question"] == QUOTED, first
assert first["header"] == "화면", first
assert [opt["label"] for opt in first["options"]][1] == "모바일 (세션 목록의 ＋)", first

# ③ 고른 것: 따옴표 낀 질문에서도 답이 정확히 나온다.
assert item["answers"][0]["picked"] == ["모바일 (세션 목록의 ＋)"], item["answers"]
# 다중선택은 고른 것을 다 잡는다.
assert sorted(item["answers"][1]["picked"]) == ["탭", "히스토리"], item["answers"]

# ④ 답 전(결과 없음)이면 기다리는 상태로 남는다 — 없는 답을 지어내지 않는다.
pending = ms._transcript_timeline(rows[:1], "claude")[0]
assert pending["kind"] == "question" and pending["status"] == "running", pending
assert pending["answers"] == [], pending

print("ok 질문·답이 대화 항목으로 나온다(따옴표 낀 질문·다중선택 포함)")
PY

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

js = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
for start, end in (("// ESC_HELPERS_START", "// ESC_HELPERS_END"),
                   ("// QUESTION_CARD_START", "// QUESTION_CARD_END")):
    if js.find(start) < 0 or js.find(end) < 0:
        raise SystemExit(f"{start} 경계가 없다")
chunk = js[js.find("// ESC_HELPERS_START"):js.find("// ESC_HELPERS_END")] \
        + js[js.find("// QUESTION_CARD_START"):js.find("// QUESTION_CARD_END")]
print("const src = " + json.dumps(chunk) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.renderAnsweredQuestion = renderAnsweredQuestion;
this.questionsFromActivity = questionsFromActivity;`, context, {filename: "chat-render.js::answered-question"});
const {renderAnsweredQuestion, questionsFromActivity} = context;

const item = {
  kind: "question", name: "AskUserQuestion", status: "completed",
  questions: [{question: "방 화면을 어느 표면에 낼까?", header: "표면",
               options: [{label: "모바일=멤버, 웹=어드민"}, {label: "한 화면이 역할로 변신"}]}],
  answers: [{text: "모바일=멤버, 웹=어드민", picked: ["모바일=멤버, 웹=어드민"]}],
};

// 서버가 준 구조를 그대로 쓴다 — 화면에서 JSON 을 다시 파싱하지 않는다.
assert.deepEqual(questionsFromActivity(item), item.questions);

const html = renderAnsweredQuestion(item);
assert.match(html, /방 화면을 어느 표면에 낼까\?/, "물은 것이 안 보인다");
assert.match(html, /모바일=멤버, 웹=어드민/, "고른 것이 안 보인다");
assert.match(html, /questionOpt chosen answered/, "고른 답이 표시되지 않는다");
assert.doesNotMatch(html, /한 화면이 역할로 변신/, "안 고른 선택지까지 다시 늘어놓으면 대화가 시끄럽다");

// 답을 못 찾았을 때 빈 카드를 만들지 않는다.
const noAnswer = renderAnsweredQuestion({...item, answers: [{text: "", picked: []}]});
assert.match(noAnswer, /고른 답을 찾지 못했어요/);
// 아직 답 전이면 기다린다고 말한다(지어내지 않는다).
const waiting = renderAnsweredQuestion({...item, status: "running", answers: []});
assert.match(waiting, /답을 기다리는 중/);

console.log("ok 질문 카드가 물은 것과 고른 것만 그린다");
''')
PY

# 배선. 말풍선 경로는 **공유 렌더러**에, 골격 비교는 모바일에 있다 — 둘 다 서빙되므로 합쳐서 본다.
html="$(PYTHONPATH="$SCR" python3 -c 'from marina_mobile import render_mobile_html; print(render_mobile_html())')
$(cat "$SCR/marina-web/chat-render.js")"

grep -qF 'if (item && item.kind === "question") return renderAnsweredQuestion(item);' <<<"$html" \
  || { echo "FAIL: renderTimelineMessage 가 질문 항목을 안 태운다"; exit 1; }
# 골격 비교에 질문이 들어가야 붙는 즉시 다시 그린다.
grep -qF '(sections.questions || []).map(item =>' <<<"$html" \
  || { echo "FAIL: exchangeShellKey 가 질문을 안 본다 — 카드가 붙어도 화면에 안 나타난다"; exit 1; }

echo "PASS test-question-answer-render"
