"""Secret-safe snapshots for explaining why a Marina build input changed."""
from __future__ import annotations

import fcntl
import hashlib
import hmac
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any


def _label(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except (OSError, ValueError):
        return path.name


def _path_digest(path: Path) -> str:
    if not path.exists():
        return "missing"
    digest = hashlib.sha256()
    if path.is_file():
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return "file:" + digest.hexdigest()
    if not path.is_dir():
        return "other"
    for directory, dirnames, filenames in os.walk(path):
        dirnames.sort()
        for filename in sorted(filenames):
            item = Path(directory) / filename
            try:
                stat = item.stat()
                rel = item.relative_to(path).as_posix()
                digest.update(f"{rel}\0{stat.st_size}\0{stat.st_mtime_ns}\n".encode())
            except OSError:
                continue
    return "dir:" + digest.hexdigest()


def _arg_digest(key: bytes, value: Any) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hmac.new(key, payload.encode("utf-8"), hashlib.sha256).hexdigest()


def _absolute(root: Path, value: str | os.PathLike[str]) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def build_input_snapshot(
    root: Path,
    config: dict[str, Any],
    selected: list[str],
    extra_build_args: dict[str, dict[str, Any]],
    key: bytes,
) -> dict[str, Any]:
    root = Path(root).resolve()
    services = config.get("services") or {}
    names = selected
    result: dict[str, Any] = {"version": 1, "status": "ok", "services": {}}
    for name in names:
        service = services.get(name)
        if not isinstance(service, dict):
            continue
        build = service.get("build")
        if not isinstance(build, dict):
            continue
        context = _absolute(root, str(build.get("context") or "."))
        dockerfile = _absolute(context, str(build.get("dockerfile") or "Dockerfile"))
        dockerfiles = {_label(root, dockerfile): _path_digest(dockerfile)}
        rebuild: dict[str, str] = {}
        develop = service.get("develop") or {}
        watch = develop.get("watch") if isinstance(develop, dict) else []
        for rule in watch if isinstance(watch, list) else []:
            if not isinstance(rule, dict) or rule.get("action") != "rebuild" or not rule.get("path"):
                continue
            path = _absolute(root, str(rule["path"]))
            if path.resolve() == dockerfile.resolve():
                continue
            rebuild[_label(root, path)] = _path_digest(path)
        args = dict(build.get("args") or {}) if isinstance(build.get("args"), dict) else {}
        local_args = extra_build_args.get(name) or {}
        if isinstance(local_args, dict):
            args.update(local_args)
        result["services"][name] = {
            "dockerfile": dockerfiles,
            "rebuild": rebuild,
            "buildArgs": {str(arg): _arg_digest(key, value) for arg, value in sorted(args.items())},
        }
    return result


def compare_build_inputs(
    current: dict[str, Any],
    previous: dict[str, Any] | None,
    op: str,
) -> list[dict[str, str]]:
    if current.get("status") == "pending":
        return []
    if current.get("status") != "ok":
        return [{
            "kind": "unknown",
            "service": "",
            "label": "build 입력 수집 실패",
            "change": "unknown",
        }]
    current_services = current.get("services") or {}
    if not current_services:
        return []
    if not previous or previous.get("status") != "ok":
        return [{
            "kind": "first-run",
            "service": "",
            "label": "이전 build 입력 기록 없음",
            "change": "unknown",
        }]
    reasons: list[dict[str, str]] = []
    previous_services = previous.get("services") or {}
    for service in sorted(current_services):
        now = current_services.get(service) or {}
        if service not in previous_services:
            reasons.append({
                "kind": "first-run",
                "service": service,
                "label": "서비스 이전 build 입력 기록 없음",
                "change": "unknown",
            })
            continue
        before = previous_services.get(service) or {}
        for field, kind in (
            ("dockerfile", "dockerfile"),
            ("rebuild", "rebuild-input"),
            ("buildArgs", "build-arg"),
        ):
            now_values = now.get(field) or {}
            old_values = before.get(field) or {}
            for label in sorted(set(now_values) | set(old_values)):
                if label not in old_values:
                    change = "added"
                elif label not in now_values:
                    change = "removed"
                elif now_values[label] != old_values[label]:
                    change = "changed"
                else:
                    continue
                reasons.append({
                    "kind": kind,
                    "service": service,
                    "label": label,
                    "change": change,
                })
    if not reasons and op == "rebuild":
        reasons.append({
            "kind": "explicit-rebuild",
            "service": "",
            "label": "사용자가 Rebuild 실행",
            "change": "requested",
        })
    return reasons


def _load_key(home: Path) -> bytes:
    home.mkdir(parents=True, exist_ok=True)
    path = home / "build-input.key"
    lock_path = home / "build-input.key.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        try:
            key = path.read_bytes()
            if len(key) >= 32:
                os.chmod(path, 0o600)
                return key
        except OSError:
            pass
        key = os.urandom(32)
        fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(home))
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as handle:
                handle.write(key)
            os.replace(tmp, path)
            os.chmod(path, 0o600)
        finally:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
        return key
    finally:
        os.close(lock_fd)


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _env_file_args(root: Path, source: Path, mapping: Any) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    if not isinstance(mapping, dict):
        return result
    for service, rel in mapping.items():
        if not service or not isinstance(rel, str) or not rel.strip():
            continue
        path = next((base / rel for base in (root, source) if (base / rel).is_file()), None)
        if path is None:
            continue
        values: dict[str, str] = {}
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            if text.startswith("export "):
                text = text[7:].strip()
            name, separator, value = text.partition("=")
            name = name.strip()
            value = value.strip().strip('"').strip("'")
            if separator and name and not value.startswith("$"):
                values[name] = value
        if values:
            result[str(service)] = values
    return result


def capture_build_inputs(root: Path, args: tuple[str, ...], env: dict[str, str]) -> dict[str, Any]:
    """Resolve the same project Compose inputs used by a dashboard lifecycle run."""
    from marina_registry import project_for, source_root_for
    from marina_state import MARINA_HOME, _bin, _mc

    root = Path(root).resolve()
    project = project_for(root)
    if not project:
        raise ValueError("registered project not found")
    project_id = str(project["id"])
    stored = MARINA_HOME / project_id / project.get("composeFile", "docker-compose.yml")
    compose_env = dict(env)
    env_name = str(project.get("composeEnvVar") or "")
    if env_name:
        compose_env[env_name] = env.get("MARINA_COMPOSE_ENV", str(project.get("composeEnvDefault") or "local"))
    proc = subprocess.run(
        [_bin("docker"), "compose", "-f", str(stored), "--project-directory", str(root),
         "config", "--format", "json"],
        capture_output=True,
        text=True,
        env=compose_env,
        timeout=15,
    )
    if proc.returncode != 0:
        raise ValueError((proc.stderr or proc.stdout or "docker compose config failed")[:500])
    config = json.loads(proc.stdout)
    mc = _mc()
    xmarina = mc.xmarina_for_stored(str(stored))
    requested = [token[2:] for token in args[1:] if token.startswith("--") and token != "--all"]
    selected, _skipped, _unknown = mc.resolved_start_targets(config, xmarina, requested)
    local_args = _read_json(MARINA_HOME / project_id / "build-args.json")
    source = source_root_for(root).resolve()
    for service, values in _env_file_args(root, source, xmarina.get("buildArgsFrom")).items():
        existing = local_args.setdefault(service, {})
        if isinstance(existing, dict):
            existing.update(values)
    return build_input_snapshot(root, config, selected, local_args, _load_key(MARINA_HOME))
