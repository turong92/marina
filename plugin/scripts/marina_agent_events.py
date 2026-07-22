#!/usr/bin/env python3
"""Fail-open, metadata-only agent lifecycle hook journal."""

from __future__ import annotations

import fcntl
import json
import math
import os
import re
import stat
import sys
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Mapping

MAX_ROWS = 100
MAX_FUTURE_SECONDS = 300
LOCK_ACQUIRE_TIMEOUT_SECONDS = 0.35
LOCK_RETRY_SECONDS = 0.01
# Hooks receive metadata plus ordinary payloads only. Cap stdin before JSON
# parsing so a malformed or oversized host payload cannot consume unbounded
# memory on a synchronous lifecycle path.
MAX_HOOK_INPUT_BYTES = 1024 * 1024
# 100 canonical metadata rows fit comfortably in this bounded tail. Keep
# reads bounded even when a corrupt or manually edited journal grows without
# limit, because this runs on dashboard/mobile polling paths.
MAX_JOURNAL_READ_BYTES = 256 * 1024
VALID_SOURCES = {"claude", "codex"}
BLOCKED_REASONS = {"permission_prompt", "idle_prompt", "elicitation_dialog"}
HOOK_EVENTS = {
    "UserPromptSubmit": "working",
    "Stop": "ended",
}

_VALID_SESSION_ID = re.compile(r"^[A-Za-z0-9._-]{1,160}$")
_VALID_EVENTS = {"working", "blocked", "ended", "failed"}


def _canonical_path(value: object) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return str(Path(value).expanduser().resolve(strict=False))
    except (OSError, ValueError):
        return None


def _session_id(payload: Mapping[str, Any]) -> str | None:
    sid = payload.get("session_id") or payload.get("thread_id")
    if not isinstance(sid, str) or not _VALID_SESSION_ID.fullmatch(sid):
        return None
    return sid


def _source_from_transcript(value: object) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parts = Path(value).expanduser().parts
    except (TypeError, ValueError):
        return None
    if ".claude" in parts:
        return "claude"
    if ".codex" in parts:
        return "codex"
    return None


def _source(payload: Mapping[str, Any], environ: Mapping[str, str]) -> str | None:
    transcript_source = _source_from_transcript(payload.get("transcript_path"))
    if transcript_source:
        return transcript_source

    explicit = payload.get("source")
    if explicit in VALID_SOURCES:
        return str(explicit)
    # Codex supplies this even when transcript_path is intentionally null. It
    # must win over the compatibility variable shared with Claude plugins.
    if environ.get("PLUGIN_ROOT"):
        return "codex"
    if isinstance(payload.get("thread_id"), str) and not payload.get("session_id"):
        return "codex"
    if environ.get("CODEX_THREAD_ID") or environ.get("CODEX_HOME"):
        return "codex"
    if environ.get("CLAUDE_PLUGIN_ROOT") or isinstance(payload.get("session_id"), str):
        return "claude"
    return None


def _directory_flags() -> int:
    if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
        raise OSError("safe journal handling requires O_DIRECTORY and O_NOFOLLOW")
    return os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)


def _file_flags(flags: int) -> int:
    if not hasattr(os, "O_NOFOLLOW"):
        raise OSError("safe journal handling requires O_NOFOLLOW")
    return flags | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)


def _open_home_directory(home: Path) -> int | None:
    try:
        fd = os.open(os.fspath(home), _directory_flags())
    except FileNotFoundError:
        return None
    try:
        if not stat.S_ISDIR(os.fstat(fd).st_mode):
            raise OSError("unsafe journal home directory")
        return fd
    except Exception:
        os.close(fd)
        raise


def _open_private_child(parent_fd: int, name: str, *, create: bool) -> int | None:
    try:
        fd = os.open(name, _directory_flags(), dir_fd=parent_fd)
    except FileNotFoundError:
        if not create:
            return None
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            pass
        fd = os.open(name, _directory_flags(), dir_fd=parent_fd)
    try:
        if not stat.S_ISDIR(os.fstat(fd).st_mode):
            raise OSError(f"unsafe journal directory: {name}")
        os.fchmod(fd, 0o700)
        return fd
    except Exception:
        os.close(fd)
        raise


@contextmanager
def _source_directory(home: Path, source: str, *, create: bool) -> Iterator[int]:
    """Open the journal directory without following any journal-tree component."""
    fds: list[int] = []
    try:
        home_fd = _open_home_directory(home)
        if home_fd is None:
            raise FileNotFoundError(os.fspath(home))
        fds.append(home_fd)
        for name in (".marina", "agent-events", source):
            child_fd = _open_private_child(fds[-1], name, create=create)
            if child_fd is None:
                raise FileNotFoundError(name)
            fds.append(child_fd)
        yield fds[-1]
    finally:
        for fd in reversed(fds):
            try:
                os.close(fd)
            except OSError:
                pass


def _private_regular_stat(fd: int, name: str) -> os.stat_result:
    file_stat = os.fstat(fd)
    if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_nlink != 1:
        raise OSError(f"unsafe journal file: {name}")
    return file_stat


