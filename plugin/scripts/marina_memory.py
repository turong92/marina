"""Best-effort host and Docker memory snapshots for Marina."""
from __future__ import annotations

import copy
import datetime as dt
import json
import platform
import re
import subprocess
import threading
import time
from typing import Any


_CACHE_TTL_SECONDS = 5.0
_DOCKER_TIMEOUT_SECONDS = 3.0
_INSPECT_TIMEOUT_SECONDS = 2.0
_cache_condition = threading.Condition()
_refreshing = False
_snapshot_cache: tuple[float, dict[str, Any]] | None = None
_inspect_cache: dict[str, dict[str, Any]] = {}


def _run(args: list[str], timeout: float) -> str:
    """Run a bounded command. Tests replace this module-level seam."""
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=timeout)


def parse_size_mb(value: str) -> int | None:
    """Parse Docker's IEC/SI size strings into whole MiB."""
    match = re.fullmatch(r"\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?i?B)?\s*", str(value or ""), re.IGNORECASE)
    if not match:
        return None
    amount = float(match.group(1))
    unit = (match.group(2) or "B").lower()
    factors = {
        "b": 1,
        "kb": 1000,
        "mb": 1000**2,
        "gb": 1000**3,
        "tb": 1000**4,
        "pb": 1000**5,
        "eb": 1000**6,
        "kib": 1024,
        "mib": 1024**2,
        "gib": 1024**3,
        "tib": 1024**4,
        "pib": 1024**5,
        "eib": 1024**6,
    }
    factor = factors.get(unit)
    return int(amount * factor / (1024**2)) if factor is not None else None


def _linux_memory() -> dict[str, Any]:
    values: dict[str, int] = {}
    try:
        with open("/proc/meminfo", encoding="utf-8") as handle:
            for line in handle:
                match = re.match(r"^(MemTotal|MemAvailable):\s*(\d+)", line)
                if match:
                    values[match.group(1)] = int(match.group(2)) // 1024
    except Exception:
        pass
    total = values.get("MemTotal")
    available = values.get("MemAvailable")
    percent = int(available * 100 / total) if total and available is not None else None
    return {"totalMb": total, "availableMb": available, "availablePercent": percent}


def _macos_memory() -> dict[str, Any]:
    total: int | None = None
    available_percent: int | None = None
    try:
        total = int(subprocess.check_output(
            ["sysctl", "-n", "hw.memsize"], text=True, stderr=subprocess.DEVNULL, timeout=2,
        ).strip()) // (1024**2)
    except Exception:
        pass
    try:
        output = subprocess.check_output(
            ["memory_pressure", "-Q"], text=True, stderr=subprocess.DEVNULL, timeout=2,
        )
        match = re.search(r"free percentage:\s*(\d+)", output)
        if match:
            available_percent = int(match.group(1))
    except Exception:
        pass
    available = total * available_percent // 100 if total is not None and available_percent is not None else None
    return {"totalMb": total, "availableMb": available, "availablePercent": available_percent}


def host_memory() -> dict[str, Any]:
    """Read host memory without allowing an unsupported platform to raise."""
    system = platform.system()
    if system == "Linux":
        return _linux_memory()
    if system == "Darwin":
        return _macos_memory()
    return {"totalMb": None, "availableMb": None, "availablePercent": None}


