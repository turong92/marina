#!/usr/bin/env bash
# 새 메시지 점의 기준 = 마지막 assistant 메시지 시각(msgTs). 파일 수정 시각은 marina 재시작으로 대화 프로세스가
# 끝날 때도 바뀌어(종료 기록이 덧붙음) 아무 말 없이 점이 켜졌다(2026-09-28 실측: 17:06 말, 파일은 17:08).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, tempfile
from datetime import datetime, timezone
from pathlib import Path
import marina_sessions as ms
with tempfile.TemporaryDirectory() as d:
    p = Path(d) / "t.jsonl"
    rows = [
        {"type": "user", "timestamp": "2026-09-28T08:00:00.000Z", "message": {"content": "해줘"}},
        {"type": "assistant", "timestamp": "2026-09-28T08:06:05.000Z", "message": {"content": [{"type": "text", "text": "다 했어요"}]}},
        {"type": "system", "timestamp": "2026-09-28T08:08:30.000Z", "subtype": "exit"},   # 종료 때 덧붙는 기록
    ]
    p.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    preview, at = ms._jsonl_last_assistant(p)
    assert preview == "다 했어요", preview
    want = datetime(2026, 9, 28, 8, 6, 5, tzinfo=timezone.utc).timestamp()
    assert abs(at - want) < 1, (at, want)
    assert ms._jsonl_last_assistant_preview(p) == "다 했어요", "옛 호출부가 깨졌다"
    empty = Path(d) / "e.jsonl"; empty.write_text("", encoding="utf-8")
    assert ms._jsonl_last_assistant(empty) == ("", 0.0)
print("PASS test-last-message-ts")
PY

# 웹의 열어 둔 대화 탭 점(markChatUnread)도 같은 기준이어야 한다 — 리뷰 지적: 여기만 파일 시각을 봐서
# 재시작하면 뒤 탭에 가짜 점이 떴다.
node - "$HERE/../scripts/marina-web/app-11-chat.js" <<'NODE'
const fs = require("node:fs"), vm = require("node:vm"), assert = require("node:assert/strict");
const src = fs.readFileSync(process.argv[2], "utf8");
const at = src.indexOf("function markChatUnread()");
let depth = 0, end = src.indexOf("{", at);
for (let i = end; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) { end = i + 1; break; } }
const ctx = {chatTabs: [], worktreeData: [], chatActive: 0, chatPane: () => ({hidden: true}), renderChatPane() {},
  anyAgentUnseen: () => false, window: {MarinaChat: {setFaviconDot() {}}}};
vm.createContext(ctx);
vm.runInContext(src.slice(at, end) + "; this.markChatUnread = markChatUnread;", ctx);
ctx.chatTabs = [{root: "/r", source: "claude", sid: "a", title: "보는 탭"}, {root: "/r", source: "claude", sid: "b", title: "뒤 탭", seenTs: 100}];
ctx.worktreeData = [{root: "/r", agents: [{source: "claude", sid: "a", ts: 1}, {source: "claude", sid: "b", msgTs: 100, statusTs: 999, ts: 999}]}];
ctx.markChatUnread();
assert.equal(ctx.chatTabs[1].unread, undefined, "재시작으로 파일 시각만 바뀌었는데 뒤 탭에 점이 떴다");
ctx.worktreeData[0].agents[1].msgTs = 150;
ctx.markChatUnread();
assert.equal(ctx.chatTabs[1].unread, true, "새 말이 왔는데 뒤 탭에 점이 없다");
console.log("PASS test-last-message-ts (web tab)");
NODE
