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
import os
import stat
import subprocess
import sys
import time
from multiprocessing import get_context
from pathlib import Path

scripts, tmp = map(Path, sys.argv[1:3])
sys.path.insert(0, str(scripts))
import marina_agent_events as events
from marina_agent_events import LOCK_ACQUIRE_TIMEOUT_SECONDS, MAX_JOURNAL_READ_BYTES, MAX_ROWS, latest_agent_event, record_hook_event

context = get_context("fork")


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


def _read_latest_in_worker(home_path, root_path, sid, ready):
    ready.put(latest_agent_event("claude", sid, root_path, home=home_path, now=1500))


def _record_in_worker(payload, home_path, ready):
    ready.put(record_hook_event(payload, home=home_path, now=1501))

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
codex_null_base = {
    "session_id": "codex-null-1",
    "cwd": str(root),
    "transcript_path": None,
}
codex_null = record_hook_event({
    **codex_null_base,
    "hook_event_name": "PermissionRequest",
}, environ={"PLUGIN_ROOT": "/codex-plugin", "CLAUDE_PLUGIN_ROOT": "/compat-plugin"}, home=home, now=1004.5)
assert codex_null and codex_null["source"] == "codex" and codex_null["event"] == "blocked", codex_null
assert (home / ".marina" / "agent-events" / "codex" / "codex-null-1.jsonl").is_file()

# Codex-only lifecycle names must fail closed when a Claude payload uses them.
assert record_hook_event({**claude_base, "hook_event_name": "PermissionRequest"}, home=home, now=1004.6) is None
assert record_hook_event({**claude_base, "hook_event_name": "PostToolUse"}, home=home, now=1004.7) is None

# A Codex tool completion clears only the approval blocker that immediately
# precedes it. The new working row must carry the later completion timestamp.
codex_post_tool = record_hook_event({
    **codex_null_base,
    "hook_event_name": "PostToolUse",
}, environ={"PLUGIN_ROOT": "/codex-plugin", "CLAUDE_PLUGIN_ROOT": "/compat-plugin"}, home=home, now=1004.75)
assert codex_post_tool and codex_post_tool["source"] == "codex" and codex_post_tool["event"] == "working", codex_post_tool
assert codex_post_tool["ts"] == 1004.75 > codex_null["ts"], codex_post_tool
codex_null_journal = home / ".marina" / "agent-events" / "codex" / "codex-null-1.jsonl"
assert [json.loads(line) for line in codex_null_journal.read_text(encoding="utf-8").splitlines()][-1] == codex_post_tool

# PostToolUse is deliberately a no-op without a journal or after normal work:
# it must not create, append, or replace a journal just to repeat working.
codex_post_without_journal = {
    "session_id": "codex-no-journal-1", "cwd": str(root), "transcript_path": None,
    "hook_event_name": "PostToolUse",
}
assert record_hook_event(
    codex_post_without_journal,
    environ={"PLUGIN_ROOT": "/codex-plugin"}, home=home, now=1004.8,
) is None
assert not (home / ".marina" / "agent-events" / "codex" / "codex-no-journal-1.jsonl").exists()

codex_working_base = {
    "session_id": "codex-working-1", "cwd": str(root), "transcript_path": None,
}
ordinary_working = record_hook_event(
    {**codex_working_base, "hook_event_name": "UserPromptSubmit"},
    environ={"PLUGIN_ROOT": "/codex-plugin"}, home=home, now=1004.85,
)
assert ordinary_working and ordinary_working["event"] == "working", ordinary_working
ordinary_working_journal = home / ".marina" / "agent-events" / "codex" / "codex-working-1.jsonl"
ordinary_working_bytes = ordinary_working_journal.read_bytes()
ordinary_working_stat = ordinary_working_journal.stat()
assert record_hook_event(
    {**codex_working_base, "hook_event_name": "PostToolUse"},
    environ={"PLUGIN_ROOT": "/codex-plugin"}, home=home, now=1004.9,
) is None
ordinary_working_after = ordinary_working_journal.stat()
assert ordinary_working_journal.read_bytes() == ordinary_working_bytes
assert (ordinary_working_after.st_dev, ordinary_working_after.st_ino, ordinary_working_after.st_mtime_ns) == (
    ordinary_working_stat.st_dev, ordinary_working_stat.st_ino, ordinary_working_stat.st_mtime_ns,
)

