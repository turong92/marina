"""Build run metadata and best-effort BuildKit/Gradle summaries."""
from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

_CACHE: dict[str, tuple[tuple[int, int, int, int], dict[str, Any]]] = {}
_DEF = re.compile(r"^#(?P<id>\d+) \[(?P<label>[^]]+)](?: (?P<command>.+))?$")
_DONE = re.compile(r"^#(?P<id>\d+) DONE (?P<seconds>\d+(?:\.\d+)?)s$")
_CACHED = re.compile(r"^#(?P<id>\d+) CACHED$")
_ERROR = re.compile(r"^#(?P<id>\d+) ERROR(?::.*)?$")
_PREBUILD = re.compile(r"^MARINA_PREBUILD_EVENT (?P<payload>\{.*\})$")
_GRADLE = re.compile(
    r"^BUILD (?P<status>SUCCESSFUL|FAILED) in "
    r"(?:(?P<minutes>\d+)m )?(?P<seconds>\d+(?:\.\d+)?)s$"
)


def build_meta_path(log_path: Path) -> Path:
    return Path(log_path).with_suffix(".meta.json")


def write_build_meta(log_path: Path, payload: dict[str, Any]) -> None:
    path = build_meta_path(log_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def read_build_meta(log_path: Path) -> dict[str, Any]:
    try:
        data = json.loads(build_meta_path(log_path).read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _display_label(label: str, command: str) -> str:
    if command.startswith("RUN "):
        text = command[4:].strip()
        return text if len(text) <= 100 else text[:97] + "..."
    if command:
        return command if len(command) <= 100 else command[:97] + "..."
    return label


def _parse(text: str) -> list[dict[str, Any]]:
    definitions: dict[str, tuple[str, str]] = {}
    terminal: dict[str, tuple[float, bool, bool]] = {}
    order: list[str] = []
    gradle: list[dict[str, Any]] = []
    prebuild: dict[str, dict[str, Any]] = {}
    prebuild_order: list[str] = []

    for raw in text.splitlines():
        line = raw.strip()
        match = _PREBUILD.match(line)
        if match:
            try:
                event = json.loads(match.group("payload"))
            except (TypeError, ValueError):
                event = {}
            event_id = str(event.get("id") or "") if isinstance(event, dict) else ""
            status = event.get("status") if isinstance(event, dict) else None
            if event_id and status in ("success", "failed"):
                if event_id not in prebuild:
                    prebuild_order.append(event_id)
                prebuild[event_id] = event
            continue
        match = _DEF.match(line)
        if match:
            step_id = match.group("id")
            if step_id not in definitions:
                order.append(step_id)
            definitions[step_id] = (match.group("label"), match.group("command") or "")
            continue
        match = _CACHED.match(line)
        if match:
            terminal[match.group("id")] = (0.0, True, False)
            continue
        match = _DONE.match(line)
        if match:
            terminal[match.group("id")] = (float(match.group("seconds")), False, False)
            continue
        match = _ERROR.match(line)
        if match:
            terminal[match.group("id")] = (0.0, False, True)
            continue
        match = _GRADLE.match(line)
        if match:
            seconds = float(match.group("seconds")) + 60 * int(match.group("minutes") or 0)
            gradle.append({
                "id": f"gradle-{len(gradle) + 1}",
                "label": "Gradle pre-build",
                "kind": "prebuild",
                "durationSec": seconds,
                "cached": False,
                "failed": match.group("status") == "FAILED",
            })

    steps = []
    if prebuild:
        for event_id in prebuild_order:
            event = prebuild[event_id]
            raw_services = event.get("services")
            services = [str(value) for value in raw_services] if isinstance(raw_services, list) else []
            try:
                duration = float(event.get("durationSec") or 0)
            except (TypeError, ValueError):
                duration = 0.0
            steps.append({
                "id": event_id,
                "label": "Pre-build · " + (", ".join(services) or "host"),
                "kind": "prebuild",
                "durationSec": duration,
                "cached": False,
                "failed": event.get("status") == "failed",
            })
    else:
        steps.extend(gradle)
    for step_id in order:
        if step_id not in terminal:
            continue
        label, command = definitions[step_id]
        seconds, cached, failed = terminal[step_id]
        steps.append({
            "id": step_id,
            "label": _display_label(label, command),
            "kind": "buildkit",
            "durationSec": seconds,
            "cached": cached,
            "failed": failed,
        })
    return steps


def build_summary(log_path: Path) -> dict[str, Any]:
    log_path = Path(log_path).resolve()
    meta_path = build_meta_path(log_path)
    log_stat = log_path.stat()
    try:
        meta_stat = meta_path.stat()
        meta_sig = (meta_stat.st_mtime_ns, meta_stat.st_size)
    except OSError:
        meta_sig = (0, 0)

    signature = (log_stat.st_mtime_ns, log_stat.st_size, meta_sig[0], meta_sig[1])
    key = str(log_path)
    cached = _CACHE.get(key)
    if cached and cached[0] == signature:
        return cached[1]

    text = log_path.read_text(encoding="utf-8", errors="replace")
    meta = read_build_meta(log_path)
    steps = _parse(text)
    misses = [step for step in steps if not step["cached"]]
    bottleneck = max(misses, key=lambda step: step["durationSec"], default=None)
    result = {
        "run": log_path.name,
        "status": meta.get("status", "unknown"),
        "op": meta.get("op", ""),
        "startedAt": meta.get("startedAt"),
        "endedAt": meta.get("endedAt"),
        "durationSec": meta.get("durationSec"),
        "cacheHits": sum(1 for step in steps if step["cached"]),
        "cacheMisses": len(misses),
        "steps": steps,
        "bottleneck": bottleneck,
    }
    _CACHE[key] = (signature, result)
    return result
