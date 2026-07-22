"""marina_sessions.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
from __future__ import annotations
import glob
import json
import math
import mmap
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
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
import importlib.util as _ilu

from marina_state import CODEX_HOME, HOST, LIFECYCLE_BUSY, PORT, _claude_agents_cache, _codex_agents_cache, _codex_titles_cache, _env, _session_titles_cache, _status_cache, _total_mem_mb_cache, _worktree_du_cache, _worktree_info_cache, busy_key
from marina_logtext import redact_text
from marina_cache import cache_category_mb, compose_build_image_items, disk_usage_mb, docker_disk_summary
from marina_registry import default_attach_of, discover_all_roots, discover_roots, is_source_checkout, project_for, project_label, root_source, subrepos_of
from marina_paths import ensure_current_log, log_run_payload, read_config, read_meta, service_log, session_dir, session_id
from marina_compose_svc import _compose_services, _log_tail_line, compose_service_names, compose_service_subrepos, missing_env_vars
from marina_memory import enrich_session_memory, memory_snapshot
from marina_agent_events import BLOCKED_REASONS, latest_agent_event

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
WORKTREE_DU_TTL = 600.0
_du_inflight: set[str] = set()
_du_lock = threading.Lock()

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

AGENTS_MAX_AGE = 7 * 86400   # 7일↑ 미활동 세션은 카드에서 제외

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

def claude_agent_sessions(refresh: bool = False) -> dict[str, list[dict[str, Any]]]:
    # worktreePath → [{"source":"claude","title","ts"(파일 mtime),"cliSessionId"}] — claude_session_titles 와 같은 소스·캐시 리듬(20s)
    # 이나, root 당 최신 1개로 축약하지 않고 전부 보존(AGENTS 섹션이 상위 최대 3개를 다시 고른다).
    global _claude_agents_cache
    now = time.time()
    if not refresh and now - _claude_agents_cache[0] < SESSION_TITLES_TTL:
        return _claude_agents_cache[1]
    by_root: dict[str, list[dict[str, Any]]] = {}
    cutoff = now - AGENTS_MAX_AGE
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
    _claude_agents_cache = (now, by_root)
    return by_root

def codex_agent_sessions(refresh: bool = False) -> dict[str, list[dict[str, Any]]]:
    # cwd → [{"source":"codex","title","ts"(rollout 파일 mtime)}] — codex_session_titles 와 같은 소스·캐시 리듬(60s),
    # root 당 전부 보존. preview 는 codex rollout 파싱 비용이 커 title+ts 만(스펙 — "가능한 만큼").
    global _codex_agents_cache
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
    cutoff = now - AGENTS_MAX_AGE
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
    _codex_agents_cache = (now, by_root)
    return by_root


def agent_belongs_to_root(root: Path, source: str, sid: str, refresh: bool = False) -> bool:
    """Verify an agent id against the complete session index for a worktree."""
    source = str(source).strip().lower()
    sid = str(sid).strip()
    if source not in ("claude", "codex") or not sid:
        return False
    roots = {str(root), str(root.resolve())}
    sessions = claude_agent_sessions(refresh) if source == "claude" else codex_agent_sessions(refresh)
    id_key = "cliSessionId" if source == "claude" else "sid"
    return any(
        str(entry.get(id_key) or "") == sid
        for root_key in roots
        for entry in sessions.get(root_key, [])
    )

def agents_payload(root: Path, refresh: bool = False) -> list[dict[str, Any]]:
    # 카드 AGENTS 섹션 — 워크트리당 최대 3개(ts 내림차순), Claude 만 preview(마지막 assistant 텍스트 80자) 부여.
    claude_by_root = claude_agent_sessions(refresh)
    codex_by_root = codex_agent_sessions(refresh)
    key = str(root)
    entries = [*claude_by_root.get(key, []), *codex_by_root.get(key, [])]
    entries.sort(key=lambda e: e["ts"], reverse=True)
    agents: list[dict[str, Any]] = []
    event_home = Path.home()
    canonical_root = root.resolve()
    for e in entries[:AGENTS_MAX_PER_ROOT]:
        item: dict[str, Any] = {"source": e["source"], "title": e["title"], "ts": int(e["ts"])}
        cli_sid = e.get("cliSessionId")
        if e["source"] == "claude" and cli_sid:
            item["sid"] = cli_sid   # 행 클릭=대화 열기 (agent-transcript) 식별자
            jpath = CLAUDE_PROJECTS_DIR / _claude_project_slug(root) / f"{cli_sid}.jsonl"
            if jpath.is_file():
                item.update(agent_status(jpath, "claude", sid=cli_sid, root=canonical_root,
                                         event_home=event_home))
                preview = _jsonl_last_assistant_preview(jpath)
                if preview:
                    from marina_logtext import redact_text   # 카드 payload 도 로그와 같은 마스킹(codex P2)
                    item["preview"] = redact_text(preview)
        elif e["source"] == "codex" and e.get("sid"):
            item["sid"] = e["sid"]
            item.update(agent_status(Path(e["path"]), "codex", sid=e["sid"], root=canonical_root,
                                     event_home=event_home))
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
    turns: list[dict[str, str]] = []
    for index, text in enumerate(_texts_of(content)):
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
    timeline = _transcript_timeline(list(reversed(native_rows)), source)
    return {"turns": turns, "timeline": timeline,
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
        target = str(payload.get("file_path") or payload.get("path") or payload.get("file") or "").strip()
        if not target and activity_type == "diff":
            match = re.search(r"\*\*\*\s+(?:update|add|delete)\s+file:\s*([^\s'\";\\]+)", detail, re.I)
            target = match.group(1) if match else ""
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


def _new_timeline_activity(source: str, offset: int, index: int, name: str,
                           call_id: str, raw_input: Any, model: str = "",
                           effort: str = "") -> dict[str, Any]:
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
    if model:
        item["model"] = model
    if effort:
        item["effort"] = effort
    return item


def _transcript_timeline(rows: list[tuple[int, dict[str, Any]]], source: str) -> list[dict[str, Any]]:
    timeline: list[dict[str, Any]] = []
    calls: dict[str, dict[str, Any]] = {}
    runtime = {"model": "", "effort": ""}

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
            message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
            content = message.get("content")
            if role not in ("user", "assistant") or not isinstance(content, list):
                continue
            message_model = str(message.get("model") or "") if role == "assistant" else ""
            message_effort = str(message.get("effort") or message.get("reasoning_effort") or "") if role == "assistant" else ""
            if message_model:
                runtime["model"] = message_model
            if message_effort:
                runtime["effort"] = message_effort
            for index, block in enumerate(content):
                if not isinstance(block, dict):
                    continue
                block_type = block.get("type")
                if block_type == "text":
                    text = _safe_activity_text(block.get("text"))
                    if text.strip():
                        timeline.append(with_runtime(
                            {"id": f"{source}:message:{offset}:{index}", "kind": "message",
                             "role": role, "text": text}, message_model, message_effort,
                        ))
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
                        item["result"] = _activity_value_text(block.get("content"))
                        item["status"] = "failed" if _activity_failed(block.get("content"), block) else "completed"
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
                for index, text in enumerate(_texts_of(payload.get("content"))):
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
        return timeline
    keep = activity_count - AGENT_TIMELINE_MAX_ACTIVITIES
    bounded: list[dict[str, Any]] = []
    for item in timeline:
        if item.get("kind") == "activity" and keep > 0:
            keep -= 1
            continue
        bounded.append(item)
    return bounded


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
    for obj in _json_objects(parent):
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

    child_dir = session_dir / sid / "subagents"
    child_paths = {path.stem.removeprefix("agent-"): path for path in child_dir.glob("agent-*.jsonl")} if child_dir.is_dir() else {}
    for item in calls.values():
        child = child_paths.get(str(item["id"]))
        if not child:
            continue
        turns = _transcript_turns(child, "claude")
        item["turns"] = turns[-12:]
        if turns:
            item["preview"] = turns[-1]["text"]
    return [calls[call_id] for call_id in order][-20:]


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
    for obj in _json_objects(parent_path):
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
            model, effort = str(message.get("model") or ""), str(message.get("effort") or "")
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
        return None
    options = config.get("additionalModelOptionsCache") if isinstance(config, dict) else None
    if not isinstance(options, list):
        return None
    for option in options:
        value = str(option.get("value") or "") if isinstance(option, dict) else ""
        if value.split("[", 1)[0] == model:
            window = _model_context_window(value)
            if window is not None:
                return window
    return None


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


def _claude_fable_limit(data: dict[str, Any]) -> tuple[Any, Any]:
    """Find Fable's model-scoped weekly limit across native usage shapes."""
    direct_percent_keys = ("fableWeekly", "fable_weekly", "sevenDayFable", "seven_day_fable")
    direct_reset_keys = ("fableWeeklyResetAt", "fable_weekly_reset_at", "sevenDayFableResetAt",
                         "seven_day_fable_reset_at")
    percent = next((data.get(name) for name in direct_percent_keys if name in data), None)
    reset = next((data.get(name) for name in direct_reset_keys if name in data), None)
    if percent is not None:
        return percent, reset

    def visit(value: Any) -> tuple[Any, Any] | None:
        if isinstance(value, dict):
            name = " ".join(str(value.get(key, "")) for key in ("display_name", "displayName", "name", "model"))
            if "fable" in name.lower():
                used = next((value.get(key) for key in ("utilization", "used_percent", "usedPercent", "percentage")
                             if key in value), None)
                reset_at = next((value.get(key) for key in ("resets_at", "resetAt", "resetsAt") if key in value), None)
                if used is not None:
                    return used, reset_at
            for child in value.values():
                found = visit(child)
                if found:
                    return found
        elif isinstance(value, list):
            for child in value:
                found = visit(child)
                if found:
                    return found
        return None

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
    """Normalize Claude HUD usage data, including optional Fable weekly quota."""
    value = cache.get("data") if isinstance(cache, dict) and isinstance(cache.get("data"), dict) else cache
    data = value if isinstance(value, dict) else {}
    windows: list[dict[str, Any]] = []
    for key, label, percent_keys, reset_keys in (
        ("fiveHour", "5시간", ("fiveHour", "five_hour"), ("fiveHourResetAt", "five_hour_reset_at")),
        ("weekly", "주간", ("sevenDay", "seven_day"), ("sevenDayResetAt", "seven_day_reset_at")),
        ("fableWeekly", "Fable 주간", (), ()),
    ):
        if key == "fableWeekly":
            percent, reset = _claude_fable_limit(data)
        else:
            percent = next((data.get(name) for name in percent_keys if name in data), None)
            reset = next((data.get(name) for name in reset_keys if name in data), None)
            if isinstance(percent, dict):
                item = percent
                percent = next((item.get(name) for name in ("utilization", "used_percent", "usedPercent", "percentage")
                                if name in item), None)
                reset = next((item.get(name) for name in ("resets_at", "resetAt", "resetsAt") if name in item), reset)
        normalized = _usage_window(key, label, percent, reset)
        if normalized:
            windows.append(normalized)
    return {"source": "claude", "windows": windows}


