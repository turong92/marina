"""marina_state.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
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

def _env(name: str, default: str) -> str:
    return os.environ.get(f"MARINA_{name}", default)

HOST = _env("CONTROL_HOST", "localhost")

PORT = int(_env("CONTROL_PORT", "3900"))

WORKTREES_ROOT = Path(os.environ.get("CODEX_WORKTREES_ROOT", str(Path.home() / ".codex" / "worktrees")))

CONTROL_SCRIPT = Path(__file__).resolve()

# 런처·attach 스크립트는 이 파일의 형제 — 위치독립(어느 프로젝트의 worktree 든 이 전역 스크립트를 쓴다).
MARINA_SCRIPT = CONTROL_SCRIPT.parent / "marina.sh"

MARINA_ATTACH = CONTROL_SCRIPT.parent / "attach-detached-subrepos.sh"

# 글로벌 프로젝트 레지스트리 — 한 데몬이 등록된 모든 프로젝트의 worktree 를 관리 (marina-standardization)
MARINA_HOME = Path(os.environ.get("MARINA_HOME", str(Path.home() / ".marina")))

PROJECTS_FILE = MARINA_HOME / "projects.json"

_MC = None

def _mc():
    """marina-compose.py 순수 함수 재사용 (compose_project_name) — CLI 와 동일 -p 이름 보장."""
    global _MC
    if _MC is None:
        spec = _ilu.spec_from_file_location("marina_compose", str(CONTROL_SCRIPT.parent / "marina-compose.py"))
        mod = _ilu.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _MC = mod
    return _MC

_GW = None

def _gw():
    """marina-gateway.py 순수 함수 재사용 (build_caddyfile·apply·caddy_bin) — 호스트 브라우저 게이트웨이."""
    global _GW
    if _GW is None:
        spec = _ilu.spec_from_file_location("marina_gateway", str(CONTROL_SCRIPT.parent / "marina-gateway.py"))
        mod = _ilu.module_from_spec(spec); spec.loader.exec_module(mod); _GW = mod
    return _GW

_GATEWAY_ON = _env("GATEWAY", "on") not in ("0", "off", "false")     # MARINA_GATEWAY — 기본 on(서비스 start 시 자동 기동). off/0/false 로 명시 비활성

_GATEWAY_PORT = int(_env("GATEWAY_PORT", "3902") or "3902")          # MARINA_GATEWAY_PORT — 기본 3902(비특권: 권한·:80충돌 회피, 대시보드3900·프리뷰3901 위). 미지정 시 위로 빈 포트 fallback

_GATEWAY_STATE = str(MARINA_HOME / "gateway" / "Caddyfile")

# 하네스 config·플러그인 매니페스트 위치 (업데이트 알림용). CLAUDE_CONFIG_DIR 는 marina-resolve 와 동일 규칙.
CLAUDE_CONFIG_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))

CODEX_HOME = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))

MARKETPLACE = "marina-dev"

PLUGIN_ID = "marina@marina-dev"

# 발견·상태 저수준 폴백 — 미등록 root 의 서브레포 (없음; 레지스트리가 권위)
_DEFAULT_SUBREPOS: tuple[str, ...] = ()

LOG_TAIL_BYTES = 64 * 1024   # SSE 초기 표시 분량 — 이전 내용은 /api/logs/chunk 페이징

LOG_CHUNK_BYTES = 64 * 1024  # "이전 더 보기" 1회 분량

_projects_cache: list[dict[str, Any]] = []

# compose-only daemon에는 세션별 editable config 기본값이 없다.
CONFIG_DEFAULTS: dict[str, str] = {}

def json_bytes(payload: Any) -> bytes:
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")

_origin_cache: dict[str, Any] = {}

def _bin(name: str) -> str:
    # launchd 데몬의 최소 PATH(/usr/bin:/bin)엔 ~/.local/bin·/opt/homebrew/bin 등이 없어 CLI 를 못 찾음
    # (Errno 2 No such file or directory). PATH 우선 조회 후, 없으면 흔한 설치 위치를 보강해 절대경로로 해석.
    found = shutil.which(name)
    if found:
        return found
    home = Path.home()
    for d in (home / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin"),
              home / ".claude/local", home / ".bun/bin", home / ".volta/bin"):
        cand = d / name
        if cand.exists():
            return str(cand)
    return name

_root_sources: dict[str, str] = {}

_roots_cache: list[tuple[float, list[Path]]] = []

_session_id_cache: dict[str, str] = {}

_source_root_cache: dict[str, Path] = {}

def invalidate_registry_caches() -> None:
    # 레지스트리 변경(add/rm) 후 파생 캐시 무효화 — 다음 폴링/요청이 projects.json 을 재로드.
    _projects_cache.clear()
    _roots_cache.clear()
    _root_sources.clear()
    _source_root_cache.clear()
    _session_id_cache.clear()
    _worktree_info_cache.clear()

_total_mem_mb_cache: list[int] = []

_status_cache: dict[str, tuple[float, dict[str, Any]]] = {}

_SUBREPO_MAP_CACHE: dict = {}   # str(stored compose path) → (mtime, submap{service:subrepo}, buildPaths{service:dfpath}) — 폴링마다 config 안 돌게(degraded 존재판정은 매 poll)

_worktree_info_cache: dict[str, tuple[float, dict[str, Any]]] = {}

_session_titles_cache: tuple[float, dict[str, dict[str, str]]] = (0.0, {})

_codex_titles_cache: tuple[float, dict[str, str]] = (0.0, {})
