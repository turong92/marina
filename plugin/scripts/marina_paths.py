"""marina_paths.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
from __future__ import annotations
import fcntl
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
import importlib.util as _ilu

from marina_state import CONFIG_DEFAULTS, _env, _session_id_cache
from marina_registry import is_source_checkout, project_for

_log_allocation_lock = threading.Lock()

def session_id(root: Path) -> str:
    # marina.sh session_id() 와 동일 규칙. codex 레이아웃은 <id>/<projectBasename> → 부모명,
    # claude 레이아웃은 .claude/worktrees/<name> 그 자체가 루트 → 자신명.
    # (dirname 일괄 적용이면 claude worktree 가 전부 "worktrees" 로 뭉개진다)
    key = str(root)
    if key not in _session_id_cache:
        if is_source_checkout(root):
            sid = "main"
        else:
            project = project_for(root)
            if project and root.name == project["root"].name:
                sid = root.parent.name  # codex <id>/<projectBasename>
            else:
                sid = root.name  # claude .claude/worktrees/<name>
        _session_id_cache[key] = sid
    return _session_id_cache[key]

def session_dir(root: Path) -> Path:
    # marina 우선, 구 dev-sessions 폴백 — 기존 worktree 세션 데이터(alias·overrides·로그) 보존.
    # 1회 mv 마이그레이션은 루트 marina.sh 진입점에서만 수행한다 (bash session_data_dir 와 동일 규칙).
    base = root / ".workspace" / "marina"
    if not base.is_dir() and (root / ".workspace" / "dev-sessions").is_dir():
        base = root / ".workspace" / "dev-sessions"
    return base / session_id(root)

def config_path(root: Path) -> Path:
    return session_dir(root) / "overrides.env"

def meta_path(root: Path) -> Path:
    return session_dir(root) / "meta.json"

def read_meta(root: Path) -> dict[str, str]:
    try:
        data = json.loads(meta_path(root).read_text(encoding="utf-8"))
    except Exception:
        return {"alias": ""}
    alias = str(data.get("alias", "")).strip()
    return {"alias": alias}

def write_meta(root: Path, updates: dict[str, str]) -> dict[str, str]:
    meta = read_meta(root)
    if "alias" in updates:
        meta["alias"] = updates["alias"].strip()[:40]
    path = meta_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return meta

def read_config(root: Path) -> dict[str, str]:
    config = dict(CONFIG_DEFAULTS)
    try:
        lines = config_path(root).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return config

    for line in lines:
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in config:
            config[key] = value
    return config

def write_config(root: Path, updates: dict[str, str]) -> dict[str, str]:
    config = read_config(root)
    for key, value in updates.items():
        if key not in config:
            raise ValueError(f"unknown config key: {key}")
        config[key] = value.strip()

    path = config_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{key}={value}\n" for key, value in sorted(config.items())), encoding="utf-8")
    return config

def log_dir(root: Path, service: str) -> Path:
    return session_dir(root) / "logs" / service

def service_log(root: Path, service: str) -> Path:
    return session_dir(root) / f"{service}.log"

def log_runs(root: Path, service: str) -> list[Path]:
    return sorted(log_dir(root, service).glob("run-*.log"), reverse=True)

def log_run_payload(root: Path, service: str) -> list[dict[str, str]]:
    runs = []
    current = service_log(root, service)
    try:
        current_target = current.resolve()
    except FileNotFoundError:
        current_target = None

    for path in log_runs(root, service):
        label = path.stem
        if current_target and path.resolve() == current_target:
            label = f"{label} (current)"
        try:
            stat = path.stat()
            kb = stat.st_size // 1024
            size_text = f"{kb / 1024:.1f}MB" if kb >= 1024 else f"{kb}KB"
            stamp = time.strftime("%m/%d %H:%M", time.localtime(stat.st_mtime))
            label = f"{label} · {stamp} · {size_text}"
        except OSError:
            pass
        runs.append({"id": path.name, "label": label})
    return runs

def next_log_path(root: Path, service: str) -> Path:
    directory = log_dir(root, service)
    directory.mkdir(parents=True, exist_ok=True)
    seq_path = session_dir(root) / f"{service}.seq"
    lock_path = seq_path.with_suffix(seq_path.suffix + ".lock")
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.chmod(lock_path, 0o600)
        with _log_allocation_lock:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            try:
                try:
                    seq = int(seq_path.read_text().strip())
                except Exception:
                    seq = 0
                while True:
                    seq += 1
                    path = directory / f"run-{seq:03d}.log"
                    try:
                        path.touch(exist_ok=False)
                        break
                    except FileExistsError:
                        continue
                seq_tmp = seq_path.with_name(f".{seq_path.name}.{os.getpid()}.{time.time_ns()}")
                try:
                    seq_tmp.write_text(f"{seq:03d}\n", encoding="utf-8")
                    os.replace(seq_tmp, seq_path)
                finally:
                    seq_tmp.unlink(missing_ok=True)

                current = service_log(root, service)
                current_tmp = current.with_name(f".{current.name}.{os.getpid()}.{time.time_ns()}")
                try:
                    current_tmp.symlink_to(path)
                    os.replace(current_tmp, current)
                finally:
                    current_tmp.unlink(missing_ok=True)

                keep = int(_env("LOG_KEEP", "10"))
                if keep > 0:
                    # 사전순은 run-1000 < run-999 로 역전 → 숫자 키 정렬
                    def run_seq(p: Path) -> int:
                        match = re.search(r"run-(\d+)\.log", p.name)
                        return int(match.group(1)) if match else 0

                    for old in sorted(directory.glob("run-*.log"), key=run_seq)[:-keep]:
                        if old != path:
                            old.unlink(missing_ok=True)
                            old.with_suffix(".meta.json").unlink(missing_ok=True)
                return path
            finally:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
    finally:
        os.close(lock_fd)

def ensure_current_log(root: Path, service: str) -> Path:
    current = service_log(root, service)
    if current.exists():
        return current
    return next_log_path(root, service)

def selected_log(root: Path, service: str, run: str | None) -> Path:
    if not run or run == "current":
        return ensure_current_log(root, service)
    if not re.fullmatch(r"run-\d{3}\.log", run):
        raise ValueError("unknown log run")
    path = log_dir(root, service) / run
    if not path.is_file():
        raise ValueError("unknown log run")
    return path

def pid_file(root: Path, service: str) -> Path:
    return session_dir(root) / f"{service}.pid"