# A transcript signal always beats ambiguous environment fallback signals.
mixed = record_hook_event({
    "session_id": "mixed-1", "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/mixed-1.jsonl"),
    "hook_event_name": "UserPromptSubmit",
}, environ={"CODEX_THREAD_ID": "codex-thread", "CODEX_HOME": "1", "CLAUDE_PLUGIN_ROOT": "/plugin"}, home=home, now=1005)
assert mixed and mixed["source"] == "claude", mixed

assert record_hook_event({"hook_event_name": "UserPromptSubmit"}, home=home, now=1006) is None
assert record_hook_event({**claude_base, "session_id": "../escape", "hook_event_name": "UserPromptSubmit"}, home=home, now=1006) is None

# Consecutive duplicates are coalesced into the current canonical row rather
# than preserving a timestamp that stale native activity could later beat.
duplicate = record_hook_event({**claude_base, "hook_event_name": "Stop"}, home=home, now=1007)
assert duplicate and duplicate["ts"] == 1007, duplicate

coalesced_base = {
    "session_id": "coalesced-1", "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/coalesced-1.jsonl"),
}
first_blocked = record_hook_event({
    **coalesced_base, "hook_event_name": "Notification", "notification_type": "permission_prompt",
}, home=home, now=1010)
second_blocked = record_hook_event({
    **coalesced_base, "hook_event_name": "Notification", "notification_type": "permission_prompt",
}, home=home, now=1011)
first_ended = record_hook_event({**coalesced_base, "hook_event_name": "Stop"}, home=home, now=1012)
second_ended = record_hook_event({**coalesced_base, "hook_event_name": "Stop"}, home=home, now=1013)
assert first_blocked and second_blocked and second_blocked["ts"] == 1011, second_blocked
assert first_ended and second_ended and second_ended["ts"] == 1013, second_ended
coalesced_journal = home / ".marina" / "agent-events" / "claude" / "coalesced-1.jsonl"
coalesced_rows = [json.loads(line) for line in coalesced_journal.read_text(encoding="utf-8").splitlines()]
assert len(coalesced_rows) == 2 <= MAX_ROWS, coalesced_rows
assert [row["ts"] for row in coalesced_rows] == [1011, 1013], coalesced_rows

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
assert latest_agent_event("claude", "claude-1", root, home=file_home, now=1402) is None
symlink_journal_result = record_hook_event({**claude_base, "hook_event_name": "UserPromptSubmit"}, home=file_home, now=1402)
assert symlink_journal_result is None or symlink_journal_result["ts"] == 1402
assert outside_journal.read_text(encoding="utf-8") == "do not touch"
if symlink_journal_result:
    assert latest_agent_event("claude", "claude-1", root, home=file_home, now=1403) == symlink_journal_result

# Readers and recorders must reject FIFOs without blocking before their file
# type check. Run these in a worker so the old blocking-open behavior fails
# quickly and cannot stall the full contract suite.
fifo_home = tmp / "fifo-home"
fifo_dir = fifo_home / ".marina" / "agent-events" / "claude"
fifo_dir.mkdir(parents=True, mode=0o700)
fifo_journal = fifo_dir / "fifo-journal-1.jsonl"
os.mkfifo(fifo_journal, 0o600)
fifo_queue = context.Queue()
fifo_reader = context.Process(target=_read_latest_in_worker, args=(fifo_home, root, "fifo-journal-1", fifo_queue))
fifo_reader.start()
fifo_reader.join(0.5)
if fifo_reader.is_alive():
    fifo_reader.terminate()
    fifo_reader.join(15)
    raise AssertionError("FIFO journal reader blocked")
assert fifo_reader.exitcode == 0, fifo_reader.exitcode
assert fifo_queue.get(timeout=1) is None
assert stat.S_ISFIFO(fifo_journal.lstat().st_mode)

fifo_lock = fifo_dir / "fifo-lock-1.lock"
os.mkfifo(fifo_lock, 0o600)
fifo_payload = {
    "session_id": "fifo-lock-1", "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/fifo-lock-1.jsonl"),
    "hook_event_name": "UserPromptSubmit",
}
fifo_queue = context.Queue()
fifo_writer = context.Process(target=_record_in_worker, args=(fifo_payload, fifo_home, fifo_queue))
fifo_writer.start()
fifo_writer.join(0.5)
if fifo_writer.is_alive():
    fifo_writer.terminate()
    fifo_writer.join(15)
    raise AssertionError("FIFO lock recorder blocked")
