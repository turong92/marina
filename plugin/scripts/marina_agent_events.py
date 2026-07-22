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
import tempfile
import time
from pathlib import Path
from typing import Any, Mapping

MAX_ROWS = 100
MAX_FUTURE_SECONDS = 300
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
    if isinstance(payload.get("thread_id"), str) and not payload.get("session_id"):
        return "codex"
    if environ.get("CODEX_THREAD_ID") or environ.get("CODEX_HOME"):
        return "codex"
    if environ.get("CLAUDE_PLUGIN_ROOT") or isinstance(payload.get("session_id"), str):
        return "claude"
    return None


def _journal_paths(home: Path, source: str, sid: str) -> tuple[Path, Path, Path]:
    source_dir = home / ".marina" / "agent-events" / source
    return source_dir, source_dir / f"{sid}.jsonl", source_dir / f"{sid}.lock"


def _ensure_private_directory(path: Path, *, parents: bool = False) -> None:
    try:
        details = path.lstat()
    except FileNotFoundError:
        try:
            path.mkdir(mode=0o700, parents=parents)
        except FileExistsError:
            pass
        details = path.lstat()
    if stat.S_ISLNK(details.st_mode) or not stat.S_ISDIR(details.st_mode):
        raise OSError(f"unsafe journal directory: {path}")
    os.chmod(path, 0o700)


def _prepare_directory(path: Path) -> None:
    marina_dir = path.parents[1]
    events_dir = path.parent
    _ensure_private_directory(marina_dir, parents=True)
    _ensure_private_directory(events_dir)
    _ensure_private_directory(path)


def _is_regular_file(path: Path) -> bool:
    try:
        details = path.lstat()
    except FileNotFoundError:
        return False
    return not stat.S_ISLNK(details.st_mode) and stat.S_ISREG(details.st_mode)


def _open_lock(path: Path):
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        details = os.fstat(fd)
        if not stat.S_ISREG(details.st_mode):
            raise OSError(f"unsafe journal lock: {path}")
        os.fchmod(fd, 0o600)
        return os.fdopen(fd, "a+", encoding="utf-8")
    except Exception:
        os.close(fd)
        raise


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


def _read_rows(path: Path, *, source: str | None = None, sid: str | None = None) -> list[dict[str, Any]]:
    """Read only a bounded tail and retain rows for the expected journal."""
    try:
        if not _is_regular_file(path):
            return []
        size = path.stat().st_size
        with path.open("rb") as handle:
            if size > MAX_JOURNAL_READ_BYTES:
                handle.seek(size - MAX_JOURNAL_READ_BYTES)
                raw = handle.read().split(b"\n", 1)
                raw = raw[1] if len(raw) == 2 else b""
            else:
                raw = handle.read()
        raw_rows = raw.decode("utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return []
    rows: list[dict[str, Any]] = []
    for line in raw_rows:
        try:
            row = _valid_row(json.loads(line))
        except (TypeError, ValueError, json.JSONDecodeError):
            row = None
        if row and (source is None or row["source"] == source) and (sid is None or row["sid"] == sid):
            rows.append(row)
    return rows


def _write_rows(path: Path, rows: list[dict[str, Any]]) -> None:
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    temp_path = Path(temp_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, separators=(",", ":"), sort_keys=True))
                handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        raise
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def _event_from_payload(payload: Mapping[str, Any]) -> tuple[str, str | None] | None:
    hook_event = payload.get("hook_event_name")
    if hook_event in HOOK_EVENTS:
        return HOOK_EVENTS[str(hook_event)], None
    if hook_event == "Notification" and payload.get("notification_type") in BLOCKED_REASONS:
        return "blocked", str(payload["notification_type"])
    return None


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
        mapped_event = _event_from_payload(payload)
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
        source_dir, journal_path, lock_path = _journal_paths(resolved_home, source, sid)
        _prepare_directory(source_dir)
        if os.path.lexists(journal_path) and not _is_regular_file(journal_path):
            return None
        current = float(row["ts"])
        with _open_lock(lock_path) as lock_handle:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
            try:
                rows = [
                    existing for existing in _read_rows(journal_path, source=source, sid=sid)
                    if existing["ts"] <= current + MAX_FUTURE_SECONDS
                ]
                rows.sort(key=lambda existing: existing["ts"])
                if (
                    rows
                    and rows[-1]["root"] == root
                    and rows[-1]["event"] == event
                    and rows[-1].get("reason") == reason
                ):
                    return rows[-1]
                rows.append(row)
                rows = sorted(rows, key=lambda existing: existing["ts"])[-MAX_ROWS:]
                _write_rows(journal_path, rows)
                return row
            finally:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
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
        source_dir, journal_path, lock_path = _journal_paths(resolved_home, source, sid)
        if not _is_regular_file(journal_path):
            return None
        current = time.time() if now is None else now
        _prepare_directory(source_dir)
        with _open_lock(lock_path) as lock_handle:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_SH)
            try:
                rows = _read_rows(journal_path, source=source, sid=sid)
            finally:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
        matching = [
            row for row in rows
            if row["source"] == source
            and row["sid"] == sid
            and row["root"] == canonical_root
            and row["ts"] <= current + MAX_FUTURE_SECONDS
        ]
        return max(matching, key=lambda row: row["ts"]) if matching else None
    except Exception:
        return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        record_hook_event(payload)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
