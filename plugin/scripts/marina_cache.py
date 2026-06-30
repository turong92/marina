"""marina_cache.py — worktree cache discovery/clear helpers."""
from __future__ import annotations
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
import importlib.util as _ilu

from marina_registry import project_for
from marina_paths import session_id
from marina_state import MARINA_HOME, _bin, _mc


CACHE_TARGET_NAMES = {
    ".cache",
    ".next",
    ".nuxt",
    ".parcel-cache",
    ".pytest_cache",
    ".ruff_cache",
    ".svelte-kit",
    ".turbo",
    ".vite",
    "__pycache__",
    "coverage",
    "node_modules",
}

def _docker_cmd(*args: str) -> list[str]:
    return [_bin("docker"), *args]

LOCAL_CACHE_TARGET_NAMES = CACHE_TARGET_NAMES - {"node_modules"}


def disk_usage_mb(path: Path) -> int | None:
    try:
        out = subprocess.check_output(
            ["du", "-sk", str(path)], text=True, stderr=subprocess.DEVNULL, timeout=30,
        )
        return int(out.split()[0]) // 1024
    except Exception:
        return None

def cache_guard_services(category: str, root: Path) -> tuple[str, ...]:
    return ()

def _stored_compose_path(root: Path) -> tuple[dict[str, Any] | None, Path | None]:
    project = project_for(root)
    if not project or project.get("kind", "compose") != "compose":
        return None, None
    try:
        return project, MARINA_HOME / str(project["id"]) / project.get("composeFile", "docker-compose.yml")
    except KeyError:
        return project, None

def _load_stored_compose(root: Path) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    project, path = _stored_compose_path(root)
    if path is None:
        return project, {}
    try:
        data = _mc()._yaml().safe_load(path.read_text(encoding="utf-8")) or {}
    except Exception:
        return project, {}
    return project, data if isinstance(data, dict) else {}

def _is_cache_target(target: str | None) -> bool:
    if not target:
        return False
    parts = [p for p in str(target).replace("\\", "/").split("/") if p]
    return any(part in CACHE_TARGET_NAMES for part in parts)

def _is_bind_source(source: str | None) -> bool:
    if not source:
        return True
    s = str(source)
    return s.startswith((".", "/", "~")) or os.sep in s or "/" in s

def _category_name(value: str) -> str:
    name = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.replace("/", "_")).strip("._-")
    name = name.replace(".", "_").strip("_")
    name = re.sub(r"_+", "_", name)
    return name or "cache"

def _parse_volume_string(spec: str) -> tuple[str | None, str | None]:
    parts = str(spec).split(":")
    if len(parts) < 2:
        return None, parts[0] if parts else None
    return parts[0], parts[1]

def _volume_actual_name(project: dict[str, Any], root: Path, volume_key: str, spec: Any) -> str:
    if isinstance(spec, dict) and spec.get("name"):
        return str(spec["name"])
    return f"{_mc().compose_project_name(str(project.get('id') or ''), session_id(root))}_{volume_key}"

def docker_volume_exists(name: str) -> bool:
    try:
        subprocess.check_output(_docker_cmd("volume", "inspect", name), stderr=subprocess.DEVNULL, timeout=5)
        return True
    except Exception:
        return False

def _parse_size_mb(value: Any) -> int:
    if isinstance(value, (int, float)):
        return max(0, int(float(value) / (1024 * 1024)))
    text = str(value or "").strip()
    if not text:
        return 0
    match = re.match(r"^([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?I?B?)$", text, re.IGNORECASE)
    if not match:
        return 0
    amount = float(match.group(1))
    unit = match.group(2).lower()
    factors = {
        "": 1 / (1024 * 1024),
        "b": 1 / (1024 * 1024),
        "kb": 1 / 1024,
        "kib": 1 / 1024,
        "mb": 1,
        "mib": 1,
        "gb": 1024,
        "gib": 1024,
        "tb": 1024 * 1024,
        "tib": 1024 * 1024,
    }
    return max(0, int(amount * factors.get(unit, 0)))

def docker_volume_sizes_mb(names: list[str] | tuple[str, ...] | set[str] | None = None) -> dict[str, int]:
    wanted = set(names or [])
    try:
        out = subprocess.check_output(
            _docker_cmd("system", "df", "-v", "--format", "json"),
            text=True, stderr=subprocess.DEVNULL, timeout=12,
        )
    except Exception:
        return {}
    docs: list[Any] = []
    try:
        docs.append(json.loads(out))
    except json.JSONDecodeError:
        for line in out.splitlines():
            try:
                docs.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    sizes: dict[str, int] = {}
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        volumes = doc.get("Volumes") or doc.get("volumes") or []
        if isinstance(volumes, dict):
            volumes = volumes.values()
        for item in volumes:
            if not isinstance(item, dict):
                continue
            name = item.get("Name") or item.get("VolumeName") or item.get("Volume")
            if not name or (wanted and name not in wanted):
                continue
            size = item.get("Size") or item.get("SizeBytes")
            usage = item.get("UsageData") if isinstance(item.get("UsageData"), dict) else {}
            if size is None:
                size = usage.get("Size")
            sizes[str(name)] = _parse_size_mb(size)
    return sizes

