#!/usr/bin/env bash
# 흐름 줄·요약 카드(스펙 7.2). 역할 이름·모델·보류 문장은 남이 정한 글자라 이스케이프.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
node - "$SCR/marina-web/chat-render.js" <<'JS'
const fs = require("fs"), vm = require("vm"), assert = require("assert/strict");
const ctx = {window: {}, console}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), ctx);
const M = ctx.window.MarinaChat;
M.configure({displayModel: m => m === "claude-sonnet-5" ? "Sonnet 5" : m});
const R = it => M.renderTimelineMessage(it);
const req = R({kind: "chain", chainId: "c1", event: "request", role: "reviewer", model: "claude-sonnet-5", round: 1, maxRounds: 2});
assert.match(req, /class="chainLine"/); assert.match(req, /리뷰 요청 · reviewer\(Sonnet 5\)/); assert.match(req, /1\/2/);
assert.ok(!/class="turn /.test(req), "흐름 줄을 말풍선으로 그렸다");
assert.match(R({kind: "chain", event: "request", role: "reviewer", round: 2, maxRounds: 2}), /재리뷰/);
assert.match(R({kind: "chain", event: "request", role: "reviewer", round: 3, maxRounds: 2, unlimited: true}), /3\/∞/);
const end = R({kind: "chain", event: "end", reason: "clean", round: 2, applied: 2, held: ["[보류] 공용 모듈로"]});
assert.match(end, /class="chainDone"/); assert.match(end, /리뷰 끝 · 2바퀴 · 반영 2/); assert.match(end, /보류 1/); assert.match(end, /공용 모듈로/);
assert.match(R({kind: "chain", event: "end", reason: "stopped", round: 1, applied: 0, held: []}), /리뷰 멈춤/);
assert.match(R({kind: "chain", event: "end", reason: "max-rounds", round: 2, applied: 3, held: []}), /상한/);
const evil = R({kind: "chain", event: "end", reason: "clean", round: 1, applied: 0, held: ['<img src=x onerror=alert(1)>']})
  + R({kind: "chain", event: "request", role: '<script>x</script>', model: '"><b>', round: 1, maxRounds: 2});
assert.ok(!evil.includes("<img src=x") && !evil.includes("<script>") && !evil.includes('"><b>'), "이스케이프 누락");
console.log("PASS: 흐름 줄·요약 카드");
JS
python3 - "$SCR" <<'PY'
import sys
h = open(f"{sys.argv[1]}/marina_handler.py", encoding="utf-8").read()
seg = h[h.index('if parsed.path == "/mobile/api/transcript":'):][:2600]
assert "merge_chain_items(" in seg and "is_latest_page=before is None" in seg, "transcript 에 묶음 병합이 없다"
print("PASS: transcript 병합 배선")
PY
bash "$HERE/test-mobile-css-tokens.sh" >/dev/null && echo "PASS: CSS 토큰"
