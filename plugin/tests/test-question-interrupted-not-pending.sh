#!/usr/bin/env bash
# 끊긴(interrupted) 질문은 **다시 답할 질문으로 되살아나면 안 된다.**
#
# 형 2026-09-10(ovation 인수인계 세션): 4문항 질문에 폰에서 답하고 보내기를 눌렀더니 카드가
# "보내기 (0/4)"로 되돌아가 한참 떠 있었다. 실측(homeserver-76 트랜스크립트):
#   17:42:19 마리나 "PTY 없음 → 세션 이어받아 글로 전달" · 17:42:20 원래 질문 tool_result =
#   "[Request interrupted by user for tool use]" · 17:42:22 형의 4개 답이 사용자 메시지로 도착(3초).
# 배달은 빨랐다. 문제는 카드다. 끊긴 질문은 타임라인에서 status='failed' 인데 pendingQuestionActivity 는
# 'completed' 만 빼서 여전히 열린 질문으로 봤다. 서버가 대기 질문 파일을 지우면 라이브 카드가 내려가고,
# 대화 안 폴백 카드가 **다른 토큰**(activity:…)으로 상태를 새로 잡아 선택이 0 으로 리셋된 채 답할 수 있게
# 떴다 — 이미 답한 질문을. 같은 렌더러의 답한-카드 코드는 failed 를 이미 '끝남'으로 본다(규칙 불일치).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

node - "$SCR/marina-web/chat-render.js" <<'JS'
const fs = require("node:fs"), vm = require("node:vm"), assert = require("node:assert/strict");
const ctx = {window: {}, console};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), ctx, {filename: "chat-render.js"});
const M = ctx.window.MarinaChat;
assert.equal(typeof M.pendingQuestionActivity, "function");

const 질문들 = [1, 2, 3, 4].map(n => ({question: `질문 ${n}`, header: `Q${n}`,
  options: [{label: "추천안 (Recommended)"}, {label: "다른 안"}]}));
const 질문 = (id, status) => ({id: `claude:question:${id}`, kind: "question", name: "AskUserQuestion",
  status, questions: 질문들, input: {questions: 질문들}});
const 열린것 = sections => M.pendingQuestionActivity(sections);

// 실측 그대로: 끊긴 4문항 질문(status=failed) — 열린 질문이 아니다.
const 끊김 = 질문("toolu_01YDmQkyiv7WTPKabWmACdTy", "failed");
assert.equal(열린것({questions: [끊김], activities: []}), undefined,
  "끊긴(interrupted) 질문이 다시 답할 질문으로 잡힌다 — 폰에 '보내기 (0/4)' 빈 카드가 되살아난다");

// 아직 기다리는 질문(running)은 그대로 열린 질문.
const 대기 = 질문("toolu_live", "running");
assert.equal(열린것({questions: [대기], activities: []}), 대기, "기다리는 질문을 놓쳤다");

// 답한 질문(completed)은 종전대로 열린 질문이 아니다.
assert.equal(열린것({questions: [질문("toolu_done", "completed")], activities: []}), undefined);

// 끊긴 것과 기다리는 것이 같이 있으면 기다리는 것을 고른다.
assert.equal(열린것({questions: [끊김], activities: [대기]}), 대기, "끊긴 질문이 기다리는 질문을 가렸다");

console.log("PASS: 끊긴 질문은 되살아나지 않고, 기다리는 질문만 열린 질문이다");
JS
