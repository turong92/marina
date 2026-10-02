"""marina_worktrees.py — 워크트리 git 상태·서비스 상태·배지 정보 (runtime).

marina_sessions.py(대시보드 겸용)에서 옮겼다(분리 A, 스펙 R1). runtime 은 대시보드·discord 코드를 부르지 않으므로
GC·삭제·게이트웨이가 쓰는 함수는 여기 있어야 한다. marina_sessions 는 이 이름들을 다시 import 해 쓴다.
"""
from __future__ import annotations
import json
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from marina_state import LIFECYCLE_BUSY, _env, _status_cache, _worktree_du_cache, _worktree_info_cache, busy_key
from marina_cache import cache_category_mb, compose_build_image_items, disk_usage_mb, docker_disk_summary
from marina_registry import default_attach_of, is_source_checkout, project_for, project_label, root_source, subrepos_of
from marina_paths import log_run_payload, read_config, read_meta, service_log, session_dir, session_id
from marina_compose_svc import _compose_services, _log_tail_line, compose_service_names, compose_service_subrepos, missing_env_vars
from marina_memory import enrich_session_memory, memory_snapshot


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


# 신선도 분리(실측): 깃 배지(dirty/ahead/branch)는 root 당 ~0.1s 로 싸서 짧게,
# du(diskMb/cacheCats)는 root 당 ~1.5s 라 장수 캐시 + 만료 시 백그라운드 갱신.
WORKTREE_INFO_TTL = 15.0


# 이 나이를 넘으면 옛 값을 주지 않고 **동기로** 계산한다. 예전 값은 120초였는데, 그게
# "오랜만에 열면 첫 화면이 한참 멈추는" 원인이었다(형 지적). 2분만 안 들어가도 모든 워크트리의
# 캐시가 이 선을 넘고, 다음 요청 하나가 root 28개 × git ~24회를 통째로 기다린다(실측 19초).
#
# 배지(브랜치·dirty·ahead)는 몇 분 낡아도 해가 없고, 만료 즉시 백그라운드 갱신이 걸려 곧
# 최신이 된다. 그러니 **먼저 보여주고 뒤에서 고치는** 쪽이 항상 낫다. 동기 계산은 캐시가
# 아예 없을 때(첫 방문·데몬 재시작)만 남긴다.
WORKTREE_INFO_MAX_STALE = float(_env("WORKTREE_INFO_MAX_STALE", "86400") or "86400")


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


_HEAD_SUBJECT_TTL = 600.0        # 커밋 제목은 커밋할 때만 바뀐다 — 자주 물을 이유가 없다


_head_subject_cache: dict[str, tuple[float, str]] = {}


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
    last_commit_ts = last_ts   # 커밋만(세션 폴더 mtime 제외) — 유휴 정리 판정용. 세션 폴더는 데몬이 부팅 때
    # ensure_current_log 로 건드려 mtime 이 "지금"이 된다(실측 2026-09-14: 재시작 후 6개 전부 당일) —
    # 그걸 활동으로 보면 재시작할 때마다 모든 워크트리가 K일간 활성으로 보여 정리가 영영 안 된다.
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
        "lastCommitTs": last_commit_ts,   # 커밋만 — 유휴 정리(marina_worktree_gc) 판정용(세션 폴더 mtime 은 데몬 부팅에 오염됨)
        "ahead": ahead,
        "aheadTotal": ahead_total,
        "branches": branches,
        "verdict": verdict,
    }
    _worktree_info_cache[key] = (time.time(), info)
    return info


# 마리나가 워크트리 안에 자기 것을 쓰는 자리(별칭·메모 — marina_paths 의 .workspace/marina).
# 이걸 형 작업물로 세면, 마리나가 파일 하나 건드린 것만으로 방이 "완료"가 된다(실측).
_MARINA_OWN = (".workspace/", ".workspace")


def own_changed_paths(status_text: str, root: Path) -> list[str]:
    """`git status --porcelain -z` 에서 **이 워크트리의** 변경 경로만 골라낸다.

    중첩 레포는 뺀다 — 완료 판정(_has_own_changes)과 **같은 규칙**을 써야 한다. 규칙이
    갈라지면 "완료라는데 바뀐 파일이 없다"가 나온다."""
    out: list[str] = []
    records = [item for item in str(status_text or "").split("\0") if item.strip()]
    index = 0
    while index < len(records):
        record = records[index]
        index += 1
        # 리네임/복사는 레코드가 **둘**이다: `R  <새경로>\0<옛경로>\0`. 옛 경로에는 XY 접두사가
        # 없는데도 앞 3글자를 자르면 이름이 뭉개지고(ab.py → "py") 개수도 하나 부푼다.
        if record[:1] in ("R", "C"):
            index += 1          # 옛 경로는 건너뛴다 — 한 번의 변경이다
        path = record[3:] if len(record) > 3 else ""
        if path in _MARINA_OWN or path.startswith(".workspace/"):
            continue        # 마리나가 쓴 것 — 형이 한 일이 아니다
        if record.startswith("?? "):
            if path.endswith("/") and _is_nested_repo(root / path):
                continue
        if path:
            out.append(path)
    return out


def _is_nested_repo(path: Path) -> bool:
    """이 디렉터리가 자기 git 레포인가. 권한이 막혀 있으면 판단을 포기한다 —
    py3.9 의 Path.exists() 는 EACCES 를 삼키지 않고 던진다(그대로 두면 방 전체가 실패 캐시로 떨어진다)."""
    try:
        return (path / ".git").exists()
    except OSError:
        return False