def _open_regular_at(source_fd: int, name: str, *, create: bool = False, writable: bool = False) -> int | None:
    flags = os.O_RDWR if writable else os.O_RDONLY
    try:
        fd = os.open(name, _file_flags(flags), 0o600, dir_fd=source_fd)
    except FileNotFoundError:
        if not create:
            return None
        try:
            fd = os.open(
                name,
                _file_flags(flags | os.O_CREAT | os.O_EXCL),
                0o600,
                dir_fd=source_fd,
            )
        except FileExistsError:
            fd = os.open(name, _file_flags(flags), 0o600, dir_fd=source_fd)
    try:
        _private_regular_stat(fd, name)
        os.fchmod(fd, 0o600)
        return fd
    except Exception:
        os.close(fd)
        raise


def _journal_exists(source_fd: int, name: str) -> bool:
    fd = _open_regular_at(source_fd, name)
    if fd is None:
        return False
    try:
        return True
    finally:
        os.close(fd)


@contextmanager
def _open_lock(source_fd: int, name: str) -> Iterator[int]:
    fd = _open_regular_at(source_fd, name, create=True, writable=True)
    if fd is None:
        raise OSError("failed to create journal lock")
    try:
        yield fd
    finally:
        os.close(fd)


def _valid_row(row: object) -> dict[str, Any] | None:
    if not isinstance(row, dict):
        return None
    source = row.get("source")
    sid = row.get("sid")
    root = _canonical_path(row.get("root"))
    event = row.get("event")
    ts = row.get("ts")
    reason = row.get("reason")
    if source not in VALID_SOURCES or not isinstance(sid, str) or not _VALID_SESSION_ID.fullmatch(sid):
        return None
    if root is None or root != row.get("root") or event not in _VALID_EVENTS:
        return None
    if not isinstance(ts, (int, float)) or isinstance(ts, bool) or not math.isfinite(ts):
        return None
    if event == "blocked" and reason not in BLOCKED_REASONS:
        return None
    if event != "blocked" and reason is not None:
        return None
    return {"source": source, "sid": sid, "root": root, "event": event, "reason": reason, "ts": ts}


def _read_rows(source_fd: int, name: str, *, source: str, sid: str) -> list[dict[str, Any]]:
    """Read only a bounded tail and retain rows for the expected journal."""
    fd: int | None = None
    try:
        fd = _open_regular_at(source_fd, name)
        if fd is None:
            return []
        size = os.fstat(fd).st_size
        offset = max(0, size - MAX_JOURNAL_READ_BYTES)
        os.lseek(fd, offset, os.SEEK_SET)
        chunks: list[bytes] = []
        remaining = min(size, MAX_JOURNAL_READ_BYTES)
        while remaining:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if offset:
            split = raw.split(b"\n", 1)
            raw = split[1] if len(split) == 2 else b""
        raw_rows = raw.decode("utf-8", errors="replace").splitlines()
    except OSError:
        return []
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
    rows: list[dict[str, Any]] = []
    for line in raw_rows:
        try:
            row = _valid_row(json.loads(line))
        except (TypeError, ValueError, json.JSONDecodeError):
            row = None
        if row and row["source"] == source and row["sid"] == sid:
            rows.append(row)
    return rows


def _write_all(fd: int, value: bytes) -> None:
    view = memoryview(value)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise OSError("failed to write journal")
        view = view[written:]


