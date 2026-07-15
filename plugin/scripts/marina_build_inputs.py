"""Secret-safe snapshots for explaining why a Marina build input changed."""
from __future__ import annotations

import fcntl
import hashlib
import hmac
import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any


def _label(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except (OSError, ValueError):
        return path.name


def _is_ignored(path: Path, ignored_paths: tuple[Path, ...]) -> bool:
    try:
        resolved = path.resolve()
    except OSError:
        resolved = path.absolute()
    for ignored in ignored_paths:
        try:
            resolved.relative_to(ignored)
            return True
        except ValueError:
            continue
    return False


def _path_digest(path: Path, ignored_paths: tuple[Path, ...] = ()) -> str:
    if _is_ignored(path, ignored_paths):
        return "ignored"
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
        directory_path = Path(directory)
        relative_directory = directory_path.relative_to(path).as_posix()
        digest.update(f"d\0{relative_directory}\n".encode())
        dirnames[:] = sorted(
            name for name in dirnames
            if not _is_ignored(directory_path / name, ignored_paths)
        )
        for filename in sorted(filenames):
            item = directory_path / filename
            if _is_ignored(item, ignored_paths):
                continue
            item_stat = item.lstat()
            rel = item.relative_to(path).as_posix()
            mode = stat.S_IMODE(item_stat.st_mode)
            if stat.S_ISLNK(item_stat.st_mode):
                digest.update(f"l\0{rel}\0{mode:o}\0{os.readlink(item)}\n".encode())
            elif stat.S_ISREG(item_stat.st_mode):
                digest.update(f"f\0{rel}\0{mode:o}\0".encode())
                with item.open("rb") as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(chunk)
                digest.update(b"\n")
            else:
                digest.update(f"o\0{rel}\0{item_stat.st_mode:o}\n".encode())
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
    ignored_paths: list[Path] | None = None,
) -> dict[str, Any]:
    root = Path(root).resolve()
    ignored = tuple(Path(path).resolve() for path in (ignored_paths or []))
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
        inline = build.get("dockerfile_inline")
        if inline is not None:
            inline_digest = hashlib.sha256(str(inline).encode("utf-8")).hexdigest()
            dockerfile = None
            dockerfiles = {"<inline>": "inline:" + inline_digest}
        else:
            dockerfile = _absolute(context, str(build.get("dockerfile") or "Dockerfile"))
            dockerfiles = {_label(root, dockerfile): _path_digest(dockerfile, ignored)}
        rebuild: dict[str, str] = {}
        develop = service.get("develop") or {}
        watch = develop.get("watch") if isinstance(develop, dict) else []
        for rule in watch if isinstance(watch, list) else []:
            if not isinstance(rule, dict) or rule.get("action") != "rebuild" or not rule.get("path"):
                continue
            path = _absolute(root, str(rule["path"]))
            if dockerfile is not None and path.resolve() == dockerfile.resolve():
                continue
            rebuild[_label(root, path)] = _path_digest(path, ignored)
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
        if not isinstance(now, dict):
            continue
        if service not in previous_services or not isinstance(previous_services.get(service), dict):
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


def build_decision(
    current: dict[str, Any],
    baseline: dict[str, Any] | None,
    explicit: bool = False,
) -> tuple[bool, list[dict[str, str]]]:
    reasons = compare_build_inputs(current, baseline, "rebuild" if explicit else "start")
    current_services = current.get("services") if isinstance(current.get("services"), dict) else {}
    baseline_services = baseline.get("services") if isinstance(baseline, dict) else {}
    if not isinstance(baseline_services, dict):
        baseline_services = {}
    if current.get("status") == "ok" and baseline and baseline.get("status") == "ok":
        for service in sorted(current_services):
            before = baseline_services.get(service)
            if not isinstance(before, dict):
                continue
            old_image = before.get("image")
            now = current_services.get(service)
            new_image = now.get("image") if isinstance(now, dict) else None
            if not _valid_image_identity(old_image) or new_image != old_image:
                reasons.append({
                    "kind": "image",
                    "service": service,
                    "label": "실제 Docker 이미지",
                    "change": "unverified" if not _valid_image_identity(old_image) else "changed",
                })
    if explicit:
        return True, reasons
    if current.get("status") != "ok" or not current_services:
        return False, reasons
    return bool(reasons), reasons


def _valid_image_identity(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and isinstance(value.get("ref"), str)
        and bool(value["ref"])
        and isinstance(value.get("id"), str)
        and bool(value["id"])
    )


def attach_image_identities(
    snapshot: dict[str, Any],
    identities: dict[str, dict[str, str]],
) -> dict[str, Any]:
    if snapshot.get("status") != "ok" or not isinstance(snapshot.get("services"), dict):
        return snapshot
    services: dict[str, Any] = {}
    for service, inputs in snapshot["services"].items():
        item = dict(inputs) if isinstance(inputs, dict) else inputs
        identity = identities.get(service)
        if isinstance(item, dict) and _valid_image_identity(identity):
            item["image"] = {"ref": identity["ref"], "id": identity["id"]}
        services[service] = item
    return {"version": 1, "status": "ok", "services": services}


def load_build_input_key(home: Path) -> bytes:
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


def write_build_input_snapshot(path: Path, payload: dict[str, Any]) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def read_build_input_snapshot(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"version": 1, "status": "unknown"}
    if (
        not isinstance(value, dict)
        or value.get("version") != 1
        or value.get("status") != "ok"
        or not isinstance(value.get("services"), dict)
    ):
        return {"version": 1, "status": "unknown"}
    for service, inputs in value["services"].items():
        if not isinstance(service, str) or not isinstance(inputs, dict):
            return {"version": 1, "status": "unknown"}
        for field in ("dockerfile", "rebuild", "buildArgs"):
            if not isinstance(inputs.get(field), dict):
                return {"version": 1, "status": "unknown"}
        image = inputs.get("image")
        if image is not None and not _valid_image_identity(image):
            return {"version": 1, "status": "unknown"}
    return {"version": 1, "status": "ok", "services": value["services"]}


def read_build_baseline(path: Path) -> dict[str, Any] | None:
    value = read_build_input_snapshot(path)
    return value if value.get("status") == "ok" else None


def merge_build_baseline(path: Path, current: dict[str, Any]) -> None:
    services = current.get("services")
    if current.get("status") != "ok" or not isinstance(services, dict) or not services:
        return
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        previous = read_build_baseline(path) or {"version": 1, "status": "ok", "services": {}}
        merged = dict(previous["services"])
        merged.update(services)
        write_build_input_snapshot(
            path,
            {"version": 1, "status": "ok", "services": merged},
        )
    finally:
        os.close(lock_fd)
