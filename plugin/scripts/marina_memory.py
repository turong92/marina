"""Best-effort host and Docker memory snapshots for Marina."""
from __future__ import annotations

import copy
import datetime as dt
import fcntl
import json
import os
import platform
import re
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

from marina_paths import session_id
from marina_registry import project_for
from marina_state import _env, _mc


_CACHE_TTL_SECONDS = 5.0
_DOCKER_TIMEOUT_SECONDS = 3.0
_INSPECT_TIMEOUT_SECONDS = 2.0
_PRESSURE_SAMPLE_INTERVAL_SECONDS = 2.0
_cache_condition = threading.Condition()
_refreshing = False
_snapshot_cache: tuple[float, dict[str, Any]] | None = None
_inspect_cache: dict[str, dict[str, Any]] = {}
_HISTORY_MAX_SERVICES = 200
_pressure_condition = threading.Condition()
_pressure_tokens: dict[str, list[dict[str, Any]]] = {}
_pressure_sampler: threading.Thread | None = None
_pressure_sampling = False
_pressure_capture_tokens: set[str] = set()
_pressure_token_sequence = 0


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


def _pressure_number(value: Any) -> int | None:
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _normal_container_total(snapshot: dict[str, Any]) -> int | None:
    """Sum observed regular containers without attributing BuildKit usage to a build."""
    containers = snapshot.get("containers")
    if not isinstance(containers, list):
        return None
    total = 0
    observed = False
    for container in containers:
        if not isinstance(container, dict):
            continue
        name = str(container.get("name") or "").lower()
        if "buildkit" in name:
            continue
        usage = _pressure_number(container.get("memoryUsageMb"))
        if usage is not None and usage >= 0:
            total += usage
            observed = True
    docker = snapshot.get("docker") if isinstance(snapshot.get("docker"), dict) else {}
    if observed or docker.get("available"):
        return total
    return None


def _pressure_sample() -> dict[str, Any]:
    """Capture cheap host pressure plus cached Docker container usage."""
    host = host_memory()
    snapshot = memory_snapshot()
    docker = snapshot.get("docker") if isinstance(snapshot.get("docker"), dict) else {}
    available = _pressure_number(host.get("availableMb"))
    containers = _normal_container_total(snapshot)
    total = _pressure_number(docker.get("totalMb"))
    return {
        "hostAvailableMb": available,
        "containersMb": containers,
        "dockerTotalMb": total,
        "partial": bool(snapshot.get("partial")) or available is None or containers is None or total is None,
    }


def _record_pressure_sample() -> None:
    """Capture one shared sample and append it to every currently active token."""
    global _pressure_capture_tokens, _pressure_sampling
    with _pressure_condition:
        while _pressure_sampling:
            _pressure_condition.wait()
        if not _pressure_tokens:
            return
        _pressure_sampling = True
        _pressure_capture_tokens = set(_pressure_tokens)
    try:
        try:
            sample = _pressure_sample()
        except Exception:
            sample = {
                "hostAvailableMb": None,
                "containersMb": None,
                "dockerTotalMb": None,
                "partial": True,
            }
        with _pressure_condition:
            for token in _pressure_capture_tokens:
                samples = _pressure_tokens.get(token)
                if samples is not None:
                    samples.append(dict(sample))
    finally:
        with _pressure_condition:
            _pressure_capture_tokens = set()
            _pressure_sampling = False
            _pressure_condition.notify_all()


def _pressure_sampler_loop() -> None:
    global _pressure_sampler
    while True:
        _record_pressure_sample()
        deadline = time.monotonic() + _PRESSURE_SAMPLE_INTERVAL_SECONDS
        with _pressure_condition:
            while _pressure_tokens:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                _pressure_condition.wait(timeout=remaining)
            if _pressure_tokens:
                continue
            if _pressure_sampler is threading.current_thread():
                _pressure_sampler = None
            _pressure_condition.notify_all()
            return


def start_pressure_observation() -> str:
    """Register one build with the process-wide, low-frequency pressure sampler."""
    global _pressure_sampler, _pressure_token_sequence
    with _pressure_condition:
        _pressure_token_sequence += 1
        token = f"pressure-{_pressure_token_sequence}"
        _pressure_tokens[token] = []
        if _pressure_sampler is None or not _pressure_sampler.is_alive():
            _pressure_sampler = threading.Thread(
                target=_pressure_sampler_loop,
                name="marina-pressure-observer",
                daemon=True,
            )
            try:
                _pressure_sampler.start()
            except Exception:
                _pressure_tokens.pop(token, None)
                _pressure_sampler = None
                raise
        _pressure_condition.notify_all()
    return token


def _pressure_summary(samples: list[dict[str, Any]]) -> dict[str, Any]:
    host_values = [value for sample in samples if (value := _pressure_number(sample.get("hostAvailableMb"))) is not None]
    container_values = [value for sample in samples if (value := _pressure_number(sample.get("containersMb"))) is not None]
    docker_totals = [value for sample in samples if (value := _pressure_number(sample.get("dockerTotalMb"))) is not None]
    return {
        "hostAvailableMinMb": min(host_values) if host_values else None,
        "containersPeakMb": max(container_values) if container_values else None,
        "dockerTotalMb": docker_totals[-1] if docker_totals else None,
        "sampleCount": len(samples),
        "partial": not samples or any(bool(sample.get("partial")) for sample in samples),
    }


