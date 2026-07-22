#!/usr/bin/env bash
# Metadata-only lifecycle hook journal contract.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SCRIPTS" "$TMP" <<'PY'
import json
import fcntl
import stat
import sys
import time
from multiprocessing import get_context
from pathlib import Path

scripts, tmp = map(Path, sys.argv[1:3])
sys.path.insert(0, str(scripts))
import marina_agent_events as events
from marina_agent_events import LOCK_ACQUIRE_TIMEOUT_SECONDS, MAX_JOURNAL_READ_BYTES, MAX_ROWS, latest_agent_event, record_hook_event


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


def _hold_lock(path, ready, duration):
    with open(path, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        ready.put(True)
        time.sleep(duration)

root = tmp / "root"
root.mkdir()
home = tmp / "home"
home.mkdir()
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

# A nullable Codex transcript still resolves from its host-specific plugin
# root, before the shared Claude compatibility variable/session fallback.
codex_null = record_hook_event({
    "session_id": "codex-null-1",
    "cwd": str(root),
    "transcript_path": None,
    "hook_event_name": "UserPromptSubmit",
}, environ={"PLUGIN_ROOT": "/codex-plugin", "CLAUDE_PLUGIN_ROOT": "/compat-plugin"}, home=home, now=1004.5)
assert codex_null and codex_null["source"] == "codex", codex_null
assert (home / ".marina" / "agent-events" / "codex" / "codex-null-1.jsonl").is_file()

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

# Rows must belong to this exact journal before they participate in duplicate
# suppression or bounded retention. A foreign final row must not swallow a
# real local event, and future-row poisoning must not evict that event.
journal.write_text(journal.read_text(encoding="utf-8") + json.dumps({
    "source": "codex", "sid": "other-session", "root": str(root.resolve()),
    "event": "working", "reason": None, "ts": 1211,
}) + "\n", encoding="utf-8")
real_after_foreign = record_hook_event(
    {**claude_base, "hook_event_name": "UserPromptSubmit"}, home=home, now=1212,
)
assert real_after_foreign and real_after_foreign["source"] == "claude" and real_after_foreign["ts"] == 1212
with journal.open("a", encoding="utf-8") as handle:
    for index in range(MAX_ROWS):
        handle.write(json.dumps({
            "source": "claude", "sid": "claude-1", "root": str(root.resolve()),
            "event": "ended", "reason": None, "ts": 10000 + index,
        }) + "\n")
real_after_poison = record_hook_event(
    {**claude_base, "hook_event_name": "Stop"}, home=home, now=1213,
)
assert real_after_poison and real_after_poison["ts"] == 1213, real_after_poison
assert latest_agent_event("claude", "claude-1", root, home=home, now=1214)["ts"] == 1213
rewritten = [json.loads(line) for line in journal.read_text(encoding="utf-8").splitlines()]
assert len(rewritten) <= MAX_ROWS
assert all(row["source"] == "claude" and row["sid"] == "claude-1" and row["ts"] <= 1513 for row in rewritten)

# Journal parsing is deliberately bounded: a corrupt prefix larger than the
# tail limit cannot make every dashboard poll read an arbitrary file.
tail_home = tmp / "tail-home"
tail_dir = tail_home / ".marina" / "agent-events" / "claude"
tail_dir.mkdir(parents=True, mode=0o700)
tail_journal = tail_dir / "tail-1.jsonl"
tail_row = {"source": "claude", "sid": "tail-1", "root": str(root.resolve()),
            "event": "working", "reason": None, "ts": 1300.25}
tail_journal.write_bytes((b"x" * (MAX_JOURNAL_READ_BYTES * 2)) + b"\n" + json.dumps(tail_row).encode() + b"\n")
assert latest_agent_event("claude", "tail-1", root, home=tail_home, now=1301) == tail_row

# One malformed UTF-8 line cannot poison a valid later JSONL row in the tail.
utf_home = tmp / "utf-home"
utf_dir = utf_home / ".marina" / "agent-events" / "claude"
utf_dir.mkdir(parents=True, mode=0o700)
utf_journal = utf_dir / "utf-1.jsonl"
utf_row = {"source": "claude", "sid": "utf-1", "root": str(root.resolve()),
           "event": "working", "reason": None, "ts": 1300.5}
utf_journal.write_bytes(b'{"bad":\xff}\n' + json.dumps(utf_row).encode() + b"\n")
assert latest_agent_event("claude", "utf-1", root, home=utf_home, now=1301) == utf_row

# A reader must not create a missing journal hierarchy merely to discover that
# no event exists.
missing_reader_home = tmp / "missing-reader-home"
missing_reader_home.mkdir()
assert latest_agent_event("claude", "missing-1", root, home=missing_reader_home, now=1301) is None
assert not (missing_reader_home / ".marina").exists()

# Refuse symlinked source directories and lock files without following or
# chmodding outside targets.
symlink_home = tmp / "symlink-home"
outside_dir = tmp / "outside-directory"
outside_dir.mkdir(mode=0o755)
source_parent = symlink_home / ".marina" / "agent-events"
source_parent.mkdir(parents=True, mode=0o700)
(source_parent / "claude").symlink_to(outside_dir, target_is_directory=True)
assert record_hook_event({**claude_base, "hook_event_name": "UserPromptSubmit"}, home=symlink_home, now=1400) is None
assert stat.S_IMODE(outside_dir.stat().st_mode) == 0o755 and not list(outside_dir.iterdir())

lock_home = tmp / "lock-home"
lock_dir = lock_home / ".marina" / "agent-events" / "claude"
lock_dir.mkdir(parents=True, mode=0o700)
outside_lock = tmp / "outside.lock"
outside_lock.write_text("do not touch", encoding="utf-8")
outside_lock.chmod(0o644)
(lock_dir / "claude-1.lock").symlink_to(outside_lock)
assert record_hook_event({**claude_base, "hook_event_name": "UserPromptSubmit"}, home=lock_home, now=1401) is None
assert outside_lock.read_text(encoding="utf-8") == "do not touch"
assert stat.S_IMODE(outside_lock.stat().st_mode) == 0o644

file_home = tmp / "file-home"
file_dir = file_home / ".marina" / "agent-events" / "claude"
file_dir.mkdir(parents=True, mode=0o700)
outside_journal = tmp / "outside.jsonl"
outside_journal.write_text("do not touch", encoding="utf-8")
(file_dir / "claude-1.jsonl").symlink_to(outside_journal)
assert record_hook_event({**claude_base, "hook_event_name": "UserPromptSubmit"}, home=file_home, now=1402) is None
assert outside_journal.read_text(encoding="utf-8") == "do not touch"

# Replace an already-opened journal ancestor during the real recorder path.
# Retained descriptor traversal must keep every following operation in the
# renamed directory, never in the symlink target now visible by pathname.
race_home = tmp / "race-home"
race_home.mkdir()
race_dir = race_home / ".marina"
race_dir.mkdir(mode=0o755)
race_outside = tmp / "race-outside"
race_outside.mkdir(mode=0o755)
race_parked = tmp / "race-parked"
real_open = events.os.open
swapped = False

def race_open(path, flags, mode=0o777, *, dir_fd=None):
    global swapped
    if path == "agent-events" and not swapped:
        race_dir.rename(race_parked)
        race_dir.symlink_to(race_outside, target_is_directory=True)
        swapped = True
    return real_open(path, flags, mode, dir_fd=dir_fd)

events.os.open = race_open
try:
    race_result = record_hook_event(
        {**claude_base, "hook_event_name": "UserPromptSubmit"}, home=race_home, now=1450,
    )
finally:
    events.os.open = real_open
assert swapped
assert stat.S_IMODE(race_outside.stat().st_mode) == 0o755
assert not list(race_outside.iterdir())
assert race_result and race_result["ts"] == 1450

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

# Synchronous hooks must fail open within their local lock deadline instead of
# stalling a turn until another recorder eventually releases the sidecar lock.
lock_bound = record_hook_event({
    "session_id": "lock-bound-1", "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/lock-bound-1.jsonl"),
    "hook_event_name": "UserPromptSubmit",
}, home=home, now=4000)
assert lock_bound
bound_lock_path = events_root / "claude" / "lock-bound-1.lock"
lock_ready = context.Queue()
holder = context.Process(target=_hold_lock, args=(bound_lock_path, lock_ready, 0.8))
holder.start()
assert lock_ready.get(timeout=15) is True
started = time.monotonic()
timed_out = record_hook_event({
    "session_id": "lock-bound-1", "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/lock-bound-1.jsonl"),
    "hook_event_name": "Stop",
}, home=home, now=4001)
elapsed = time.monotonic() - started
holder.join(15)
assert holder.exitcode == 0, holder.exitcode
assert timed_out is None
assert elapsed < LOCK_ACQUIRE_TIMEOUT_SECONDS + 0.2, elapsed
print("ok hook journal")
PY