assert fifo_writer.exitcode == 0, fifo_writer.exitcode
assert fifo_queue.get(timeout=1) is None
assert stat.S_ISFIFO(fifo_lock.lstat().st_mode)

# Linked journal artifacts must never chmod or write their outside inode. A
# recorder may fail open or replace just the journal pathname with a fresh inode.
hardlink_home = tmp / "hardlink-home"
hardlink_dir = hardlink_home / ".marina" / "agent-events" / "claude"
hardlink_dir.mkdir(parents=True, mode=0o700)
outside_hard_lock = tmp / "outside-hard-lock"
outside_hard_lock.write_text("outside lock", encoding="utf-8")
outside_hard_lock.chmod(0o644)
os.link(outside_hard_lock, hardlink_dir / "hard-lock-1.lock")
hard_lock_payload = {
    "session_id": "hard-lock-1", "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/hard-lock-1.jsonl"),
    "hook_event_name": "UserPromptSubmit",
}
assert record_hook_event(hard_lock_payload, home=hardlink_home, now=1510) is None
assert outside_hard_lock.read_text(encoding="utf-8") == "outside lock"
assert stat.S_IMODE(outside_hard_lock.stat().st_mode) == 0o644

outside_hard_journal = tmp / "outside-hard-journal"
outside_hard_journal.write_text("outside journal", encoding="utf-8")
outside_hard_journal.chmod(0o644)
hard_journal = hardlink_dir / "hard-journal-1.jsonl"
os.link(outside_hard_journal, hard_journal)
hard_journal_payload = {
    "session_id": "hard-journal-1", "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/hard-journal-1.jsonl"),
    "hook_event_name": "UserPromptSubmit",
}
assert latest_agent_event("claude", "hard-journal-1", root, home=hardlink_home, now=1511) is None
hard_journal_result = record_hook_event(hard_journal_payload, home=hardlink_home, now=1512)
assert hard_journal_result is None or hard_journal_result["ts"] == 1512
assert outside_hard_journal.read_text(encoding="utf-8") == "outside journal"
assert stat.S_IMODE(outside_hard_journal.stat().st_mode) == 0o644
if hard_journal_result:
    assert latest_agent_event("claude", "hard-journal-1", root, home=hardlink_home, now=1513) == hard_journal_result

# A temp inode linked after exclusive creation is unsafe before it can be
# chmodded or written. The outside hard-link target stays empty.
temp_link_home = tmp / "temp-link-home"
temp_link_home.mkdir()
temp_link_outside = tmp / "outside-temp-link"
real_open = events.os.open
linked_temp = False

def link_temp_open(path, flags, mode=0o777, *, dir_fd=None):
    global linked_temp
    fd = real_open(path, flags, mode, dir_fd=dir_fd)
    if isinstance(path, str) and path.endswith(".tmp") and not linked_temp:
        os.link(path, temp_link_outside, src_dir_fd=dir_fd)
        linked_temp = True
    return fd

events.os.open = link_temp_open
try:
    temp_link_result = record_hook_event({
        "session_id": "temp-link-1", "cwd": str(root),
        "transcript_path": str(tmp / ".claude/projects/root/temp-link-1.jsonl"),
        "hook_event_name": "UserPromptSubmit",
    }, home=temp_link_home, now=1514)
finally:
    events.os.open = real_open
assert linked_temp
assert temp_link_result is None
assert temp_link_outside.read_bytes() == b""

# Preserve the written temp descriptor across replace. If an attacker swaps
# the temp pathname for a symlink immediately before the real replace, fail
# closed, leave the outside target intact, and allow a later normal recorder
# to replace that unsafe journal entry with a trustworthy inode.
swap_home = tmp / "swap-home"
swap_home.mkdir()
swap_outside = tmp / "swap-outside"
swap_outside.write_text("outside swap", encoding="utf-8")
swap_outside.chmod(0o644)
real_replace = events.os.replace
swapped_temp = False

def swap_temp_replace(source, destination, *, src_dir_fd=None, dst_dir_fd=None):
    global swapped_temp
    if isinstance(source, str) and source.endswith(".tmp") and not swapped_temp:
        os.unlink(source, dir_fd=src_dir_fd)
        os.symlink(swap_outside, source, dir_fd=src_dir_fd)
        swapped_temp = True
    return real_replace(source, destination, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd)

