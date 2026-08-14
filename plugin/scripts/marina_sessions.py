"""marina_sessions.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
from __future__ import annotations
import base64
import glob
import json
import math
import mmap
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
import importlib.util as _ilu

from marina_state import CODEX_HOME, HOST, LIFECYCLE_BUSY, PORT, _claude_agents_all_cache, _claude_agents_cache, _codex_agents_all_cache, _codex_agents_cache, _codex_titles_cache, _env, _session_titles_cache, _status_cache, _total_mem_mb_cache, _worktree_du_cache, _worktree_info_cache, busy_key
from marina_logtext import redact_text
from marina_cache import cache_category_mb, compose_build_image_items, disk_usage_mb, docker_disk_summary
from marina_registry import default_attach_of, discover_all_roots, discover_roots, is_source_checkout, project_for, project_label, root_source, subrepos_of
from marina_paths import ensure_current_log, log_run_payload, read_config, read_meta, service_log, session_dir, session_id
from marina_compose_svc import _compose_services, _log_tail_line, compose_service_names, compose_service_subrepos, missing_env_vars
from marina_memory import enrich_session_memory, memory_snapshot
from marina_agent_events import BLOCKED_REASONS, latest_agent_event
from marina_term import term_list

def git_output(args: list[str], cwd: Path) -> str:
    return subprocess.check_output(["git", *args], cwd=str(cwd), text=True, stderr=subprocess.STDOUT)

def status_lines(repo: Path, ignore_top_level: set[str] | None = None) -> list[str]:
    try:
        output = git_output(["status", "--porcelain", "--untracked-files=all"], repo)
    except Exception as exc:
        return [f"!! git status failed: {exc}"]
    lines: list[str] = []
    for line in output.splitlines():
        path = line[3:] if len(line) > 3 else ""
        top = path.split("/", 1)[0]
        if ignore_top_level and top in ignore_top_level:
            continue
        lines.append(line)
    return lines

def _repo_status_entry(name: str, path: Path, lines: list[str]) -> dict[str, Any]:
    # git status 가 실패(깨진/고아 워크트리 — gitfile dangling 등)하면 status_lines 가 '!! git status failed' 한 줄을 돌려준다.
    # 이건 '미커밋 변경분' 이 아니라 '확인 불가' 다 → dirty 로 세지 않고 broken 으로 구분(폐기할 변경 없음 → 삭제 시 안 겁줌).
    if lines and lines[0].startswith("!! git status failed"):
        return {"name": name, "path": str(path), "broken": True, "dirty": False,
                "changes": ["(git 링크 깨짐 — 고아 워크트리, 폐기할 변경 없음)"],
                "changeCount": 0, "trackedCount": 0, "untrackedCount": 0}
    untracked = sum(1 for ln in lines if ln.startswith("??"))
    # tracked(실제 수정) 와 untracked(주로 .venv·빌드산출물 등 툴링 찌꺼기) 분리 — 칩이 신호/노이즈를 섞지 않게
    return {"name": name, "path": str(path), "broken": False, "dirty": bool(lines),
            "changes": lines[:80], "changeCount": len(lines),
            "trackedCount": len(lines) - untracked, "untrackedCount": untracked}

def compose_scoped_subrepos(root: Path) -> list[str]:
    subs = subrepos_of(root)
    project = project_for(root)
    if not project or project.get("kind", "compose") != "compose":
        return subs
    try:
        used = {name for name in compose_service_subrepos(root, project).values() if name and name != "."}
    except Exception:
        used = set()
    return [repo for repo in subs if repo in used] if used else subs

def worktree_status(root: Path) -> dict[str, Any]:
    repos: list[dict[str, Any]] = []
    all_subrepos = subrepos_of(root)
    scan_subrepos = compose_scoped_subrepos(root)
    repos.append(_repo_status_entry(project_label(root), root, status_lines(root, {*all_subrepos, ".workspace"})))
    for repo in scan_subrepos:
        path = root / repo
        if not path.exists():
            repos.append({"name": repo, "path": str(path), "missing": True, "broken": False,
                          "dirty": False, "changes": [], "changeCount": 0, "trackedCount": 0, "untrackedCount": 0})
            continue
        repos.append(_repo_status_entry(repo, path, status_lines(path)))
    dirty = [item for item in repos if item.get("dirty")]
    return {"clean": not dirty, "broken": any(r.get("broken") for r in repos), "repos": repos}

def system_memory() -> dict[str, Any]:
    info: dict[str, Any] = {"totalMb": None, "freePercent": None, "freeMb": None}
    if not _total_mem_mb_cache:
        try:
            total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True, stderr=subprocess.DEVNULL).strip())
            _total_mem_mb_cache.append(total // (1024 * 1024))
        except Exception:
            return info
    info["totalMb"] = _total_mem_mb_cache[0]
    try:
        output = subprocess.check_output(["memory_pressure", "-Q"], text=True, stderr=subprocess.DEVNULL)
        match = re.search(r"free percentage:\s*(\d+)", output)
        if match:
            info["freePercent"] = int(match.group(1))
            info["freeMb"] = info["totalMb"] * info["freePercent"] // 100
    except Exception:
        pass
    return info

def group_rss_mb(snapshot: list[dict[str, Any]], pids: set[int]) -> int:
    # 추적 pid 들이 속한 프로세스 그룹 전체의 RSS 합 (MB)
    if not pids:
        return 0
    pgids = {row["pgid"] for row in snapshot if row["pid"] in pids}
    total_kb = 0
    for row in snapshot:
        if row["pid"] in pids or row["pgid"] in pgids:
            total_kb += row["rssKb"]
    return total_kb // 1024

def worktree_status_cached(root: Path, ttl: float = 15.0) -> dict[str, Any]:
    # dirty 표시는 5초 신선도가 필요 없다 — git status(레포 4개)를 폴링 핫패스에서 떼어냄.
    # 정확성이 필요한 경로(remove 가드·Changes 조회)는 worktree_status 직접 호출.
    key = str(root)
    cached = _status_cache.get(key)
    if cached and time.time() - cached[0] < ttl:
        return cached[1]
    status = worktree_status(root)
    _status_cache[key] = (time.time(), status)
    return status

def log_targets_for(root: Path) -> tuple[str, ...]:
    project = project_for(root)
    if project and project.get("kind") == "compose":
        return (*compose_service_names(root, project), "console", "build")   # build = 가상 서비스(lifecycle 출력 run — console 선례)
    return ("console", "build")

def svc_state(s: dict):
    """서비스 dict → (state, reason). state ∈ running|starting|error|stopped|external|degraded.
    UI 가 busy/health/external/degraded 불리언 조합을 추측하지 않게 백엔드가 한 곳에서 판정한다(콘솔 스펙 D5·상태모델).
    우선순위: busyError > busy > degraded > external > health(bad→error, starting) > running > stopped."""
    if s.get("busyError"):
        return "error", s["busyError"]
    if s.get("busy"):
        return "starting", None
    if s.get("degraded"):
        return "degraded", s.get("degradedReason") or "Dockerfile 없음"
    if s.get("external"):
        return "external", None
    h = s.get("health")
    if h == "bad":
        return "error", "unhealthy"
    if h == "starting":
        return "starting", None
    if s.get("running"):
        return "running", None
    # 비정상 종료(크래시·OOM)를 '정지'와 구분 — 0/130(SIGINT)/143(SIGTERM=정상 stop)은 의도된 정지로 본다
    code = s.get("exitCode")
    if code not in (None, 0, 130, 143):
        return "error", f"비정상 종료 (exit {code})"
    return "stopped", None


def session_payload(root: Path, memory: dict[str, Any] | None = None) -> dict[str, Any]:
    project = project_for(root)
    kind = (project or {}).get("kind", "compose")
    services = _compose_services(root, project) if kind == "compose" else []
    if kind == "compose":
        enrich_session_memory(root, project or {}, services, memory if isinstance(memory, dict) else memory_snapshot())
    # 기동/재시작 진행·실패 상태 머지 — start 는 백그라운드(prebuild+빌드 수 분)라 폴링이 이걸로 "기동 중"을 그린다(새로고침에도 유지).
    all_busy = LIFECYCLE_BUSY.get(busy_key(root, "--all"))
    for s in services:
        own = LIFECYCLE_BUSY.get(busy_key(root, s.get("service") or ""))
        # --all busy 는 시작 그룹 멤버에만 — startGroup 밖(옵션) 서비스까지 '기동중' 스핀을 돌리면
        # 실제론 안 띄우는데 전부 띄우는 것처럼 보인다(형 실사용 오인 사례)
        b = own or (all_busy if s.get("inStartGroup") is not False else None)
        if b:
            if "error" in b:
                s["busyError"] = b["error"]
            elif own or not s.get("running"):
                # 자기 서비스 op 는 항상 표시(restart 중엔 구 컨테이너가 아직 running) —
                # --all 폴백만 미기동 서비스에 한정(부분 완료된 스택에서 이미 뜬 건 running 표시 우선)
                s["busy"] = b.get("op") or "start"
        if s.get("busy"):                             # 기동/재시작 중엔 미리보기를 build 로그 tail 로 — 빌드 진행이 카드에 보이게
            bt, bts = _log_tail_line(str(service_log(root, "build")))
            if bt:
                s["logTail"], s["logTs"] = bt, bts
        s["state"], s["stateReason"] = svc_state(s)   # 정규화 상태 — UI 는 이것만 본다(콘솔 스펙)
    # A2 — env 누락 '시작 전' 감지. 세션 전체(보관 compose) 단위 — 카드 원인줄 경고(시작은 막지 않음).
    try:
        missing_env = missing_env_vars(root, project) if (kind == "compose" and project) else []
    except Exception:
        missing_env = []
    return {
        "id": session_id(root),
        "alias": read_meta(root).get("alias", ""),
        "source": root_source(root),
        "projectId": (project or {}).get("id") or root_source(root),   # 게이트웨이 도메인(<wt>.<proj>.localhost) 계산용 — _gateway_snapshot 과 동일 pid
        "root": str(root),
        "ports": {},
        "kind": kind,
        "config": read_config(root),
        "worktreeStatus": worktree_status_cached(root),
        "services": services,
        "missingEnv": missing_env,
        "consoleLogRuns": log_run_payload(root, "console"),
        "buildLogRuns": log_run_payload(root, "build"),
    }

def safe_root(root_text: str) -> Path:
    root = Path(root_text).expanduser().resolve()
    allowed = {r.resolve() for r in discover_all_roots()}
    if root not in allowed:
        # 생성 60s 내 새 worktree 가 discover 캐시에 없어 액션이 거부되는 엣지 — 1회 강제 재탐색
        allowed = {r.resolve() for r in discover_all_roots(refresh=True)}
    if root not in allowed:
        raise ValueError("unknown worktree root")
    return root

def safe_service(service: str, root: Path) -> str:
    if service not in log_targets_for(root):
        raise ValueError("unknown service")
    return service

def origin_allowed(origin: str | None, allow_any_local_port: bool) -> bool:
    # Origin 없음(curl·same-origin GET) 은 허용. 그 외에는 localhost 만,
    # 제어 엔드포인트는 대시보드 자신의 포트만 허용 (임의 웹사이트의 CSRF 차단).
    if not origin:
        return True
    try:
        parts = urllib.parse.urlsplit(origin)
    except ValueError:
        return False
    if parts.hostname not in ("127.0.0.1", "localhost", "::1"):
        return False
    if allow_any_local_port:
        return True
    return parts.port == PORT

def host_allowed(host: str | None) -> bool:
    """DNS 리바인딩 가드 — /api/* 는 Host 가 로컬일 때만.

    origin_allowed 만으로는 못 막는다: 그건 Origin 이 없으면 통과시키는데(curl·same-origin GET),
    리바인딩된 페이지의 same-origin GET 은 **Origin 을 안 보낸다**. 즉 악성 사이트가 evil.com 을
    127.0.0.1 로 되돌린 뒤 fetch 하면 그냥 통과했다. POST 는 Origin 을 보내 403 이라 RCE 는 아니지만,
    유출되는 게 워크트리 경로·에이전트 sid·PTY tid 이고 tid 를 알면 term-stream 으로 살아있는 셸
    스크롤백(타이핑한 비밀값)까지 간다. Host 는 리바인딩으로 위조할 수 없어 여기서 닫힌다.

    Host 없음은 허용 — 브라우저는 Host 를 항상 보내므로 리바인딩 경로가 아니다(HTTP/1.0 curl·스크립트).
    CONTROL_HOST 로 바인드 주소를 바꿔 쓰면 그 이름으로 접근하므로 함께 허용한다.
    """
    if not host:
        return True
    try:
        hostname = urllib.parse.urlsplit(f"//{host}").hostname
    except ValueError:
        return False
    return hostname in ("127.0.0.1", "localhost", "::1", HOST)


def root_for_session_id(value: str) -> Path:
    for root in discover_roots():
        if session_id(root) == value:
            return root
    raise ValueError("unknown session")

def append_console_log(payload: dict[str, Any]) -> dict[str, Any]:
    root = root_for_session_id(str(payload.get("session", "")))
    path = ensure_current_log(root, "console")
    path.parent.mkdir(parents=True, exist_ok=True)

    level = str(payload.get("level", "log"))
    url = str(payload.get("url", ""))
    timestamp = str(payload.get("timestamp", ""))
    args = payload.get("args")
    if not isinstance(args, list):
        args = []

    message = " ".join(redact_text(str(item)) for item in args)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"[{timestamp}] [{level}] {url}\n")
        if message:
            handle.write(message + "\n")
        handle.write("\n")

    return {"ok": True}

# 신선도 분리(실측): 깃 배지(dirty/ahead/branch)는 root 당 ~0.1s 로 싸서 짧게,
# du(diskMb/cacheCats)는 root 당 ~1.5s 라 장수 캐시 + 만료 시 백그라운드 갱신.
WORKTREE_INFO_TTL = 15.0
# 이 나이를 넘으면 옛 값을 주지 않고 동기 계산한다(오래된 배지를 무한정 보여주지 않기 위해).
WORKTREE_INFO_MAX_STALE = float(_env("WORKTREE_INFO_MAX_STALE", "120") or "120")
WORKTREE_DU_TTL = 600.0
_du_inflight: set[str] = set()
_du_lock = threading.Lock()
_info_inflight: set[str] = set()
_info_lock = threading.Lock()


def _kick_worktree_refresh(root: Path) -> None:
    """만료된 worktree_info 를 백그라운드에서 한 번만 갱신한다(single-flight, fail-open)."""
    key = str(root)
    with _info_lock:
        if key in _info_inflight:
            return
        _info_inflight.add(key)

    def _run() -> None:
        try:
            worktree_info(root, refresh=True)
        except Exception:
            pass
        finally:
            with _info_lock:
                _info_inflight.discard(key)

    threading.Thread(target=_run, daemon=True, name=f"wt-info-{key[-24:]}").start()


def warm_worktree_info(roots: list[Path]) -> None:
    """부팅 직후 캐시를 채운다 — 첫 요청이 콜드 캐시를 기다리지 않게."""
    for root in roots:
        try:
            worktree_info(root)
        except Exception:
            continue

def _compute_du(root: Path, is_main: bool) -> tuple[float, Any, dict[str, int], int, dict[str, int]]:
    # main 체크아웃 전체 du 는 수백 GB 라 비싸고 UI 에서도 안 씀 → 스킵
    image_mb = sum(int(item.get("sizeMb") or 0) for item in compose_build_image_items(root))
    return (time.time(), None if is_main else disk_usage_mb(root), cache_category_mb(root), image_mb, docker_disk_summary())

def _du_info(root: Path, is_main: bool, refresh: bool) -> tuple[Any, dict[str, int], int, dict[str, int]]:
    """(diskMb, cacheCats, imageMb, dockerDisk) — 있던 값은 즉시 주고 갱신은 백그라운드. 응답을 du 가 못 막게.
    동기 계산은 캐시가 아예 없는 refresh(=캐시 정리 직후 loadWorktrees(true) 가 새 용량을 기대) 뿐."""
    key = str(root)
    cached = _worktree_du_cache.get(key)
    if cached and len(cached) == 3:
        cached = (cached[0], cached[1], cached[2], 0, {"imagesMb": 0, "buildCacheMb": 0, "volumesMb": 0})
        _worktree_du_cache[key] = cached
    if cached and not refresh and time.time() - cached[0] < WORKTREE_DU_TTL:
        return cached[1], cached[2], cached[3], cached[4]
    if cached is None and refresh:
        info = _compute_du(root, is_main)
        _worktree_du_cache[key] = info
        return info[1], info[2], info[3], info[4]
    with _du_lock:
        spawn = key not in _du_inflight
        if spawn:
            _du_inflight.add(key)
    if spawn:
        def _calc() -> None:
            try:
                _worktree_du_cache[key] = _compute_du(root, is_main)
            finally:
                with _du_lock:
                    _du_inflight.discard(key)
        threading.Thread(target=_calc, daemon=True).start()
    if cached:
        return cached[1], cached[2], cached[3], cached[4]   # 만료된 값이라도 공백보단 낫다 — 다음 폴이 새 값을 집어감
    return None, {}, 0, {"imagesMb": 0, "buildCacheMb": 0, "volumesMb": 0}

# Claude 데스크톱 앱의 세션 타이틀 — worktree 정체성으로 사용 (LLM 자동생성, 유저 수정 가능).
# CLI(터미널 claude)는 이 파일을 안 만들므로 비어 있으면 headSubject→해시 폴백.
CLAUDE_SESSIONS_DIR = Path(os.environ.get(
    "CLAUDE_DESKTOP_SESSIONS_DIR",
    str(Path.home() / "Library" / "Application Support" / "Claude" / "claude-code-sessions"),
))

SESSION_TITLES_TTL = 20.0

def claude_session_titles(refresh: bool = False) -> dict[str, dict[str, str]]:
    # worktreePath → {"title", "titleSource"}. 데스크톱 앱 세션 메타(local_*.json)에서.
    # 폴링 핫패스 보호: TTL 캐시. 같은 worktree 다중 세션이면 lastActivityAt 최신 채택.
    global _session_titles_cache
    now = time.time()
    if not refresh and now - _session_titles_cache[0] < SESSION_TITLES_TTL:
        return _session_titles_cache[1]
    titles: dict[str, dict[str, str]] = {}
    best_ts: dict[str, float] = {}
    if CLAUDE_SESSIONS_DIR.is_dir():
        for path in glob.iglob(str(CLAUDE_SESSIONS_DIR / "**" / "local_*.json"), recursive=True):
            try:
                data = json.loads(Path(path).read_text(encoding="utf-8"))
            except Exception:
                continue
            wt = data.get("worktreePath")
            title = (data.get("title") or "").strip()
            if not wt or not title:
                continue
            ts = float(data.get("lastActivityAt") or data.get("createdAt") or 0)
            if wt in best_ts and best_ts[wt] >= ts:
                continue
            best_ts[wt] = ts
            titles[wt] = {"title": title, "titleSource": data.get("titleSource") or ""}
    _session_titles_cache = (now, titles)
    return titles

# Codex 세션 타이틀 — codex worktree(detached HEAD)는 브랜치명이 없어 정체성이 특히 약하다.
# 체인: worktree cwd → rollout session_meta(line0 의 cwd+id) → session_index.jsonl 의 thread_name.
CODEX_SESSION_INDEX = CODEX_HOME / "session_index.jsonl"

CODEX_ROLLOUT_DIRS = (CODEX_HOME / "sessions", CODEX_HOME / "archived_sessions")

CODEX_TITLES_TTL = 60.0

CODEX_ROLLOUT_MAX_AGE = 45 * 86400  # 오래된 세션은 스캔 제외 — 히스토리 누적돼도 비용 상한

def codex_session_titles(refresh: bool = False) -> dict[str, str]:
    # worktree cwd(=marina root) → thread_name. rollout 헤더 스캔이 무거워 TTL 60s 캐시 + mtime 필터.
    global _codex_titles_cache
    now = time.time()
    if not refresh and now - _codex_titles_cache[0] < CODEX_TITLES_TTL:
        return _codex_titles_cache[1]
    names: dict[str, str] = {}  # session id → thread_name
    try:
        with CODEX_SESSION_INDEX.open(encoding="utf-8") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                # codex thread_name 은 깔끔한 요약일 때도, raw 첫 메시지(길거나 잡스러움)일 때도 있어 상한만 둔다.
                tid, tn = o.get("id"), (o.get("thread_name") or "").strip()
                if tid and tn:
                    names[tid] = tn[:120]
    except Exception:
        pass
    best: dict[str, tuple[str, str]] = {}  # cwd → (timestamp, session id) 최신
    cutoff = now - CODEX_ROLLOUT_MAX_AGE
    for base in CODEX_ROLLOUT_DIRS:
        if not base.is_dir():
            continue
        for path in glob.iglob(str(base / "**" / "rollout-*.jsonl"), recursive=True):
            try:
                if os.path.getmtime(path) < cutoff:
                    continue
                with open(path, encoding="utf-8") as fh:
                    o = json.loads(fh.readline())
            except Exception:
                continue
            if o.get("type") != "session_meta":
                continue
            p = o.get("payload") or {}
            cwd, sid, ts = p.get("cwd"), p.get("id"), str(p.get("timestamp") or "")
            if not cwd or not sid:
                continue
            cur = best.get(cwd)
            if cur is None or ts > cur[0]:
                best[cwd] = (ts, sid)
    titles = {cwd: names[sid] for cwd, (ts, sid) in best.items() if sid in names}
    _codex_titles_cache = (now, titles)
    return titles

# A1 — 카드 AGENTS 섹션: 워크트리에서 도는 Claude/Codex 세션 가시화(Orca 의 "이 안에서 뭐가 도는지" 를 서비스뿐 아니라 에이전트에도).
# CLI 트랜스크립트(~/.claude/projects/<슬러그>/<cliSessionId>.jsonl) — Claude Code 가 절대경로의 '/'·'.'을 '-'로 치환해 만드는 디렉토리명.
CLAUDE_PROJECTS_DIR = Path(os.environ.get("CLAUDE_PROJECTS_DIR", str(Path.home() / ".claude" / "projects")))
CLAUDE_CONFIG_FILE = Path(os.environ.get("CLAUDE_CONFIG_FILE", str(Path.home() / ".claude.json")))
CLAUDE_USAGE_CACHE_FILE = Path(os.environ.get(
    "CLAUDE_USAGE_CACHE_FILE",
    str(Path.home() / ".claude" / "plugins" / "claude-hud" / ".usage-cache.json"),
))
CLAUDE_USAGE_CACHE_MAX_AGE_MS = int(os.environ.get("CLAUDE_USAGE_CACHE_MAX_AGE_MS", "300000"))

AGENTS_MAX_PER_ROOT = 3

AGENTS_MAX_AGE = 7 * 86400   # 7일↑ 미활동 세션은 기본 목록에서 제외
AGENTS_MAX_AGE_ALL = 90 * 86400   # '전체보기'가 훑는 범위(형: "7일 이후도 볼 수 있어야지")

AGENT_PREVIEW_TAIL_BYTES = 16 * 1024   # preview 는 파일 끝만 읽는다 — 전체 파싱 금지(폴링 비용 상한)

AGENT_PREVIEW_LEN = 80

AGENT_STATE_TAIL_BYTES = 1024 * 1024

def _claude_project_slug(root: Path) -> str:
    return re.sub(r"[/.]", "-", str(root))

def _jsonl_last_assistant_preview(path: Path) -> str:
    # 파일 끝 16KB 만 읽어 마지막 유효 assistant 텍스트를 역방향으로 찾는다. 경계에서 잘린 첫 줄은
    # json.loads 가 실패해 자연히 건너뛴다(부분 파싱 크래시 없음).
    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            if size > AGENT_PREVIEW_TAIL_BYTES:
                fh.seek(size - AGENT_PREVIEW_TAIL_BYTES)
            raw = fh.read()
    except Exception:
        return ""
    text = raw.decode("utf-8", errors="ignore")
    for line in reversed(text.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") != "assistant":
            continue
        content = ((obj.get("message") or {}).get("content")) or []
        if not isinstance(content, list):
            continue
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text" and item.get("text"):
                snippet = " ".join(str(item["text"]).split())
                if snippet:
                    return snippet[:AGENT_PREVIEW_LEN]
    return ""


def _agent_event_ts(obj: dict[str, Any], fallback: float) -> float:
    raw = obj.get("timestamp")
    if isinstance(raw, (int, float)) and not isinstance(raw, bool) and math.isfinite(raw):
        return float(raw)
    if isinstance(raw, str) and raw:
        try:
            return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
        except ValueError:
            pass
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
    for key in ("completed_at", "started_at"):
        value = payload.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
            return float(value)
    return float(fallback)


def _agent_state_rows(path: Path) -> tuple[list[dict[str, Any]], float]:
    try:
        with path.open("rb") as fh:
            descriptor_stat = os.fstat(fh.fileno())
            offset = max(0, descriptor_stat.st_size - AGENT_STATE_TAIL_BYTES)
            if offset:
                fh.seek(offset)
            raw = fh.read(min(descriptor_stat.st_size, AGENT_STATE_TAIL_BYTES))
    except OSError:
        return [], 0
    if offset:
        split = raw.split(b"\n", 1)
        raw = split[1] if len(split) == 2 else b""
    rows: list[dict[str, Any]] = []
    for line in raw.decode("utf-8", errors="ignore").splitlines():
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows, descriptor_stat.st_mtime


EVENT_TO_STATUS = {
    "working": "working",
    "blocked": "blocked",
    "ended": "completed",
    "failed": "failed",
}


def _is_tool_result_only(content: Any) -> bool:
    """tool_result 블록만 담은 user 메시지 판정 — 사용자가 친 프롬프트가 아니라 tool 완료 기록."""
    if not isinstance(content, list) or not content:
        return False
    return all(isinstance(block, dict) and block.get("type") == "tool_result" for block in content)


def _native_agent_status(path: Path, source: str, *, now: float | None = None) -> dict[str, Any]:
    """Normalize native Claude/Codex turn boundaries without reading an entire rollout."""
    rows, mtime = _agent_state_rows(path)
    current = time.time() if now is None else now
    best: dict[str, Any] | None = None

    def offer(status: str, ts: float, reason: str | None = None) -> None:
        nonlocal best
        if not math.isfinite(ts) or ts > current + 300:
            return
        candidate: dict[str, Any] = {"status": status, "statusTs": ts}
        if reason:
            candidate["statusReason"] = reason[:120]
        # Iterating in append order makes an equal timestamp deterministically
        # prefer the later native record, while newer timestamps always win.
        if best is None or ts >= best["statusTs"]:
            best = candidate

    if source == "codex":
        for obj in rows:
            payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
            event = payload.get("type") if obj.get("type") == "event_msg" else None
            ts = _agent_event_ts(obj, mtime)
            if event == "task_complete":
                offer("completed", ts)
            elif event == "turn_aborted":
                reason = str(payload.get("reason") or "aborted")
                offer("failed", ts, reason)
            elif event in ("error", "stream_error"):
                reason = str(payload.get("message") or payload.get("error") or event)
                offer("failed", ts, reason)
            elif event == "task_started":
                offer("working", ts)
    elif source == "claude":
        for obj in rows:
            typ = obj.get("type")
            ts = _agent_event_ts(obj, mtime)
            if typ == "system" and obj.get("subtype") == "api_error":
                offer("failed", ts, "api_error")
            elif typ == "system" and obj.get("subtype") == "stop_hook_summary":
                errors = obj.get("hookErrors") if isinstance(obj.get("hookErrors"), list) else []
                if errors:
                    offer("failed", ts, "stop hook failed")
                else:
                    offer("completed", ts)
            elif typ == "assistant":
                message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
                if message.get("stop_reason") == "end_turn":
                    offer("completed", ts)
                else:
                    offer("working", ts)
            elif typ == "user":
                content = (obj.get("message") or {}).get("content") if isinstance(obj.get("message"), dict) else None
                if _is_tool_result_only(content):
                    continue                # tool_result = 능동 작업 아니라 tool 완료(수동) 기록.
                    # 턴이 tool 로 끝나면 마지막 항목이 tool_result 라, 이걸 working 으로 offer 하면 그 tool_result
                    # 의 ts 가 Stop 훅 ended 보다 커져 merge 가 훅을 무시하고 working 에 고착된다(형 피드백:
                    # "재시작한다고 배시로 끝났을 때 워킹"). 그 앞 assistant tool_use 가 이미 더 이른 ts 로 working
                    # 을 offer 하므로 ended 훅이 그걸 덮어 completed→waiting 로 정상 전환된다.
                texts = _texts_of(content)
                if _is_interrupt_marker(texts):
                    offer("completed", ts)  # 사용자 중단 = 턴 종료
                elif _is_injected_user(obj, source, texts):
                    continue                # 주입 user(Continue 등)는 턴 경계 아님 — working 고착 방지
                else:
                    offer("working", ts)
    if best is not None:
        return best
    if mtime and mtime <= current and current - mtime < 120:
        return {"status": "working", "statusTs": mtime, "statusReason": "recent activity"}
    return {"status": "idle", "statusTs": mtime if mtime <= current else 0}


def merge_agent_status(
    native: dict[str, Any], event: dict[str, Any] | None, terminal_active: bool = False,
) -> dict[str, Any]:
    """Prefer a valid newest lifecycle event, then derive waiting from a live terminal."""
    result = dict(native)
    try:
        native_ts = float(result.get("statusTs") or 0)
    except (TypeError, ValueError):
        native_ts = 0

    if isinstance(event, dict):
        event_name = event.get("event")
        raw_ts = event.get("ts")
        try:
            event_ts = float(raw_ts)
        except (TypeError, ValueError):
            event_ts = float("nan")
        if (
            event_name in EVENT_TO_STATUS
            and math.isfinite(event_ts)
            and event_ts >= native_ts
        ):
            status = EVENT_TO_STATUS[str(event_name)]
            result = {"status": status, "statusTs": event_ts}
            reason = event.get("reason")
            if status == "blocked" and reason in BLOCKED_REASONS:
                # idle_prompt = 턴을 끝내고 프롬프트에서 유휴 대기(막힘 아님) → waiting("응답 대기").
                # permission_prompt·elicitation_dialog 만 진짜 blocked("응답 필요", red) — 작업 진행에 사용자
                # 조치가 필요한 상태다. idle_prompt 를 red 로 두면 끝난 세션이 오류처럼 보인다(형 피드백 2026-07-24).
                # "completed + 터미널 살아있음 → waiting"(아래) 과 동일한 의미 — 프로세스는 살아서 입력만 기다린다.
                if reason == "idle_prompt":
                    result["status"] = "waiting"
                else:
                    result["statusReason"] = str(reason)[:120]

    if terminal_active and result.get("status") == "completed":
        result["status"] = "waiting"
    return result


def agent_status(
    path: Path,
    source: str,
    terminal_active: bool = False,
    *,
    sid: str = "",
    root: Path | None = None,
    event_home: Path | None = None,
    now: float | None = None,
) -> dict[str, Any]:
    """Resolve native transcript state with an optional explicit lifecycle event."""
    native = _native_agent_status(path, source, now=now)
    event = None
    if sid and root is not None:
        event = latest_agent_event(source, sid, Path(root), home=event_home, now=now)
    return merge_agent_status(native, event, terminal_active)

def _read_transcript_cwd(path: Path, max_lines: int = 40) -> str | None:
    # CLI 트랜스크립트 앞부분에서 첫 top-level cwd. 선두 메타 라인(last-prompt/mode)엔 없다.
    try:
        with path.open(encoding="utf-8") as fh:
            for i, line in enumerate(fh):
                if i >= max_lines:
                    break
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                cwd = o.get("cwd") if isinstance(o, dict) else None
                if isinstance(cwd, str) and cwd:
                    return cwd
    except OSError:
        return None
    return None


_SHELL_NOISE_RE = re.compile(
    r"^(cd|ls|cat|git|npm|npx|yarn|pnpm|python3?|pip3?|bash|sh|zsh|export|source|rm|cp|mv|mkdir|echo|curl|docker|make|go|cargo)\b|^[~./]"
)


def _looks_like_shell_noise(s: str) -> bool:
    # cd/경로/순수 셸명령 — 세션 제목으로 부적절(호출부가 커밋제목으로 폴백).
    return bool(_SHELL_NOISE_RE.match(s.strip()))


def _read_transcript_title(path: Path, max_lines: int = 40) -> str:
    # aiTitle 우선(claude 가 지은 제목). 없으면 lastPrompt 지만 cd/경로/셸명령 노이즈는 제외.
    title = ""
    try:
        with path.open(encoding="utf-8") as fh:
            for i, line in enumerate(fh):
                if i >= max_lines:
                    break
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if not isinstance(o, dict):
                    continue
                if isinstance(o.get("aiTitle"), str) and o["aiTitle"].strip():
                    return o["aiTitle"].strip()[:120]
                if not title and isinstance(o.get("lastPrompt"), str) and o["lastPrompt"].strip():
                    title = o["lastPrompt"].strip()[:120]
    except OSError:
        return ""
    return "" if _looks_like_shell_noise(title) else title


def _claude_cli_sessions(now: float, cutoff: float) -> dict[str, list[dict[str, Any]]]:
    # ~/.claude/projects/<slug>/<sid>.jsonl 스캔 → cwd 로 worktree, 파일 stem 으로 진짜 sid.
    by_root: dict[str, list[dict[str, Any]]] = {}
    if not CLAUDE_PROJECTS_DIR.is_dir():
        return by_root
    for raw in glob.iglob(str(CLAUDE_PROJECTS_DIR / "*" / "*.jsonl")):
        path = Path(raw)
        try:
            mtime = os.path.getmtime(raw)
        except OSError:
            continue
        if mtime < cutoff:                      # 7일 필터를 파일 열기 전에 (싸게)
            continue
        cwd = _read_transcript_cwd(path)
        if not cwd:
            continue
        sid = path.stem
        title = _read_transcript_title(path) or repo_head_subject(Path(cwd)) or sid[:8]
        by_root.setdefault(cwd, []).append({
            "source": "claude", "title": title, "ts": mtime, "cliSessionId": sid,
        })
    return by_root


def claude_agent_sessions(refresh: bool = False, include_all: bool = False) -> dict[str, list[dict[str, Any]]]:
    # worktreePath → [{"source":"claude","title","ts"(파일 mtime),"cliSessionId"}] — claude_session_titles 와 같은 소스·캐시 리듬(20s)
    # 이나, root 당 최신 1개로 축약하지 않고 전부 보존(AGENTS 섹션이 상위 최대 3개를 다시 고른다).
    global _claude_agents_cache, _claude_agents_all_cache
    now = time.time()
    cache = _claude_agents_all_cache if include_all else _claude_agents_cache
    if not refresh and now - cache[0] < SESSION_TITLES_TTL:
        return cache[1]
    by_root: dict[str, list[dict[str, Any]]] = {}
    cutoff = now - (AGENTS_MAX_AGE_ALL if include_all else AGENTS_MAX_AGE)
    if CLAUDE_SESSIONS_DIR.is_dir():
        for path in glob.iglob(str(CLAUDE_SESSIONS_DIR / "**" / "local_*.json"), recursive=True):
            try:
                mtime = os.path.getmtime(path)
                if mtime < cutoff:
                    continue
                data = json.loads(Path(path).read_text(encoding="utf-8"))
            except Exception:
                continue
            wt = data.get("worktreePath")
            title = (data.get("title") or "").strip()
            if not wt or not title:
                continue
            by_root.setdefault(wt, []).append({
                "source": "claude", "title": title, "ts": mtime,
                "cliSessionId": data.get("cliSessionId") or "",
            })
    # CLI 트랜스크립트 소스 병합 — Desktop local_*.json 이 없는 순수 CLI 세션도 잡는다.
    # 진짜 sid(파일 stem)를 cliSessionId 로 실어 agents_payload 가 상태/preview 를 진짜 sid 로 조회.
    for cli_root, cli_entries in _claude_cli_sessions(now, cutoff).items():
        existing = by_root.setdefault(cli_root, [])
        seen = {str(e.get("cliSessionId") or "") for e in existing}
        for entry in cli_entries:
            if entry["cliSessionId"] not in seen:      # Desktop 이 같은 sid 를 이미 가지면 skip
                existing.append(entry)
    if include_all:
        _claude_agents_all_cache = (now, by_root)
    else:
        _claude_agents_cache = (now, by_root)
    return by_root

def codex_agent_sessions(refresh: bool = False, include_all: bool = False) -> dict[str, list[dict[str, Any]]]:
    # cwd → [{"source":"codex","title","ts"(rollout 파일 mtime)}] — codex_session_titles 와 같은 소스·캐시 리듬(60s),
    # root 당 전부 보존. preview 는 codex rollout 파싱 비용이 커 title+ts 만(스펙 — "가능한 만큼").
    global _codex_agents_cache, _codex_agents_all_cache
    now = time.time()
    if not refresh and now - _codex_agents_cache[0] < CODEX_TITLES_TTL:
        return _codex_agents_cache[1]
    names: dict[str, str] = {}
    try:
        with CODEX_SESSION_INDEX.open(encoding="utf-8") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                tid, tn = o.get("id"), (o.get("thread_name") or "").strip()
                if tid and tn:
                    names[tid] = tn[:120]
    except Exception:
        pass
    by_root: dict[str, list[dict[str, Any]]] = {}
    cutoff = now - (AGENTS_MAX_AGE_ALL if include_all else AGENTS_MAX_AGE)
    for base in CODEX_ROLLOUT_DIRS:
        if not base.is_dir():
            continue
        for path in glob.iglob(str(base / "**" / "rollout-*.jsonl"), recursive=True):
            try:
                mtime = os.path.getmtime(path)
                if mtime < cutoff:
                    continue
                with open(path, encoding="utf-8") as fh:
                    o = json.loads(fh.readline())
            except Exception:
                continue
            if o.get("type") != "session_meta":
                continue
            p = o.get("payload") or {}
            cwd, sid = p.get("cwd"), p.get("id")
            title = names.get(sid) if sid else None
            if not cwd or not title:
                continue
            by_root.setdefault(cwd, []).append({"source": "codex", "title": title, "ts": mtime,
                                                "sid": sid or "", "path": path})   # path 는 서버 내부용(payload 미노출)
    if include_all:
        _codex_agents_all_cache = (now, by_root)
    else:
        _codex_agents_cache = (now, by_root)
    return by_root


def agent_belongs_to_root(root: Path, source: str, sid: str, refresh: bool = False) -> bool:
    """Verify an agent id against the complete session index for a worktree."""
    source = str(source).strip().lower()
    sid = str(sid).strip()
    if source not in ("claude", "codex") or not sid:
        return False
    roots = {str(root), str(root.resolve())}
    # 목록 창(7일)과 무관하게 **넓은 색인**으로 확인한다 — 전체보기로 연 오래된 세션에 전송이 막히면 안 된다.
    sessions = (claude_agent_sessions(refresh, True) if source == "claude"
                else codex_agent_sessions(refresh, True))
    id_key = "cliSessionId" if source == "claude" else "sid"
    return any(
        str(entry.get(id_key) or "") == sid
        for root_key in roots
        for entry in sessions.get(root_key, [])
    )

# ── 세션 liveness (작업중/blocked → idle 강등 판정) ─────────────────────────────────────────
# 정석 신호는 "프로세스의 cwd". 예전엔 `ps command=` 를 shlex 로 파싱해 `claude --resume <sid>` 에서 sid 를
# 뽑았는데, Claude Code 는 유저 프롬프트를 argv 로 넘겨(claude --resume <sid> <프롬프트>) ps 줄 끝에 임의의
# 유저 텍스트가 붙는다 — 따옴표(don't/it's/")만 있어도 파싱이 깨져 sid 를 놓치고 작업중 세션이 유휴로 오탐됐다.
# → 프롬프트 오염된 텍스트에서 sid 를 긁는 방식을 폐기하고, 인자가 전혀 없는 `ps comm=`(실행파일명)로 claude/codex
#   프로세스를 식별해 그 cwd(=worktree root, marina 는 워크트리=세션 1:1)를 liveness 로 쓴다. 프롬프트 무관.

def _parse_agent_pids(ps_output: str) -> list[str]:
    # ps -axo pid=,comm= 출력(= "<pid> <실행파일경로>", 인자 없음) → claude/codex 프로세스 pid 목록.
    # comm 에는 프롬프트/인자가 절대 안 붙으므로 파싱이 유저 입력에 오염되지 않는다(정석).
    pids: list[str] = []
    for line in ps_output.splitlines():
        head, _, comm = line.strip().partition(" ")
        if not head.isdigit() or not comm.strip():
            continue
        if Path(comm.strip()).name in ("claude", "codex"):
            pids.append(head)
    return pids


_live_cwds_cache: tuple[float, set[Path]] = (0.0, set())


def _live_agent_cwds(refresh: bool = False) -> set[Path]:
    # 살아있는 claude/codex 프로세스들의 cwd(=worktree root) 집합 — 세션 liveness. 5s 캐시(세션마다 ps 방지).
    global _live_cwds_cache
    now = time.time()
    if not refresh and now - _live_cwds_cache[0] < 5.0:
        return _live_cwds_cache[1]
    try:
        result = subprocess.run(["ps", "-axo", "pid=,comm="], check=False,
                                capture_output=True, text=True, timeout=1)
    except (OSError, subprocess.SubprocessError):
        return _live_cwds_cache[1]
    pids = _parse_agent_pids(result.stdout)
    cwds: set[Path] = set()
    if pids:
        try:
            out = subprocess.run(["lsof", "-a", "-d", "cwd", "-p", ",".join(pids), "-Fn"],
                                 check=False, capture_output=True, text=True, timeout=2)
            for l in out.stdout.splitlines():
                if l.startswith("n") and l[1:].strip():
                    try:
                        cwds.add(Path(l[1:].strip()).resolve())
                    except OSError:
                        pass
        except (OSError, subprocess.SubprocessError):
            pass
    _live_cwds_cache = (now, cwds)
    return cwds


_live_tids_cache: tuple[float, dict[tuple[str, str], str]] = (0.0, {})


def _live_agent_tids(refresh: bool = False) -> dict[tuple[str, str], str]:
    # 마리나가 쥔 살아있는 PTY 맵 — (source, sid)→tid, resolve_session_liveness 의 reachable/tid 신호.
    # term_list() 는 foreground term 마다 ps 를 띄운다(_fg_command) — agents_payload 가 루트마다
    # 부르면 폴링 한 사이클에 root 수만큼 fan-out 된다. _live_agent_cwds 와 동일한 5s 캐시로 억제.
    global _live_tids_cache
    now = time.time()
    if not refresh and now - _live_tids_cache[0] < 5.0:
        return _live_tids_cache[1]
    out: dict[tuple[str, str], str] = {}
    for t in term_list().get("sessions", []):
        agent = t.get("agent") if isinstance(t.get("agent"), dict) else None
        if not agent:
            continue
        key = (str(agent.get("source") or ""), str(agent.get("sid") or ""))
        if all(key):
            out[key] = str(t.get("tid") or "")
    _live_tids_cache = (now, out)
    return out


def _crosses_nested_worktree(root: Path, cwd: Path) -> bool:
    # root 아래로 내려가는 경로 도중 `.claude/worktrees/` 경계를 넘는지 — marina 워크트리는
    # 물리적으로 메인 루트 밑에 중첩(<main>/.claude/worktrees/<wt>)되므로, 그 경계를 넘은 cwd 는
    # main 이 아니라 그 중첩 워크트리에 속한다(방향: root→cwd 로 내려가며 검사).
    try:
        rel_parts = cwd.relative_to(root).parts
    except ValueError:
        return False
    for i in range(len(rel_parts) - 1):
        if rel_parts[i] == ".claude" and rel_parts[i + 1] == "worktrees":
            return True
    return False


def _root_has_live_agent(root: Path | None, live_cwds: set[Path]) -> bool:
    # root 자체가 어떤 살아있는 agent 의 cwd 이거나, 그 cwd 를 품고 있으면(서브폴더에서 실행) live —
    # 단, 그 cwd 가 root 아래 중첩된 워크트리(.claude/worktrees/...) 안이면 제외한다. 그렇지 않으면
    # 메인 체크아웃 root 가 그 밑 모든 워크트리의 살아있는 세션에 반응해 항상 live 로 오판된다
    # (메인 세션이 실제로 종료돼도 idle 강등이 안 되는 원인).
    if root is None:
        return False
    for cwd in live_cwds:
        if cwd == root:
            return True
        if root in cwd.parents and not _crosses_nested_worktree(root, cwd):
            return True
    return False


def _downgrade_if_dead(item: dict[str, Any], live_cwds: set[Path] | None = None,
                       root: Path | None = None) -> dict[str, Any]:
    # 프로세스가 없으면 작업중일 수 없다 — root 에 살아있는 claude/codex 프로세스가 없으면 working/blocked 를 idle 로 강등.
    if item.get("status") in ("working", "blocked") and not _root_has_live_agent(root, live_cwds or set()):
        item["status"] = "idle"
        item["statusReason"] = "프로세스 없음"
    return item


WORKING_STALE_S = 3600   # 이만큼 그 세션 트랜스크립트가 조용하면 "작업 중"이 아니다.
# 넉넉히 잡는다: 긴 도구 호출(빌드·테스트 스위트)은 시작과 끝 사이에 아무것도 안 쓸 수 있어서,
# 짧게 잡으면 진짜 작업 중인 세션을 유휴로 오판한다(예전에 그 반대 사고가 있었다).
# 목표는 "며칠째 작업중" 을 없애는 것이지 분 단위 정확도가 아니다.


def resolve_session_liveness(
    source: str,
    sid: str,
    root: Path | None,
    *,
    native: dict[str, Any],
    event: dict[str, Any] | None,
    live_cwds: set[Path],
    live_tids: dict[tuple[str, str], str],
    now: float | None = None,
) -> dict[str, Any]:
    """Single canonical liveness resolver — status + reachable + tid, all from given signals.

    여러 호출부가 각자 status(merge_agent_status)·강등(_downgrade_if_dead)·reachable(터미널
    맵 조회)을 따로 계산하던 걸 하나로 캐논화한다. 신호(native/event/live_cwds/live_tids)는
    전부 인자로 받는 순수 함수 — 내부에서 ps/lsof/파일을 새로 읽지 않는다(테스트/캐시 용이).

    - status: merge_agent_status(native, event) 로 기본 산출(S4 트랜스크립트 vs S5 훅 이벤트,
      ts 로 병합, idle_prompt→waiting 포함).
    - D3: 그 status 가 working/blocked 인데 root 에 살아있는 agent 가 없으면(_root_has_live_agent)
      idle+"프로세스 없음" 으로 강등 — _downgrade_if_dead 와 동일 판정, 여기로 캐논화.
    - reachable/tid: (source, sid) 가 live_tids(마리나가 살아있는 PTY 를 쥔 세션 맵)에 있으면
      reachable=True, tid=그 값; 아니면 False/"".
    - D4: status 가 completed 인데 reachable(살아있는 PTY 존재)이면 waiting 으로 승격 — 세션은
      끝났지만 프로세스가 입력을 기다리는 중. merge_agent_status 의 죽은 terminal_active 경로를
      여기서 대체(캐논 위치는 이 함수).
    """
    merged = merge_agent_status(native, event)
    status = merged.get("status")
    reason = merged.get("statusReason")

    if status in ("working", "blocked") and not _root_has_live_agent(root, live_cwds):
        status = "idle"
        reason = "프로세스 없음"

    # D3b: root 에 살아있는 agent 가 있어도 **그게 이 세션이라는 보장은 없다**. 워크트리 하나에 세션이
    # 여럿이고, 하위 폴더에서 도는 무관한 프로세스도 root live 로 잡힌다(실측: 8일째 떠 있던 claude 하나가
    # mdc-main 소속 세션을 전부 "작업중"으로 만들었다 — 형: "계속 작업중 상태인거 보기 싫음").
    # 진짜 작업 중이면 그 세션 트랜스크립트가 초 단위로 쓰인다. 오래 조용하면 작업 중이 아니다.
    # blocked 는 제외한다 — 답을 기다리는 동안은 원래 아무것도 안 쓴다.
    if status == "working":
        try:
            status_ts = float(merged.get("statusTs") or 0)
        except (TypeError, ValueError):
            status_ts = 0
        if status_ts and (now or time.time()) - status_ts > WORKING_STALE_S:
            status = "idle"
            reason = "오래 조용함"

    reachable = (source, sid) in live_tids
    tid = live_tids.get((source, sid), "") if reachable else ""

    if status == "completed" and reachable:
        status = "waiting"

    return {"status": status, "reachable": reachable, "tid": tid, "reason": reason}


def agents_payload(root: Path, refresh: bool = False, include_all: bool = False) -> list[dict[str, Any]]:
    # 카드 AGENTS 섹션 — 워크트리당 최대 3개(ts 내림차순), Claude 만 preview(마지막 assistant 텍스트 80자) 부여.
    # status 는 resolve_session_liveness 로 캐논화(S4 native + S5 event 병합 → D3 강등 → D4 승격 한 경로).
    claude_by_root = claude_agent_sessions(refresh, include_all)
    codex_by_root = codex_agent_sessions(refresh, include_all)
    key = str(root)
    entries = [*claude_by_root.get(key, []), *codex_by_root.get(key, [])]
    entries.sort(key=lambda e: e["ts"], reverse=True)
    agents: list[dict[str, Any]] = []
    event_home = Path.home()
    canonical_root = root.resolve()
    live_cwds = _live_agent_cwds(refresh)   # 정석: claude/codex 프로세스 cwd→root 로 liveness(프롬프트 파싱 없음)
    live_tids = _live_agent_tids(refresh)   # 마리나가 쥔 살아있는 PTY — (source,sid)→tid, 5s 캐시(루트 fan-out 억제)
    for e in entries[:AGENTS_MAX_PER_ROOT]:
        item: dict[str, Any] = {"source": e["source"], "title": e["title"], "ts": int(e["ts"])}
        sid = ""
        jpath: Path | None = None
        if e["source"] == "claude" and e.get("cliSessionId"):
            sid = e["cliSessionId"]
            item["sid"] = sid   # 행 클릭=대화 열기 (agent-transcript) 식별자
            candidate = CLAUDE_PROJECTS_DIR / _claude_project_slug(root) / f"{sid}.jsonl"
            if candidate.is_file():
                jpath = candidate
        elif e["source"] == "codex" and e.get("sid"):
            sid = e["sid"]
            item["sid"] = sid
            jpath = Path(e["path"])
        if jpath is not None:
            native = _native_agent_status(jpath, e["source"])
            event = latest_agent_event(e["source"], sid, canonical_root, home=event_home) if sid else None
            merged = merge_agent_status(native, event)   # statusTs 는 resolver 가 안 실어 여기서 따로.
            if merged.get("statusTs") is not None:
                item["statusTs"] = merged["statusTs"]
            resolved = resolve_session_liveness(e["source"], sid, canonical_root, native=native,
                                                event=event, live_cwds=live_cwds, live_tids=live_tids)
            item["status"] = resolved["status"]
            if resolved.get("reason"):
                item["statusReason"] = resolved["reason"]
            if e["source"] == "claude":
                preview = _jsonl_last_assistant_preview(jpath)
                if preview:
                    from marina_logtext import redact_text   # 카드 payload 도 로그와 같은 마스킹(codex P2)
                    item["preview"] = redact_text(preview)
        if "status" not in item:
            item.update({"status": "idle", "statusTs": int(e["ts"])})
        agents.append(item)
    return agents


def activate_agent_payloads(agents: list[dict[str, Any]],
                            active_agents: set[tuple[str, str]]) -> list[dict[str, Any]]:
    """Promote successful ended turns to waiting when their Marina PTY is still alive."""
    for item in agents:
        key = (str(item.get("source") or ""), str(item.get("sid") or ""))
        if key in active_agents and item.get("status") == "completed":
            item["status"] = "waiting"
    return agents


AGENT_TRANSCRIPT_TAIL_BYTES = 256 * 1024
AGENT_TRANSCRIPT_MAX_TURNS = 60
AGENT_TURN_MAX_CHARS = 4000
AGENT_TIMELINE_MAX_ACTIVITIES = 120

def _texts_of(content: Any) -> list[str]:
    # message.content — 문자열이거나 [{type:text|input_text|output_text, text}] 리스트. 텍스트 블록만 수집.
    if isinstance(content, str):
        return [content] if content.strip() else []
    out: list[str] = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, dict) and item.get("type") in ("text", "input_text", "output_text"):
                t = str(item.get("text") or "")
                if t.strip():
                    out.append(t)
    return out

def _tail_lines(path: Path) -> list[str]:
    size = path.stat().st_size
    with path.open("rb") as fh:
        if size > AGENT_TRANSCRIPT_TAIL_BYTES:
            fh.seek(size - AGENT_TRANSCRIPT_TAIL_BYTES)
        raw = fh.read()
    return raw.decode("utf-8", errors="ignore").splitlines()


def _json_objects(path: Path) -> list[dict[str, Any]]:
    objects: list[dict[str, Any]] = []
    for line in _tail_lines(path):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            objects.append(obj)
    return objects


def _scan_json_objects(path: Path, markers: tuple[bytes, ...]):
    """파일 전체를 처음부터 흘려 읽는다 — _json_objects 는 끝 256KB 만 봐서 긴 세션의 앞부분을
    통째로 놓친다(서브에이전트 호출은 대개 대화 초반에 몰려 있어 목록이 아예 비었다).
    값싼 바이트 필터로 관심 없는 줄은 파싱조차 하지 않는다."""
    if not path.is_file():
        return
    with path.open("rb") as handle:
        for raw in handle:
            if markers and not any(marker in raw for marker in markers):
                continue
            try:
                obj = json.loads(raw)
            except Exception:
                continue
            if isinstance(obj, dict):
                yield obj


def _reverse_json_objects(path: Path):
    """Yield complete JSONL objects newest-first without a fixed tail window."""
    if not path.is_file() or path.stat().st_size == 0:
        return
    with path.open("rb") as handle:
        with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
            cursor = len(data)
            while cursor > 0:
                line_end = cursor - 1 if data[cursor - 1] == 10 else cursor
                if line_end <= 0:
                    break
                newline = data.rfind(b"\n", 0, line_end)
                line_start = newline + 1
                raw = data[line_start:line_end].strip()
                cursor = line_start
                if not raw.startswith(b"{"):
                    continue
                try:
                    obj = json.loads(raw)
                except Exception:
                    continue
                if isinstance(obj, dict):
                    yield obj


# 사용자 라인 중 하네스/도구가 주입한 것 — 진짜 입력이 아니라 turn 에서 뺀다.
# 슬래시 명령(/model 등)도 user 행으로 남는다(<command-name>·<local-command-stdout>). 이걸 진짜
# 입력으로 읽으면 "user 가 마지막 = 작업 중"인데 슬래시 명령엔 응답도 Stop 훅도 안 와서
# **영원히 작업중**에 고착된다(형: "무한으로 작업중이고 정지버튼 안먹었었어" — /model 직후).
_CLAUDE_INJECT_PREFIXES = ("<task-notification>", "<system-reminder>",
                           "[SYSTEM NOTIFICATION", "<command-name>",
                           "<local-command-stdout>", "<local-command-caveat>")
_CODEX_INJECT_PREFIXES = ("# AGENTS.md instructions", "<INSTRUCTIONS>",
                          "<user_instructions>", "<environment_context>")


def _is_injected_user(obj: dict[str, Any], source: str, texts: list[str]) -> bool:
    if source == "claude" and obj.get("isMeta"):
        return True
    prefixes = _CLAUDE_INJECT_PREFIXES if source == "claude" else _CODEX_INJECT_PREFIXES
    # 모든 텍스트 블록이 주입 래퍼로 시작하면 주입 라인(혼합이면 진짜 입력이 섞인 것 → 보존).
    return bool(texts) and all(t.lstrip().startswith(prefixes) for t in texts)


_NOOP_ASSISTANT = "No response requested"
_INTERRUPT_PREFIX = "[Request interrupted"


def _is_noop_assistant(texts: list[str]) -> bool:
    # 하네스 재개(Continue)에 대한 무응답 마커 — 대화에 표시할 내용이 없다.
    return bool(texts) and all(t.strip().rstrip(". ").strip() == _NOOP_ASSISTANT for t in texts)


def _is_interrupt_marker(texts: list[str]) -> bool:
    # 사용자 중단([Request interrupted by user]) — 턴 종료 신호이자 렌더 숨김 대상.
    return bool(texts) and all(t.lstrip().startswith(_INTERRUPT_PREFIX) for t in texts)


def _is_hidden_turn(obj: dict[str, Any], role: str, source: str, texts: list[str]) -> bool:
    # 대화 렌더에서 숨길 턴 — 주입/중단 user + noop assistant.
    if role == "user":
        return _is_injected_user(obj, source, texts) or _is_interrupt_marker(texts)
    if role == "assistant":
        return _is_noop_assistant(texts)
    return False


def _transcript_object_turns(obj: dict[str, Any], source: str,
                             line_offset: int | None = None) -> list[dict[str, str]]:
    if source == "claude":
        role = obj.get("type")
        content = (obj.get("message") or {}).get("content")
    else:
        payload = obj.get("payload") or {}
        if payload.get("type") != "message":
            return []
        role = payload.get("role")
        content = payload.get("content")
    if role not in ("user", "assistant"):
        return []
    texts = _texts_of(content)
    if _is_hidden_turn(obj, role, source, texts):
        return []
    turns: list[dict[str, str]] = []
    for index, text in enumerate(texts):
        turn = {"role": str(role), "text": text[:AGENT_TURN_MAX_CHARS]}
        if line_offset is not None:
            turn["id"] = f"{line_offset}:{index}"
        turns.append(turn)
    return turns


def _redact_turns(turns: list[dict[str, str]]) -> list[dict[str, str]]:
    turns = turns[-AGENT_TRANSCRIPT_MAX_TURNS:]
    for turn in turns:
        turn["text"] = _redact_transcript(redact_text(turn["text"]))
    return turns


def _transcript_turns(path: Path, source: str) -> list[dict[str, str]]:
    turns: list[dict[str, str]] = []
    for obj in _json_objects(path):
        turns.extend(_transcript_object_turns(obj, source))
    return _redact_turns(turns)


def _transcript_page(path: Path, source: str, before: int | None,
                     limit: int) -> dict[str, Any]:
    size = path.stat().st_size
    end = size if before is None else max(0, min(size, int(before)))
    limit = max(1, min(100, int(limit or 40)))
    if not size or not end:
        return {"turns": [], "cursor": None, "hasMore": False, "fileSize": size}
    groups: list[list[dict[str, str]]] = []
    native_rows: list[tuple[int, dict[str, Any]]] = []
    count = 0
    cursor = end
    with path.open("rb") as handle:
        with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
            while cursor > 0 and count < limit:
                line_end = cursor - 1 if data[cursor - 1] == 10 else cursor
                if line_end <= 0:
                    cursor = 0
                    break
                newline = data.rfind(b"\n", 0, line_end)
                line_start = newline + 1
                raw = data[line_start:line_end].strip()
                cursor = line_start
                if not raw.startswith(b"{"):
                    continue
                try:
                    obj = json.loads(raw)
                except Exception:
                    continue
                if not isinstance(obj, dict):
                    continue
                native_rows.append((line_start, obj))
                line_turns = _transcript_object_turns(obj, source, line_start)
                if not line_turns:
                    continue
                for turn in line_turns:
                    turn["text"] = _redact_transcript(redact_text(turn["text"]))
                groups.append(line_turns)
                count += len(line_turns)
    turns = [turn for group in reversed(groups) for turn in group]
    timeline, trimmed_activities = _transcript_timeline_bounded(list(reversed(native_rows)), source)
    return {"turns": turns, "timeline": timeline,
            "trimmedActivities": trimmed_activities,
            "cursor": cursor if cursor > 0 else None,
            "hasMore": cursor > 0, "fileSize": size}


def _json_value(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except Exception:
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


def _content_text(content: Any) -> str:
    return "\n".join(_texts_of(content)) if isinstance(content, list) else str(content or "")


def _safe_activity_text(value: Any, limit: int = AGENT_TURN_MAX_CHARS) -> str:
    return _redact_transcript(redact_text(str(value or "")[:limit]))


def _activity_value_text(value: Any) -> str:
    if isinstance(value, str):
        raw = value
    elif value is None:
        raw = ""
    else:
        try:
            raw = json.dumps(value, ensure_ascii=False, indent=2)
        except (TypeError, ValueError):
            raw = str(value)
    return _safe_activity_text(raw)


# 대화 안 이미지(붙여넣은 스크린샷 · Read 한 png · 브라우저 캡처)는 트랜스크립트에 base64 로 통째
# 박혀 있다 — 한 장에 수 MB 라 타임라인 JSON 에 실으면 3초 폴링이 못 버틴다. 그래서 타임라인엔
# **참조만** 넣고 바이트는 요청이 올 때 그 줄만 다시 읽어 돌려준다.
# ref = "<줄 시작 바이트오프셋>-<블록 인덱스>[-<tool_result 안 중첩 인덱스>]".
_IMAGE_REF_RE = re.compile(r"\d{1,15}(?:-\d{1,4}){1,2}")
_IMAGE_LINE_MAX = 64 * 1024 * 1024
_IMAGE_BYTES_MAX = 32 * 1024 * 1024


def _image_descriptor(block: Any, offset: int, indexes: tuple[int, ...]) -> dict[str, Any] | None:
    if not isinstance(block, dict) or block.get("type") != "image":
        return None
    src = block.get("source") if isinstance(block.get("source"), dict) else {}
    data = src.get("data")
    if src.get("type") != "base64" or not isinstance(data, str) or not data:
        return None      # url 소스 등 — 우리가 다시 읽어 줄 수 있는 형태가 아니다
    return {
        "ref": "-".join(str(part) for part in (offset, *indexes)),
        "mediaType": str(src.get("media_type") or "image/png"),
        "bytes": _b64_size(data),
    }


def _b64_size(data: str) -> int:
    padding = len(data) - len(data.rstrip("="))
    return max(0, (len(data) * 3) // 4 - padding)


def _image_descriptors(content: Any, offset: int, prefix: tuple[int, ...] = ()) -> list[dict[str, Any]]:
    if not isinstance(content, list):
        return []
    found: list[dict[str, Any]] = []
    for index, block in enumerate(content):
        item = _image_descriptor(block, offset, (*prefix, index))
        if item:
            found.append(item)
    return found


def _activity_type(name: str, detail: str) -> str:
    lowered = name.strip().lower()
    detail_lower = detail.lower()
    if lowered == "skill" or re.search(r"(?:^|/)skills/[^/]+/skill\.md(?:\s|$|['\"])", detail_lower):
        return "skill"
    if lowered in ("apply_patch", "edit", "multiedit", "patch") or "tools.apply_patch(" in detail_lower or re.search(r"\*\*\*\s+(?:update|add|delete)\s+file:", detail_lower):
        return "diff"
    if lowered in ("write", "read", "notebookedit"):
        return "file"
    if lowered in ("bash", "exec", "exec_command", "shell", "terminal"):
        return "command"
    if lowered in ("agent", "task", "spawn_agent", "create_agent"):
        return "agent"
    return "tool"


def _activity_file_path(raw_input: Any, detail: str) -> str:
    """file/diff 활동이 건드린 파일 경로. 라벨과 payload 두 군데서 쓰므로 규칙은 여기 하나뿐이다."""
    payload = _json_value(raw_input)
    target = str(payload.get("file_path") or payload.get("path") or payload.get("file") or "").strip()
    if not target:
        # codex diff 는 구조화 payload 가 없고 본문에 "*** Update File: <경로>" 로만 남는다
        match = re.search(r"\*\*\*\s+(?:update|add|delete)\s+file:\s*([^\s'\";\\]+)", detail, re.I)
        target = match.group(1) if match else ""
    return target


def _activity_label(name: str, activity_type: str, raw_input: Any, detail: str) -> str:
    payload = _json_value(raw_input)
    if activity_type == "skill":
        skill = str(payload.get("skill") or payload.get("name") or "").strip()
        if not skill:
            match = re.search(r"(?:^|/)skills/([^/]+)/skill\.md", detail, re.I)
            skill = match.group(1) if match else ""
        return skill or "Skill"
    if activity_type == "command":
        command = str(payload.get("cmd") or payload.get("command") or "").strip()
        fallback = detail.strip().splitlines()[0][:140] if detail.strip() else name
        return (command.splitlines()[0][:140] if command else fallback) or "Command"
    if activity_type in ("diff", "file"):
        target = _activity_file_path(raw_input, detail)
        return target or name or ("Diff" if activity_type == "diff" else "File")
    if activity_type == "agent":
        prompt = str(payload.get("message") or payload.get("prompt") or payload.get("task") or "").strip()
        return (prompt.splitlines()[0][:140] if prompt else name) or "Agent"
    return name or "Tool"


def _activity_failed(value: Any, container: dict[str, Any]) -> bool:
    if bool(container.get("is_error") or container.get("isError")):
        return True
    parsed = _json_value(value)
    return bool(parsed.get("is_error") or parsed.get("isError") or parsed.get("error"))


# 질문·답은 **대화**다 — 도구가 아니다.
#
# 답을 마친 AskUserQuestion 은 지금껏 접힌 "작업" 서랍 안의 도구 한 줄로 들어갔다. 질문 전문도
# 형이 고른 답도 그 안에 다 들어 있는데 대화엔 안 보였다(형: "질문한거랑 답변한거 왜 안보여줘").
# 그래서 활동이 아니라 **전용 kind** 로 내보낸다. 웹·모바일이 같은 타임라인을 쓰므로 여기 하나면 된다.
_QUESTION_TOOL = "AskUserQuestion"
_ANSWER_TAIL_RE = re.compile(r"\.\s*You can now continue.*$", re.S)


def _question_blocks(raw_input: Any) -> list[dict[str, Any]]:
    payload = _json_value(raw_input)
    raw = payload.get("questions")
    if not isinstance(raw, list):
        return []
    blocks: list[dict[str, Any]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        options = [
            {"label": _safe_activity_text(option.get("label"), 200),
             "description": _safe_activity_text(option.get("description"), 400)}
            for option in (entry.get("options") or []) if isinstance(option, dict)
        ]
        blocks.append({
            "question": _safe_activity_text(entry.get("question"), 600),
            "header": _safe_activity_text(entry.get("header"), 60),
            "multiSelect": bool(entry.get("multiSelect")),
            "options": options,
        })
    return blocks


def _question_answers(questions: list[dict[str, Any]], result: str) -> list[dict[str, Any]]:
    """결과 문구에서 질문별로 고른 답을 뽑는다.

    형식은 `Your questions have been answered: "<질문>"="<답>", … .` 인데, **문자열을 따옴표로
    쪼개면 안 된다** — 질문 안에 따옴표가 들어가면(실제로 있었다) 바로 어긋난다. 질문 원문으로
    자리를 잡고, 거기서부터는 **아는 선택지 라벨과 대조**해 고른 것을 찾는다."""
    body = _ANSWER_TAIL_RE.sub("", str(result or "")).strip()
    answers: list[dict[str, Any]] = []
    for entry in questions:
        question = str(entry.get("question") or "")
        marker = f'"{question}"="'
        at = body.find(marker) if question else -1
        rest = body[at + len(marker):] if at >= 0 else ""
        end = rest.rfind('"')
        text = (rest[:end] if end > 0 else rest).strip()
        labels = sorted((str(option.get("label") or "") for option in entry.get("options") or []),
                        key=len, reverse=True)
        picked: list[str] = []
        for label in labels:
            # 긴 라벨부터 본다 — 짧은 라벨이 긴 라벨의 일부일 때 둘 다 고른 것처럼 보이면 안 된다.
            if label and label in text and not any(label in chosen for chosen in picked):
                picked.append(label)
        answers.append({"text": text, "picked": picked})
    return answers


def _new_timeline_question(source: str, offset: int, index: int, call_id: str,
                           questions: list[dict[str, Any]], model: str, effort: str) -> dict[str, Any]:
    item = {
        "id": f"{source}:question:{call_id or f'{offset}:{index}'}",
        "kind": "question",
        "name": _QUESTION_TOOL,
        "questions": questions,
        "answers": [],
        "status": "running",
    }
    if model:
        item["model"] = model
    if effort:
        item["effort"] = effort
    return item


def _new_timeline_activity(source: str, offset: int, index: int, name: str,
                           call_id: str, raw_input: Any, model: str = "",
                           effort: str = "") -> dict[str, Any]:
    if name == _QUESTION_TOOL:
        questions = _question_blocks(raw_input)
        if questions:
            return _new_timeline_question(source, offset, index, call_id, questions, model, effort)
    detail = _activity_value_text(raw_input)
    activity_type = _activity_type(name, detail)
    item = {
        "id": f"{source}:activity:{call_id or f'{offset}:{index}'}",
        "kind": "activity",
        "activityType": activity_type,
        "name": name,
        "label": _activity_label(name, activity_type, raw_input, detail),
        "detail": detail,
        "result": "",
        "status": "running",
    }
    # 파일/디프 활동은 대상 경로를 **명시 필드**로 싣는다 — 채팅에서 그 파일을 바로 열려면 UI 가
    # 경로를 알아야 하는데, label 은 표시용이라(잘리고 바뀐다) 계약으로 쓸 수 없다.
    if activity_type in ("diff", "file"):
        target = _activity_file_path(raw_input, detail)
        if target:
            item["path"] = target
    if model:
        item["model"] = model
    if effort:
        item["effort"] = effort
    return item


def _transcript_timeline(rows: list[tuple[int, dict[str, Any]]], source: str) -> list[dict[str, Any]]:
    """타임라인만. 기존 계약(리스트 반환)을 그대로 유지한다 — 여러 테스트가 이 helper 를 직접 부른다."""
    timeline, _ = _transcript_timeline_bounded(rows, source)
    return timeline


def _transcript_timeline_bounded(rows: list[tuple[int, dict[str, Any]]],
                                 source: str) -> tuple[list[dict[str, Any]], int]:
    """(타임라인, 상한 때문에 버린 활동 수). 버린 수를 같이 주는 이유는 화면이 조용히 적게
    세는 걸 막기 위해서다 — 잘렸으면 잘렸다고 말해야 한다."""
    timeline: list[dict[str, Any]] = []
    calls: dict[str, dict[str, Any]] = {}
    runtime = {"model": "", "effort": ""}
    seen_queue: set[str] = set()   # 큐 메시지 content dedup(시스템이 enqueue→remove 후 재enqueue 하는 아티팩트 방지)
    # 큐 메시지의 최후: **전달** 아니면 **취소**다. 미리 스캔해 말풍선 처리를 가른다.
    #
    # 전달: Claude Code 는 큐를 소비할 때 dequeue 를 남기는데 그 행은 content 가 null 이라 내용으로
    # 못 맞춘다. 대신 소비된 큐는 **진짜 user 행**으로 다시 기록되므로 그걸 신호로 쓴다. 전달된 큐는
    # 말풍선을 아예 만들지 않는다 — 안 그러면 같은 말이 두 번 뜨고(queued + user) 배지도 "대기 중"으로
    # 영원히 남는다(실기기 확인: enqueue 23 / dequeue 22 / remove 1 인데 remove 만 보고 있었다).
    #
    # 취소: remove 는 사용자가 큐에서 뺀 것이라 전달이 아니다 — 따로 표시한다.
    # 매칭 키는 enqueue 쪽과 **같은 변환**을 거쳐야 한다(_safe_activity_text = 마스킹 + 길이 제한).
    # 한쪽만 원문이면 긴 메시지나 secret 포함 메시지에서 조용히 안 맞는다.
    def queue_key(value: Any) -> str:
        return _safe_activity_text(value).strip()

    delivered_queue: set[str] = set()
    for _, o in rows:
        if o.get("type") != "user":
            continue
        message = o.get("message") if isinstance(o.get("message"), dict) else {}
        content = message.get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = " ".join(str(c.get("text") or "") for c in content
                            if isinstance(c, dict) and c.get("type") == "text")
        else:
            text = ""
        if text.strip():
            delivered_queue.add(queue_key(text))
    # **스티어링(작업 중 끼어든 메시지)**: 실행 중인 턴이 삼키면 진짜 user 행이 안 생기고
    # attachment(type=queued_command, prompt=원문)로만 배달 기록이 남는다. 그리고 큐에서 빠지니
    # remove 도 같이 남는다. 그래서 remove 만 보고 '취소됨'을 붙이면, 형이 보내고 내가 실제로 소화한
    # 메시지가 취소됨으로 뒤집힌다(실측: 최근 25세션에 27건 · 이 세션의 "뭐하니"가 그 예).
    steered_queue: set[str] = set()
    for _, o in rows:
        if o.get("type") != "attachment":
            continue
        attachment = o.get("attachment") if isinstance(o.get("attachment"), dict) else {}
        if attachment.get("type") != "queued_command":
            continue
        prompt = queue_key(attachment.get("prompt"))
        if prompt:
            steered_queue.add(prompt)
    # 취소는 **배달 흔적이 하나도 없는** remove 뿐이다.
    cancelled_queue: set[str] = {
        key for key in (
            queue_key(o.get("content"))
            for _, o in rows
            if o.get("type") == "queue-operation" and o.get("operation") == "remove"
        )
        if key and key not in delivered_queue and key not in steered_queue
    }

    def with_runtime(item: dict[str, Any], model: str = "", effort: str = "") -> dict[str, Any]:
        resolved_model = model or runtime["model"]
        resolved_effort = effort or runtime["effort"]
        if resolved_model:
            item["model"] = resolved_model
        if resolved_effort:
            item["effort"] = resolved_effort
        return item

    for offset, obj in rows:
        if source == "claude":
            role = str(obj.get("type") or "")
            # 큐 메시지: Claude Code 는 작업 중 큐로 넣은 사용자 메시지를 type:user 가 아니라 queue-operation(enqueue/remove)
            # 으로만 기록한다. user/assistant 만 읽으면 통째로 사라지고 그 작업이 앞 exchange 에 묶인다. enqueue 를 user 메시지로 렌더.
            if role == "queue-operation":
                if obj.get("operation") == "enqueue":
                    qtext = _safe_activity_text(obj.get("content"))
                    key = qtext.strip()
                    # 주입 래퍼(<task-notification>·<system-reminder>·[SYSTEM NOTIFICATION])는 작업 중 도착하면
                    # queue-operation 으로 기록되는데, 이건 사용자가 친 큐 메시지가 아니라 하네스 주입이다. user/assistant
                    # 경로의 _is_injected_user 필터가 여기엔 안 걸려 그동안 "대기 중" 큐 말풍선으로 새어 문신됐다(형 지적).
                    if key in delivered_queue:
                        continue          # 이미 진짜 user 행으로 들어온다 — 말풍선을 또 만들면 중복이다
                    if key and key not in seen_queue and not key.lstrip().startswith(_CLAUDE_INJECT_PREFIXES):
                        seen_queue.add(key)
                        item = {"id": f"{source}:queue:{offset}", "kind": "message",
                                "role": "user", "text": qtext}
                        if key in steered_queue:
                            # 작업 중에 전달돼 이미 소화된 말이다 — 대기도 취소도 아니다. 진짜 user 행이
                            # 없으니 여기서 말풍선을 만들어야 형이 자기가 한 말을 볼 수 있다.
                            item["steered"] = True
                        else:
                            item["queued"] = True
                            item["queuedCancelled"] = key in cancelled_queue
                        timeline.append(with_runtime(item))
                continue
            message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
            content = message.get("content")
            if role not in ("user", "assistant"):
                continue
            if isinstance(content, str):   # 사용자 직접 입력은 content 가 str — timeline 에서 빠지지 않게 정규화
                content = [{"type": "text", "text": content}] if content.strip() else []
            if not isinstance(content, list):
                continue
            if _is_hidden_turn(obj, role, source, _texts_of(content)):
                continue                    # 주입 user + noop assistant 제외(turns 와 동일)
            message_model = str(message.get("model") or "") if role == "assistant" else ""
            if message_model == "<synthetic>":   # 합성 메시지는 실모델 아님 — 직전 실모델 유지(라벨/설정에 synthetic 새는 것 방지)
                message_model = ""
            message_effort = str(obj.get("effort") or message.get("effort") or message.get("reasoning_effort") or "") if role == "assistant" else ""   # effort 는 row 최상위에 있음
            if message_model:
                runtime["model"] = message_model
            if message_effort:
                runtime["effort"] = message_effort
            message_images = _image_descriptors(content, offset)
            first_message_item: dict[str, Any] | None = None
            for index, block in enumerate(content):
                if not isinstance(block, dict):
                    continue
                block_type = block.get("type")
                if block_type == "text":
                    text = _safe_activity_text(block.get("text"))
                    if text.strip():
                        item = with_runtime(
                            {"id": f"{source}:message:{offset}:{index}", "kind": "message",
                             "role": role, "text": text}, message_model, message_effort,
                        )
                        timeline.append(item)
                        if first_message_item is None:
                            first_message_item = item
                elif block_type == "tool_use":
                    call_id = str(block.get("id") or "")
                    item = _new_timeline_activity(source, offset, index, str(block.get("name") or ""),
                                                  call_id, block.get("input"), message_model, message_effort)
                    timeline.append(item)
                    if call_id:
                        calls[call_id] = item
                elif block_type == "tool_result":
                    call_id = str(block.get("tool_use_id") or "")
                    item = calls.get(call_id)
                    if item is not None:
                        result_text = _activity_value_text(block.get("content"))
                        item["status"] = "failed" if _activity_failed(block.get("content"), block) else "completed"
                        if item.get("kind") == "question":
                            # 질문 카드는 결과 원문을 싣지 않는다 — 고른 답만 대화에 보이면 된다.
                            item["answers"] = _question_answers(item.get("questions") or [], result_text)
                        else:
                            item["result"] = result_text
                        # 스크린샷·이미지 Read 의 결과는 tool_result 안에 base64 로 들어온다 — 참조만 붙인다.
                        result_images = _image_descriptors(block.get("content"), offset, (index,))
                        if result_images:
                            item["images"] = result_images
            if message_images:
                # 텍스트 없이 이미지만 붙여넣은 턴도 있다 — 그때는 이미지 전용 말풍선을 따로 만든다.
                if first_message_item is not None:
                    first_message_item["images"] = message_images
                else:
                    timeline.append(with_runtime(
                        {"id": f"{source}:message:{offset}:img", "kind": "message",
                         "role": role, "text": "", "images": message_images},
                        message_model, message_effort,
                    ))
        else:
            payload = obj.get("payload") or {}
            payload_type = payload.get("type")
            if obj.get("type") == "turn_context":
                runtime["model"] = str(payload.get("model") or runtime["model"])
                runtime["effort"] = str(payload.get("effort") or payload.get("reasoning_effort") or runtime["effort"])
                continue
            if obj.get("type") != "response_item":
                continue
            if payload_type == "message":
                role = str(payload.get("role") or "")
                if role not in ("user", "assistant"):
                    continue
                msg_texts = _texts_of(payload.get("content"))
                if _is_hidden_turn(obj, role, source, msg_texts):
                    continue                # 주입 user + noop assistant 제외
                for index, text in enumerate(msg_texts):
                    safe_text = _safe_activity_text(text)
                    timeline.append(with_runtime(
                        {"id": f"{source}:message:{offset}:{index}", "kind": "message",
                         "role": role, "text": safe_text},
                    ))
            elif payload_type in ("function_call", "custom_tool_call"):
                call_id = str(payload.get("call_id") or payload.get("id") or "")
                raw_input = payload.get("arguments") if payload_type == "function_call" else payload.get("input")
                item = _new_timeline_activity(source, offset, 0, str(payload.get("name") or ""),
                                              call_id, raw_input, runtime["model"], runtime["effort"])
                timeline.append(item)
                if call_id:
                    calls[call_id] = item
            elif payload_type in ("function_call_output", "custom_tool_call_output"):
                call_id = str(payload.get("call_id") or "")
                item = calls.get(call_id)
                if item is not None:
                    output = payload.get("output")
                    item["result"] = _activity_value_text(output)
                    item["status"] = "failed" if _activity_failed(output, payload) else "completed"
    activity_count = sum(1 for item in timeline if item.get("kind") == "activity")
    if activity_count <= AGENT_TIMELINE_MAX_ACTIVITIES:
        return timeline, 0
    # 상한을 넘으면 오래된 활동을 버리는데, **몇 개 버렸는지 같이 돌려준다**. 예전엔 조용히 잘라서
    # 화면의 "작업 N"이 실제보다 적었고, 형이 기억하는 것과 안 맞았다(상한에 딱 걸린 세션이 그 예).
    dropped = activity_count - AGENT_TIMELINE_MAX_ACTIVITIES
    keep = dropped
    bounded: list[dict[str, Any]] = []
    for item in timeline:
        if item.get("kind") == "activity" and keep > 0:
            keep -= 1
            continue
        bounded.append(item)
    return bounded, dropped


def _codex_rollout_path(sid: str, root: Path | None = None) -> Path | None:
    matches: list[Path] = []
    for base in CODEX_ROLLOUT_DIRS:
        if not base.is_dir():
            continue
        for raw_path in glob.iglob(str(base / "**" / f"rollout-*{sid}.jsonl"), recursive=True):
            path = Path(raw_path)
            try:
                with path.open(encoding="utf-8") as handle:
                    meta = json.loads(handle.readline())
                payload = meta.get("payload") or {}
                if meta.get("type") != "session_meta" or payload.get("id") != sid:
                    continue
                if root is not None and Path(str(payload.get("cwd") or "")).resolve() != root.resolve():
                    continue
            except Exception:
                continue
            matches.append(path)
    return max(matches, key=lambda path: path.stat().st_mtime) if matches else None


def _claude_agent_activity(root: Path, sid: str) -> list[dict[str, Any]]:
    session_dir = CLAUDE_PROJECTS_DIR / _claude_project_slug(root)
    parent = session_dir / f"{sid}.jsonl"
    if not parent.is_file():
        return []
    calls: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    markers = (b'"tool_use"', b'"tool_result"', b"task-notification")
    for obj in _scan_json_objects(parent, markers):
        message_content = (obj.get("message") or {}).get("content")
        notification = obj.get("content") if isinstance(obj.get("content"), str) else message_content if isinstance(message_content, str) else ""
        if "<task-notification>" in notification:
            tool_match = re.search(r"<tool-use-id>([^<]+)</tool-use-id>", notification)
            task_match = re.search(r"<task-id>([^<]+)</task-id>", notification)
            status_match = re.search(r"<status>([^<]+)</status>", notification)
            item = calls.get(tool_match.group(1)) if tool_match else None
            if item is None and task_match:
                task_id = task_match.group(1).strip()
                item = next(
                    (candidate for call_id, candidate in calls.items() if call_id == task_id or candidate.get("id") == task_id),
                    None,
                )
            if item and status_match:
                status = status_match.group(1).strip().lower()
                if status == "completed":
                    item["status"] = "completed"
                elif status in ("failed", "error"):
                    item["status"] = "failed"
                elif status in ("stopped", "cancelled", "canceled"):
                    item["status"] = "stopped"
        blocks = message_content if isinstance(message_content, list) else []
        for block in blocks:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use" and block.get("name") in ("Agent", "Task"):
                call_id = str(block.get("id") or "")
                if not call_id:
                    continue
                args = block.get("input") if isinstance(block.get("input"), dict) else {}
                calls[call_id] = {
                    "id": call_id,
                    "title": _safe_activity_text(args.get("description") or args.get("subagent_type") or "Subagent", 160),
                    "status": "running",
                    "preview": _safe_activity_text(args.get("prompt") or args.get("description") or ""),
                    "turns": [],
                    "name": str(args.get("name") or ""),
                }
                order.append(call_id)
            elif block.get("type") == "tool_result":
                call_id = str(block.get("tool_use_id") or "")
                item = calls.get(call_id)
                if not item:
                    continue
                result_text = _content_text(block.get("content"))
                match = re.search(r"agentId\s*[:=]\s*['\"]?([A-Za-z0-9_-]+)", result_text)
                if match:
                    item["id"] = match.group(1)
                if block.get("is_error"):
                    item["status"] = "failed"
                elif "working in the background" not in result_text.lower():
                    item["status"] = "completed"
                if result_text and item["status"] != "running":
                    item["preview"] = _safe_activity_text(result_text)

    by_tool, by_name, by_id = _claude_subagent_index(session_dir / sid / "subagents")
    for call_id, item in calls.items():
        # 파일명(agentId)은 비동기로 띄운 것만 결과 텍스트에 실린다. 동기 실행·이름 붙은
        # 팀메이트는 agentId 가 없어 지금껏 파일이 있는데도 못 붙었다 — .meta.json 의
        # toolUseId·name 이 하네스가 남긴 진짜 연결고리다.
        name = str(item.pop("name", "") or "")
        child = by_tool.get(call_id) or by_id.get(str(item["id"])) or (by_name.get(name) if name else None)
        if not child:
            continue
        turns = _transcript_turns(child, "claude")
        item["turns"] = turns[-12:]
        if turns:
            item["preview"] = turns[-1]["text"]
    return [calls[call_id] for call_id in order][-20:]


def _claude_subagent_index(child_dir: Path) -> tuple[dict[str, Path], dict[str, Path], dict[str, Path]]:
    """subagents/ 를 toolUseId·name·파일명(agentId) 세 갈래로 색인한다."""
    by_tool: dict[str, Path] = {}
    by_name: dict[str, Path] = {}
    by_id: dict[str, Path] = {}
    if not child_dir.is_dir():
        return by_tool, by_name, by_id
    for path in child_dir.glob("agent-*.jsonl"):
        by_id[path.stem.removeprefix("agent-")] = path
        try:
            meta = json.loads(path.with_suffix(".meta.json").read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(meta, dict):
            continue
        tool_use_id = str(meta.get("toolUseId") or "")
        name = str(meta.get("name") or "")
        if tool_use_id:
            by_tool[tool_use_id] = path
        if name:
            by_name[name] = path
    return by_tool, by_name, by_id


def _codex_agent_activity(root: Path, sid: str) -> list[dict[str, Any]]:
    entries = codex_agent_sessions().get(str(root), [])
    parent_entry = next((entry for entry in entries if entry.get("sid") == sid), None)
    parent_path = Path(parent_entry.get("path") or "") if parent_entry else _codex_rollout_path(sid, root)
    if not parent_path or not parent_path.is_file():
        return []
    calls: dict[str, dict[str, Any]] = {}
    spawn_calls: dict[str, str] = {}
    wait_calls: dict[str, list[str]] = {}
    order: list[str] = []
    for obj in _scan_json_objects(parent_path, (b'"function_call"', b'"function_call_output"')):
        payload = obj.get("payload") or {}
        payload_type = payload.get("type")
        call_id = str(payload.get("call_id") or "")
        if payload_type == "function_call" and payload.get("name") == "spawn_agent":
            args = _json_value(payload.get("arguments"))
            spawn_calls[call_id] = call_id
            calls[call_id] = {
                "id": call_id,
                "title": _safe_activity_text(args.get("agent_type") or "Subagent", 160),
                "status": "running",
                "preview": _safe_activity_text(args.get("message") or ""),
                "turns": [],
                "agentType": _safe_activity_text(args.get("agent_type") or "", 80),
            }
            order.append(call_id)
        elif payload_type == "function_call" and payload.get("name") in ("wait_agent", "wait"):
            args = _json_value(payload.get("arguments"))
            wait_calls[call_id] = [str(value) for value in args.get("targets", [])]
        elif payload_type == "function_call_output" and call_id in spawn_calls:
            output = _json_value(payload.get("output"))
            item = calls.get(spawn_calls[call_id])
            if not item:
                continue
            agent_id = str(output.get("agent_id") or "")
            if agent_id:
                item["id"] = agent_id
            nickname = str(output.get("nickname") or "")
            agent_type = str(item.pop("agentType", "") or "")
            item["title"] = _safe_activity_text(" · ".join(value for value in (nickname, agent_type) if value) or "Subagent", 160)
            if not agent_id:
                item["status"] = "failed"
        elif payload_type == "function_call_output" and call_id in wait_calls:
            output = _json_value(payload.get("output"))
            statuses = output.get("status") if isinstance(output.get("status"), dict) else {}
            for agent_id in wait_calls[call_id]:
                item = next((value for value in calls.values() if value.get("id") == agent_id), None)
                status = statuses.get(agent_id) if isinstance(statuses, dict) else None
                if not item or not isinstance(status, dict):
                    continue
                if "completed" in status:
                    item["status"] = "completed"
                    item["preview"] = _safe_activity_text(status.get("completed"))
                elif "failed" in status or "error" in status:
                    item["status"] = "failed"

    for item in calls.values():
        child_path = _codex_rollout_path(str(item["id"]), root)
        if not child_path or not child_path.is_file():
            item.pop("agentType", None)
            continue
        turns = _transcript_turns(child_path, "codex")
        item["turns"] = turns[-12:]
        if turns:
            item["preview"] = turns[-1]["text"]
    return [calls[call_id] for call_id in order][-20:]


def agent_activity(root: Path, source: str, sid: str) -> list[dict[str, Any]]:
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]{3,63}", sid or ""):
        return []
    if source == "claude":
        return _claude_agent_activity(root, sid)
    if source == "codex":
        return _codex_agent_activity(root, sid)
    return []


def agent_runtime_settings(root: Path, source: str, sid: str) -> dict[str, str]:
    """Read the model/effort last recorded by the native CLI session."""
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]{3,63}", sid or ""):
        return {"model": "", "effort": ""}
    if source == "claude":
        path = CLAUDE_PROJECTS_DIR / _claude_project_slug(root) / f"{sid}.jsonl"
    elif source == "codex":
        entry = next((e for e in codex_agent_sessions().get(str(root), []) if e.get("sid") == sid), None)
        path = Path(str((entry or {}).get("path") or ""))
    else:
        return {"model": "", "effort": ""}
    if not path.is_file():
        return {"model": "", "effort": ""}
    for obj in _reverse_json_objects(path):
        if source == "claude" and obj.get("type") == "assistant":
            message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
            # effort 는 Claude Code 가 row 최상위에 기록한다(message 안이 아님) — 그래서 지금껏 항상 빈 값이었음.
            model = str(message.get("model") or "")
            effort = str(obj.get("effort") or message.get("effort") or "")
            if model == "<synthetic>":   # Claude Code 합성 어시스턴트 메시지 — 실모델 아님, 더 뒤로 스캔
                continue
        elif source == "codex" and obj.get("type") in ("turn_context", "event_msg"):
            payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
            if obj.get("type") == "event_msg" and payload.get("type") != "thread_settings_applied":
                continue
            settings = payload.get("thread_settings") if isinstance(payload.get("thread_settings"), dict) else payload
            model = str(settings.get("model") or "")
            effort = str(settings.get("effort") or settings.get("reasoning_effort") or "")
        else:
            continue
        if model or effort:
            return {"model": model, "effort": effort}
    return {"model": "", "effort": ""}


def _usage_token_count(usage: dict[str, Any], key: str) -> int:
    value = usage.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return 0
    return max(0, int(value))


# Claude Code CLI 가 받는 모델 + 네이티브 컨텍스트 윈도우(권위 자료: claude-api 스킬, 2026).
# codex 는 ~/.codex/models_cache.json 을 쓰지만 Claude Code 는 완전한 모델 캐시가 없다
# (~/.claude.json additionalModelOptionsCache 는 사용자가 직접 만진 커스텀 모델만 담아 불완전).
# 그래서 모바일 모델 드롭다운과 컨텍스트 윈도우 폴백을 이 큐레이트 목록에서 공급한다.
# 기본값 + 정식 버전만(형 지시 — opus/sonnet/haiku alias '최신' 항목은 헷갈려 제거). 목록에 없는 건 "직접 입력"으로.
CLAUDE_MODEL_CATALOG = [
    {"value": "default", "label": "기본값 (CLI 설정 모델)", "window": None},
    {"value": "claude-opus-5", "label": "Opus 5", "window": 1_000_000},
    {"value": "claude-opus-4-8", "label": "Opus 4.8", "window": 1_000_000},
    {"value": "claude-sonnet-5", "label": "Sonnet 5", "window": 1_000_000},
    {"value": "claude-haiku-4-5", "label": "Haiku 4.5", "window": 200_000},
    {"value": "claude-fable-5", "label": "Fable 5", "window": 1_000_000},
]
_CLAUDE_WINDOW_BY_MODEL = {m["value"]: m["window"] for m in CLAUDE_MODEL_CATALOG if m["window"]}


def claude_model_catalog() -> list[dict[str, Any]]:
    """큐레이트 카탈로그 + CLI 가 캐시해 둔 추가 모델. 새 모델이 나와도 CLI 를 한 번 쓰면 따라온다.

    codex 처럼 완전한 목록 캐시(models_cache.json)가 claude 엔 없다. `~/.claude.json` 의
    additionalModelOptionsCache 는 '기본 목록에 더해진' 것만 담고(지금 이 머신엔 1개뿐) 비어 있을
    수도 있어서, 그것만으로 드롭다운을 채우면 오히려 목록이 무너진다 — 그래서 병합이다.
    캐시 값은 `claude-fable-5[1m]` 처럼 컨텍스트 마커가 붙어 오는데, CLI 인자로 넘길 값은
    마커를 뗀 모델 id 다(_MODEL_RE 가 대괄호를 허용하지 않는다)."""
    catalog = list(CLAUDE_MODEL_CATALOG)
    known = {str(m["value"]) for m in catalog}
    try:
        config = json.loads(CLAUDE_CONFIG_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return catalog
    if not isinstance(config, dict):
        return catalog
    for key in ("additionalModelOptionsCache", "modelAccessCache"):
        options = config.get(key)
        if not isinstance(options, list):
            continue
        for option in options:
            if not isinstance(option, dict):
                continue
            raw = str(option.get("value") or "")
            value = raw.split("[", 1)[0].strip()
            if not value or value in known:
                continue
            known.add(value)
            catalog.append({
                "value": value,
                "label": str(option.get("label") or value),
                "window": _model_context_window(raw),
            })
    return catalog


def _model_context_window(value: str) -> int | None:
    match = re.search(r"\[(\d+(?:\.\d+)?)([km])\]$", value.strip().lower())
    if not match:
        return None
    multiplier = 1_000 if match.group(2) == "k" else 1_000_000
    return int(float(match.group(1)) * multiplier)


def _claude_context_window(model: str) -> int | None:
    direct = _model_context_window(model)
    if direct is not None or not model:
        return direct
    try:
        config = json.loads(CLAUDE_CONFIG_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        config = None
    options = config.get("additionalModelOptionsCache") if isinstance(config, dict) else None
    if isinstance(options, list):
        for option in options:
            value = str(option.get("value") or "") if isinstance(option, dict) else ""
            if value.split("[", 1)[0] == model:
                window = _model_context_window(value)
                if window is not None:
                    return window
    # 폴백 — 트랜스크립트의 message.model 은 접미사 없는 bare id(claude-opus-4-8)라 위 두 경로가 못 잡는다.
    # 알려진 Claude 모델의 네이티브 윈도우로 컨텍스트% 를 계산(없으면 모바일 usage 패널이 "-" 로 뜬다).
    return _CLAUDE_WINDOW_BY_MODEL.get(model)


def _empty_agent_usage(source: str, model: str = "") -> dict[str, Any]:
    return {
        "source": source,
        "model": model,
        "usedTokens": None,
        "contextWindow": None,
        "remainingTokens": None,
        "contextPercent": None,
    }


def _usage_percent(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return min(100.0, max(0.0, round(float(value), 1)))


def _usage_reset_timestamp(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        return int(value)
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return int(parsed.timestamp())
    except ValueError:
        return None


def _usage_window(key: str, label: str, used: Any, reset: Any) -> dict[str, Any] | None:
    percent = _usage_percent(used)
    if percent is None:
        return None
    return {
        "key": key,
        "label": label,
        "usedPercent": percent,
        "remainingPercent": round(100.0 - percent, 1),
        "resetsAt": _usage_reset_timestamp(reset),
    }


_USAGE_PERCENT_KEYS = ("percent", "utilization", "used_percent", "usedPercent", "percentage")
_USAGE_RESET_KEYS = ("resets_at", "resetAt", "resetsAt")
# limits 항목의 kind → 우리 창. 나머지(weekly_scoped 등)는 모델 이름으로 칸을 만든다.
_CLAUDE_LIMIT_KINDS = {"session": ("fiveHour", "5시간"), "weekly_all": ("weekly", "주간")}


def _scoped_weekly_slot(name: Any) -> tuple[str, str]:
    """'Fable 5' → ('fableWeekly', 'Fable 주간'). 버전 꼬리는 뗀다 — 모델이 올라가도 같은 칸에 쌓인다."""
    head = next((part for part in re.split(r"[\s_-]+", str(name or "").strip()) if part), "")
    if not head or not head[0].isalpha():
        return "", ""
    return head[0].lower() + head[1:] + "Weekly", f"{head} 주간"


def _claude_limit_windows(data: dict[str, Any]) -> list[tuple[str, str, Any, Any]]:
    """`limits` 배열을 창 후보로 편다.

    **이 배열이 계정 한도의 진짜 목록이다.** 평평한 seven_day_opus/seven_day_sonnet 등은 이 계정에서
    전부 null 인데 배열에는 페이블 주간이 들어 있었다 — 평평한 키만 보면 영영 안 보인다. 모델을
    하드코딩하지 않는다: 새 모델이 생기면 배열에 얹혀 그대로 뜬다.

    hud 캐시의 옛 모양({"display_name": …, "utilization": …})도 같이 받는다.
    """
    entries = data.get("limits")
    if not isinstance(entries, list):
        return []
    found: list[tuple[str, str, Any, Any]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        percent = next((entry[name] for name in _USAGE_PERCENT_KEYS if entry.get(name) is not None), None)
        if percent is None:
            continue
        reset = next((entry[name] for name in _USAGE_RESET_KEYS if entry.get(name) is not None), None)
        slot = _CLAUDE_LIMIT_KINDS.get(str(entry.get("kind") or ""))
        if slot:
            found.append((slot[0], slot[1], percent, reset))
            continue
        scope = entry.get("scope") if isinstance(entry.get("scope"), dict) else {}
        model = scope.get("model") if isinstance(scope.get("model"), dict) else {}
        key, label = _scoped_weekly_slot(
            model.get("display_name") or model.get("displayName")
            or entry.get("display_name") or entry.get("displayName") or entry.get("name"))
        if key:
            found.append((key, label, percent, reset))
    return found

    return visit(data) or (None, None)


def account_usage_from_rate_limits(rate_limits: dict[str, Any] | None) -> dict[str, Any]:
    """Normalize Codex primary/secondary quota windows for the mobile UI."""
    limits = rate_limits if isinstance(rate_limits, dict) else {}
    by_minutes = {300: ("fiveHour", "5시간"), 10080: ("weekly", "주간")}
    windows_by_key: dict[str, dict[str, Any]] = {}
    for name in ("primary", "secondary"):
        item = limits.get(name)
        if not isinstance(item, dict) or item.get("window_minutes") not in by_minutes:
            continue
        key, label = by_minutes[item["window_minutes"]]
        normalized = _usage_window(key, label, item.get("used_percent"), item.get("resets_at"))
        if normalized:
            windows_by_key[key] = normalized
    windows = [windows_by_key[key] for key in ("fiveHour", "weekly") if key in windows_by_key]
    return {"source": "codex", "windows": windows}


def account_usage_from_claude_cache(cache: dict[str, Any] | None) -> dict[str, Any]:
    """Claude 계정 사용량을 창 목록으로 정규화한다(공식 /api/oauth/usage 응답과 hud 캐시 두 모양)."""
    value = cache.get("data") if isinstance(cache, dict) and isinstance(cache.get("data"), dict) else cache
    data = value if isinstance(value, dict) else {}
    scoped = _claude_limit_windows(data)
    from_limits = {key: (percent, reset) for key, _, percent, reset in reversed(scoped)}
    windows: list[dict[str, Any]] = []
    emitted: set[str] = set()
    # 모델별 주간 창은 계정/플랜에 따라 있을 때만 값이 온다(없으면 null → 창이 안 생긴다).
    for key, label, percent_keys, reset_keys in (
        ("fiveHour", "5시간", ("fiveHour", "five_hour"), ("fiveHourResetAt", "five_hour_reset_at")),
        ("weekly", "주간", ("sevenDay", "seven_day"), ("sevenDayResetAt", "seven_day_reset_at")),
        ("opusWeekly", "Opus 주간", ("sevenDayOpus", "seven_day_opus"), ()),
        ("sonnetWeekly", "Sonnet 주간", ("sevenDaySonnet", "seven_day_sonnet"), ()),
        ("fableWeekly", "Fable 주간", ("fableWeekly", "fable_weekly", "sevenDayFable", "seven_day_fable"),
         ("fableWeeklyResetAt", "fable_weekly_reset_at", "sevenDayFableResetAt", "seven_day_fable_reset_at")),
    ):
        percent = next((data.get(name) for name in percent_keys if name in data), None)
        reset = next((data.get(name) for name in reset_keys if name in data), None)
        if isinstance(percent, dict):
            item = percent
            percent = next((item.get(name) for name in _USAGE_PERCENT_KEYS if name in item), None)
            reset = next((item.get(name) for name in _USAGE_RESET_KEYS if name in item), reset)
        if percent is None:   # 평평한 키가 없거나 null 이면 limits 배열이 답이다
            percent, reset = from_limits.get(key, (None, reset))
        normalized = _usage_window(key, label, percent, reset)
        if normalized:
            windows.append(normalized)
            emitted.add(key)
    # 위 목록에 없는 모델의 주간 창(=우리가 모르는 새 모델)은 응답 순서대로 뒤에 붙인다
    for key, label, percent, reset in scoped:
        normalized = _usage_window(key, label, percent, reset) if key not in emitted else None
        if normalized:
            windows.append(normalized)
            emitted.add(key)
    return {"source": "claude", "windows": windows}


def _latest_codex_rate_limits(root: Path | None = None) -> dict[str, Any] | None:
    # 계정 한도는 **계정 단위**다. 예전엔 root 의 롤아웃을 우선 봤는데, 그 워크트리에서 codex 를
    # 한동안 안 쓰면 낡은 숫자가 계속 떴다(다른 워크트리에서 쓴 최신 값이 있는데도). 그래서
    # 모든 롤아웃 중 가장 최근 것을 본다 — root 는 동률일 때의 선호로만 남긴다.
    paths: list[Path] = []
    for base in CODEX_ROLLOUT_DIRS:
        if base.is_dir():
            paths.extend(Path(path) for path in glob.iglob(str(base / "**" / "rollout-*.jsonl"), recursive=True))
    if not paths and root is not None:
        paths = [Path(str(item.get("path"))) for item in codex_agent_sessions().get(str(root), []) if item.get("path")]
    for path in sorted(paths, key=lambda item: item.stat().st_mtime if item.is_file() else 0, reverse=True):
        for obj in _reverse_json_objects(path):
            payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
            limits = payload.get("rate_limits")
            if obj.get("type") == "event_msg" and payload.get("type") == "token_count" and isinstance(limits, dict):
                return limits
    return None


def provider_account_usage(source: str, root: Path | None = None) -> dict[str, Any]:
    if source == "codex":
        return account_usage_from_rate_limits(_latest_codex_rate_limits(root))
    if source == "claude":
        # 1순위: 우리가 직접 가져온다(claude CLI 와 같은 /api/oauth/usage). 예전엔 써드파티 플러그인의
        # 캐시만 읽었는데 그게 47일째 멈춰 있어 사용량이 늘 빈칸이었다 — 남의 캐시를 기다리지 않는다.
        try:
            from marina_usage import claude_usage_payload
            payload = claude_usage_payload()
        except Exception:
            payload = None
        if payload:
            live = account_usage_from_claude_cache(payload)
            if live.get("windows"):
                return live
        # 2순위: 그 플러그인 캐시가 **신선할 때만**(토큰을 못 읽는 환경 대비).
        try:
            cache = json.loads(CLAUDE_USAGE_CACHE_FILE.read_text(encoding="utf-8"))
            timestamp = cache.get("timestamp") if isinstance(cache, dict) else None
            if not isinstance(timestamp, (int, float)) or time.time() * 1000 - timestamp > CLAUDE_USAGE_CACHE_MAX_AGE_MS:
                return {"source": "claude", "windows": []}
            return account_usage_from_claude_cache(cache)
        except (OSError, ValueError):
            return {"source": "claude", "windows": []}
    return {"source": source, "windows": []}


def _normalized_agent_usage(source: str, model: str, used: int,
                            window: int | None) -> dict[str, Any]:
    if window is None or window <= 0:
        remaining = None
        percent = None
    else:
        remaining = max(0, window - used)
        percent = min(100.0, round(used * 100 / window, 1))
    return {
        "source": source,
        "model": model,
        "usedTokens": used,
        "contextWindow": window,
        "remainingTokens": remaining,
        "contextPercent": percent,
    }


def agent_usage_from_path(path: Path, source: str) -> dict[str, Any]:
    """Read the newest native context counter without scanning session history."""
    if source not in ("claude", "codex"):
        raise ValueError("unknown source")
    if not path.is_file():
        return _empty_agent_usage(source)
    for obj in _reverse_json_objects(path):
        if source == "codex":
            payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
            if obj.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
            latest = info.get("last_token_usage") if isinstance(info.get("last_token_usage"), dict) else {}
            used = latest.get("total_tokens")
            window = info.get("model_context_window")
            if isinstance(used, bool) or not isinstance(used, (int, float)):
                continue
            normalized_window = int(window) if isinstance(window, (int, float)) and not isinstance(window, bool) else None
            return _normalized_agent_usage(source, "", max(0, int(used)), normalized_window)
        if obj.get("type") != "assistant":
            continue
        message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
        usage = message.get("usage") if isinstance(message.get("usage"), dict) else {}
        if not usage:
            continue
        model = str(message.get("model") or "")
        used = sum(_usage_token_count(usage, key) for key in (
            "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens",
        ))
        return _normalized_agent_usage(source, model, used, _claude_context_window(model))
    return _empty_agent_usage(source)


def agent_usage(root: Path, source: str, sid: str) -> dict[str, Any]:
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]{3,63}", sid or ""):
        raise ValueError("invalid session id")
    if source == "claude":
        path = CLAUDE_PROJECTS_DIR / _claude_project_slug(root) / f"{sid}.jsonl"
    elif source == "codex":
        entry = next((item for item in codex_agent_sessions().get(str(root), []) if item.get("sid") == sid), None)
        path = Path(str((entry or {}).get("path") or ""))
        if not entry:
            raise ValueError("codex rollout 을 못 찾았어요 (세션 만료)")
    else:
        raise ValueError("unknown source")
    if not path.is_file():
        raise ValueError("transcript 파일이 없어요 (세션 만료/이동)")
    return agent_usage_from_path(path, source)


def agent_transcript_path(root: Path, source: str, sid: str) -> Path:
    """세션 트랜스크립트 파일 경로. sid 검증 포함(경로 조작 방지)."""
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]{3,63}", sid or ""):   # leading dash 금지
        raise ValueError("invalid session id")
    if source == "claude":
        jpath = CLAUDE_PROJECTS_DIR / _claude_project_slug(root) / f"{sid}.jsonl"
        if not jpath.is_file():
            raise ValueError("transcript 파일이 없어요 (세션 만료/이동)")
        return jpath
    if source == "codex":
        entry = next((e for e in codex_agent_sessions().get(str(root), []) if e.get("sid") == sid), None)
        if not entry or not Path(entry["path"]).is_file():
            raise ValueError("codex rollout 을 못 찾았어요 (세션 만료)")
        return Path(entry["path"])
    raise ValueError("unknown source")


def agent_transcript(root: Path, source: str, sid: str, before: int | None = None,
                     limit: int = 40) -> dict[str, Any]:
    # AGENTS 대화 — byte cursor 기준 역방향 페이지. 도구 호출·결과는 생략하고 로그와 같은 마스킹 적용.
    from marina_logtext import redact_text   # 지역 import — 순환 의존 예방
    jpath = agent_transcript_path(root, source, sid)
    return {**_transcript_page(jpath, source, before, limit), "source": source}


def _read_transcript_line(path: Path, offset: int) -> dict[str, Any]:
    size = path.stat().st_size
    if offset < 0 or offset >= size:
        raise ValueError("이미지를 못 찾았어요 (트랜스크립트가 바뀌었어요)")
    with path.open("rb") as handle:
        handle.seek(offset)
        raw = handle.readline(_IMAGE_LINE_MAX)
    try:
        obj = json.loads(raw)
    except Exception:
        raise ValueError("이미지를 못 찾았어요 (줄을 못 읽었어요)")
    if not isinstance(obj, dict):
        raise ValueError("이미지를 못 찾았어요")
    return obj


def agent_transcript_image(root: Path, source: str, sid: str, ref: str) -> tuple[bytes, str]:
    """타임라인 ref 로 이미지 원본 바이트를 돌려준다 — 그 한 줄만 다시 읽는다."""
    if source != "claude":
        raise ValueError("이미지는 Claude 세션만 지원해요")
    if not _IMAGE_REF_RE.fullmatch(ref or ""):
        raise ValueError("invalid image ref")
    path = agent_transcript_path(root, source, sid)
    parts = [int(part) for part in ref.split("-")]
    obj = _read_transcript_line(path, parts[0])
    node: Any = (obj.get("message") or {}).get("content")
    block: Any = None
    for index in parts[1:]:
        if not isinstance(node, list) or index >= len(node):
            raise ValueError("이미지를 못 찾았어요 (내용이 바뀌었어요)")
        block = node[index]
        node = block.get("content") if isinstance(block, dict) else None
    if not isinstance(block, dict) or block.get("type") != "image":
        raise ValueError("이미지를 못 찾았어요 (내용이 바뀌었어요)")
    src = block.get("source") if isinstance(block.get("source"), dict) else {}
    data = src.get("data")
    if src.get("type") != "base64" or not isinstance(data, str) or not data:
        raise ValueError("이미지를 못 찾았어요 (형식)")
    if _b64_size(data) > _IMAGE_BYTES_MAX:
        raise ValueError("이미지가 너무 커요")
    media = str(src.get("media_type") or "image/png")
    if not media.startswith("image/") or len(media) > 60:
        media = "image/png"
    try:
        return base64.b64decode(data, validate=False), media
    except Exception:
        raise ValueError("이미지를 못 읽었어요 (디코드 실패)")


# 이 세션에서 에이전트가 **만든/바꾼 파일** — 대화에 박힌 이미지(agent_transcript_images)와는 다른 축이다.
# 만들기만 한 파일은 트랜스크립트에 내용이 안 남고 경로만 남으므로, 도구 호출의 file_path 가 유일한 근거다.
# (실측: 세션 하나에 Write 2 + Edit 44 인데 트랜스크립트 이미지는 0장 — 갤러리로는 아무것도 안 잡힌다.)
_WRITE_TOOLS = {"write", "edit", "multiedit", "notebookedit", "apply_patch", "patch"}
_PATCH_TARGET_RE = re.compile(r"\*\*\*\s+(?:update|add|delete)\s+file:\s*([^\s'\";\\]+)", re.I)
AGENT_SESSION_FILES_MAX = 300
_SESSION_FILE_BYTES_MAX = 8 * 1024 * 1024
_SESSION_FILE_IMAGE_TYPES = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
    ".webp": "image/webp", ".bmp": "image/bmp",
    # .svg 는 일부러 뺐다 — 스크립트를 품을 수 있어서 그림으로 띄우면 대시보드 오리진에서 실행된다.
}


def _tool_file_targets(name: str, raw_input: Any) -> list[str]:
    if name.strip().lower() not in _WRITE_TOOLS:
        return []
    payload = _json_value(raw_input)
    direct = payload.get("file_path") or payload.get("path") or payload.get("file")
    if isinstance(direct, str) and direct.strip():
        return [direct.strip()]
    # apply_patch 계열은 경로가 패치 본문 안에 있다.
    blob = payload.get("input") or payload.get("patch") or ""
    if not isinstance(blob, str):
        blob = ""
    if not blob and isinstance(raw_input, str):
        blob = raw_input
    return [m.group(1) for m in _PATCH_TARGET_RE.finditer(blob)]


def session_file_in_root(root: Path, raw: str) -> Path | None:
    """워크트리 **안**으로 resolve 되는 경로만 통과. 심링크 탈출·상대경로 탈출을 여기서 막는다."""
    try:
        base = root.resolve()
        candidate = Path(raw).expanduser()
        if not candidate.is_absolute():
            candidate = base / candidate
        resolved = candidate.resolve()
    except (OSError, RuntimeError, ValueError):
        return None
    if resolved == base or base in resolved.parents:
        return resolved
    return None


def agent_session_files(root: Path, source: str, sid: str,
                        limit: int = AGENT_SESSION_FILES_MAX) -> dict[str, Any]:
    """이 세션이 만든/바꾼 파일 목록 — 최근에 손댄 것이 앞. 내용은 안 싣는다(메타만)."""
    path = agent_transcript_path(root, source, sid)
    limit = max(1, min(AGENT_SESSION_FILES_MAX, int(limit or AGENT_SESSION_FILES_MAX)))
    order: list[str] = []
    seen: dict[str, dict[str, Any]] = {}
    # 전체 파일을 줄 단위로 흘려 읽는다 — _json_objects 는 끝 256KB 만 읽어서 긴 세션의 Write/Edit 를
    # 거의 다 놓친다(이 세션만 해도 46건 중 대부분이 그 밖에 있다). 값싼 사전 필터로 대부분의 줄은 건너뛴다.
    marker = b'"tool_use"' if source == "claude" else b'"function_call"'
    with path.open("rb") as handle:
        for raw in handle:
            if marker not in raw:
                continue
            try:
                obj = json.loads(raw)
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            if source == "claude":
                blocks = (obj.get("message") or {}).get("content")
                calls = [(str(b.get("name") or ""), b.get("input")) for b in blocks
                         if isinstance(b, dict) and b.get("type") == "tool_use"] if isinstance(blocks, list) else []
            else:
                payload = obj.get("payload") or {}
                if obj.get("type") != "response_item" or payload.get("type") not in ("function_call", "custom_tool_call"):
                    continue
                calls = [(str(payload.get("name") or ""),
                          payload.get("arguments") if payload.get("type") == "function_call" else payload.get("input"))]
            for name, raw_input in calls:
                for target in _tool_file_targets(name, raw_input):
                    resolved = session_file_in_root(root, target)
                    if resolved is None:
                        continue                  # 워크트리 밖은 목록에도 안 넣는다
                    key = str(resolved)
                    record = seen.get(key)
                    if record is None:
                        record = {"path": key, "name": resolved.name,
                                  "relPath": str(resolved.relative_to(root.resolve())),
                                  "action": "created" if name.strip().lower() == "write" else "edited",
                                  "touches": 0}
                        seen[key] = record
                        order.append(key)
                    record["touches"] += 1
                    if name.strip().lower() == "write":
                        record["action"] = "created"
    files: list[dict[str, Any]] = []
    for key in reversed(order):                   # 최근에 처음 손댄 것이 앞
        record = seen[key]
        target = Path(key)
        suffix = target.suffix.lower()
        try:
            stat = target.stat()
            record.update({"exists": True, "size": stat.st_size, "mtime": int(stat.st_mtime)})
        except OSError:
            record.update({"exists": False, "size": 0, "mtime": 0})
        record["isImage"] = suffix in _SESSION_FILE_IMAGE_TYPES
        record["servable"] = bool(record["exists"] and record["size"] <= _SESSION_FILE_BYTES_MAX)
        files.append(record)
    return {"files": files[:limit], "total": len(files), "source": source}


def agent_session_file_bytes(root: Path, raw_path: str) -> tuple[bytes, str]:
    """워크트리 안 파일 원본. 이미지 화이트리스트 외에는 전부 text/plain 으로 준다 —
    대시보드 오리진에서 HTML/JS 를 그대로 서빙하면 저장형 XSS 가 되기 때문."""
    resolved = session_file_in_root(root, raw_path or "")
    if resolved is None:
        raise ValueError("이 워크트리 밖의 경로예요")
    if not resolved.is_file():
        raise ValueError("파일이 없어요")
    size = resolved.stat().st_size
    if size > _SESSION_FILE_BYTES_MAX:
        raise ValueError("파일이 너무 커요 (8MB 상한)")
    data = resolved.read_bytes()
    media = _SESSION_FILE_IMAGE_TYPES.get(resolved.suffix.lower())
    return data, media if media else "text/plain; charset=utf-8"


AGENT_GALLERY_MAX = 300


def agent_transcript_images(root: Path, source: str, sid: str,
                            limit: int = AGENT_GALLERY_MAX) -> dict[str, Any]:
    """세션 대화에 등장한 이미지 전부 — '모아보기' 갤러리용. 최신이 앞."""
    if source != "claude":
        return {"images": [], "source": source}
    path = agent_transcript_path(root, source, sid)
    limit = max(1, min(AGENT_GALLERY_MAX, int(limit or AGENT_GALLERY_MAX)))
    found: list[dict[str, Any]] = []
    offset = 0
    with path.open("rb") as handle:
        for raw in handle:
            line_start = offset
            offset += len(raw)
            if b'"image"' not in raw:      # 값싼 사전 필터 — 대부분의 줄은 여기서 걸러진다
                continue
            try:
                obj = json.loads(raw)
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
            content = message.get("content")
            if not isinstance(content, list):
                continue
            ts = str(obj.get("timestamp") or "")
            for index, block in enumerate(content):
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "image":
                    item = _image_descriptor(block, line_start, (index,))
                    if item:
                        found.append({**item, "ts": ts, "origin": "message"})
                elif block.get("type") == "tool_result":
                    for item in _image_descriptors(block.get("content"), line_start, (index,)):
                        found.append({**item, "ts": ts, "origin": "tool"})
    found.reverse()
    return {"images": found[:limit], "source": source, "total": len(found)}


# 대화 전용 마스킹 — redact_text(키워드 key/value) 로는 안 잡히는 bare 토큰/이메일(codex P2).
# 모달이 '민감정보 마스킹'을 약속하므로 대화 본문에 노출된 흔한 secret 형태를 추가로 가린다.
_TRANSCRIPT_SECRET_RES = [
    re.compile(r"gh[porsu]_[A-Za-z0-9]{20,}"),                 # GitHub PAT/OAuth
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),               # GitHub fine-grained PAT
    re.compile(r"sk-[A-Za-z0-9_-]{20,}"),                      # OpenAI 계열
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),               # Slack
    re.compile(r"AKIA[0-9A-Z]{16}"),                           # AWS access key id
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"),          # Bearer 토큰
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}"),  # JWT
    re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),  # 이메일
]

# 기본 **꺼짐**. 트랜스크립트 원본(~/.claude/projects/*.jsonl)엔 이미 평문으로 저장돼 있어서,
# 그릴 때만 가리는 건 "대시보드 로그인은 있는데 파일 접근은 없는 사람"에게만 의미가 있다.
# 지금 그런 사용자가 없다(어드민 혼자 = 파일도 다 본다) → 얻는 것 0, 이메일 오탐만 남았다(형 지적).
# 의미가 생기는 시점은 member 역할이 붙어 비개발자가 남의 대화를 볼 때다. 그때 그 화면에서만 켠다.
_REDACT_TRANSCRIPT = os.environ.get("MARINA_REDACT_TRANSCRIPT", "").strip().lower() in ("1", "true", "yes", "on")


def _redact_transcript(text: str) -> str:
    if not _REDACT_TRANSCRIPT:
        return text
    for rx in _TRANSCRIPT_SECRET_RES:
        text = rx.sub("[redacted]", text)
    return text

def repo_head_subject(repo: Path) -> str:
    # 최신 커밋 제목 — 세션 타이틀 없을 때(CLI/codex) 카드 식별 폴백.
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "log", "-1", "--format=%s"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return out.strip()
    except Exception:
        return ""

def repo_last_commit_ts(repo: Path) -> int:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "log", "-1", "--format=%ct"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return int(out.strip() or "0")
    except Exception:
        return 0

def repo_branch(repo: Path) -> str:
    # detached HEAD(codex worktree 루트 기본 상태)는 빈 문자열
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "branch", "--show-current"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return out.strip()
    except Exception:
        return ""

def repo_ahead_of_main(repo: Path) -> int | None:
    # 이 worktree 가 "생성된 이후" 쌓은 커밋 수 (= 이 세션의 미머지 작업). main 없으면 None.
    # main..HEAD 는 worktree 생성 시 물려받은 공유 base 까지 세어 모든 카드에 같은 유령이 깔린다 →
    # reflog 기반 fork-point 를 생성 시점 기준으로 삼아 이 세션 커밋만 센다 (실패 시 main..HEAD 폴백).
    try:
        subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "--verify", "main"],
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return None
    base = "main"
    branch = repo_branch(repo)
    if branch and branch != "main":
        try:
            fp = subprocess.check_output(
                ["git", "-C", str(repo), "merge-base", "--fork-point", "main", branch],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()
            if fp:
                base = fp
        except Exception:
            pass
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "rev-list", "--count", f"{base}..HEAD"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return int(out.strip())
    except Exception:
        return None

def worktree_info(root: Path, refresh: bool = False) -> dict[str, Any]:
    key = str(root)
    cached = _worktree_info_cache.get(key)
    if cached and not refresh:
        age = time.time() - cached[0]
        if age < WORKTREE_INFO_TTL:
            return cached[1]
        if age < WORKTREE_INFO_MAX_STALE:
            # 만료됐지만 아직 쓸 만하다 — **기다리지 않고** 옛 값을 주고 뒤에서 갱신한다(du 와 같은 방식).
            # 이게 없으면 TTL 이 끝나는 15초마다 한 번씩 요청이 root 전체의 git 서브프로세스를 기다린다
            # (첫 화면이 늦는 진짜 이유). 너무 오래된 값은 아래로 떨어져 동기 계산한다.
            _kick_worktree_refresh(root)
            return cached[1]

    is_main = is_source_checkout(root)
    subs = subrepos_of(root)
    scan_subs = compose_scoped_subrepos(root)
    # 물리 attach 상태(fs 판정). main 체크아웃은 원본 클론이라 전부 attach 로 본다.
    attached_subrepos = list(subs) if is_main else [s for s in subs if (root / s / ".git").exists()]
    default_explicit = default_attach_of(root)
    status = worktree_status(root)
    last_ts = 0
    ahead: dict[str, int] = {}
    branches: dict[str, str] = {}
    # claude worktree 는 서브레포가 없는 경우가 많아 root 레포도 활동·ahead 에 포함
    repos_to_scan = [(project_label(root), root)] + [(name, root / name) for name in scan_subs]
    for repo_name, repo in repos_to_scan:
        if not (repo / ".git").exists():
            continue
        last_ts = max(last_ts, repo_last_commit_ts(repo))
        count = repo_ahead_of_main(repo)
        if count is not None:
            ahead[repo_name] = count
        branch = repo_branch(repo)
        if branch:
            branches[repo_name] = branch
    sdir = session_dir(root)
    if sdir.exists():
        try:
            last_ts = max(last_ts, int(sdir.stat().st_mtime))
        except OSError:
            pass

    ahead_total = sum(ahead.values())
    idle_days = round((time.time() - last_ts) / 86400, 1) if last_ts else None
    stale_days = float(_env("STALE_DAYS", "7"))
    if is_main:
        verdict = "main"
    elif not status["clean"]:
        verdict = "dirty"
    elif ahead_total > 0:
        verdict = "has-commits"
    elif idle_days is not None and idle_days >= stale_days:
        verdict = "stale"
    else:
        verdict = "active"

    disk_mb, cache_by_cat, image_mb, docker_disk = _du_info(root, is_main, refresh)   # du 는 별도 장수 캐시 — 여기서 안 기다림
    project = project_for(root)
    info = {
        "id": session_id(root),
        "alias": read_meta(root).get("alias", ""),
        # 카드 제목 폴백 — 세션 타이틀(앱) 없을 때 "무슨 작업인지" 식별용 최신 커밋 제목
        "headSubject": repo_head_subject(root),
        "source": root_source(root),
        "root": str(root),
        # 프로젝트 식별 — 대시보드 좌측 패널 그룹핑 키 (멀티프로젝트)
        "projectId": project["id"] if project else project_label(root),
        "projectLabel": project_label(root),
        "projectRoot": str(project["root"]) if project else str(root),
        # 레지스트리에 등록된 subrepos(큐레이션된 집합) — switcher "subrepos 편집" 프리필용. fs 의 universe(infer)와 구분.
        "subrepos": list(project["subrepos"]) if project else [],
        # 이 worktree 에 물리 attach 된 subrepo (fs 판정; main 은 전부). 클라이언트 트리 attach 상태원.
        "attachedSubrepos": attached_subrepos,
        # 전체 기본 attach 집합 — 명시값 없으면 universe(=전부). main 카드 "기본" 토글 프리필.
        "defaultAttach": default_explicit if default_explicit is not None else list(subs),
        "isMain": is_main,
        "clean": status["clean"],
        # du 2종은 _du_info 캐시 산 — 콜드 직후엔 None/0 이었다가 다음 폴(≤15s)에 채워짐
        "diskMb": disk_mb,
        "cacheMb": sum(cache_by_cat.values()),
        "imageMb": image_mb,
        "cacheCats": cache_by_cat,
        "dockerDisk": docker_disk,
        "idleDays": idle_days,
        "lastTs": last_ts,   # 최근 활동(커밋·세션 mtime) — 좌측 카드 최근순 정렬용
        "ahead": ahead,
        "aheadTotal": ahead_total,
        "branches": branches,
        "verdict": verdict,
    }
    _worktree_info_cache[key] = (time.time(), info)
    return info
