"""marina_cache.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
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

def cache_paths_by_category(root: Path) -> dict[str, list[Path]]:
    return {}

def cache_category_mb(root: Path) -> dict[str, int]:
    return {
        category: sum(disk_usage_mb(path) or 0 for path in paths)
        for category, paths in cache_paths_by_category(root).items()
    }