def docker_volume_rm(name: str) -> bool:
    subprocess.check_output(_docker_cmd("volume", "rm", name), text=True, stderr=subprocess.STDOUT, timeout=30)
    return True

def _compose_cache_volumes(root: Path, project: dict[str, Any] | None, data: dict[str, Any]) -> list[dict[str, Any]]:
    if not project:
        return []
    services = data.get("services") if isinstance(data.get("services"), dict) else {}
    top_volumes = data.get("volumes") if isinstance(data.get("volumes"), dict) else {}
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for service_name, service in services.items():
        if not isinstance(service, dict):
            continue
        for entry in service.get("volumes") or []:
            source, target = None, None
            if isinstance(entry, str):
                source, target = _parse_volume_string(entry)
            elif isinstance(entry, dict):
                if str(entry.get("type") or "volume") != "volume":
                    continue
                source = entry.get("source") or entry.get("src")
                target = entry.get("target") or entry.get("dst") or entry.get("destination")
            if not source or _is_bind_source(str(source)) or not _is_cache_target(str(target or "")):
                continue
            volume_spec = top_volumes.get(str(source), {})
            if isinstance(volume_spec, dict) and volume_spec.get("external"):
                continue
            volume_name = _volume_actual_name(project, root, str(source), volume_spec)
            if volume_name in seen or not docker_volume_exists(volume_name):
                continue
            seen.add(volume_name)
            category = _category_name(str(source))
            items.append({
                "type": "volume",
                "category": category,
                "service": str(service_name),
                "target": str(target or ""),
                "name": str(source),
                "volume": volume_name,
                "sizeMb": 0,
            })
    sizes = docker_volume_sizes_mb([item["volume"] for item in items])
    for item in items:
        item["sizeMb"] = sizes.get(item["volume"], 0)
    return items

def _build_contexts(root: Path, data: dict[str, Any]) -> list[Path]:
    services = data.get("services") if isinstance(data.get("services"), dict) else {}
    contexts: list[Path] = []
    seen: set[Path] = set()
    for service in services.values():
        if not isinstance(service, dict):
            continue
        build = service.get("build")
        context = build.get("context") if isinstance(build, dict) else build if isinstance(build, str) else None
        if not context:
            continue
        path = Path(str(context)).expanduser()
        if not path.is_absolute():
            path = root / path
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        if resolved not in seen and resolved.is_dir():
            seen.add(resolved)
            contexts.append(resolved)
    return contexts

def _local_cache_items(root: Path, data: dict[str, Any]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    seen: set[Path] = set()
    for base in [root, *_build_contexts(root, data)]:
        for name in LOCAL_CACHE_TARGET_NAMES:
            path = base / name
            if path in seen or path.is_symlink() or not path.is_dir():
                continue
            seen.add(path)
            try:
                rel = os.path.relpath(os.path.realpath(str(path)), os.path.realpath(str(root))).replace(os.sep, "/")
                if rel.startswith(".."):
                    rel = path.name
            except (ValueError, OSError):
                rel = path.name
            items.append({
                "type": "path",
                "category": _category_name(rel),
                "path": path,
                "name": rel,
                "sizeMb": disk_usage_mb(path) or 0,
            })
    return items

def cache_items_by_category(root: Path) -> dict[str, list[dict[str, Any]]]:
    project, data = _load_stored_compose(root)
    out: dict[str, list[dict[str, Any]]] = {}
    for item in [*_compose_cache_volumes(root, project, data), *_local_cache_items(root, data)]:
        out.setdefault(str(item["category"]), []).append(item)
    return out

def cache_paths_by_category(root: Path) -> dict[str, list[Path]]:
    out: dict[str, list[Path]] = {}
    for category, items in cache_items_by_category(root).items():
        paths = [item["path"] for item in items if item.get("type") == "path" and isinstance(item.get("path"), Path)]
        if paths:
            out[category] = paths
    return out

def cache_category_mb(root: Path) -> dict[str, int]:
    return {
        category: sum(int(item.get("sizeMb") or 0) for item in items)
        for category, items in cache_items_by_category(root).items()
    }
