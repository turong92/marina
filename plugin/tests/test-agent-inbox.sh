#!/usr/bin/env bash
# Claude/Codex native event normalization and shared desktop/mobile Agent Inbox contracts.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SCR" "$TMP" <<'PY'
import json
import os
import sys
from pathlib import Path

scr, tmp = sys.argv[1:3]
sys.path.insert(0, scr)
import marina_sessions as ms
from marina_agent_events import record_hook_event

tmp = Path(tmp)

def write(name, rows):
    path = tmp / name
    path.write_text("{truncated\n" + "\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
    return path

claude_working = write("claude-working.jsonl", [
    {"type": "user", "timestamp": "2026-07-20T09:00:00Z", "message": {"role": "user", "content": [{"type": "text", "text": "do it"}]}},
    {"type": "assistant", "timestamp": "2026-07-20T09:00:01Z", "message": {"role": "assistant", "stop_reason": "tool_use", "content": [{"type": "tool_use", "name": "Read"}]}},
])
claude_done = write("claude-done.jsonl", [
    {"type": "user", "timestamp": "2026-07-20T09:01:00Z", "message": {"role": "user", "content": [{"type": "text", "text": "done?"}]}},
    {"type": "assistant", "timestamp": "2026-07-20T09:01:02Z", "message": {"role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": "done"}]}},
])
claude_failed = write("claude-failed.jsonl", [
    {"type": "user", "timestamp": "2026-07-20T09:02:00Z", "message": {"role": "user", "content": [{"type": "text", "text": "retry"}]}},
    {"type": "system", "subtype": "api_error", "timestamp": "2026-07-20T09:02:03Z", "error": "Bearer secret-value"},
])

codex_working = write("codex-working.jsonl", [
    {"timestamp": "2026-07-20T09:03:00Z", "type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-1"}},
    {"timestamp": "2026-07-20T09:03:02Z", "type": "event_msg", "payload": {"type": "agent_reasoning", "text": "hidden"}},
])
codex_done = write("codex-done.jsonl", [
    {"timestamp": "2026-07-20T09:04:00Z", "type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-2"}},
    {"timestamp": "2026-07-20T09:04:05Z", "type": "event_msg", "payload": {"type": "task_complete", "turn_id": "turn-2", "last_agent_message": "done"}},
])
codex_failed = write("codex-failed.jsonl", [
    {"timestamp": "2026-07-20T09:05:00Z", "type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-3"}},
    {"timestamp": "2026-07-20T09:05:04Z", "type": "event_msg", "payload": {"type": "turn_aborted", "turn_id": "turn-3", "reason": "interrupted"}},
])

assert ms.agent_status(claude_working, "claude")["status"] == "working"
assert ms.agent_status(claude_done, "claude", terminal_active=True)["status"] == "waiting"
assert ms.agent_status(claude_done, "claude", terminal_active=False)["status"] == "completed"
claude_error = ms.agent_status(claude_failed, "claude")
assert claude_error["status"] == "failed" and claude_error.get("statusReason") == "api_error", claude_error
assert ms.agent_status(codex_working, "codex")["status"] == "working"
assert ms.agent_status(codex_done, "codex", terminal_active=True)["status"] == "waiting"
assert ms.agent_status(codex_done, "codex", terminal_active=False)["status"] == "completed"
failed = ms.agent_status(codex_failed, "codex")
assert failed["status"] == "failed" and failed.get("statusReason") == "interrupted", failed
assert ms.agent_status(tmp / "missing.jsonl", "claude")["status"] == "idle"

