"""marina_lifecycle.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
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

import threading

from marina_state import LIFECYCLE_BUSY, MARINA_ATTACH, MARINA_HOME, WORKTREES_ROOT, _GATEWAY_ON, _GATEWAY_PORT, _GATEWAY_STATE, _env, _gw, _mc, _roots_cache, _status_cache, _worktree_du_cache, _worktree_info_cache, busy_key
from marina_cache import cache_items_by_category, disk_usage_mb, docker_volume_rm
from marina_registry import discover_roots, has_attached_subrepos, is_source_checkout, project_for, project_label, source_root_for, subrepos_of
from marina_paths import session_dir, session_id
from marina_cli import _marina_cli, _marina_cli_logged, marina_env, script
from marina_logtext import redact_text
from marina_sessions import git_output, session_payload, system_memory, worktree_status

def stop_external(root: Path, service: str, port: int) -> dict[str, Any]:
    """'외부 :<port>'(marina 컨테이너가 아닌 호스트 프로세스가 서비스 포트 점유 — IDE/터미널 직접 실행) 정지.
    리스너 pid 를 찾아 SIGTERM. docker 소유 리스너는 거부(다른 워크트리 컨테이너의 published 포트일 수 있음 —
    그건 그 워크트리 카드에서 내려야 안전)."""
    if not (0 < int(port) < 65536):
        raise ValueError(f"잘못된 포트: {port}")
    try:
        out = subprocess.check_output(["lsof", "-nP", f"-iTCP:{int(port)}", "-sTCP:LISTEN", "-t"],
                                      text=True, stderr=subprocess.DEVNULL, timeout=5)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return {"stopped": False, "reason": f":{port} 리스너 없음 — 이미 종료된 듯(새로고침하면 반영)"}
    pids = sorted({int(x) for x in out.split() if x.strip().isdigit()})
    if not pids:
        return {"stopped": False, "reason": f":{port} 리스너 없음 — 이미 종료된 듯(새로고침하면 반영)"}
    comms = {}
    for pid in pids:
        try:
            comms[pid] = subprocess.run(["ps", "-p", str(pid), "-o", "comm="],
                                        capture_output=True, text=True, timeout=3).stdout.strip()
        except Exception:
            comms[pid] = ""
        if "docker" in comms[pid].lower():
            raise ValueError(f":{port} 는 docker 가 점유 중(pid {pid}) — 다른 워크트리 컨테이너일 수 있어 여기선 안 내림. 그 워크트리 카드에서 정지하세요.")
    import signal
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            raise ValueError(f"pid {pid} 종료 권한 없음({comms.get(pid) or '?'})")
    import socket
    def _listening() -> bool:
        for family, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
            try:
                with socket.socket(family, socket.SOCK_STREAM) as s:
                    s.settimeout(0.25)
                    if s.connect_ex((addr, int(port))) == 0:
                        return True
            except OSError:
                pass
        return False
    for _ in range(15):   # 최대 ~3s 포트 해제 대기 — 폴링이 바로 '꺼짐'으로 그리게
        if not _listening():
            break
        time.sleep(0.2)
    return {"stopped": True, "pids": pids, "comm": [comms.get(p) or "?" for p in pids]}


def _clear_busy_error(key: str) -> None:
    """최근 실패 마커만 청소(진행중 항목은 그 스레드가 스스로 정리)."""
    cur = LIFECYCLE_BUSY.get(key)
    if cur and "error" in cur:
        LIFECYCLE_BUSY.pop(key, None)

def stop_service(root: Path, service: str) -> dict[str, Any]:
    try:
        out = _marina_cli(root, "stop", f"--{service}")   # compose_main → docker compose stop <svc>
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"stop failed: {(exc.output or '')[-500:]}")
    _clear_busy_error(busy_key(root, service))
    refresh_gateway()   # 이벤트 즉시반영
    return {"stopped": True, "output": out[-1000:]}

def stop_all(root: Path) -> dict[str, Any]:
    try:
        out = _marina_cli(root, "stop", "--all")          # compose_main → docker compose down --remove-orphans
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"stop-all failed: {(exc.output or '')[-500:]}")
    for k in [k for k in LIFECYCLE_BUSY if k.startswith(f"{root}::")]:
        _clear_busy_error(k)
    refresh_gateway()   # 이벤트 즉시반영
    return {"stoppedAll": True, "output": out[-1000:]}

LIFECYCLE_TIMEOUT = int(_env("LIFECYCLE_TIMEOUT", "1800"))   # start/restart 백그라운드 실행 상한 — prebuild(gradle)+첫 이미지 빌드가 몇 분 걸림(120s 로 죽이던 버그 수정)


def _spawn_lifecycle(key: str, op: str, fn) -> dict[str, Any]:
    """긴 lifecycle(start/restart)을 백그라운드 스레드로 — API 는 즉시 응답, 진행/실패는
    LIFECYCLE_BUSY 로 폴링 payload 에 실린다(대시보드가 120s 타임아웃으로 빌드를 죽이던 버그의 근본 수정).
    이미 진행 중이면 중복 기동 거부. 실패 항목은 다음 시도/정지 때 청소."""
    cur = LIFECYCLE_BUSY.get(key)
    if cur and "error" not in cur:
        return {"busy": True, "op": cur.get("op")}
    LIFECYCLE_BUSY[key] = {"op": op, "ts": time.time()}

    def _run():
        try:
            fn()
            LIFECYCLE_BUSY.pop(key, None)
            refresh_gateway()   # 라우트 반영(자동 기동은 marina.sh 훅의 gateway-ensure 가 단일 처리 — CLI·대시보드 공통)
        except subprocess.CalledProcessError as exc:
            detail = redact_text(str(exc.output or "")[-500:])
            LIFECYCLE_BUSY[key] = {"op": op, "error": f"{op} failed: {detail}", "endedTs": time.time()}
        except subprocess.TimeoutExpired:
            LIFECYCLE_BUSY[key] = {"op": op, "error": f"{op} timed out ({LIFECYCLE_TIMEOUT}s)", "endedTs": time.time()}
        except Exception as exc:
            LIFECYCLE_BUSY[key] = {"op": op, "error": redact_text(str(exc)[-500:]), "endedTs": time.time()}

    threading.Thread(target=_run, daemon=True, name=f"lifecycle-{op}").start()
    return {"starting": True, "op": op}


def start_all(root: Path) -> dict[str, Any]:
    return _spawn_lifecycle(busy_key(root, "--all"), "start",
                            lambda: _marina_cli_logged(root, "start", "--all", timeout=LIFECYCLE_TIMEOUT))   # compose_main → ensure+pre-build+ up -d. 출력은 'build' 로그 run 으로(대시보드 노출)

def cleanup_session(root: Path) -> dict[str, Any]:
    stop_all(root)
    path = session_dir(root)
    if path.exists():
        shutil.rmtree(path)
    return {"removed": str(path)}

def remove_git_worktree(source_repo: Path, target: Path, force: bool = False) -> dict[str, Any]:
    if not target.exists():
        return {"missing": str(target)}
    args = ["worktree", "remove"]
    if force:
        args.append("--force")  # 미커밋 변경·untracked 가 있어도 폐기하고 제거
    args.append(str(target))
    try:
        git_output(args, source_repo)
        return {"removed": str(target)}
    except subprocess.CalledProcessError as exc:
        # 고아/깨진 워크트리는 'git worktree remove' 가 실패('not a working tree' 등) → 폴더가 남는다.
        # force 면 폴더 직접 정리 + prune 으로 메타데이터까지 청소(깨진 워크트리도 실제로 삭제되게).
        if force:
            shutil.rmtree(target, ignore_errors=True)
            try:
                git_output(["worktree", "prune"], source_repo)
            except Exception:
                pass
            if not target.exists():
                return {"removed": str(target), "orphanCleanup": True}
        return {"error": exc.output.strip() or str(exc), "path": str(target)}

def remove_worktree(root: Path, force: bool = False) -> dict[str, Any]:
    # 전역 대시보드는 프로젝트 worktree 밖(marina 레포)에서 돌므로 "자기 세션 삭제" 가드 불요.
    # 원본(main) 보호 — 레지스트리 root 일치(subrepos=[] 단일레포도 커버) 또는 서브레포 .git 존재.
    project = project_for(root)
    if (project and project["root"].resolve() == root.resolve()) or is_source_checkout(root):
        raise ValueError("원본 체크아웃(main)은 삭제할 수 없습니다")

    status = worktree_status(root)
    if not status["clean"] and not force:
        raise ValueError("변경사항이 있어 삭제할 수 없습니다 (force 로 폐기+삭제 가능): " + json.dumps(status, ensure_ascii=False))

    sid = session_id(root)
    stop_all(root)
    cleanup_session(root)
    bootout_session_dashboard(sid)

    # 브랜치/worktree 정리는 원본(main) 체크아웃에서 돌아야 한다 (삭제될 worktree 경로가 아니라).
    main_checkout = source_root_for(root)
    if main_checkout.resolve() == root.resolve():
        raise ValueError("원본 체크아웃을 찾지 못해 삭제를 중단합니다")
    branch = f"codex/{sid}"
    try:
        root_branch = git_output(["branch", "--show-current"], root).strip()
    except Exception:
        root_branch = ""
    results: dict[str, Any] = {"subrepos": {}, "branches": {}, "root": None}
    for repo in subrepos_of(root):
        target = root / repo
        source_repo = main_checkout / repo
        if source_repo.exists():
            removed = remove_git_worktree(source_repo, target, force=force)
            results["subrepos"][repo] = removed
            if "error" not in removed:
                # worktree 가 빠졌으니 codex/<id> 브랜치도 안전 삭제 시도 (미머지면 skipped)
                results["branches"][repo] = delete_merged_branch(source_repo, branch)
        elif target.exists():
            results["subrepos"][repo] = {"error": f"source repo not found: {source_repo}", "path": str(target)}

    results["root"] = remove_git_worktree(main_checkout, root, force=force)
    # 루트 레포 브랜치 정리: claude worktree 는 claude/<id> 를 물고 있음. codex 루트는 보통
    # detached HEAD 라 root_branch 가 비어 스킵되지만, 브랜치 체크아웃이면 동일하게 -d 시도.
    if root_branch and re.match(r"^(codex|claude)/", root_branch) and "removed" in (results["root"] or {}):
        results["branches"][project_label(main_checkout)] = delete_merged_branch(main_checkout, root_branch)
    # codex 레이아웃(<id>/<projectBasename>)은 제거 후 빈 부모 셸 <id>/ 가 남는다 → 정리
    parent = root.parent
    if "removed" in (results["root"] or {}) and root.name == main_checkout.name and parent.parent == WORKTREES_ROOT:
        try:
            if parent.is_dir() and not any(parent.iterdir()):
                parent.rmdir()
                results["parentDir"] = f"removed {parent}"
        except OSError:
            pass
    _worktree_info_cache.pop(str(root), None)
    _worktree_du_cache.pop(str(root), None)
    _roots_cache.clear()  # 삭제된 root 가 60s 캐시에 남지 않게
    return results

def attach_subrepo_action(root: Path, subrepo: str) -> dict[str, Any]:
    # 단일 subrepo 물리 attach — 기존 attach 스크립트 재사용(MARINA_SUBREPOS=<하나>). idempotent + yml/env/venv 동기화.
    source = source_root_for(root)
    if source.resolve() == root.resolve():
        raise ValueError("원본 체크아웃에는 attach 대상이 없습니다")
    env = {
        **os.environ,
        "DEST_ROOT": str(root),
        "SOURCE_ROOT": str(source),
        "MARINA_SUBREPOS": subrepo,
        "SYNC_IDEA": os.environ.get("SYNC_IDEA", "false"),
    }
    try:
        out = subprocess.check_output([str(MARINA_ATTACH)], text=True, stderr=subprocess.STDOUT, env=env)
    except subprocess.CalledProcessError as exc:
        raise ValueError((exc.output or "").strip() or str(exc))
    _worktree_info_cache.pop(str(root), None)
    _worktree_du_cache.pop(str(root), None)
    _status_cache.pop(str(root), None)
    return {"ok": True, "attached": subrepo, "output": out.strip()}

def detach_subrepo_action(root: Path, subrepo: str, force: bool = False, stop_services: bool = False) -> dict[str, Any]:
    target = root / subrepo
    if not (target / ".git").exists():
        return {"ok": True, "detached": subrepo, "note": "already detached"}
    # dirty working tree — clean 이면 지금 제거, 미커밋 변경 있으면 confirm 후 --force.
    status = worktree_status(root)
    entry = next((r for r in status["repos"] if r["name"] == subrepo), None)
    if entry and entry.get("dirty") and not force:
        return {"needsConfirm": True, "changes": entry.get("changes", [])}
    source_repo = source_root_for(root) / subrepo
    if not source_repo.exists():
        return {"error": f"source repo not found: {source_repo}"}
    # 브랜치는 보존(worktree remove 만) — 미머지 커밋 안전, 재attach 시 재사용.
    res = remove_git_worktree(source_repo, target, force=force)
    _worktree_info_cache.pop(str(root), None)
    _worktree_du_cache.pop(str(root), None)
    _status_cache.pop(str(root), None)
    if "error" in res:
        return res
    return {"ok": True, "detached": subrepo, **res}

def memory_block(force: bool) -> dict[str, Any] | None:
    # 가용 메모리가 기준 미만이면 시작을 막는다 (UI confirm 후 force=true 로 재시도 가능)
    if force:
        return None
    info = system_memory()
    free_mb = info.get("freeMb")
    min_free = int(_env("MIN_FREE_MB", "4096"))
    if free_mb is not None and free_mb < min_free:
        return {"blocked": "low-memory", "freeMb": free_mb, "minFreeMb": min_free}
    return None

def start_service(root: Path, service: str, force: bool = False) -> dict[str, Any]:
    block = memory_block(force)
    if block:
        return block

    # 구버전은 foreground 모드 + 자체 로그 fd 로 띄워서 (1) 시작마다 로그 run 이 2개 생기고
    # (2) fd 가 누수됐다. CLI start 경로로 일원화 — 로그·pid 관리는 marina.sh 가 전담.
    session_dir(root).mkdir(parents=True, exist_ok=True)
    env = marina_env(root)
    # codex worktree 는 dashboard 기동 시 prepare 완료 — claude worktree 는 미attach 면 start 가 attach 수행
    env["MARINA_SKIP_PREPARE"] = "1" if has_attached_subrepos(root) else "0"

    def _do_start():
        _marina_cli_logged(root, "start", f"--{service}", timeout=LIFECYCLE_TIMEOUT,
                           extra_env={"MARINA_SKIP_PREPARE": env["MARINA_SKIP_PREPARE"]})

    return _spawn_lifecycle(busy_key(root, service), "start", _do_start)

def restart_service(root: Path, service: str, force: bool = False) -> dict[str, Any]:
    return _spawn_lifecycle(busy_key(root, service), "restart",
                            lambda: _marina_cli_logged(root, "restart", f"--{service}", timeout=LIFECYCLE_TIMEOUT))

def rebuild_service(root: Path, service: str, force: bool = False) -> dict[str, Any]:
    block = memory_block(force)
    if block:
        return block
    return _spawn_lifecycle(busy_key(root, service), "rebuild",
                            lambda: _marina_cli_logged(root, "rebuild", f"--{service}", timeout=LIFECYCLE_TIMEOUT))

def clear_worktree_cache(root: Path, category: str = "all") -> dict[str, Any]:
    by_category = cache_items_by_category(root)
    if category != "all" and category not in by_category:
        raise ValueError("unknown cache category")
    targets = [item for cat, items in by_category.items() if category in ("all", cat) for item in items]
    removed: list[str] = []
    freed = 0
    for item in targets:
        size = int(item.get("sizeMb") or 0)
        try:
            if item.get("type") == "volume":
                volume = str(item.get("volume") or "")
                docker_volume_rm(volume)
                removed.append(volume)
            else:
                path = item.get("path")
                if not isinstance(path, Path):
                    continue
                if not size:
                    size = disk_usage_mb(path) or 0
                shutil.rmtree(path)
                try:
                    label = os.path.relpath(os.path.realpath(str(path)), os.path.realpath(str(root))).replace(os.sep, "/")
                except (ValueError, OSError):
                    label = str(path)
                removed.append(label)
            freed += size
        except (OSError, subprocess.CalledProcessError) as exc:
            label = str(item.get("volume") or item.get("name") or item.get("path") or "cache")
            removed.append(f"{label} (실패: {exc})")
    _worktree_info_cache.pop(str(root), None)
    _worktree_du_cache.pop(str(root), None)
    return {"removed": removed, "freedMb": freed}

def delete_merged_branch(source_repo: Path, branch: str) -> dict[str, Any]:
    # 안전 삭제(-d): 미머지 커밋이 있으면 git 이 거부 → skipped 로 보고
    try:
        git_output(["branch", "-d", branch], source_repo)
        return {"deleted": branch}
    except subprocess.CalledProcessError as exc:
        return {"skipped": branch, "reason": (exc.output or "").strip()[-200:]}
    except Exception as exc:
        return {"skipped": branch, "reason": str(exc)[-200:]}

def bootout_session_dashboard(sid: str) -> None:
    # worktree 삭제 후 launchd 에 세션 라벨이 유령으로 남는 것 방지 (best-effort)
    if not shutil.which("launchctl"):
        return
    # 신 라벨 + 리네이밍 전 설치본 라벨 둘 다 정리
    for label in (f"marina.dashboard.{sid}", f"dev.codex.session-dashboard.{sid}"):
        subprocess.run(
            ["launchctl", "bootout", f"gui/{os.getuid()}/{label}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

def _expose_cors_targets(xm_gateway: dict) -> dict:
    """x-marina.gateway.expose 에서 `gateway:svc` 로 지목된 be → 그 consumer 서비스명 목록(=CORS 허용 origin 의 주인).
    `origin:` 은 same-origin 이라 CORS 불요 → 제외. consumer 가 비대표(admin 등)여도 그 origin 을 허용해야
    하므로 bool 이 아니라 consumer 목록을 스냅샷에 실어 보낸다(코덱스 P2)."""
    out = {}
    for consumer, envmap in ((xm_gateway or {}).get("expose") or {}).items():
        for _var, val in (envmap or {}).items():
            tok = _mc().parse_expose_token(str(val))
            if tok and tok[0] == "gateway":
                out.setdefault(tok[1], [])
                if consumer not in out[tok[1]]:
                    out[tok[1]].append(consumer)
    return {k: sorted(v) for k, v in out.items()}


def _gateway_snapshot() -> list:
    """모든 워크트리 → {id, projectId, services:[{service,port,running,routes}]} (라이브 호스트포트). 게이트웨이 config 입력.
    routes = backing.json top-level gatewayRoutes[<service>](경로 prefix 리스트) — 브라우저 상대주소 be 호출을 대표 도메인에서 path 라우팅(limit#1)."""
    out = []
    for root in discover_roots():
        try:
            p = session_payload(root)
            proj = project_for(root) or {}
            pid = proj.get("id") or p.get("source") or ""
        except Exception:
            continue
        groutes = {}; gprimary = ""; xm_gw = {}             # 선언형 — 감지 안 함(SPEC 원칙)
        try:                                                # x-marina.gateway (보관 compose, 새 SoT) 우선
            cfile = proj.get("composeFile", "docker-compose.yml")
            xm_gw = _mc().xmarina_for_stored(str(MARINA_HOME / str(pid) / cfile)).get("gateway") or {}
            xm_routes = xm_gw.get("routes") or {}
            gprimary = str(xm_gw.get("primary") or "")      # 대표 도메인 서비스(명시). 없으면 web-name 자동
        except Exception:
            xm_routes = {}
        if xm_routes:
            groutes = xm_routes
        else:                                               # 레거시 backing.json gatewayRoutes fallback (전환기)
            try:
                _bj = json.loads((MARINA_HOME / str(pid) / "backing.json").read_text(encoding="utf-8"))
                groutes = _bj.get("gatewayRoutes") or {}
            except Exception:
                groutes = {}
        cors_map = _expose_cors_targets(xm_gw)              # 도메인 모드 expose 타겟 → {be: [consumer...]} (그 be 서브도메인에 consumer origin CORS)
        out.append({"id": p.get("id"), "projectId": pid, "primary": gprimary,
                    "services": [{"service": s.get("service"), "port": s.get("port"), "running": s.get("running"),
                                  "routes": groutes.get(s.get("service")) or [],
                                  "cors": s.get("service") in cors_map,
                                  "corsConsumers": cors_map.get(s.get("service")) or []}
                                 for s in (p.get("services") or [])]})
    return out

_GW_DIR = MARINA_HOME / "gateway"
_GW_PORT_FILE = _GW_DIR / "port"
_GW_PID_FILE = _GW_DIR / "caddy.pid"
_GW_CONTROL = Path(__file__).resolve().parent / "marina-gateway-control.sh"


def _gw_pid_alive() -> bool:
    try:
        pid = int(_GW_PID_FILE.read_text().strip())
        os.kill(pid, 0)                                   # 존재 확인
        # PID 재사용 오판 방지 — 그 PID 가 실제 caddy 인지 검증(아니면 stale 로 간주)
        comm = subprocess.run(["ps", "-p", str(pid), "-o", "comm="],
                              capture_output=True, text=True, timeout=3).stdout
        return "caddy" in comm
    except Exception:
        return False


def _port_file_reusable() -> int:
    """게이트웨이 미기동 상태에서 port 파일 값이 유효 범위·빈 포트면 그 값(재사용), 아니면 0."""
    try:
        p = int(_GW_PORT_FILE.read_text().strip())
        if not (0 < p < 65536):
            return 0
    except Exception:
        return 0
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(("127.0.0.1", p))
            return p
        except OSError:
            return 0


def _free_port_from(base: int, span: int = 50) -> int:
    """base 부터 위로 첫 빈 포트(127.0.0.1). base=3902 위로만 가 대시보드(3900)·프리뷰(3901)와 절대 안 겹침."""
    import socket
    for p in range(base, base + span):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", p))
                return p
            except OSError:
                continue
    return base


def _resolved_gateway_port() -> int:
    if _env("GATEWAY_PORT", ""):                          # 명시 지정이면 그대로
        return _GATEWAY_PORT
    try:
        return int(_GW_PORT_FILE.read_text().strip())     # 자동 기동 시 확정·기록한 포트
    except Exception:
        return _GATEWAY_PORT


def ensure_gateway() -> None:
    """서비스 start 이벤트 — 라우트 대상(실행중·호스트포트 보유 서비스)이 있고 caddy 설치돼 있으면
    게이트웨이를 없을 때 자동 기동(비특권 포트, 권한 불요)하고 라우트를 반영한다. 절대 예외 안 던짐(서비스 흐름·데몬 안 깸)."""
    if not _GATEWAY_ON:
        return
    try:
        snap = _gateway_snapshot()
        if not any((s or {}).get("running") and str((s or {}).get("port") or "").isdigit()
                   for wt in (snap or []) for s in ((wt or {}).get("services") or [])):
            return                                        # 라우팅할 게 없으면 안 띄움
        if not _gw().caddy_bin():
            return                                        # caddy 미설치 → 조용히(나머지 marina 정상)
        if _gw_pid_alive():
            port = _resolved_gateway_port()
        else:
            # port 파일 값이 아직 빈 포트면 재사용 — 먼저 돈 cmd_up(expose env 주입)이 그 파일을 읽고/선기록하므로
            # 여기서 딴 포트를 고르면 주입 URL 과 기동 포트가 어긋난다(코덱스 P2). 못 쓰면 그때만 새로.
            port = _GATEWAY_PORT if _env("GATEWAY_PORT", "") else (_port_file_reusable() or _free_port_from(_GATEWAY_PORT))
            _GW_DIR.mkdir(parents=True, exist_ok=True)
            _GW_PORT_FILE.write_text(str(port))
            # caddy 가 읽을 config 를 기동 전에 선기록 → caddy run 이 즉시 포트+라우트로 바인드
            # (reload 레이스 제거: admin 미준비 상태에서 apply→reload 실패로 라우트 누락되는 문제 방지)
            _gw().write_config(_gw().build_caddyfile(snap, port), _GATEWAY_STATE)
            subprocess.run(["bash", str(_GW_CONTROL), "start"],
                           env={**os.environ, "MARINA_GATEWAY_PORT": str(port), "MARINA_HOME": str(MARINA_HOME)},
                           timeout=20, capture_output=True)
        _gw().apply(snap, port, _GATEWAY_STATE)   # 이미 떠있던 경우/드리프트 시 무중단 reload
    except Exception as exc:
        sys.stderr.write(f"gateway ensure 실패(무시): {exc}\n")


def refresh_gateway() -> None:
    """stop 등 이벤트 — 게이트웨이가 이미 떠있을 때만 라우트 reload(자동 기동은 안 함). caddy 없거나 미기동이면 no-op. 절대 예외 안 던짐."""
    if not _GATEWAY_ON:
        return
    try:
        if _gw().caddy_bin() and _gw_pid_alive():
            _gw().apply(_gateway_snapshot(), _resolved_gateway_port(), _GATEWAY_STATE)
    except Exception as exc:
        sys.stderr.write(f"gateway refresh 실패(무시): {exc}\n")
