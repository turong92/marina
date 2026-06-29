"""marina_cli.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
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

from marina_state import MARINA_SCRIPT
from marina_registry import external_repos_for, source_root_for, subrepos_of

def script(root: Path) -> Path:
    # 런처는 이 레포의 전역 marina.sh — worktree 위치와 무관 (구 SCRIPT_REL = 워크스페이스 내부 사본 탐색 제거).
    return MARINA_SCRIPT

def marina_env(root: Path, ignore_overrides: bool = False) -> dict[str, str]:
    source = source_root_for(root)
    env = {**os.environ, "ROOT": str(root)}
    if source != root:
        env["SOURCE_ROOT"] = str(source)
    # 전역 런처에 프로젝트 서브레포를 전달 (marina.sh 가 하드코딩 대신 받아 쓴다)
    env["MARINA_SUBREPOS"] = " ".join(subrepos_of(root))
    env["MARINA_EXTERNAL_REPOS"] = "\n".join(f"{e['name']}={e['source']}" for e in external_repos_for(root))
    if ignore_overrides:
        env["MARINA_IGNORE_PORT_OVERRIDES"] = "1"
    return env

def run_text(args: list[str], cwd: Path) -> str:
    return subprocess.check_output(args, cwd=str(cwd), text=True, stderr=subprocess.STDOUT)

def run_marina(root: Path, *args: str, ignore_overrides: bool = False) -> str:
    return subprocess.check_output(
        [str(script(root)), *args],
        cwd=str(root),
        text=True,
        stderr=subprocess.STDOUT,
        env=marina_env(root, ignore_overrides=ignore_overrides),
    )

def run_marina_registry(*args: str) -> str:
    # 레지스트리 CLI(add/infer/rm)는 위치 무관 — worktree ROOT/MARINA_SUBREPOS env 없이 전역 런처 호출.
    return subprocess.check_output(
        [str(MARINA_SCRIPT), *args],
        text=True,
        stderr=subprocess.STDOUT,
    )

def _marina_cli(root: Path, *args: str, timeout: float = 120) -> str:
    return subprocess.check_output(
        [str(script(root)), *args], cwd=str(root), text=True,
        stderr=subprocess.STDOUT, env=marina_env(root), timeout=timeout,
    )