events.os.replace = swap_temp_replace
swap_payload = {
    "session_id": "swap-temp-1", "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/swap-temp-1.jsonl"),
    "hook_event_name": "UserPromptSubmit",
}
try:
    swap_result = record_hook_event(swap_payload, home=swap_home, now=1515)
finally:
    events.os.replace = real_replace
assert swapped_temp
assert swap_result is None
assert swap_outside.read_text(encoding="utf-8") == "outside swap"
assert stat.S_IMODE(swap_outside.stat().st_mode) == 0o644
recovered = record_hook_event(swap_payload, home=swap_home, now=1516)
assert recovered and recovered["ts"] == 1516, recovered
assert latest_agent_event("claude", "swap-temp-1", root, home=swap_home, now=1517) == recovered

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

# The wrapper caps stdin before JSON parsing. A larger payload fails open
# quickly, leaves no journal hierarchy, and avoids unbounded allocation.
oversized_wrapper_home = tmp / "oversized-wrapper-home"
oversized_wrapper_home.mkdir()
started = time.monotonic()
oversized = subprocess.run(
    [str(scripts / "marina-agent-event-hook.sh")],
    input=b"x" * (events.MAX_HOOK_INPUT_BYTES + 1),
    env={**os.environ, "HOME": str(oversized_wrapper_home)},
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    timeout=5,
)
elapsed = time.monotonic() - started
assert oversized.returncode == 0, oversized.returncode
assert elapsed < 3, elapsed
assert not (oversized_wrapper_home / ".marina").exists()
print("ok hook journal")
PY

python3 - "$HERE/../hooks/hooks.json" "$HERE/../hooks/codex-hooks.json" "$HERE/../.claude-plugin/plugin.json" "$HERE/../.codex-plugin/plugin.json" "$HERE/../../README.md" <<'PY'
import json
import sys
from pathlib import Path

claude_hooks = json.load(open(sys.argv[1], encoding="utf-8"))["hooks"]
codex_hooks = json.load(open(sys.argv[2], encoding="utf-8"))["hooks"]
claude_manifest = json.load(open(sys.argv[3], encoding="utf-8"))
codex_manifest = json.load(open(sys.argv[4], encoding="utf-8"))
readme = Path(sys.argv[5]).read_text(encoding="utf-8")

assert "Notification" in claude_hooks
assert "Notification" not in codex_hooks
assert set(codex_hooks) == {
    "SessionStart", "PreToolUse", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop",
}
assert codex_manifest["hooks"] == "./hooks/codex-hooks.json"
assert "hooks" not in claude_manifest

for name in ("UserPromptSubmit", "Notification", "Stop"):
    commands = claude_hooks[name][0]["hooks"]
    assert len(commands) == 1 and commands[0].get("async") is False, (name, commands)
    assert commands[0].get("timeout") == 2, (name, commands)
    assert "${CLAUDE_PLUGIN_ROOT}" in commands[0]["command"], (name, commands)

for name in ("UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop"):
    commands = codex_hooks[name][0]["hooks"]
    assert len(commands) == 1 and commands[0].get("async") is False, (name, commands)
    assert commands[0].get("timeout") == 2, (name, commands)
    assert "${PLUGIN_ROOT}" in commands[0]["command"], (name, commands)

for name in ("PermissionRequest", "PostToolUse"):
    assert codex_hooks[name][0].get("matcher") == "^(Bash|apply_patch|Edit|Write|mcp__.*)$", (name, codex_hooks[name])

for name in ("SessionStart", "PreToolUse"):
    command = codex_hooks[name][0]["hooks"][0]["command"]
    assert "${PLUGIN_ROOT}" in command, (name, command)
assert "hooks/codex-hooks.json" in readme
assert "Codex 도 동일 hooks.json" not in readme
print("ok host-specific synchronous lifecycle hook contract")
PY

WRAPPER="$SCRIPTS/marina-agent-event-hook.sh"
mkdir -p "$TMP/wrapper-home"
printf '{not json}\n' | HOME="$TMP/wrapper-home" "$WRAPPER"
printf '%s\n' '{"session_id":"wrapper-1","cwd":"/tmp","transcript_path":"/tmp/.claude/x.jsonl","hook_event_name":"UserPromptSubmit"}' | HOME="$TMP/wrapper-home" "$WRAPPER"
test -f "$TMP/wrapper-home/.marina/agent-events/claude/wrapper-1.jsonl" || { echo "FAIL wrapper did not record valid input"; exit 1; }

echo "PASS test-agent-events"
