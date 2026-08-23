#!/usr/bin/env bash
# 질문 여러 개짜리 폼에서 **글로 답한 질문도 '답한 것'** 이다 — 형: "첫 번째 대화는 직접
# 입력했고, 두 번째 선택했는데 1/2 라서 보내기 오류".
#
# 예전엔 고른 개수만 셌다. 1번을 글로 쓰고 2번을 고르면 카운터가 1/2 에 머물러 보내기가
# 잠긴다. 게다가 기타 입력의 [보내기]는 그 자리에서 폼 전체를 보내려다 "아직 답 안 했어요"
# 토스트만 띄우고 막혔다 — 형 입장에선 어느 쪽으로도 못 보내는 상태.
#
# 규칙: 기타 입력은 **적어두기**다(카드에 남고 카운터에 포함). 폼은 [보내기]로 한 번에 간다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

렌더 = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
print("const src = " + json.dumps(렌더) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
// 렌더러는 window.MarinaChat 로 자기를 내건다(브라우저와 같은 경로로 싣는다).
const ctx = {console};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(src, ctx, {filename: "chat-render"});
const render = ctx.MarinaChat && ctx.MarinaChat.renderQuestionCard;
assert.ok(render, "renderQuestionCard 를 못 찾음");

const item = {kind: "question", questions: [
  {header: "방식", question: "어느 쪽?", options: [{label: "A"}, {label: "B"}]},
  {header: "범위", question: "어디까지?", options: [{label: "가"}, {label: "나"}]},
]};

// ① 1번은 글로, 2번은 골랐다 → 2/2 이고 보내기가 열려 있어야 한다.
const html = render(item, true, {choices: [[], [1]], otherText: ["직접 쓴 답"], otherOpen: []});
assert.ok(html.includes("보내기 (2/2)"), `카운터가 글 답을 안 센다: ${(html.match(/보내기 \([^)]*\)/) || [])[0]}`);
assert.ok(!/data-answer-submit[^>]*disabled/.test(html), "다 답했는데 보내기가 잠겨 있다");

// ② 적어둔 글은 카드에 남는다 — 접히면서 사라지면 답이 날아간 줄 안다.
assert.ok(html.includes("직접 쓴 답"), `적어둔 글이 카드에서 사라졌다: ${html.slice(0, 300)}`);

// ③ 아직 아무것도 안 한 질문이 있으면 잠겨 있다.
const html2 = render(item, true, {choices: [[], []], otherText: ["직접 쓴 답"], otherOpen: []});
assert.ok(html2.includes("보내기 (1/2)"), "안 답한 질문이 있는데 다 답한 것처럼 센다");
assert.ok(/data-answer-submit[^>]*disabled/.test(html2), "덜 답했는데 보내기가 열려 있다");
console.log("ok 폼: 글 답도 세고 · 적어둔 글이 남고 · 덜 답하면 잠긴다");
''')
PY

# ④ 보낼 때 글 답이 {text} 로 실린다 — 빈 채로 가면 셀렉터에서 1번이 확정된다.
PYTHONPATH="$SCR" python3 - <<'PY2'
from marina_mobile import render_mobile_html

html = render_mobile_html()
제출 = html[html.find("async function submitLiveAnswer"):][:900]
assert "{text: 글}" in 제출 or "text: 글" in 제출, f"글 답을 안 싣는다: {제출[:400]}"
기타 = html[html.find("function sendLiveOther"):][:2000]
assert "적어뒀어요" in 기타, f"기타 입력이 여전히 폼 전체를 보내려 한다: {기타[:400]}"
print("ok 제출 payload 에 글 답이 실린다")
PY2

echo "PASS test-answer-mixed-form"