# Native lifecycle rows are selected by their greatest valid timestamp, rather
# than append order. Equal timestamps retain the later append as the tiebreak.
codex_out_of_order = write("codex-out-of-order.jsonl", [
    {"timestamp": 1000, "type": "event_msg", "payload": {"type": "task_complete"}},
    {"timestamp": 999, "type": "event_msg", "payload": {"type": "task_started"}},
    {"timestamp": 1000, "type": "event_msg", "payload": {"type": "task_started"}},
])
assert ms.agent_status(codex_out_of_order, "codex", now=1000) == {"status": "working", "statusTs": 1000}
claude_out_of_order = write("claude-out-of-order.jsonl", [
    {"type": "assistant", "timestamp": 1000, "message": {"stop_reason": "end_turn"}},
    {"type": "user", "timestamp": 999, "message": {}},
])
assert ms.agent_status(claude_out_of_order, "claude", now=1000) == {"status": "completed", "statusTs": 1000}

# Future native rows and a future file mtime cannot manufacture recent work.
codex_future_native = write("codex-future-native.jsonl", [
    {"timestamp": 1401, "type": "event_msg", "payload": {"type": "task_started"}},
])
os.utime(codex_future_native, (1401, 1401))
assert ms.agent_status(codex_future_native, "codex", now=1000) == {"status": "idle", "statusTs": 0}

# Native transcript parsing remains the fallback, but an explicit lifecycle event at
# the same or newer timestamp is authoritative for this root/session only.
events = tmp / "events-home"
events.mkdir()
claude_done_ts = 1784538062
record_hook_event({
    "hook_event_name": "Notification", "notification_type": "permission_prompt",
    "session_id": "claude-1", "cwd": str(tmp),
    "transcript_path": str(tmp / ".claude" / "projects" / "root" / "claude-1.jsonl"),
}, home=events, now=claude_done_ts + 10)
blocked = ms.agent_status(
    claude_done, "claude", sid="claude-1", root=tmp,
    event_home=events, now=claude_done_ts + 11,
)
assert blocked == {"status": "blocked", "statusTs": claude_done_ts + 10,
                   "statusReason": "permission_prompt"}, blocked

record_hook_event({
    "hook_event_name": "UserPromptSubmit", "session_id": "claude-1", "cwd": str(tmp),
    "transcript_path": str(tmp / ".claude" / "projects" / "root" / "claude-1.jsonl"),
}, home=events, now=claude_done_ts + 20)
working = ms.agent_status(
    claude_done, "claude", sid="claude-1", root=tmp,
    event_home=events, now=claude_done_ts + 21,
)
assert working == {"status": "working", "statusTs": claude_done_ts + 20}, working

record_hook_event({
    "hook_event_name": "Stop", "thread_id": "codex-1", "cwd": str(tmp),
    "transcript_path": str(tmp / ".codex" / "sessions" / "rollout.jsonl"),
}, home=events, now=1784538000)
older = ms.agent_status(
    codex_done, "codex", sid="codex-1", root=tmp,
    event_home=events, now=1784538200,
)
assert older == {"status": "completed", "statusTs": 1784538245}, older

record_hook_event({
    "hook_event_name": "Notification", "notification_type": "idle_prompt",
    "thread_id": "codex-equal", "cwd": str(tmp),
    "transcript_path": str(tmp / ".codex" / "sessions" / "rollout.jsonl"),
}, home=events, now=1784538245)
equal = ms.agent_status(
    codex_done, "codex", sid="codex-equal", root=tmp,
    event_home=events, now=1784538250,
)
assert equal == {"status": "blocked", "statusTs": 1784538245,
                 "statusReason": "idle_prompt"}, equal

record_hook_event({
    "hook_event_name": "UserPromptSubmit", "thread_id": "codex-future", "cwd": str(tmp),
    "transcript_path": str(tmp / ".codex" / "sessions" / "rollout.jsonl"),
}, home=events, now=1784538600)
future = ms.agent_status(
    codex_done, "codex", sid="codex-future", root=tmp,
    event_home=events, now=1784538250,
)
assert future == {"status": "completed", "statusTs": 1784538245}, future

