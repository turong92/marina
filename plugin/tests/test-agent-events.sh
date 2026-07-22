#!/usr/bin/env bash
# Metadata-only lifecycle hook journal contract.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SCRIPTS" "$TMP" <<'PY'
import json
import stat
import sys
from multiprocessing import get_context
from pathlib import Path

scripts, tmp = map(Path, sys.argv[1:3])
sys.path.insert(0, str(scripts))
from marina_agent_events import MAX_ROWS, latest_agent_event, record_hook_event


def _concurrent_write(index, ready, release):
    ready.put(index)
    if not release.wait(15):
        raise RuntimeError("concurrent writer did not receive release signal")
    worker_root = tmp / "concurrent-roots" / f"worker-{index}"
    result = record_hook_event({
        "session_id": "concurrent-1",
        "cwd": str(worker_root),
        "transcript_path": str(tmp / ".claude/projects/root/concurrent-1.jsonl"),
        "hook_event_name": "UserPromptSubmit",
    }, home=home, now=3000 + index)
    if not result or result["ts"] != 3000 + index:
        raise RuntimeError(f"concurrent write {index} was not recorded: {result}")

root = tmp / "root"
root.mkdir()
home = tmp / "home"
claude_base = {
    "session_id": "claude-1",
    "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/claude-1.jsonl"),
}

assert record_hook_event({**claude_base, "hook_event_name": "UserPromptSubmit"}, home=home, now=1000)["event"] == "working"
assert record_hook_event({**claude_base, "hook_event_name": "Notification", "notification_type": "permission_prompt"}, home=home, now=1001)["event"] == "blocked"
assert record_hook_event({**claude_base, "hook_event_name": "Stop"}, home=home, now=1002)["event"] == "ended"
assert record_hook_event({**claude_base, "hook_event_name": "Notification", "notification_type": "auth_success"}, home=home, now=1003) is None

codex = record_hook_event({
    "thread_id": "codex-1",
    "cwd": str(root),
    "transcript_path": str(tmp / ".codex/sessions/2026/07/rollout-codex-1.jsonl"),
    "hook_event_name": "UserPromptSubmit",
}, home=home, now=1004)
assert codex and codex["source"] == "codex" and codex["sid"] == "codex-1", codex

# A transcript signal always beats ambiguous environment fallback signals.
mixed = record_hook_event({
    "session_id": "mixed-1", "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/mixed-1.jsonl"),
    "hook_event_name": "UserPromptSubmit",
}, environ={"CODEX_THREAD_ID": "codex-thread", "CODEX_HOME": "1", "CLAUDE_PLUGIN_ROOT": "/plugin"}, home=home, now=1005)
assert mixed and mixed["source"] == "claude", mixed

assert record_hook_event({"hook_event_name": "UserPromptSubmit"}, home=home, now=1006) is None
assert record_hook_event({**claude_base, "session_id": "../escape", "hook_event_name": "UserPromptSubmit"}, home=home, now=1006) is None

# Consecutive duplicates do not grow the journal.
duplicate = record_hook_event({**claude_base, "hook_event_name": "Stop"}, home=home, now=1007)
assert duplicate and duplicate["ts"] == 1002, duplicate

resumed_root = tmp / "resumed-root"
resumed_root.mkdir()
resumed = record_hook_event({
    **claude_base,
    "cwd": str(resumed_root),
    "hook_event_name": "Stop",
}, home=home, now=1008)
assert resumed and resumed["ts"] == 1008, resumed

events_root = home / ".marina" / "agent-events"
journal = events_root / "claude" / "claude-1.jsonl"
lock_file = events_root / "claude" / "claude-1.lock"
assert stat.S_IMODE(events_root.stat().st_mode) == 0o700
assert stat.S_IMODE((events_root / "claude").stat().st_mode) == 0o700
assert stat.S_IMODE(journal.stat().st_mode) == 0o600
assert stat.S_IMODE(lock_file.stat().st_mode) == 0o600

# The file is bounded to the newest 100 valid rows.
for index in range(110):
    event = "working" if index % 2 == 0 else "ended"
    payload = {**claude_base, "hook_event_name": "UserPromptSubmit" if event == "working" else "Stop"}
    result = record_hook_event(payload, home=home, now=1100 + index)
    assert result
rows = [json.loads(line) for line in journal.read_text(encoding="utf-8").splitlines()]
assert len(rows) == 100, len(rows)
assert rows[-1]["ts"] == 1209, rows[-1]

latest = latest_agent_event("claude", "claude-1", root, home=home, now=1210)
assert latest and latest["root"] == str(root.resolve()), latest
assert latest_agent_event("claude", "claude-1", tmp / "other", home=home, now=1210) is None

# Malformed blocked rows without a recognized reason are ignored.
journal.write_text(journal.read_text(encoding="utf-8") + json.dumps({
    "source": "claude", "sid": "claude-1", "root": str(root.resolve()),
    "event": "blocked", "reason": None, "ts": 1250,
}) + "\n", encoding="utf-8")
assert latest_agent_event("claude", "claude-1", root, home=home, now=1600)["ts"] == 1209

# A future event is retained as evidence but is never usable for status resolution.
journal.write_text(journal.read_text(encoding="utf-8") + json.dumps({
    "source": "claude", "sid": "claude-1", "root": str(root.resolve()),
    "event": "blocked", "reason": "permission_prompt", "ts": 2000,
}) + "\n", encoding="utf-8")
assert latest_agent_event("claude", "claude-1", root, home=home, now=1210)["ts"] == 1209

# Sidecar locking retains all valid writes from a synchronized process burst.
for index in range(MAX_ROWS):
    prefill = record_hook_event({
        "session_id": "concurrent-1",
        "cwd": str(tmp / "concurrent-roots" / f"prefill-{index}"),
        "transcript_path": str(tmp / ".claude/projects/root/concurrent-1.jsonl"),
        "hook_event_name": "UserPromptSubmit",
    }, home=home, now=2000 + index)
    assert prefill and prefill["ts"] == 2000 + index, prefill

workers = 12
context = get_context("fork")
ready = context.Queue()
release = context.Event()
processes = [context.Process(target=_concurrent_write, args=(index, ready, release)) for index in range(workers)]
for process in processes:
    process.start()
assert {ready.get(timeout=15) for _ in processes} == set(range(workers))
release.set()
for process in processes:
    process.join(15)
    assert process.exitcode == 0, process.exitcode

concurrent_journal = events_root / "claude" / "concurrent-1.jsonl"
concurrent_rows = [json.loads(line) for line in concurrent_journal.read_text(encoding="utf-8").splitlines()]
assert len(concurrent_rows) == MAX_ROWS, len(concurrent_rows)
assert {row["ts"] for row in concurrent_rows} == set(range(2012, 2100)) | set(range(3000, 3000 + workers))
print("ok hook journal")
PY

WRAPPER="$SCRIPTS/marina-agent-event-hook.sh"
printf '{not json}\n' | HOME="$TMP/wrapper-home" "$WRAPPER"
printf '%s\n' '{"session_id":"wrapper-1","cwd":"/tmp","transcript_path":"/tmp/.claude/x.jsonl","hook_event_name":"UserPromptSubmit"}' | HOME="$TMP/wrapper-home" "$WRAPPER"
test -f "$TMP/wrapper-home/.marina/agent-events/claude/wrapper-1.jsonl" || { echo "FAIL wrapper did not record valid input"; exit 1; }

echo "PASS test-agent-events"
