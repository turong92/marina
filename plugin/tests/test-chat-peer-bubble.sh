#!/usr/bin/env bash
# 공유 렌더러 — 다른 Claude 세션이 보낸 메시지(role=peer)는 **형의 말풍선도, 에이전트 답도 아닌**
# '보낸 세션' 말풍선이다. 서버가 role=peer·from 을 주는데 렌더러가 모르면 assistant 로 떨어져, 남이
# 시킨 말이 에이전트가 한 말처럼 보인다. from 은 다른 세션이 정한 이름이라 믿을 수 없는 글자다.
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
assert.equal(typeof M.renderTimelineMessage, "function", "renderTimelineMessage 가 노출되지 않았다");

const html = M.renderTimelineMessage({id: "claude:peer:44:0", kind: "message", role: "peer",
                                      from: "chat-fe", text: "리뷰 부탁해 — **파일은 고치지 마**"});
assert.match(html, /class="turn peer/, `보낸 세션 말풍선이 아니다: ${html.slice(0, 160)}`);
assert.ok(!/class="turn (user|assistant)/.test(html), "형의 말풍선이나 에이전트 답으로 그렸다");
assert.match(html, /chat-fe/, "누가 보냈는지 안 보인다");
assert.match(html, /리뷰 부탁해/, "본문이 없다");

const 위험 = M.renderTimelineMessage({kind: "message", role: "peer",
                                     from: '<img src=x onerror=alert(1)>', text: "hi"});
assert.ok(!위험.includes("<img src=x"), "보낸 세션 이름이 마크업이 됐다 — 남의 세션이 정한 글자다");

// 기존 역할은 그대로.
assert.match(M.renderTimelineMessage({kind: "message", role: "user", text: "형"}), /class="turn user/);
assert.match(M.renderTimelineMessage({kind: "message", role: "assistant", text: "답"}), /class="turn assistant/);
console.log("PASS: role=peer 는 보낸 세션 말풍선, 이름은 이스케이프");
JS