# `latest_agent_event` owns supplied-now future validation. Once it returns an
# event, changing the process wall clock must not alter this result.
deterministic_event_ts = 2000000100
record_hook_event({
    "hook_event_name": "Notification", "notification_type": "permission_prompt",
    "session_id": "claude-deterministic", "cwd": str(tmp),
    "transcript_path": str(tmp / ".claude" / "projects" / "root" / "claude-deterministic.jsonl"),
}, home=events, now=deterministic_event_ts)
real_time = ms.time.time
ms.time.time = lambda: 0
try:
    deterministic = ms.agent_status(
        claude_done, "claude", sid="claude-deterministic", root=tmp,
        event_home=events, now=deterministic_event_ts + 1,
    )
finally:
    ms.time.time = real_time
assert deterministic == {"status": "blocked", "statusTs": deterministic_event_ts,
                         "statusReason": "permission_prompt"}, deterministic

fractional = ms.merge_agent_status(
    {"status": "completed", "statusTs": claude_done_ts},
    {"event": "working", "ts": claude_done_ts + 0.25},
)
assert fractional == {"status": "working", "statusTs": claude_done_ts + 0.25}, fractional

waiting = ms.merge_agent_status(
    {"status": "completed", "statusTs": claude_done_ts},
    {"event": "ended", "ts": claude_done_ts + 1},
    True,
)
assert waiting == {"status": "waiting", "statusTs": claude_done_ts + 1}, waiting
assert ms.merge_agent_status(
    {"status": "failed", "statusTs": claude_done_ts + 2},
    {"event": "ended", "ts": claude_done_ts + 1},
    True,
)["status"] == "failed"
assert ms.merge_agent_status(
    {"status": "blocked", "statusTs": claude_done_ts}, None, True,
)["status"] == "blocked"
print("ok journal/native status precedence")
print("ok native agent status normalization")
PY

INDEX="$SCR/marina-web/index.html"
CORE="$SCR/marina-web/app-1-core.js"
SESSIONS="$SCR/marina-web/app-5-sessions.js"
MOBILE="$SCR/marina_mobile.py"

grep -q 'id="agentInboxBtn"' "$INDEX" || { echo "FAIL desktop inbox button missing"; exit 1; }
grep -q 'id="agentInboxPanel"' "$INDEX" || { echo "FAIL desktop inbox panel missing"; exit 1; }
grep -q 'marinaAgentInboxRead' "$CORE" || { echo "FAIL desktop inbox read-state key missing"; exit 1; }
grep -q 'function agentInboxEntries' "$CORE" || { echo "FAIL desktop inbox derivation missing"; exit 1; }
grep -q 'openAgentTerminal' "$CORE" || { echo "FAIL desktop inbox does not reuse agent terminal"; exit 1; }
grep -q 'agent.status' "$SESSIONS" || { echo "FAIL agent rows do not use normalized status"; exit 1; }

grep -q 'id="inboxMenuBtn"' "$MOBILE" || { echo "FAIL mobile inbox menu entry missing"; exit 1; }
grep -q 'id="inboxSheet"' "$MOBILE" || { echo "FAIL mobile inbox sheet missing"; exit 1; }
grep -q 'function openInbox' "$MOBILE" || { echo "FAIL mobile inbox open flow missing"; exit 1; }
grep -q 'chooseSession' "$MOBILE" || { echo "FAIL mobile inbox does not reuse chat selection"; exit 1; }