def _json_rows(output: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in output.splitlines():
        try:
            item = json.loads(line)
        except (TypeError, json.JSONDecodeError):
            continue
        if isinstance(item, dict):
            rows.append(item)
    if not rows:
        try:
            item = json.loads(output)
        except (TypeError, json.JSONDecodeError):
            return []
        if isinstance(item, dict):
            return [item]
        if isinstance(item, list):
            return [row for row in item if isinstance(row, dict)]
    return rows


def _labels(row: dict[str, Any]) -> dict[str, str]:
    raw = row.get("Labels") or row.get("labels") or {}
    if isinstance(raw, dict):
        return {str(key): str(value) for key, value in raw.items()}
    labels: dict[str, str] = {}
    for item in str(raw).split(","):
        key, separator, value = item.partition("=")
        if separator:
            labels[key] = value
    return labels


def _inspect(container_id: str) -> dict[str, Any]:
    cached = _inspect_cache.get(container_id)
    if cached is not None:
        return cached
    rows = _json_rows(_run(["docker", "inspect", container_id], _INSPECT_TIMEOUT_SECONDS))
    details = rows[0] if rows else {}
    _inspect_cache[container_id] = details
    return details


def _container_rows(docker_total_mb: int | None) -> tuple[list[dict[str, Any]], bool, list[str]]:
    stats_rows = _json_rows(_run(["docker", "stats", "--no-stream", "--format", "{{json .}}"], _DOCKER_TIMEOUT_SECONDS))
    ps_rows = _json_rows(_run(["docker", "ps", "--format", "{{json .}}"], _DOCKER_TIMEOUT_SECONDS))
    ps_by_id = {str(row.get("ID") or row.get("Id") or ""): row for row in ps_rows}
    containers: list[dict[str, Any]] = []
    partial = False
    errors: list[str] = []
    for stat in stats_rows:
        container_id = str(stat.get("ID") or stat.get("Id") or "")
        usage_text, _, stats_limit_text = str(stat.get("MemUsage") or stat.get("MemUsageBytes") or "").partition("/")
        usage_mb = parse_size_mb(usage_text.strip())
        stat_limit_mb = parse_size_mb(stats_limit_text.strip())
        ps_row = ps_by_id.get(container_id, {})
        labels = _labels(ps_row)
        details: dict[str, Any] = {}
        if container_id:
            try:
                details = _inspect(container_id)
                labels.update(_labels((details.get("Config") or {}).get("Labels") or {}))
            except Exception as exc:
                partial = True
                errors.append(_error_text(exc))
        host_config = details.get("HostConfig") if isinstance(details.get("HostConfig"), dict) else {}
        configured_bytes = host_config.get("Memory")
        configured_limit_mb = int(configured_bytes) // (1024**2) if configured_bytes else None
        effective_limit_mb = configured_limit_mb or docker_total_mb or stat_limit_mb
        percent = int(usage_mb * 100 / effective_limit_mb) if usage_mb is not None and effective_limit_mb else None
        state = details.get("State") if isinstance(details.get("State"), dict) else {}
        containers.append({
            "id": container_id,
            "name": stat.get("Name") or stat.get("Names") or ps_row.get("Names") or None,
            "composeProject": labels.get("com.docker.compose.project"),
            "composeService": labels.get("com.docker.compose.service"),
            "memoryUsageMb": usage_mb,
            "memoryLimitMb": effective_limit_mb,
            "memoryPercent": percent,
            "oomKilled": state.get("OOMKilled") if details else None,
            "imageId": details.get("Image") if details else None,
        })
    return containers, partial, errors


def _error_text(exc: Exception) -> str:
    return f"{type(exc).__name__}: {exc}"


def _captured_at() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _empty_snapshot(error: str | None = None) -> dict[str, Any]:
    return {
        "host": host_memory(),
        "docker": {"totalMb": None, "usedMb": None, "availableMb": None, "serverOs": None, "available": False},
        "containers": [],
        "stale": False,
        "partial": error is not None,
        "error": error,
        "capturedAt": _captured_at(),
    }


def _collect_snapshot() -> dict[str, Any]:
    snapshot = _empty_snapshot()
    info_rows = _json_rows(_run(["docker", "info", "--format", "{{json .}}"], _DOCKER_TIMEOUT_SECONDS))
    info = info_rows[0] if info_rows else {}
    total_bytes = info.get("MemTotal")
    total_mb = round(int(total_bytes) / (1024**2)) if total_bytes is not None else None
    containers, partial, errors = _container_rows(total_mb)
    used_mb = sum(row["memoryUsageMb"] for row in containers if row["memoryUsageMb"] is not None)
    snapshot.update({
        "docker": {
            "totalMb": total_mb,
            "usedMb": used_mb,
            "availableMb": max(0, total_mb - used_mb) if total_mb is not None else None,
            "serverOs": info.get("OperatingSystem"),
            "available": bool(info_rows),
        },
        "containers": containers,
        "partial": partial,
        "error": "; ".join(errors) if errors else None,
    })
    return snapshot


def _cache_value(snapshot: dict[str, Any], *, stale: bool = False, error: str | None = None) -> dict[str, Any]:
    value = copy.deepcopy(snapshot)
    if stale:
        value["stale"] = True
        value["partial"] = True
        value["error"] = error
    return value


def memory_snapshot(force: bool = False) -> dict[str, Any]:
    """Return a cached best-effort host/Docker snapshot; never raise."""
    global _refreshing, _snapshot_cache
    now = time.monotonic()
    with _cache_condition:
        if _snapshot_cache and not force and now - _snapshot_cache[0] < _CACHE_TTL_SECONDS:
            return _cache_value(_snapshot_cache[1])
        if _refreshing:
            _cache_condition.wait(timeout=_DOCKER_TIMEOUT_SECONDS + _INSPECT_TIMEOUT_SECONDS)
            if _snapshot_cache:
                if _refreshing:
                    return _cache_value(
                        _snapshot_cache[1], stale=True, error="memory snapshot refresh is still running",
                    )
                return _cache_value(_snapshot_cache[1])
            return _empty_snapshot("memory snapshot refresh is still running")
        previous = _snapshot_cache[1] if _snapshot_cache else None
        _refreshing = True
    try:
        snapshot = _collect_snapshot()
    except Exception as exc:
        error = _error_text(exc)
        failed_snapshot = _cache_value(previous, stale=True, error=error) if previous is not None else _empty_snapshot(error)
        with _cache_condition:
            _snapshot_cache = (time.monotonic(), failed_snapshot)
        return _cache_value(failed_snapshot)
    else:
        with _cache_condition:
            _snapshot_cache = (time.monotonic(), snapshot)
        return _cache_value(snapshot)
    finally:
        with _cache_condition:
            _refreshing = False
            _cache_condition.notify_all()


def system_memory() -> dict[str, Any]:
    host = memory_snapshot().get("host") or {}
    return {
        "totalMb": host.get("totalMb"),
        "freeMb": host.get("availableMb"),
        "freePercent": host.get("availablePercent"),
    }
