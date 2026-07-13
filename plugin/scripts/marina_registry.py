"""marina_registry.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
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

from marina_state import PROJECTS_FILE, WORKTREES_ROOT, _DEFAULT_SUBREPOS, _projects_cache, _root_sources, _roots_cache, _session_id_cache, _source_root_cache

def _registered_roots() -> list[Path]:
    # 레지스트리에 등록된 프로젝트 root 들. import 시점(load_projects 정의 전)에도 쓰이므로 파일 직접 읽기.
    try:
        data = json.loads(PROJECTS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return []
    roots: list[Path] = []
    for entry in data.get("projects", []):
        try:
            roots.append(Path(str(entry["root"])).expanduser())
        except Exception:
            continue
    return roots

def _git_main_checkout(root: Path) -> Path | None:
    # worktree → 원본(main) 체크아웃을 git 토폴로지로 역추적. 레지스트리에 없는 root 의 폴백.
    # (worktree → 원본 체크아웃을 git common-dir 토폴로지로 역추적)
    if is_source_checkout(root):
        return root
    for repo in subrepos_of(root):
        repo_path = root / repo
        if not (repo_path / ".git").exists():
            continue
        try:
            common = subprocess.check_output(
                ["git", "-C", str(repo_path), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()
        except Exception:
            continue
        if common:
            candidate = Path(common).parent.parent  # <main>/<repo>/.git → <main>
            if candidate.is_dir():
                return candidate
    try:
        common = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        common = ""
    if common:
        candidate = Path(common).parent  # <main>/.git → <main>
        if candidate.is_dir():
            return candidate
    return None

def load_projects() -> list[dict[str, Any]]:
    # ~/.marina/projects.json — 명시 등록(marina project add)된 프로젝트만 읽는다.
    # 비면 빈 목록(대시보드 빈 상태) — 현재 체크아웃을 추측하지 않는다(명시 등록 marina project add 필요).
    if _projects_cache:
        return _projects_cache
    items: list[dict[str, Any]] = []
    try:
        data = json.loads(PROJECTS_FILE.read_text(encoding="utf-8"))
        for entry in data.get("projects", []):
            # resolve — 발견 경로와 매칭 일관성 (심볼릭링크·~)
            root = Path(str(entry["root"])).expanduser().resolve()
            _da = entry.get("defaultAttach")
            items.append({
                "id": str(entry.get("id") or root.name),
                "root": root,
                "subrepos": [str(s) for s in entry.get("subrepos", [])],
                "defaultAttach": [str(s) for s in _da] if isinstance(_da, list) else None,
                "worktreeGlobs": [str(g) for g in entry.get("worktreeGlobs", [])],
                "kind": str(entry.get("kind") or "compose"),
                "composeFile": str(entry.get("composeFile") or "docker-compose.yml"),
                "composeEnvVar": str(entry.get("composeEnvVar") or ""),
                "composeEnvDefault": str(entry.get("composeEnvDefault") or "local"),
                "externalRepos": [{"name": str(e.get("name") or ""), "source": str(e.get("source") or "")}
                                  for e in (entry.get("externalRepos") or [])
                                  if isinstance(e, dict) and e.get("name") and e.get("source")],
            })
    except Exception:
        items = []
    _projects_cache[:] = items
    return items

def project_for(root: Path) -> dict[str, Any] | None:
    # root 가 어느 프로젝트 소속인지 — 프로젝트 root 자신/하위(claude worktree),
    # 또는 codex 레이아웃(<worktrees>/<id>/<basename>) 한정 basename 일치. 단일 등록이면 항상 그 프로젝트.
    projects = load_projects()
    if not projects:
        return None
    try:
        rroot = root.resolve()
    except OSError:
        rroot = root
    best = None
    best_len = -1
    for project in projects:
        proot = project["root"].resolve()
        sproot = str(proot)
        if rroot == proot or str(rroot).startswith(sproot + os.sep):
            if len(sproot) > best_len:
                best, best_len = project, len(sproot)
    if best is not None:
        return best
    # codex 레이아웃(<worktrees>/<id>/<basename>) 한정 basename 매치 — 동일 basename 다중 프로젝트 충돌 방지
    try:
        in_codex_layout = rroot.parent.parent == WORKTREES_ROOT.resolve()
    except (OSError, ValueError):
        in_codex_layout = False
    if in_codex_layout:
        for project in projects:
            if root.name == project["root"].name:
                return project
    return projects[0] if len(projects) == 1 else None

def containing_project_for(root: Path) -> dict[str, Any] | None:
    """root 를 실제로 포함하는 프로젝트만 — project_for 의 '단일 등록이면 무조건 그 프로젝트' 폴백 제외.
    등록 가드(compose-register/import 의 워크트리 승격)용: 폴백 포함 판정을 쓰면 프로젝트가 1개일 때
    무관한 새 레포 등록이 기존 프로젝트로 흡수된다."""
    projects = load_projects()
    if not projects:
        return None
    try:
        rroot = root.resolve()
    except OSError:
        rroot = root
    best = None
    best_len = -1
    for project in projects:
        proot = project["root"].resolve()
        sproot = str(proot)
        if rroot == proot or str(rroot).startswith(sproot + os.sep):
            if len(sproot) > best_len:
                best, best_len = project, len(sproot)
    if best is not None:
        return best
    try:
        in_codex_layout = rroot.parent.parent == WORKTREES_ROOT.resolve()
    except (OSError, ValueError):
        in_codex_layout = False
    if in_codex_layout:
        for project in projects:
            if root.name == project["root"].name:
                return project
    return None

def subrepos_of(root: Path) -> list[str]:
    project = project_for(root)
    return list(project["subrepos"]) if project else list(_DEFAULT_SUBREPOS)

def external_repos_for(root: Path) -> list:
    """프로젝트의 외부 레포 [{name, source}] — attach 가 워크트리마다 git worktree 로 격리."""
    project = project_for(root)
    return list(project.get("externalRepos") or []) if project else []

def default_attach_of(root: Path) -> list[str] | None:
    # 전체 기본 attach 집합 (명시값). 부재 시 None → 호출부가 "전체 universe" 로 해석 (backward compatible).
    project = project_for(root)
    if not project:
        return None
    da = project.get("defaultAttach")
    return [str(s) for s in da] if isinstance(da, list) else None

def project_label(root: Path) -> str:
    # 루트 레포 라벨 — 소속 프로젝트 root basename.
    project = project_for(root)
    return project["root"].name if project else root.name

def _expand_worktree_glob(project_root: Path, pattern: str) -> list[Path]:
    # worktreeGlobs 항목 전개. 절대(~ 포함)면 그대로, 상대면 프로젝트 root 기준.
    pat = os.path.expanduser(pattern)
    if not os.path.isabs(pat):
        pat = str(project_root / pat)
    return [Path(p) for p in glob.glob(pat)]

def _glob_source(pattern: str) -> str:
    # 카드 라벨용 출처 태그 — codex 레이아웃(~/.codex/worktrees/...)인지로 구분.
    return "codex" if ".codex" in pattern else "claude"

DISCOVER_TTL = 60.0

def discover_all_roots(refresh: bool = False) -> list[Path]:
    # 전수 목록 — worktree 정리 패널·safe_root 용. 등록된 모든 프로젝트 × worktreeGlobs 를 전개.
    # 폴링 틱마다 glob+resolve 를 돌리지 않게 60s 캐시 (새 worktree 는 최대 60s 늦게 보임 — Refresh 가 즉시 무효화)
    # clear()(remove 경로)와의 경합 대비 — 길이 체크와 인덱스 접근 사이가 안 벌어지게 슬라이스 스냅샷
    snapshot = _roots_cache[:]
    if not refresh and snapshot and time.time() - snapshot[0][0] < DISCOVER_TTL:
        return snapshot[0][1]
    if refresh:
        # 명시 Refresh — 레지스트리(projects.json)와 파생 캐시도 재로드 (marina project add 후 즉시 반영)
        _projects_cache.clear()
        _source_root_cache.clear()
        _session_id_cache.clear()
    roots: list[Path] = []
    seen: set[Path] = set()
    sources: dict[str, str] = {}
    for project in load_projects():
        proot = project["root"]
        try:
            rproot = proot.resolve()
        except OSError:
            rproot = proot
        if rproot not in seen and rproot.is_dir():
            roots.append(rproot)
            seen.add(rproot)
            sources[str(rproot)] = "main"
        for pattern in project["worktreeGlobs"]:
            src = _glob_source(pattern)
            for match in _expand_worktree_glob(proot, pattern):
                try:
                    resolved = match.resolve()
                except OSError:
                    continue
                if resolved in seen or not resolved.is_dir():
                    continue
                # worktree 후보는 .git 존재만 확인 (옛 fork 도 정리 대상으로 보이게)
                if not (resolved / ".git").exists():
                    continue
                roots.append(resolved)
                seen.add(resolved)
                sources[str(resolved)] = src
    # ThreadingHTTPServer 동시 요청 대비: 로컬에서 채운 뒤 한 번에 교체
    _root_sources.update(sources)
    _roots_cache[:] = [(time.time(), roots)]
    return roots

def root_source(root: Path) -> str:
    return _root_sources.get(str(root), "unknown")

def has_attached_subrepos(root: Path) -> bool:
    # 디렉토리만 있고 .git 링크가 없는 attach 중간 상태는 미attach 로 본다
    return any((root / repo / ".git").exists() for repo in subrepos_of(root))

def discover_roots() -> list[Path]:
    # 세션(관제) 목록 = 전수. 과거엔 claude 수십 개의 폴링 부담 때문에 "활성화된 것만"
    # 2계층으로 나눴지만, listener map 단일화·status 캐시로 틱이 충분히 싸져 통합 (카드는 기본 접힘).
    return discover_all_roots()

def is_source_checkout(root: Path) -> bool:
    # 원본(main) 체크아웃 판정. 레지스트리 우선 — root 가 등록된 프로젝트 root 자신이면 main.
    # (단일/모노레포 subrepos=[] 도 커버 — fs 판정만이면 서브레포 없는 프로젝트의 main 을 놓침)
    # 미등록 root 는 서브레포 .git 디렉토리(실제 레포 vs worktree 의 gitdir 파일)로 폴백.
    project = project_for(root)
    if project:
        try:
            return project["root"].resolve() == root.resolve()
        except OSError:
            return project["root"] == root
    return any((root / repo / ".git").is_dir() for repo in subrepos_of(root))

def source_root_for(root: Path) -> Path:
    # 이 worktree 가 속한 프로젝트의 원본(main) 체크아웃. 레지스트리 우선, git 토폴로지 폴백.
    key = str(root)
    cached = _source_root_cache.get(key)
    if cached is None:
        project = project_for(root)
        cached = project["root"] if project else (_git_main_checkout(root) or root)
        _source_root_cache[key] = cached
    return cached