node - "$CORE" "$SESSIONS" <<'JS'
const fs = require('fs');
const vm = require('vm');
const [corePath, sessionsPath] = process.argv.slice(2);
const coreSource = fs.readFileSync(corePath, 'utf8');
const sessionsSource = fs.readFileSync(sessionsPath, 'utf8');
const start = coreSource.indexOf('const AGENT_STATUS_META = {');
const end = coreSource.indexOf("document.getElementById('agentInboxBtn').onclick");
if (start < 0 || end < 0) throw new Error('desktop inbox source boundaries missing');
const context = {
  localStorage: {getItem: () => null, setItem: () => {}},
  worktreeData: [{
    root: '/tmp/marina-project', projectId: 'project', projectLabel: 'Project',
    agents: [
      {source: 'claude', sid: 'claude-blocked', status: 'blocked', statusTs: 200, title: 'Needs approval'},
      {source: 'codex', sid: 'codex-working', status: 'working', statusTs: 100, title: 'Still working'},
    ],
  }],
  escapeHtml: value => String(value),
  relTime: value => `${value}s`,
  openAgentTerminal: () => {},
};
vm.createContext(context);
vm.runInContext(`${coreSource.slice(start, end)}\nthis.__meta = AGENT_STATUS_META;`, context, {filename: corePath});
vm.runInContext(sessionsSource, context, {filename: sessionsPath});
const meta = context.__meta.blocked;
if (!meta || meta.label !== '응답 필요' || meta.title !== '권한 승인 또는 사용자 입력이 필요함') {
  throw new Error(`blocked metadata mismatch: ${JSON.stringify(meta)}`);
}
const entries = context.agentInboxEntries();
if (entries.length !== 1 || entries[0].sid !== 'claude-blocked') {
  throw new Error(`blocked Inbox membership mismatch: ${JSON.stringify(entries)}`);
}
const summary = context.agentsSummary(context.worktreeData[0].agents);
if (!summary.includes('▤ 1')) throw new Error(`blocked attention count missing: ${summary}`);
console.log('ok desktop blocked inbox membership and attention count');
JS

PYTHONPATH="$SCR" python3 - <<'PY' | node
import json
from marina_mobile import render_mobile_html

html = render_mobile_html()
start = html.rfind("<script>")
end = html.rfind("</script>")
if start < 0 or end < 0 or end <= start:
    raise SystemExit("mobile script boundaries missing")
