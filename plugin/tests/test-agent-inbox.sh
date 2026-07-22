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

# Native transcript parsing remains the fallback, but an explicit lifecycle event at
# the same or newer timestamp is authoritative for this root/session only.
events = tmp / "events-home"
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

echo "PASS test-agent-inbox"
