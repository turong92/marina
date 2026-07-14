"""Language-neutral planning and execution primitives for host prebuild jobs."""
from __future__ import annotations

import json
import subprocess
import sys
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Mapping, Sequence

EVENT_PREFIX = "MARINA_PREBUILD_EVENT "


class PrebuildConfigError(ValueError):
    """Raised when a prebuild declaration is unsafe or malformed."""


@dataclass(frozen=True)
class PrebuildJob:
    id: str
    services: tuple[str, ...]
    cwd: str
    command: str
    java_key: str
    legacy: bool = False


def _inside_root(root: Path, relative: str) -> Path:
    root = root.resolve()
    if not relative or Path(relative).is_absolute():
        raise PrebuildConfigError(
            f"prebuild cwd must be a non-empty relative path: {relative!r}"
        )
    resolved = (root / relative).resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise PrebuildConfigError(
            f"prebuild cwd escapes worktree root: {relative}"
        ) from exc
    if not resolved.is_dir():
        raise PrebuildConfigError(f"prebuild cwd does not exist: {relative}")
    return resolved


def _legacy_subrepo(build: Any, root: Path) -> str:
    context = build.get("context") if isinstance(build, Mapping) else build
    if not context:
        return "."
    path = Path(str(context))
    if not path.is_absolute():
        path = root / path
    try:
        parts = path.resolve().relative_to(root.resolve()).parts
    except ValueError as exc:
        raise PrebuildConfigError(
            f"legacy prebuild context escapes worktree root: {context}"
        ) from exc
    if parts[:2] == (".workspace", "external") and len(parts) >= 3:
        return parts[2]
    return parts[0] if parts else "."


def _java_key(cwd: str) -> str:
    parts = Path(cwd).parts
    if parts[:2] == (".workspace", "external") and len(parts) >= 3:
        return parts[2]
    return parts[0] if parts and parts[0] != "." else "default"


def plan_prebuild_jobs(
    raw: Any,
    config: Mapping[str, Any],
    targets: Sequence[str],
    root: Path,
) -> list[PrebuildJob]:
    """Validate prebuild declarations and return selected, deduplicated jobs."""
    if raw in (None, {}):
        return []
    if not isinstance(raw, Mapping):
        raise PrebuildConfigError("x-marina.prebuild must be a mapping")

    configured = config.get("services")
    services = configured if isinstance(configured, Mapping) else {}
    target_set = set(targets)
    legacy_targets: dict[str, list[str]] = {}
    for name in targets:
        service = services.get(name)
        if not isinstance(service, Mapping):
            continue
        subrepo = _legacy_subrepo(service.get("build"), root)
        legacy_targets.setdefault(subrepo, []).append(name)

    planned: list[PrebuildJob] = []
    for raw_key, value in raw.items():
        key = str(raw_key)
        if isinstance(value, str):
            command = value.strip()
            if command and key in legacy_targets:
                external = root / ".workspace" / "external" / key
                cwd = f".workspace/external/{key}" if external.is_dir() else key
                _inside_root(root, cwd)
                planned.append(
                    PrebuildJob(
                        "",
                        tuple(sorted(legacy_targets[key])),
                        cwd,
                        command,
                        key,
                        True,
                    )
                )
            continue

        if not isinstance(value, Mapping):
            raise PrebuildConfigError(
                f"prebuild.{key} must be a command string or {{cwd, command}} mapping"
            )
        if key not in services:
            raise PrebuildConfigError(
                f"prebuild service is not defined by Compose: {key}"
            )
        if set(value) != {"cwd", "command"}:
            raise PrebuildConfigError(
                f"prebuild.{key} requires exactly cwd and command"
            )
        cwd = str(value.get("cwd") or "").strip()
        command = str(value.get("command") or "").strip()
        if not cwd or not command:
            raise PrebuildConfigError(
                f"prebuild.{key} requires non-empty cwd and command"
            )
        if key in target_set:
            _inside_root(root, cwd)
            planned.append(
                PrebuildJob("", (key,), cwd, command, _java_key(cwd), False)
            )

    deduped: list[PrebuildJob] = []
    by_identity: dict[tuple[str, str], int] = {}
    for job in planned:
        identity = (str((root / job.cwd).resolve()), job.command)
        existing = by_identity.get(identity)
        if existing is not None:
            current = deduped[existing]
            deduped[existing] = replace(
                current,
                services=tuple(sorted(set(current.services + job.services))),
            )
            continue
        by_identity[identity] = len(deduped)
        deduped.append(job)

    return [
        replace(job, id=f"prebuild-{index}")
        for index, job in enumerate(deduped, 1)
    ]


def _event(
    job: PrebuildJob,
    status: str,
    duration: float | None = None,
    exit_code: int | None = None,
) -> None:
    payload: dict[str, Any] = {
        "id": job.id,
        "services": list(job.services),
        "cwd": job.cwd,
        "command": job.command if status == "started" else "",
        "status": status,
    }
    if duration is not None:
        payload["durationSec"] = round(duration, 3)
    if exit_code is not None:
        payload["exitCode"] = exit_code
    print(
        EVENT_PREFIX + json.dumps(payload, ensure_ascii=False, sort_keys=True),
        flush=True,
    )


def run_prebuild_jobs(
    jobs: Sequence[PrebuildJob],
    root: Path,
    environ: Mapping[str, str],
) -> int:
    """Run planned jobs serially and stop on the first non-zero command."""
    try:
        java_homes = json.loads(environ.get("MARINA_JAVA_HOMES", "{}") or "{}")
    except (TypeError, ValueError):
        java_homes = {}
    if not isinstance(java_homes, dict):
        java_homes = {}

    for job in jobs:
        env = dict(environ)
        java_home = java_homes.get(job.java_key) or java_homes.get("default")
        if java_home:
            env["JAVA_HOME"] = str(java_home)
        _event(job, "started")
        started = time.monotonic()
        try:
            result = subprocess.run(
                ["bash", "-c", job.command],
                cwd=root / job.cwd,
                env=env,
                check=False,
            )
            exit_code = result.returncode
        except OSError as exc:
            print(f"prebuild execution failed: {exc}", file=sys.stderr)
            exit_code = 127
        elapsed = time.monotonic() - started
        _event(job, "success" if exit_code == 0 else "failed", elapsed, exit_code)
        if exit_code:
            return exit_code
    return 0