print("const mobileSource = " + json.dumps(html[start + len("<script>"):end]) + ";")
print(r'''
const assert = require("node:assert/strict");
const vm = require("node:vm");

class FakeClassList {
  constructor() { this.values = new Set(); }
  add(...values) { values.forEach(value => this.values.add(value)); }
  remove(...values) { values.forEach(value => this.values.delete(value)); }
  toggle(value, force) {
    const next = force === undefined ? !this.values.has(value) : Boolean(force);
    if (next) this.values.add(value); else this.values.delete(value);
    return next;
  }
  contains(value) { return this.values.has(value); }
}

class FakeElement {
  constructor() {
    this.classList = new FakeClassList();
    this.style = {};
    this.attributes = {};
    this.innerHTML = "";
    this.textContent = "";
    this.value = "";
    this.scrollHeight = 0;
    this.scrollTop = 0;
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  querySelectorAll() { return []; }
  querySelector() { return null; }
  contains() { return true; }
}

const ids = [
  "mobileLogin", "mobileApp", "loginStatus", "listView", "chatView", "chatComposer",
  "backBtn", "menuBtn", "menuPanel", "chatTitle", "chatSubtitle", "rootSelect",
  "targetSelect", "prompt", "sessionSearch", "sessionList", "projectTabs", "sourceTabs",
  "turns", "olderMessagesBtn", "suggestions", "newMessagesBtn", "retryBtn", "sendBtn",
  "subagentMenuBtn", "subagentCount", "subagentSheet", "subagentList", "inboxMenuBtn",
  "inboxCount", "inboxSheet", "inboxList", "status", "loginForm", "tokenInput",
  "refreshBtn", "logoutBtn", "notifyBtn", "inboxCloseBtn", "subagentCloseBtn",
];
const elements = Object.fromEntries(ids.map(id => [id, new FakeElement()]));
const storage = new Map([
  ["marinaAgentInboxRead", JSON.stringify(["claude:blocked:blocked:300"])],
]);
const location = {href: "https://mobile.example.test/mobile", pathname: "/mobile", replaceCalls: []};
const document = {
  cookie: "",
  visibilityState: "visible",
  activeElement: null,
  documentElement: {scrollHeight: 0},
  getElementById(id) { return elements[id] || (elements[id] = new FakeElement()); },
  addEventListener() {},
};
const window = {
  innerHeight: 800,
  scrollY: 0,
  addEventListener() {},
  scrollTo() {},
};
location.replace = value => location.replaceCalls.push(value);
const context = {
  console,
  document,
  window,
  location,
  history: {replaceState() {}},
  localStorage: {
    getItem: key => storage.has(key) ? storage.get(key) : null,
    setItem: (key, value) => storage.set(key, String(value)),
    removeItem: key => storage.delete(key),
    keys: () => [...storage.keys()],
  },
  navigator: {},
  URL,
  setInterval() {},
  setTimeout,
  clearTimeout,
  requestAnimationFrame: callback => callback(),
  fetch: async () => { throw new Error("unexpected fetch"); },
};
vm.createContext(context);
vm.runInContext(`${mobileSource}
let chooseSessionCalls = [];
chooseSession = key => chooseSessionCalls.push(key);
this.mobileTest = {
  setState: value => { state = value; },
  inboxSessions,
  openInbox,
  inboxList,
  inboxCount,
  inboxSheet,
  chooseSessionCalls,
};`, context, {filename: "marina_mobile.py::_MOBILE_HTML"});

const root = "/tmp/marina-project";
const blocked = {
  key: `agent:claude:blocked:${root}`, kind: "agent", source: "claude", sid: "blocked",
  status: "blocked", statusTs: 300, title: "Needs approval", preview: "Approve access", root,
};
const waiting = {
  key: `agent:claude:waiting:${root}`, kind: "agent", source: "claude", sid: "waiting",
  status: "waiting", statusTs: 250, title: "Waiting", preview: "Ready for input", root,
};
const completed = {
  key: `agent:codex:completed:${root}`, kind: "agent", source: "codex", sid: "completed",
  status: "completed", statusTs: 200, title: "Finished", preview: "Done", root,
};
const working = {
  key: `agent:codex:working:${root}`, kind: "agent", source: "codex", sid: "working",
  status: "working", statusTs: 400, title: "Still working", preview: "In progress", root,
};
context.mobileTest.setState({
  worktrees: [{root, projectId: "project", projectLabel: "Project"}],
  sessions: [working, completed, blocked, waiting],
});

const items = context.mobileTest.inboxSessions();
assert.equal(JSON.stringify(items.map(item => item.status)), JSON.stringify(["blocked", "waiting", "completed"]));
assert.equal(items.some(item => item.sid === "working"), false);
assert.ok(items.some(item => item.sid === "blocked"));
assert.ok(items.every((item, index) => index === 0 || item.statusTs <= items[index - 1].statusTs));

context.mobileTest.openInbox();
const blockedEventId = "claude:blocked:blocked:300";
const rendered = context.mobileTest.inboxList.innerHTML;
const blockedMarkup = rendered.match(new RegExp(`class="inboxItem [^"]*"[^>]*data-inbox-id="${blockedEventId}"[\\s\\S]*?</button>`));
assert.ok(blockedMarkup, `blocked Inbox item missing: ${rendered}`);
assert.match(blockedMarkup[0], /class="inboxItem read"/);
const label = blockedMarkup[0].match(/<span class="inboxState">([^<]+)<\/span>/);
assert.ok(label, blockedMarkup[0]);
assert.equal(label[1].split(" · ", 1)[0], "응답 필요");

context.mobileTest.inboxList.onclick({
  target: {closest: () => ({getAttribute: () => blockedEventId})},
});
assert.equal(JSON.stringify(context.mobileTest.chooseSessionCalls), JSON.stringify([blocked.key]));
assert.equal(context.mobileTest.inboxSheet.classList.contains("open"), false);
assert.deepEqual(JSON.parse(storage.get("marinaAgentInboxRead")), [blockedEventId]);
assert.deepEqual(location.replaceCalls, []);
assert.equal(location.href, "https://mobile.example.test/mobile");
console.log("ok mobile blocked Inbox behavior");
''')
PY

echo "PASS test-agent-inbox"
