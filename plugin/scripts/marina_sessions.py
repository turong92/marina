"""marina_sessions.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
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
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
import importlib.util as _ilu

from marina_state import CODEX_HOME, HOST, LIFECYCLE_BUSY, PORT, _claude_agents_cache, _codex_agents_cache, _codex_titles_cache, _env, _session_titles_cache, _status_cache, _total_mem_mb_cache, _worktree_du_cache, _worktree_info_cache, busy_key
from marina_logtext import redact_text
from marina_cache import cache_category_mb, disk_usage_mb
from marina_registry import default_attach_of, discover_all_roots, discover_roots, is_source_checkout, project_for, project_label, root_source, subrepos_of
from marina_paths import ensure_current_log, log_run_payload, read_config, read_meta, service_log, session_dir, session_id
from marina_compose_svc import _compose_services, _log_tail_line, compose_service_names, compose_service_subrepos, missing_env_vars

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


def session_payload(root: Path) -> dict[str, Any]:
    project = project_for(root)
    kind = (project or {}).get("kind", "compose")
    services = _compose_services(root, project) if kind == "compose" else []
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

def _compute_du(root: Path, is_main: bool) -> tuple[float, Any, dict[str, int]]:
    # main 체크아웃 전체 du 는 수백 GB 라 비싸고 UI 에서도 안 씀 → 스킵
    return (time.time(), None if is_main else disk_usage_mb(root), cache_category_mb(root))

def _du_info(root: Path, is_main: bool, refresh: bool) -> tuple[Any, dict[str, int]]:
    """(diskMb, cacheCats) — 있던 값은 즉시 주고 갱신은 백그라운드. 응답을 du 가 못 막게.
    동기 계산은 캐시가 아예 없는 refresh(=캐시 정리 직후 loadWorktrees(true) 가 새 용량을 기대) 뿐."""
    key = str(root)
    cached = _worktree_du_cache.get(key)
    if cached and not refresh and time.time() - cached[0] < WORKTREE_DU_TTL:
        return cached[1], cached[2]
    if cached is None and refresh:
        info = _compute_du(root, is_main)
        _worktree_du_cache[key] = info
        return info[1], info[2]
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
        return cached[1], cached[2]   # 만료된 값이라도 공백보단 낫다 — 다음 폴이 새 값을 집어감
    return None, {}

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

AGENTS_MAX_PER_ROOT = 3

AGENTS_MAX_AGE = 7 * 86400   # 7일↑ 미활동 세션은 카드에서 제외

AGENT_PREVIEW_TAIL_BYTES = 16 * 1024   # preview 는 파일 끝만 읽는다 — 전체 파싱 금지(폴링 비용 상한)

AGENT_PREVIEW_LEN = 80

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

def agents_payload(root: Path, refresh: bool = False) -> list[dict[str, Any]]:
    # 카드 AGENTS 섹션 — 워크트리당 최대 3개(ts 내림차순), Claude 만 preview(마지막 assistant 텍스트 80자) 부여.
    claude_by_root = claude_agent_sessions(refresh)
    codex_by_root = codex_agent_sessions(refresh)
    key = str(root)
    entries = [*claude_by_root.get(key, []), *codex_by_root.get(key, [])]
    entries.sort(key=lambda e: e["ts"], reverse=True)
    agents: list[dict[str, Any]] = []
    for e in entries[:AGENTS_MAX_PER_ROOT]:
        item: dict[str, Any] = {"source": e["source"], "title": e["title"], "ts": int(e["ts"])}
        cli_sid = e.get("cliSessionId")
        if e["source"] == "claude" and cli_sid:
            item["sid"] = cli_sid   # 행 클릭=대화 열기 (agent-transcript) 식별자
            jpath = CLAUDE_PROJECTS_DIR / _claude_project_slug(root) / f"{cli_sid}.jsonl"
            if jpath.is_file():
                preview = _jsonl_last_assistant_preview(jpath)
                if preview:
                    from marina_logtext import redact_text   # 카드 payload 도 로그와 같은 마스킹(codex P2)
                    item["preview"] = redact_text(preview)
        elif e["source"] == "codex" and e.get("sid"):
            item["sid"] = e["sid"]
        agents.append(item)
    return agents


AGENT_TRANSCRIPT_TAIL_BYTES = 256 * 1024
AGENT_TRANSCRIPT_MAX_TURNS = 60
AGENT_TURN_MAX_CHARS = 4000

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

def agent_transcript(root: Path, source: str, sid: str) -> dict[str, Any]:
    # AGENTS 행 클릭 뷰어 — 끝 256KB 에서 user/assistant 텍스트 턴만 추출(도구 호출·결과는 생략), 로그처럼 마스킹.
    from marina_logtext import redact_text   # 지역 import — 순환 의존 예방
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]{3,63}", sid or ""):   # leading dash 금지
        raise ValueError("invalid session id")
    turns: list[dict[str, str]] = []
    if source == "claude":
        jpath = CLAUDE_PROJECTS_DIR / _claude_project_slug(root) / f"{sid}.jsonl"
        if not jpath.is_file():
            raise ValueError("transcript 파일이 없어요 (세션 만료/이동)")
        for line in _tail_lines(jpath):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            role = obj.get("type")
            if role not in ("user", "assistant"):
                continue
            for t in _texts_of((obj.get("message") or {}).get("content")):
                turns.append({"role": role, "text": t[:AGENT_TURN_MAX_CHARS]})
    elif source == "codex":
        entry = next((e for e in codex_agent_sessions().get(str(root), []) if e.get("sid") == sid), None)
        if not entry or not Path(entry["path"]).is_file():
            raise ValueError("codex rollout 을 못 찾았어요 (세션 만료)")
        for line in _tail_lines(Path(entry["path"])):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            p = obj.get("payload") or {}
            if p.get("type") != "message" or p.get("role") not in ("user", "assistant"):
                continue
            for t in _texts_of(p.get("content")):
                turns.append({"role": p["role"], "text": t[:AGENT_TURN_MAX_CHARS]})
    else:
        raise ValueError("unknown source")
    turns = turns[-AGENT_TRANSCRIPT_MAX_TURNS:]
    for t in turns:
        t["text"] = _redact_transcript(redact_text(t["text"]))
    return {"turns": turns, "source": source}


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

    disk_mb, cache_by_cat = _du_info(root, is_main, refresh)   # du 는 별도 장수 캐시 — 여기서 안 기다림
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
        "cacheCats": cache_by_cat,
        "idleDays": idle_days,
        "lastTs": last_ts,   # 최근 활동(커밋·세션 mtime) — 좌측 카드 최근순 정렬용
        "ahead": ahead,
        "aheadTotal": ahead_total,
        "branches": branches,
        "verdict": verdict,
    }
    _worktree_info_cache[key] = (time.time(), info)
    return info