def _write_rows(source_fd: int, name: str, rows: list[dict[str, Any]]) -> None:
    temp_name = f".{name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    fd: int | None = None
    replaced = False
    try:
        fd = os.open(
            temp_name,
            _file_flags(os.O_WRONLY | os.O_CREAT | os.O_EXCL),
            0o600,
            dir_fd=source_fd,
        )
        _private_regular_stat(fd, temp_name)
        os.fchmod(fd, 0o600)
        for row in rows:
            _private_regular_stat(fd, temp_name)
            _write_all(fd, json.dumps(row, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n")
        os.fsync(fd)
        expected = _private_regular_stat(fd, temp_name)
        os.replace(temp_name, name, src_dir_fd=source_fd, dst_dir_fd=source_fd)
        final_stat = os.lstat(name, dir_fd=source_fd)
        if (
            not stat.S_ISREG(final_stat.st_mode)
            or final_stat.st_nlink != 1
            or (final_stat.st_dev, final_stat.st_ino) != (expected.st_dev, expected.st_ino)
        ):
            raise OSError("journal replacement did not preserve temporary inode")
        replaced = True
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if not replaced:
            try:
                os.unlink(temp_name, dir_fd=source_fd)
            except FileNotFoundError:
                pass
            except OSError:
                pass


def _event_from_payload(payload: Mapping[str, Any], source: str) -> tuple[str, str | None] | None:
    hook_event = payload.get("hook_event_name")
    if source == "codex":
        if hook_event == "PermissionRequest":
            return "blocked", "permission_prompt"
        if hook_event == "PostToolUse":
            return "working", None
    if hook_event in HOOK_EVENTS:
        return HOOK_EVENTS[str(hook_event)], None
    if source == "claude" and hook_event == "Notification" and payload.get("notification_type") in BLOCKED_REASONS:
        return "blocked", str(payload["notification_type"])
    return None


def _acquire_lock(lock_fd: int, mode: int) -> bool:
    """Acquire a sidecar lock without letting a synchronous hook stall a turn."""
    deadline = time.monotonic() + LOCK_ACQUIRE_TIMEOUT_SECONDS
    while True:
        try:
            fcntl.flock(lock_fd, mode | fcntl.LOCK_NB)
            return True
        except (BlockingIOError, OSError):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            time.sleep(min(LOCK_RETRY_SECONDS, remaining))


def record_hook_event(
    payload: dict[str, Any],
    *,
    environ: Mapping[str, str] | None = None,
    home: Path | None = None,
    now: float | None = None,
) -> dict[str, Any] | None:
    """Append one normalized lifecycle event, returning None for every invalid input."""
    try:
        if not isinstance(payload, dict):
            return None
        environment = os.environ if environ is None else environ
        source = _source(payload, environment)
        sid = _session_id(payload)
        root = _canonical_path(payload.get("cwd"))
        mapped_event = _event_from_payload(payload, source)
        if source not in VALID_SOURCES or not sid or not root or not mapped_event:
            return None
        event, reason = mapped_event
        row = {
            "source": source,
            "sid": sid,
            "root": root,
            "event": event,
            "reason": reason,
            "ts": time.time() if now is None else now,
        }
        if _valid_row(row) is None:
            return None

        resolved_home = Path.home() if home is None else Path(home)
        journal_name = f"{sid}.jsonl"
        lock_name = f"{sid}.lock"
        current = float(row["ts"])
        is_codex_post_tool_use = source == "codex" and payload.get("hook_event_name") == "PostToolUse"
        with _source_directory(resolved_home, source, create=not is_codex_post_tool_use) as source_fd:
            if is_codex_post_tool_use and not _journal_exists(source_fd, journal_name):
                return None
            with _open_lock(source_fd, lock_name) as lock_fd:
                if not _acquire_lock(lock_fd, fcntl.LOCK_EX):
                    return None
                try:
                    rows = [
                        existing for existing in _read_rows(source_fd, journal_name, source=source, sid=sid)
                        if existing["ts"] <= current + MAX_FUTURE_SECONDS
                    ]
                    if is_codex_post_tool_use:
                        root_rows = [existing for existing in rows if existing["root"] == root]
                        if not root_rows:
                            return None
                        newest = max(enumerate(root_rows), key=lambda pair: (pair[1]["ts"], pair[0]))[1]
                        if newest["event"] != "blocked":
                            return None
                    rows.sort(key=lambda existing: existing["ts"])
                    if (
                        rows
                        and rows[-1]["root"] == root
                        and rows[-1]["event"] == event
                        and rows[-1].get("reason") == reason
                    ):
                        rows[-1] = row
                    else:
                        rows.append(row)
                    rows = sorted(rows, key=lambda existing: existing["ts"])[-MAX_ROWS:]
                    _write_rows(source_fd, journal_name, rows)
                    return row
                finally:
                    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    except Exception:
        return None


def latest_agent_event(
    source: str,
    sid: str,
    root: Path,
    *,
    home: Path | None = None,
    now: float | None = None,
) -> dict[str, Any] | None:
    """Return the newest valid journal event for the canonical session/root pair."""
    try:
        if source not in VALID_SOURCES or not isinstance(sid, str) or not _VALID_SESSION_ID.fullmatch(sid):
            return None
        canonical_root = _canonical_path(str(root))
        if canonical_root is None:
            return None
        resolved_home = Path.home() if home is None else Path(home)
        journal_name = f"{sid}.jsonl"
        lock_name = f"{sid}.lock"
        current = time.time() if now is None else now
        with _source_directory(resolved_home, source, create=False) as source_fd:
            if not _journal_exists(source_fd, journal_name):
                return None
            with _open_lock(source_fd, lock_name) as lock_fd:
                if not _acquire_lock(lock_fd, fcntl.LOCK_SH):
                    return None
                try:
                    rows = _read_rows(source_fd, journal_name, source=source, sid=sid)
                finally:
                    fcntl.flock(lock_fd, fcntl.LOCK_UN)
        matching = [
            row for row in rows
            if row["source"] == source
            and row["sid"] == sid
            and row["root"] == canonical_root
            and row["ts"] <= current + MAX_FUTURE_SECONDS
        ]
        return max(enumerate(matching), key=lambda pair: (pair[1]["ts"], pair[0]))[1] if matching else None
    except Exception:
        return None


def main() -> int:
    try:
        raw = sys.stdin.buffer.read(MAX_HOOK_INPUT_BYTES + 1)
        if len(raw) > MAX_HOOK_INPUT_BYTES:
            return 0
        payload = json.loads(raw)
        record_hook_event(payload)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
