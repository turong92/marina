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