def _latest_codex_rate_limits(root: Path | None = None) -> dict[str, Any] | None:
    paths: list[Path] = []
    if root is not None:
        paths = [Path(str(item.get("path"))) for item in codex_agent_sessions().get(str(root), []) if item.get("path")]
    if not paths:
        for base in CODEX_ROLLOUT_DIRS:
            if base.is_dir():
                paths.extend(Path(path) for path in glob.iglob(str(base / "**" / "rollout-*.jsonl"), recursive=True))
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


def agent_transcript(root: Path, source: str, sid: str, before: int | None = None,
                     limit: int = 40) -> dict[str, Any]:
    # AGENTS 대화 — byte cursor 기준 역방향 페이지. 도구 호출·결과는 생략하고 로그와 같은 마스킹 적용.
    from marina_logtext import redact_text   # 지역 import — 순환 의존 예방
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]{3,63}", sid or ""):   # leading dash 금지
        raise ValueError("invalid session id")
    if source == "claude":
        jpath = CLAUDE_PROJECTS_DIR / _claude_project_slug(root) / f"{sid}.jsonl"
        if not jpath.is_file():
            raise ValueError("transcript 파일이 없어요 (세션 만료/이동)")
    elif source == "codex":
        entry = next((e for e in codex_agent_sessions().get(str(root), []) if e.get("sid") == sid), None)
        if not entry or not Path(entry["path"]).is_file():
            raise ValueError("codex rollout 을 못 찾았어요 (세션 만료)")
        jpath = Path(entry["path"])
    else:
        raise ValueError("unknown source")
    return {**_transcript_page(jpath, source, before, limit), "source": source}


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

def _redact_transcript(text: str) -> str:
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
    if cached and not refresh and time.time() - cached[0] < WORKTREE_INFO_TTL:
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