python3 - "$HERE/../hooks/hooks.json" "$HERE/../hooks/codex-hooks.json" "$HERE/../.claude-plugin/plugin.json" "$HERE/../.codex-plugin/plugin.json" <<'PY'
import json
import sys

claude_hooks = json.load(open(sys.argv[1], encoding="utf-8"))["hooks"]
codex_hooks = json.load(open(sys.argv[2], encoding="utf-8"))["hooks"]
claude_manifest = json.load(open(sys.argv[3], encoding="utf-8"))
codex_manifest = json.load(open(sys.argv[4], encoding="utf-8"))

assert "Notification" in claude_hooks
assert "Notification" not in codex_hooks
assert set(codex_hooks) == {"SessionStart", "PreToolUse", "UserPromptSubmit", "Stop"}
assert codex_manifest["hooks"] == "./hooks/codex-hooks.json"
assert "hooks" not in claude_manifest

for name in ("UserPromptSubmit", "Notification", "Stop"):
    commands = claude_hooks[name][0]["hooks"]
    assert len(commands) == 1 and commands[0].get("async") is False, (name, commands)
    assert commands[0].get("timeout") == 2, (name, commands)
    assert "${CLAUDE_PLUGIN_ROOT}" in commands[0]["command"], (name, commands)

for name in ("UserPromptSubmit", "Stop"):
    commands = codex_hooks[name][0]["hooks"]
    assert len(commands) == 1 and commands[0].get("async") is False, (name, commands)
    assert commands[0].get("timeout") == 2, (name, commands)
    assert "${PLUGIN_ROOT}" in commands[0]["command"], (name, commands)

for name in ("SessionStart", "PreToolUse"):
    command = codex_hooks[name][0]["hooks"][0]["command"]
    assert "${PLUGIN_ROOT}" in command, (name, command)
print("ok host-specific synchronous lifecycle hook contract")
PY

WRAPPER="$SCRIPTS/marina-agent-event-hook.sh"
mkdir -p "$TMP/wrapper-home"
printf '{not json}\n' | HOME="$TMP/wrapper-home" "$WRAPPER"
printf '%s\n' '{"session_id":"wrapper-1","cwd":"/tmp","transcript_path":"/tmp/.claude/x.jsonl","hook_event_name":"UserPromptSubmit"}' | HOME="$TMP/wrapper-home" "$WRAPPER"
test -f "$TMP/wrapper-home/.marina/agent-events/claude/wrapper-1.jsonl" || { echo "FAIL wrapper did not record valid input"; exit 1; }

echo "PASS test-agent-events"
