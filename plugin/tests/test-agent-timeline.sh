#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SCR" "$TMP" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

scr, tmp = sys.argv[1:3]
claude_projects = Path(tmp) / "claude-projects"
codex_home = Path(tmp) / "codex"
os.environ["CLAUDE_PROJECTS_DIR"] = str(claude_projects)
os.environ["CODEX_HOME"] = str(codex_home)
sys.path.insert(0, scr)
import marina_sessions as ms

root = Path(tmp) / "worktree"
root.mkdir()

def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

codex_sid = "codex-timeline-0001"
(codex_home / "session_index.jsonl").parent.mkdir(parents=True, exist_ok=True)
(codex_home / "session_index.jsonl").write_text(
    json.dumps({"id": codex_sid, "thread_name": "Timeline"}) + "\n", encoding="utf-8"
)
codex_path = codex_home / "sessions" / f"rollout-{codex_sid}.jsonl"
write_jsonl(codex_path, [
    {"type": "session_meta", "payload": {"cwd": str(root), "id": codex_sid}},
    {"type": "turn_context", "payload": {"model": "gpt-5.6-sol", "effort": "high"}},
    {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": "Inspect it"},
    ]}},
    {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec", "call_id": "call-skill", "input":
        json.dumps({"cmd": "cat /repo/.agents/skills/audit/SKILL.md"})}},
    {"type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call-skill", "output": "loaded"}},
    {"type": "response_item", "payload": {"type": "function_call", "name": "apply_patch", "call_id": "call-patch", "arguments":
        json.dumps({"patch": "*** Begin Patch\n+ghp_abcdefghijklmnopqrstuvwxyz012345\n*** End Patch"})}},
    {"type": "response_item", "payload": {"type": "function_call_output", "call_id": "call-patch", "output": "Done!"}},
    {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec", "call_id": "call-nested-patch", "input":
        "const patch = '*** Update File: /repo/web.js'; await tools.apply_patch(patch);"}},
    {"type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call-nested-patch", "output": "Done!"}},
    {"type": "response_item", "payload": {"type": "function_call", "name": "spawn_agent", "call_id": "call-agent", "arguments":
        json.dumps({"message": "Review the change"})}},
    {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [
        {"type": "output_text", "text": "Finished"},
    ]}},
    {"type": "event_msg", "payload": {"type": "thread_settings_applied", "thread_settings": {
        "model": "gpt-5.6-luna", "reasoning_effort": "max",
    }}},
])

codex = ms.agent_transcript(root, "codex", codex_sid)
assert [turn["text"] for turn in codex["turns"]] == ["Inspect it", "Finished"], codex
assert [item["kind"] for item in codex["timeline"]] == [
    "message", "activity", "activity", "activity", "activity", "message",
], codex["timeline"]
codex_activities = [item for item in codex["timeline"] if item["kind"] == "activity"]
assert [item["activityType"] for item in codex_activities] == ["skill", "diff", "diff", "agent"], codex_activities
assert [item["status"] for item in codex_activities] == ["completed", "completed", "completed", "running"], codex_activities
assert all(item.get("model") == "gpt-5.6-sol" and item.get("effort") == "high" for item in codex["timeline"]), codex["timeline"]
assert "[redacted]" in codex_activities[1]["detail"], codex_activities[1]
assert "ghp_" not in codex_activities[1]["detail"], codex_activities[1]
assert codex_activities[2]["label"] == "/repo/web.js", codex_activities[2]
assert ms.agent_runtime_settings(root, "codex", codex_sid) == {
    "model": "gpt-5.6-luna", "effort": "max",
}

claude_sid = "claude-timeline-0001"
claude_path = claude_projects / re.sub(r"[/.]", "-", str(root)) / f"{claude_sid}.jsonl"
write_jsonl(claude_path, [
    {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "Deploy it"}]}},
    {"type": "assistant", "message": {"role": "assistant", "model": "claude-fable-5", "effort": "high", "content": [
        {"type": "thinking", "thinking": "private"},
        {"type": "tool_use", "id": "tool-skill", "name": "Skill", "input": {"skill": "deploy"}},
        {"type": "tool_use", "id": "tool-bash", "name": "Bash", "input": {"command": "git status --short"}},
        {"type": "tool_use", "id": "tool-edit", "name": "Edit", "input": {
            "file_path": "/repo/app.py", "old_string": "old", "new_string": "new",
        }},
    ]}},
    {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "tool-skill", "content": "Loaded deploy"},
        {"type": "tool_result", "tool_use_id": "tool-bash", "content": "ghp_abcdefghijklmnopqrstuvwxyz012345", "is_error": True},
        {"type": "tool_result", "tool_use_id": "tool-edit", "content": "Updated"},
    ]}},
    {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Deployed"}]}},
])

claude = ms.agent_transcript(root, "claude", claude_sid)
assert [turn["text"] for turn in claude["turns"]] == ["Deploy it", "Deployed"], claude
claude_activities = [item for item in claude["timeline"] if item["kind"] == "activity"]
assert [item["activityType"] for item in claude_activities] == ["skill", "command", "diff"], claude_activities
assert [item["status"] for item in claude_activities] == ["completed", "failed", "completed"], claude_activities
assert claude_activities[0]["label"] == "deploy", claude_activities[0]
assert claude_activities[1]["result"] == "[redacted]", claude_activities[1]
assert all(item.get("model") == "claude-fable-5" and item.get("effort") == "high" for item in claude_activities), claude_activities
assert next(item for item in claude["timeline"] if item.get("role") == "assistant")["model"] == "claude-fable-5"

ids = [item["id"] for item in codex["timeline"] + claude["timeline"]]
assert len(ids) == len(set(ids)), ids
print("ok native agent timeline")
PY

echo "PASS test-agent-timeline"