def finish_pressure_observation(token: str) -> dict[str, Any]:
    """Stop one build observation and return only its observed interval summary."""
    samples: list[dict[str, Any]] = []
    try:
        with _pressure_condition:
            while _pressure_sampling and token in _pressure_capture_tokens:
                _pressure_condition.wait()
            needs_sample = token in _pressure_tokens and not _pressure_tokens[token]
        if needs_sample:
            _record_pressure_sample()
    finally:
        with _pressure_condition:
            samples = _pressure_tokens.pop(token, [])
            _pressure_condition.notify_all()
    return _pressure_summary(samples)


def _memory_history_path(project_id: str) -> Path:
    home = Path(os.environ.get("MARINA_HOME") or (Path.home() / ".marina"))
    return home / project_id / "memory-history.json"


def _history_payload(value: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(value, dict) or value.get("version") != 1:
        return {}
    services = value.get("services")
    if not isinstance(services, dict):
        return {}
    out: dict[str, dict[str, Any]] = {}
    for name, entry in services.items():
        if not isinstance(entry, dict):
            continue
        try:
            peak = int(entry.get("peakMb"))
        except (TypeError, ValueError):
            continue
        if peak < 0:
            continue
        out[str(name)] = {
            "peakMb": peak,
            "imageId": entry.get("imageId") if isinstance(entry.get("imageId"), str) else None,
            "observedAt": str(entry.get("observedAt") or ""),
        }
    return out


def _read_memory_history(path: Path) -> dict[str, dict[str, Any]]:
    try:
        return _history_payload(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return {}


def _write_memory_history(path: Path, services: dict[str, dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"version": 1, "services": services}
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _bounded_history(services: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    ranked = sorted(
        services.items(), key=lambda item: (str(item[1].get("observedAt") or ""), item[0]), reverse=True,
    )[:_HISTORY_MAX_SERVICES]
    return dict(ranked)


def _observe_memory_history(project_id: str, observations: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Merge observed service usage under a cross-process lock and atomically persist it."""
    if not project_id:
        return {}
    path = _memory_history_path(project_id)
    if not observations:
        return _read_memory_history(path)
    lock_path = path.with_name("memory-history.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        services = _read_memory_history(path)
        observed_at = _captured_at()
        for name, observation in observations.items():
            usage = observation.get("memoryUsageMb")
            try:
                usage = int(usage)
            except (TypeError, ValueError):
                continue
            if usage < 0:
                continue
            previous = services.get(name) or {}
            previous_peak = int(previous.get("peakMb") or 0)
            peak = max(previous_peak, usage)
            # A lower sample from a rebuilt image is only a same-service estimate;
            # keep the image identity that actually produced the retained peak.
            image_id = (
                observation.get("imageId") or previous.get("imageId")
                if usage >= previous_peak
                else previous.get("imageId")
            )
            services[name] = {
                "peakMb": peak,
                "imageId": image_id if isinstance(image_id, str) else None,
                "observedAt": observed_at,
            }
        services = _bounded_history(services)
        _write_memory_history(path, services)
        return services
    except OSError:
        return _read_memory_history(path)
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)


def _service_memory(snapshot: dict[str, Any], project_name: str) -> dict[str, dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    containers = snapshot.get("containers") if isinstance(snapshot, dict) else None
    for container in containers if isinstance(containers, list) else []:
        if not isinstance(container, dict) or container.get("composeProject") != project_name:
            continue
        service = container.get("composeService")
        if isinstance(service, str) and service:
            grouped.setdefault(service, []).append(container)

    mapped: dict[str, dict[str, Any]] = {}
    for service, containers in grouped.items():
        usages = [int(value) for row in containers if isinstance((value := row.get("memoryUsageMb")), (int, float))]
        limits = [int(value) for row in containers if isinstance((value := row.get("memoryLimitMb")), (int, float)) and value > 0]
        usage = sum(usages) if usages else None
        limit = sum(limits) if limits else None
        oom_values = [row.get("oomKilled") for row in containers if isinstance(row.get("oomKilled"), bool)]
        image_ids = {row.get("imageId") for row in containers if isinstance(row.get("imageId"), str) and row.get("imageId")}
        mapped[service] = {
            "memoryUsageMb": usage,
            "memoryLimitMb": limit,
            "memoryPercent": int(usage * 100 / limit) if usage is not None and limit else None,
            "oomKilled": True if any(oom_values) else False if oom_values else None,
            "imageId": next(iter(image_ids)) if len(image_ids) == 1 else None,
        }
    return mapped


def enrich_session_memory(root: Path, project: dict, services: list[dict], snapshot: dict) -> None:
    """Mutate one Compose session's service payloads with its matching snapshot and peaks."""
    project_id = str((project or {}).get("id") or "")
    try:
        project_name = _mc().compose_project_name(project_id, session_id(root))
        current = _service_memory(snapshot, project_name)
    except Exception:
        current = {}
    try:
        history = _observe_memory_history(project_id, current)
    except Exception:
        history = _read_memory_history(_memory_history_path(project_id)) if project_id else {}
    for service in services:
        if not isinstance(service, dict):
            continue
        name = str(service.get("service") or "")
        observed = current.get(name) or {}
        historical = history.get(name) or {}
        usage = observed.get("memoryUsageMb")
        service["memoryUsageMb"] = usage
        service["memoryPeakMb"] = historical.get("peakMb")
        service["memoryLimitMb"] = observed.get("memoryLimitMb")
        service["memoryPercent"] = observed.get("memoryPercent")
        service["oomKilled"] = observed.get("oomKilled")
        service["rssMb"] = round(usage) if isinstance(usage, (int, float)) else None


def estimate_services(root: Path, service_names: list[str], snapshot: dict) -> tuple[list[dict[str, Any]], list[str]]:
    """Return learned high-water estimates and explicit unknown services for one worktree."""
    project = project_for(root)
    project_id = str((project or {}).get("id") or "")
    if not project_id:
        return [], list(service_names)
    history = _read_memory_history(_memory_history_path(project_id))
    current = _service_memory(snapshot, _mc().compose_project_name(project_id, session_id(root)))
    estimated: list[dict[str, Any]] = []
    unknown: list[str] = []
    for name in service_names:
        entry = history.get(name)
        if not entry:
            unknown.append(name)
            continue
        image_id = (current.get(name) or {}).get("imageId")
        confidence = "same-image" if image_id and image_id == entry.get("imageId") else "same-service"
        estimated.append({"service": name, "memoryMb": entry["peakMb"], "confidence": confidence})
    return estimated, unknown


def _configured_reserve_mb(docker_total_mb: int | None) -> int | None:
    override = os.environ.get("MARINA_DOCKER_RESERVE_MB")
    if override not in (None, ""):
        try:
            return max(0, int(override))
        except ValueError:
            pass
    return max(4096, round(docker_total_mb * 0.20)) if docker_total_mb is not None else None


def _configured_min_free_mb() -> int:
    try:
        return max(0, int(_env("MIN_FREE_MB", "4096")))
    except ValueError:
        return 4096


def memory_guard(
    root: Path,
    service_names: list[str],
    force: bool = False,
    snapshot: dict | None = None,
) -> dict[str, Any] | None:
    """Return a structured memory block before a lifecycle operation, or ``None``.

    Docker's current working set is always considered. Learned high-water usage is
    added only for requested services that are not already running in this session.
    """
    if force:
        return None
    snapshot = snapshot if isinstance(snapshot, dict) else memory_snapshot(force=True)
    host = snapshot.get("host") if isinstance(snapshot.get("host"), dict) else {}
    docker = snapshot.get("docker") if isinstance(snapshot.get("docker"), dict) else {}
    host_free = host.get("availableMb")
    docker_total = docker.get("totalMb")
    docker_used = docker.get("usedMb")
    host_free = int(host_free) if isinstance(host_free, (int, float)) else None
    docker_total = int(docker_total) if isinstance(docker_total, (int, float)) else None
    docker_used = int(docker_used) if isinstance(docker_used, (int, float)) else None
    reserve = _configured_reserve_mb(docker_total)
    min_free = _configured_min_free_mb()

    names = list(dict.fromkeys(str(name) for name in service_names if str(name)))
    project = project_for(root)
    project_id = str((project or {}).get("id") or "")
    try:
        project_name = _mc().compose_project_name(project_id, session_id(root)) if project_id else ""
        running = set(_service_memory(snapshot, project_name)) if project_name else set()
    except Exception:
        running = set()
    stopped_names = [name for name in names if name not in running]
    estimated, unknown = estimate_services(root, stopped_names, snapshot)
    additional = sum(int(item["memoryMb"]) for item in estimated)
    current_free = docker_total - docker_used if docker_total is not None and docker_used is not None else None
    projected_free = current_free - additional if current_free is not None else None
    decision = {
        "blocked": "low-memory",
        "hostFreeMb": host_free,
        "dockerTotalMb": docker_total,
        "dockerUsedMb": docker_used,
        "estimatedAdditionalMb": additional,
        "reserveMb": reserve,
        "projectedFreeMb": projected_free,
        "estimatedServices": estimated,
        "unknownServices": unknown,
        # Keep the existing host-only response readable to older callers.
        "freeMb": host_free,
        "minFreeMb": min_free,
    }
    if host_free is not None and host_free < min_free:
        return {**decision, "reason": "host-critical"}
    if current_free is not None and reserve is not None and current_free < reserve:
        return {**decision, "reason": "docker-current"}
    if projected_free is not None and reserve is not None and projected_free < reserve:
        return {**decision, "reason": "docker-projected"}
    return None
