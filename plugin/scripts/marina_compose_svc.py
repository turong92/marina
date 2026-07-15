"""marina_compose_svc.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
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

from marina_state import MARINA_HOME, _SUBREPO_MAP_CACHE, _bin, _mc
from marina_dockerfile import _detect_injections, _prebuild_suggest, detect_profile_var, is_profile_var
from marina_paths import log_run_payload, service_log, session_id

def _docker_cmd(*args: str) -> list[str]:
    return [_bin("docker"), *args]

_LOG_TAIL_CACHE: dict[str, tuple[float, int, str]] = {}   # path → (mtime, size, line). 5s 폴링에 stat 만으로 재사용.

def _log_tail_line(path: str):
    """로그 파일의 마지막 비어있지 않은 1줄(+mtime) — 카드 미리보기·상대시간용(콘솔 카드 질감).
    끝 2KB 만 seek 해 읽고 (mtime,size) 캐시로 매 폴링 재파싱을 피한다. ANSI 는 제거."""
    try:
        st = os.stat(path)
    except OSError:
        return None, None
    cached = _LOG_TAIL_CACHE.get(path)
    if cached and cached[0] == st.st_mtime and cached[1] == st.st_size:
        return cached[2], st.st_mtime
    try:
        with open(path, "rb") as f:
            f.seek(max(0, st.st_size - 2048))
            chunk = f.read().decode("utf-8", "replace")
    except OSError:
        return None, None
    line = next((l for l in reversed(chunk.splitlines()) if l.strip()), "")
    line = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", line).strip()[:200]
    _LOG_TAIL_CACHE[path] = (st.st_mtime, st.st_size, line)
    return line, st.st_mtime

def _service_host_ports(svc_cfg: Any) -> dict[str, list[int]]:
    """compose config(서비스) → {pub: publish된 호스트포트, tgt: 컨테이너(앱) 포트}. 포트 기반 liveness 용.
    pub 은 어느 세션에서나 격리 호스트포트라 안전. tgt 는 직접 실행(npm/node) 시 앱이 host 에 바인딩하는 포트 — main 에서만 fallback."""
    pub: list[int] = []
    tgt: list[int] = []
    def _add(lst, v):
        try:
            if v not in (None, ""):
                lst.append(int(str(v)))
        except (TypeError, ValueError):
            pass
    for p in ((svc_cfg or {}).get("ports") if isinstance(svc_cfg, dict) else None) or []:
        if isinstance(p, dict):
            _add(pub, p.get("published")); _add(tgt, p.get("target"))
        elif isinstance(p, str):                       # "3000:3000" · "127.0.0.1:3000:3000" · "3000"
            parts = p.split(":")
            _add(tgt, parts[-1])
            if len(parts) >= 2:
                _add(pub, parts[-2])
    return {"pub": sorted(set(pub)), "tgt": sorted(set(tgt))}

def _port_listening(port: int) -> bool:
    """로컬에서 그 TCP 포트를 누가 listen 중인지(연결 가능 여부). docker 컨테이너 밖(직접 node/gradle 실행)도 감지."""
    import socket
    for family, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        try:
            with socket.socket(family, socket.SOCK_STREAM) as s:
                s.settimeout(0.25)
                if s.connect_ex((addr, port)) == 0:
                    return True
        except OSError:
            pass
    return False

def _yaml_without_external_includes(yaml_text: str) -> str:
    """compose_validate 전용 — `.workspace/external` 를 가리키는 include 항목 제거.
    등록 시점엔 외부 레포가 아직 attach 안 됐어서 docker 가 그 include 를 못 풂(start 때 생성·검증).
    include: 블록이 통째로 비면 키까지 제거. 블록 스타일(- item) 가정(프론트가 그렇게 emit)."""
    lines = yaml_text.splitlines()
    out, i = [], 0
    while i < len(lines):
        ln = lines[i]
        if re.match(r"^\s*include\s*:\s*$", ln):
            j = i + 1
            items = []
            while j < len(lines) and re.match(r"^\s*-\s", lines[j]):
                items.append(lines[j]); j += 1
            kept = [it for it in items if ".workspace/external" not in it.replace(os.sep, "/")]
            if kept:
                out.append(ln); out.extend(kept)
            i = j; continue
        out.append(ln); i += 1
    return "\n".join(out) + ("\n" if yaml_text.endswith("\n") else "")

def compose_validate(yaml_text: str, project_dir: Path,
                     env_var: str = "", env_default: str = "") -> dict[str, Any]:
    """yaml 을 temp 에 써서 `docker compose config` 로 해석 → isolation_breakers.
    반환 {ok, errors[], warnings[]}. docker 실패(파싱/보간) → ok:False + stderr.
    워크트리 .env(여러 env)는 --project-directory 로 docker 가 자동 로드(compose 표준).
    외부 레포 include 는 attach 전이라 검증에서 제외(start 때 resolve)."""
    env = dict(os.environ)
    if env_var:
        env.setdefault(env_var, env_default or "local")
    with tempfile.TemporaryDirectory() as td:
        f = Path(td) / "docker-compose.yml"
        f.write_text(_yaml_without_external_includes(yaml_text), encoding="utf-8")
        try:
            r = subprocess.run(
                _docker_cmd("compose", "-f", str(f), "--project-directory", str(project_dir),
                            "config", "--format", "json"),
                capture_output=True, text=True, env=env)
        except FileNotFoundError:
            return {"ok": False,
                    "errors": ["Docker 미설치 — compose-kind 는 Docker 필요 (Docker Desktop 설치 후 재시도)."],
                    "warnings": []}
        if r.returncode != 0:                       # 실패 → stderr(보간/파싱 에러) 노출
            return {"ok": False,
                    "errors": [(r.stderr or r.stdout or "").strip() or "docker compose config 실패"],
                    "warnings": []}
        out = r.stdout                              # stdout 만 = 순수 JSON. stderr(docker warning, 예: version obsolete)가 섞여 json.loads 가 깨지지 않게 분리.
    config = json.loads(out)
    errors, warnings = _mc().isolation_breakers(config)
    missing = _mc().missing_dockerfile_services(config)            # Dockerfile 없는 build 서비스 → 차단 대신 경고(부분 등록 허용: 하나 깨져도 나머지는 등록·기동)
    build_total = sum(1 for s in (config.get("services") or {}).values() if (s or {}).get("build"))
    if missing and len(missing) >= build_total:                   # build 서비스가 전부 Dockerfile 누락 → 등록 의미 없음(차단)
        errors = errors + [f"service '{n}': Dockerfile 없음 ({p}) — compose-kind 는 build 서비스에 Dockerfile 필수." for n, p in missing.items()]
    else:
        warnings = warnings + [f"service '{n}': Dockerfile 없음 ({p}) — 이 서비스는 비활성으로 등록(기동 시 건너뜀, 나머지는 정상)." for n, p in missing.items()]
    return {"ok": not errors, "errors": errors, "warnings": warnings, "degraded": sorted(missing)}

def compose_health(state: str, health: str) -> str | None:
    """docker compose ps State/Health → pill 문자열. 정지 상태는 None(OFF).
    healthcheck 없으면 Health='' → running 이면 ok."""
    state = (state or "").lower()
    health = (health or "").lower()
    if state == "running":
        if health == "unhealthy":
            return "bad"
        if health == "starting":
            return "starting"
        return "ok"
    if state == "restarting":
        return "starting"
    return None  # created / paused / exited / dead / removing → OFF (▶ 표시)

def build_compose_services(ps_rows: list) -> list:
    """`docker compose ps --all --format json` 행 → 대시보드 서비스 dict.
    running = (health is not None) — 프론트 pillState 가 running 으로 health 표시를 게이트하기 때문.
    포트는 PublishedPort(str/int 혼재 가능) int 캐스트·dedup 후 최소값 대표(다중 publish 는 v1 한계)."""
    out = []
    for r in ps_rows:
        if not isinstance(r, dict):
            continue
        svc = r.get("Service") or r.get("Name") or "?"
        pubs = set()
        for p in (r.get("Publishers") or []):
            if isinstance(p, dict) and p.get("PublishedPort"):
                try:
                    pubs.add(int(p["PublishedPort"]))
                except (TypeError, ValueError):
                    pass
        health = compose_health(r.get("State") or "", r.get("Health") or "")
        try:   # exited 컨테이너의 종료 코드 — 크래시(비정상 종료)를 '정지'와 구분해 표면화
            exit_code = int(r.get("ExitCode")) if str(r.get("State") or "").lower() == "exited" else None
        except (TypeError, ValueError):
            exit_code = None
        out.append({
            "service": svc,
            "port": str(min(pubs)) if pubs else None,
            "running": health is not None,
            "health": health,
            "exitCode": exit_code,
            "external": False,
            "trackedPid": None,
            "trackedAlive": False,
            "listenerPids": [],
            "rssMb": None,
            "memoryUsageMb": None,
            "memoryPeakMb": None,
            "memoryLimitMb": None,
            "memoryPercent": None,
            "oomKilled": None,
            "log": "",
            "logRuns": [],
            "subrepo": "",
            "source": "compose",
            "def": None,
        })
    out.sort(key=lambda s: s["service"])
    return out

def compose_ps(root: Path, project_name: str) -> list:
    """docker compose -p <name> ps --all --format json → 행 리스트. docker 없거나 실패 시 [].
    --all 로 정지 컨테이너도 포함(대시보드에서 재기동 가능)."""
    try:
        out = subprocess.check_output(
            _docker_cmd("compose", "-p", project_name, "ps", "--all", "--format", "json"),
            cwd=str(root), text=True, stderr=subprocess.DEVNULL, timeout=5,
        )
    except Exception:
        return []
    out = out.strip()
    if not out:
        return []
    try:
        v = json.loads(out)
        return v if isinstance(v, list) else [v]
    except json.JSONDecodeError:
        rows = []
        for ln in out.splitlines():
            ln = ln.strip()
            if ln:
                try:
                    rows.append(json.loads(ln))
                except json.JSONDecodeError:
                    pass
        return rows

def compose_service_names(root: Path, project: dict) -> tuple:
    """compose 워크트리의 서비스 이름들 = 보관 compose 정의 ∪ ps 라이브 — log_targets_for/safe_service 검증용.
    중지된 서비스도 포함해야 대시보드에서 ▶ 시작·로그 선택이 됨(없으면 safe_service 가 'unknown service' 로 거부)."""
    name = _mc().compose_project_name(project.get("id", ""), session_id(root))
    live = {(r.get("Service") or r.get("Name") or "")
            for r in compose_ps(root, name)
            if isinstance(r, dict) and (r.get("Service") or r.get("Name"))}
    # 페이로드(_compose_services)와 동일하게 include(서브레포 자체 compose) 해석분도 포함 —
    # 안 그러면 stopped include 서비스가 카드엔 보이는데 safe_service 가 'unknown service' 로 거부(코덱스 감사 #2).
    try:
        included = set(compose_service_subrepos(root, project))
    except Exception:
        included = set()
    return tuple(sorted(live | set(_compose_defined_services(project)) | included))

def _compose_defined_services(project: dict) -> list:
    """보관된 compose 의 services: 하위 키들 — 중지 상태라도 카드에 행을 띄워 ▶ 시작할 수 있게.
    docker 불요(가벼운 들여쓰기 파싱). 블록 스타일 가정 — marina 생성·검증 compose 는 항상 블록 스타일."""
    try:
        sp = MARINA_HOME / str(project["id"]) / project.get("composeFile", "docker-compose.yml")
        text = sp.read_text(encoding="utf-8")
    except (OSError, KeyError):
        return []
    out: list = []
    in_services = False
    svc_indent = None
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        key = raw.strip()
        if not in_services:
            if indent == 0 and key.rstrip() == "services:":
                in_services = True
            continue
        if indent == 0:                       # 다음 top-level 키 → services 블록 끝
            break
        if svc_indent is None:
            svc_indent = indent               # 첫 서비스의 들여쓰기 = 서비스 레벨
        if indent == svc_indent and key.endswith(":"):
            out.append(key[:-1].strip().strip("\"'"))
    return out

def _subrepo_label_from_context(ctx, root: Path) -> str:
    """build 컨텍스트 절대경로 → 서브레포 라벨. .workspace/external/<name>/… → <name>(외부),
    <top>/… → <top>(내부 서브레포), 루트 → "."(단일레포, prebuild/config 키잉용·표시는 ungroup), build 없음/밖 → ""."""
    if not ctx:
        return ""
    try:   # realpath 양쪽 — root 가 심볼릭(macOS /tmp→/private/tmp 등)이고 compose 가 realpath context 를 줄 때 어긋남 방지(코덱스 감사 #8)
        rel = os.path.relpath(os.path.realpath(str(ctx)), os.path.realpath(str(root))).replace(os.sep, "/")
    except (ValueError, OSError):
        return ""
    if rel.startswith(".."):
        return ""
    if rel in (".", ""):
        return "."
    parts = rel.split("/")
    if rel.startswith(".workspace/external/") and len(parts) >= 3:
        return parts[2]
    return parts[0]

def _compose_config_maps(root: Path, project: dict) -> tuple[dict, dict, dict]:
    """보관 compose 를 `docker compose config` 로 한 번 해석 → (서비스→서브레포 라벨 맵, degraded 맵{svc: 없는 Dockerfile 경로}).
    config 결과(submap·build Dockerfile 경로)는 보관 compose mtime 으로 캐시(폴링마다 docker 안 돌림).
    degraded(파일 존재)는 매 poll 재판정 — Dockerfile 추가/삭제를 즉시 반영(코덱스 리뷰 #2). config 실패(미attach 등) → 직전 캐시/빈."""
    try:
        sp = MARINA_HOME / str(project["id"]) / project.get("composeFile", "docker-compose.yml")
        mtime = sp.stat().st_mtime
    except (OSError, KeyError):
        return {}, {}, {}
    key = (str(sp), os.path.realpath(str(root)))
    hit = _SUBREPO_MAP_CACHE.get(key)
    if hit and hit[0] == mtime and hit[1]:
        submap, build_paths, port_map = hit[1], hit[2], (hit[3] if len(hit) > 3 else {})
    else:
        submap, build_paths, port_map = {}, {}, {}
        try:
            out = subprocess.check_output(
                _docker_cmd("compose", "-f", str(sp), "--project-directory", str(root),
                            "config", "--format", "json"),
                text=True, stderr=subprocess.DEVNULL, timeout=8)
            config = json.loads(out)
            for sname, svc in (config.get("services") or {}).items():
                b = (svc or {}).get("build")
                ctx = b.get("context") if isinstance(b, dict) else (b if isinstance(b, str) else None)
                submap[sname] = _subrepo_label_from_context(ctx, root)
                hp = _service_host_ports(svc)
                if hp["pub"] or hp["tgt"]:
                    port_map[sname] = hp
            build_paths = _mc().build_dockerfile_paths(config)   # 경로만(존재 여부 X) → 캐시 가능
        except Exception:
            if not hit:
                return {}, {}, {}
            submap, build_paths, port_map = hit[1], hit[2], (hit[3] if len(hit) > 3 else {})  # config 실패 → 직전 캐시 유지
        if submap:
            _SUBREPO_MAP_CACHE[key] = (mtime, submap, build_paths, port_map)
    degraded = {svc: p for svc, p in build_paths.items() if not os.path.exists(p)}   # 매 poll 재판정(Dockerfile 추가/삭제 즉시 반영)
    return submap, degraded, port_map

def compose_service_subrepos(root: Path, project: dict) -> dict:
    """서비스 → 서브레포 라벨 (하위호환 래퍼 — _compose_config_maps 의 submap)."""
    return _compose_config_maps(root, project)[0]

def _profile_value(svc_build_args) -> str:
    """서비스 build-args.json 항목 → 명시 설정된 profile 값(후보 키의 값) 또는 ''. 카드 칩용(글랜스)."""
    for k, v in (svc_build_args or {}).items():
        if is_profile_var(k):
            return str(v)
    return ""


def _service_profile(arg_names, marina_build_args, stored_build_args) -> dict:
    """ARG 목록 + (marina overlay build args, stored build args) → {profileVar, profileValue}.
    값은 marina overlay 우선, 없으면 stored, 둘 다 없으면 ''."""
    var = detect_profile_var(arg_names)
    if not var:
        return {"profileVar": None, "profileValue": ""}
    val = (marina_build_args or {}).get(var)
    if val is None:
        val = (stored_build_args or {}).get(var)
    return {"profileVar": var, "profileValue": "" if val is None else str(val)}


def _docker_compose_config_json(
    sp: Path,
    root: Path,
    env: dict[str, str] | None = None,
) -> tuple[dict | None, str]:
    """보관 compose(sp) → `docker compose config --format json` 해석 결과(raw dict) 또는 (None, error).
    compose_resolved_view·weave_map(연결 탭 P3) 공유 — 같은 docker 호출 규약(중복 회피). 컨테이너를 안 띄우는
    '설정 해석' 1회 호출이라 가볍다(up/ps 아님) — daemon 이 꺼져 있어도 대체로 동작."""
    try:   # stdout/stderr 분리 — docker 경고(version obsolete 등)가 JSON 에 섞이면 안 됨
        proc = subprocess.run(
            _docker_cmd("compose", "-f", str(sp), "--project-directory", str(root),
                        "config", "--format", "json"),
            capture_output=True, text=True, timeout=12, env=env)
    except FileNotFoundError:
        return None, "docker 미설치"
    except subprocess.TimeoutExpired:
        return None, "docker compose config 시간 초과"
    if proc.returncode != 0:
        return None, ((proc.stderr or proc.stdout or "").strip()[:800] or "docker compose config 실패")
    try:
        return json.loads(proc.stdout), ""
    except json.JSONDecodeError:
        return None, "config json 파싱 실패"


def compose_start_targets(root: Path, project: dict, requested: list[str]) -> list[str]:
    """Resolve actual Compose start targets, including startGroup and dependencies.

    Lifecycle safety checks must fail explicitly when config cannot be resolved;
    treating that failure as an empty target set would incorrectly report that
    everything is already running.
    """
    try:
        stored = MARINA_HOME / str(project["id"]) / project.get("composeFile", "docker-compose.yml")
    except KeyError as exc:
        raise ValueError("project id 없음") from exc
    if not stored.exists():
        raise ValueError(f"보관 compose 없음: {stored}")
    try:
        source = stored.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"compose 파일 읽기 실패: {exc}") from exc
    resolved_source = source
    for external in project.get("externalRepos") or []:
        if not isinstance(external, dict):
            continue
        name = str(external.get("name") or "").strip()
        source_path = str(external.get("source") or "").strip()
        if not name or not source_path:
            continue
        attached = root / ".workspace" / "external" / name
        replacement = attached if attached.exists() else Path(source_path).expanduser()
        resolved_source = resolved_source.replace(f"./.workspace/external/{name}", str(replacement))
        resolved_source = resolved_source.replace(f".workspace/external/{name}", str(replacement))

    plan_file = stored
    temporary: str | None = None
    if resolved_source != source:
        fd, temporary = tempfile.mkstemp(prefix=stored.name + ".memory-plan-", dir=str(stored.parent))
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(resolved_source)
        plan_file = Path(temporary)

    env = dict(os.environ)
    env_var = str(project.get("composeEnvVar") or "").strip()
    if env_var:
        env[env_var] = os.environ.get("MARINA_COMPOSE_ENV") or str(project.get("composeEnvDefault") or "local")
    try:
        config, error = _docker_compose_config_json(plan_file, root, env=env)
    finally:
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
    if config is None:
        raise ValueError(f"compose config 해석 실패: {error}")
    try:
        xmarina = _mc().xmarina_for_stored(str(stored)) or {}
        grouped, _unknown = _mc().start_group_requested(xmarina, list(requested), config.get("services") or {})
        targets = _mc().service_dependency_closure(config, grouped)
    except Exception as exc:
        raise ValueError(f"compose 시작 대상 해석 실패: {exc}") from exc
    return list(dict.fromkeys(str(target) for target in targets if str(target)))


def weave_map(root: Path, project: dict) -> dict:
    """엮기(forward) 최종 맵 — `marina up` 과 동일한 병합 우선순위(legacy hostForward < 자동 서비스타겟 < 명시
    forward(backing.json < x-marina))를 marina-compose.py 순수 함수로 재계산(연결 탭 P3 데이터 소스). docker 는
    config 해석 1회만(가볍게 — up/ps 안 돌림, 컨테이너 기동 없음). 실패 → {ok:False, error}."""
    try:
        sp = MARINA_HOME / str(project["id"]) / project.get("composeFile", "docker-compose.yml")
    except KeyError:
        return {"ok": False, "error": "project id 없음"}
    if not sp.exists():
        return {"ok": False, "error": f"보관 compose 없음: {sp}"}
    cfg, err = _docker_compose_config_json(sp, root)
    if cfg is None:
        return {"ok": False, "error": err}
    warnings: list[str] = []
    conn: dict = {}
    conn_path = MARINA_HOME / str(project["id"]) / "backing.json"   # cmd_up 과 동일 경로 관례(marina-lib-compose.sh --connectivity)
    if conn_path.exists():
        try:
            conn = json.loads(conn_path.read_text(encoding="utf-8"))
        except Exception as exc:
            warnings.append(f"connectivity(backing.json) 읽기 실패 — 엮기 선언 건너뜀: {exc}")
    mc = _mc()
    xm = mc.xmarina_for_stored(str(sp))
    try:   # cmd_up(marina-compose.py) 과 동일 순서 — legacy hostForward < 자동 서비스타겟 < 명시(backing.json < x-marina)
        forward = {**mc._legacy_host_forward(conn), **mc._legacy_host_forward(xm),
                   **mc._auto_service_forward(cfg),
                   **mc._normalize_forward(conn), **mc._normalize_forward(xm)}
    except ValueError as exc:   # _port_targets 포트범위 파싱 실패 등(marina-compose.py 코덱스 리뷰 P3 와 동일 가드)
        return {"ok": False, "error": str(exc)}
    services_cfg = cfg.get("services") or {}
    applied: dict[str, list] = {}
    for name in sorted(services_cfg):
        svc = services_cfg.get(name) or {}
        if not svc.get("build"):
            continue   # image-only 서비스는 사이드카 없음(_applied_forward 와 동일 규칙 — _forward_for_service 재사용)
        pairs = mc._forward_for_service(forward, name, mc._served_ports(svc))
        if pairs:
            applied[name] = [list(p) for p in pairs]
    # 보관(stored) compose 가 정의한 실제 앱 서비스명 — 런타임에만 존재하는 `<svc>-bind` 엮기 사이드카(marina 가 build_overlay
    # 로 주입, docker compose ps 에는 보임)를 연결 탭이 서비스 노드에서 걸러낼 수 있게(코덱스/셀프 리뷰: 플러밍을 앱 서비스처럼 그리면 혼란).
    # gateway(routes·expose·primary) 원문 — 연결 탭이 서비스↔서비스(expose) 엣지를 그리고 편집하는 데 씀.
    # expose={consumer:{ENV:'gateway:target'|'origin:target'}} = 타겟 서비스 URL 을 consumer 의 env 로 주입(진짜 per-pair 관계).
    gw_raw = xm.get("gateway")
    return {"ok": True, "forward": forward, "applied": applied, "warnings": warnings,
            "appServices": sorted(services_cfg),
            "gateway": gw_raw if isinstance(gw_raw, dict) else {}}


def compose_resolved_view(root: Path, project: dict) -> dict:
    """읽기전용 구성 뷰 — `docker compose config` 로 해석한 서비스별 구성: 빌드 컨텍스트·Dockerfile(내용 포함)·
    포트·env 키(값은 비밀 우려로 숨김)·command·출처(직접/ include). config 실패 → {ok:False, error}."""
    try:
        sp = MARINA_HOME / str(project["id"]) / project.get("composeFile", "docker-compose.yml")
    except KeyError:
        return {"ok": False, "error": "project id 없음"}
    if not sp.exists():
        return {"ok": False, "error": f"보관 compose 없음: {sp}"}
    cfg, err = _docker_compose_config_json(sp, root)
    if cfg is None:
        return {"ok": False, "error": err}
    direct = set(_compose_defined_services(project))   # 보관 compose 직접 정의 — 나머지는 include 출처
    try:   # marina 가 주입할 build args(레지스트리=각자 로컬) — ⓘ 모달에서 편집
        ba_all = json.loads((MARINA_HOME / str(project["id"]) / "build-args.json").read_text(encoding="utf-8"))
    except Exception:
        ba_all = {}
    try:   # pre-build 명령 — x-marina.prebuild(보관 compose=SoT, 실행되는 것) 우선,
           # 없으면 레거시 prebuild.json. 표시=실행 일치(레거시 stale 표시 드리프트 제거).
        _stored = MARINA_HOME / str(project["id"]) / (project.get("composeFile") or "docker-compose.yml")
        _xpb = (_mc().xmarina_for_stored(str(_stored)) or {}).get("prebuild")
        if isinstance(_xpb, dict) and _xpb:
            pb_all = _xpb
        else:
            pb_all = json.loads((MARINA_HOME / str(project["id"]) / "prebuild.json").read_text(encoding="utf-8"))
    except Exception:
        pb_all = {}
    services = []
    for name in sorted(cfg.get("services") or {}):
        svc = cfg["services"][name] or {}
        b = svc.get("build")
        build, df_text = None, None
        if isinstance(b, dict) and b.get("context"):
            ctx_abs, df = b["context"], (b.get("dockerfile") or "Dockerfile")
            try:
                ctx_rel = os.path.relpath(ctx_abs, str(root)).replace(os.sep, "/")
            except ValueError:
                ctx_rel = str(ctx_abs)
            build = {"context": ctx_rel, "dockerfile": df}
            dfp = df if os.path.isabs(df) else os.path.join(ctx_abs, df)
            try:
                df_text = Path(dfp).read_text(encoding="utf-8", errors="replace")
            except OSError:                            # 케이스 어긋남 등 → 케이스 무관 재시도
                try:
                    d, base = os.path.dirname(dfp), os.path.basename(dfp).lower()
                    real = next((f for f in os.listdir(d) if f.lower() == base), None)
                    if real:
                        df_text = Path(os.path.join(d, real)).read_text(encoding="utf-8", errors="replace")
                except OSError:
                    pass
            if df_text and len(df_text) > 8000:
                df_text = df_text[:8000] + "\n… (생략)"
        env = svc.get("environment")
        env_keys = (sorted(env.keys()) if isinstance(env, dict)
                    else sorted(e.split("=", 1)[0] for e in env) if isinstance(env, list) else [])
        ports = [str(p.get("target")) for p in (svc.get("ports") or [])
                 if isinstance(p, dict) and p.get("target")]
        sub_label = _subrepo_label_from_context(b.get("context") if isinstance(b, dict) else None, root)
        pb_dir = None                          # 서브레포 루트(빌드도구 감지용) — 외부 마운트 우선
        if sub_label:
            _ext = root / ".workspace" / "external" / sub_label
            pb_dir = _ext if _ext.is_dir() else (root / sub_label)
        _inj = _detect_injections(df_text or "")
        _mba = (ba_all.get(name) if isinstance(ba_all.get(name), dict) else {})
        _stored_ba = (b.get("args") if isinstance(b, dict) and isinstance(b.get("args"), dict) else {})
        _service_pb = pb_all.get(name) if isinstance(pb_all, dict) else None
        if isinstance(_service_pb, dict):
            prebuild = {
                "mode": "service",
                "cwd": str(_service_pb.get("cwd") or ""),
                "command": str(_service_pb.get("command") or ""),
            }
        else:
            _legacy_pb = pb_all.get(sub_label) if isinstance(pb_all, dict) and sub_label else None
            prebuild = ({"mode": "legacy", "cwd": sub_label, "command": _legacy_pb}
                        if isinstance(_legacy_pb, str) else None)
        services.append({
            "service": name,
            "subrepo": sub_label,
            "image": svc.get("image"),
            "build": build,
            "dockerfile": df_text,
            "ports": ports,
            "envKeys": env_keys,
            "command": svc.get("command"),
            "source": ("직접 정의/스캐폴드" if name in direct else "include (서브레포 compose)"),
            "marinaBuildArgs": _mba,
            "injections": _inj,
            "prebuild": prebuild,
            "prebuildSuggest": (_prebuild_suggest(pb_dir) if (pb_dir and pb_dir.is_dir()) else ""),
            **_service_profile(_inj["args"], _mba, _stored_ba),
        })
    return {"ok": True, "services": services}

def _compose_services(root: Path, project: dict) -> list:
    """compose-kind 워크트리 서비스 = docker compose ps 라이브 + 정의됐지만 미실행 서비스(보관 compose)도 표시.
    중지 서비스도 행으로 보여 ▶ 시작 가능. log/logRuns 는 네이티브 헬퍼 재사용 → 로그 뷰어 그대로. /api/sessions 절대 500 금지."""
    try:
        is_main = session_id(root) == "main"            # 원본 checkout — 직접 실행(npm/node) dev 가 흔해 포트 fallback 폭 넓힘
        name = _mc().compose_project_name(project.get("id", ""), session_id(root))
        live_rows = compose_ps(root, name)
        live_names = {(r.get("Service") or r.get("Name")) for r in live_rows
                      if isinstance(r, dict) and (r.get("Service") or r.get("Name"))}
        submap, degraded, port_map = _compose_config_maps(root, project)  # 서비스→서브레포(빌드 컨텍스트) + Dockerfile 없는 서비스(비활성) + 서비스→호스트포트. include 해석분 포함.
        defined = set(_compose_defined_services(project)) | set(submap)   # 직접 정의 + include 해석분(정지 상태도 표시)
        stub_rows = [{"Service": s, "State": "stopped"}        # 미실행 정의 서비스 → OFF 행(▶)
                     for s in sorted(defined) if s not in live_names]
        svcs = build_compose_services([*live_rows, *stub_rows])
        ba_all = _read_marina_json(project.get("id", ""), "build-args.json")   # 명시 설정된 profile(글랜스 칩용)
        if not isinstance(ba_all, dict):
            ba_all = {}
        # x-marina.startGroup — 선언 시 '시작 그룹' 밖 서비스는 옵션(카드 집계 분모에서 제외, 꺼져 있는 동안)
        sp = MARINA_HOME / str(project.get("id", "")) / project.get("composeFile", "docker-compose.yml")
        try:
            _raw = (_mc().xmarina_for_stored(str(sp)) or {}).get("startGroup")
            _auto = [str(x) for x in _raw if isinstance(x, (str, int))] if isinstance(_raw, (list, tuple)) else []
        except Exception:
            _auto = []
        for s in svcs:
            base = s["service"][:-5] if s["service"].endswith("-bind") else s["service"]   # 엮기 사이드카는 본체를 따라감
            s["inStartGroup"] = (not _auto) or (base in _auto)
            s["subrepo"] = submap.get(s["service"], "")
            s["degraded"] = s["service"] in degraded   # Dockerfile 없음 → 기동 시 건너뜀(대시보드 '비활성' 배지)
            if s["degraded"]:                          # 원인 경로를 UI 까지 — '조용한 무시 금지'(콘솔 스펙)
                s["degradedReason"] = f"{degraded[s['service']]} 없음"
            _tgt = (port_map.get(s["service"]) or {}).get("tgt") or []   # 컨테이너 내부 포트 — '내부→호스트' 표기용(콘솔 스펙 D6)
            if _tgt:
                s["targetPort"] = str(min(_tgt))
            s["log"] = str(service_log(root, s["service"]))
            s["logRuns"] = log_run_payload(root, s["service"])
            tail, ts = _log_tail_line(s["log"])                    # 카드 미리보기 1줄 + 상대시간(콘솔 카드 질감)
            if tail:
                s["logTail"], s["logTs"] = tail, ts
            _svc_ba = ba_all.get(s["service"]) if isinstance(ba_all.get(s["service"]), dict) else {}
            s["profile"] = _profile_value(_svc_ba)
            if not s["running"] and not s["degraded"]:   # compose 컨테이너로는 안 도는데 그 서비스 포트를 누가 listen → 외부/직접 실행으로 점등(예: main 에서 node 로 직접 dev)
                pm = port_map.get(s["service"], {})
                ports = list(pm.get("pub") or [])
                if is_main:                               # main 은 직접 실행(npm/node)이 흔해 앱 포트(tgt)도 확인 — worktree 는 격리 host포트(pub)만(공유포트 오탐 방지)
                    ports += [p for p in (pm.get("tgt") or []) if p not in ports]
                for hp in ports:
                    if _port_listening(hp):
                        s["running"], s["health"], s["external"], s["port"] = True, "ok", True, str(hp)
                        break
        return svcs
    except Exception:
        return []

def _read_marina_json(pid, name):
    try:
        return json.loads((MARINA_HOME / str(pid) / name).read_text(encoding="utf-8"))
    except Exception:
        return None

# ${VAR} · ${VAR:?err} · ${VAR?err}(기본값 없음 — required) vs ${VAR:-x} · ${VAR-x}(기본값 있음 — docker compose 자체 해결) 구분.
# 선행 `(?<!\$)` 로 `$${VAR}`(compose 리터럴 이스케이프)는 인터폴레이션이 아니므로 제외.
_ENV_VAR_RE = re.compile(r"(?<!\$)\$\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*(:-|-|:\?|\?)?[^}]*\}")

def _required_env_vars(compose_text: str) -> list[str]:
    """compose 텍스트의 ${VAR}·${VAR:?err}(기본값 없는 인터폴레이션만) → 등장 순서로 dedup 한 이름 목록.
    ${VAR:-x}·${VAR-x} 는 기본값이 있어 docker compose 가 스스로 해결 — '누락'이 아니므로 제외(A2 스펙)."""
    out: list[str] = []
    seen: set[str] = set()
    for m in _ENV_VAR_RE.finditer(compose_text or ""):
        name, op = m.group(1), m.group(2)
        if op in ("-", ":-"):        # 기본값 있음 → 제외
            continue
        if name in seen:
            continue
        seen.add(name)
        out.append(name)
    return out

def _env_file_vars(path: Path) -> set[str]:
    """.env 파일에서 설정된 변수명 집합(값은 안 봄) — 주석(#)·빈 줄 무시, `export FOO=` 허용, 따옴표 유무 무관.
    파일 없으면 빈 집합(정상 — 대부분 프로젝트엔 .env 가 없다)."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return set()
    names: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if m:
            names.add(m.group(1))
    return names

_MISSING_ENV_CACHE: dict[tuple, tuple[tuple, list]] = {}   # (sp,wtEnv,projEnv) → ((mtimes...), 결과) — 5s 폴링마다 재파싱 방지

def missing_env_vars(root: Path, project: dict) -> list:
    """A2 — 보관 compose 의 필수 ${VAR}(기본값 없음) 중 어디서도 안 채워지는 것 → [{name, hint}].
    '설정됨' 판정 우선순위: ①프로세스 env(os.environ) ②워크트리 root/.env ③프로젝트 root/.env
    ④marina 자체 주입(build-args.json 의 키들 — build-arg 로 채움 · project.composeEnvVar — start 시 --env= 로 항상 주입).
    시작을 막지 않는다(경고만 — 카드 원인줄). compose mtime + 두 .env mtime 캐시(_compose_config_maps 캐시 패턴과 동일 취지)."""
    try:
        pid = str(project["id"])
        sp = MARINA_HOME / pid / project.get("composeFile", "docker-compose.yml")
        compose_mtime = sp.stat().st_mtime
    except (OSError, KeyError):
        return []
    wt_env_path = root / ".env"
    try:
        proj_root = Path(project["root"])
    except KeyError:
        proj_root = root
    proj_env_path = proj_root / ".env"

    def _mtime(p: Path) -> float:
        try:
            return p.stat().st_mtime
        except OSError:
            return -1.0

    key = (str(sp), str(wt_env_path), str(proj_env_path))
    cache_stamp = (compose_mtime, _mtime(wt_env_path), _mtime(proj_env_path))
    hit = _MISSING_ENV_CACHE.get(key)
    if hit and hit[0] == cache_stamp:
        return hit[1]
    try:
        compose_text = sp.read_text(encoding="utf-8")
    except OSError:
        return []
    required = _required_env_vars(compose_text)
    if not required:
        _MISSING_ENV_CACHE[key] = (cache_stamp, [])
        return []
    configured = set(os.environ.keys())
    configured |= _env_file_vars(wt_env_path)
    if proj_env_path != wt_env_path:
        configured |= _env_file_vars(proj_env_path)
    ba_all = _read_marina_json(pid, "build-args.json")            # marina 가 build-arg 로 주입 — host env 불요(코덱스 감사 대비: 오탐 배제)
    if isinstance(ba_all, dict):
        for svc_args in ba_all.values():
            if isinstance(svc_args, dict):
                configured |= {str(k) for k in svc_args.keys()}
    env_var = str(project.get("composeEnvVar") or "")             # marina-lib-compose.sh 가 start 때 --env=$envvar=... 로 항상 주입
    if env_var:
        configured.add(env_var)
    result = [{"name": n, "hint": f"{wt_env_path} 에 {n}= 추가"} for n in required if n not in configured]
    _MISSING_ENV_CACHE[key] = (cache_stamp, result)
    return result

def _migrate_to_xmarina(pid) -> dict:
    """흩어진 레거시 JSON(~/.marina/<id>/{prebuild,links,backing}.json) → x-marina dict.
    prebuild.json→prebuild · links.json(central custom)→links.symlink · backing.json forward→forward ·
    backing.json gatewayRoutes→gateway.routes. build-args.json 은 build.args(서비스)라 x-marina 아님(별도 병합).
    레거시 파일은 보존(비파괴·롤백 가능) — x-marina 가 stored compose 에 없을 때 합쳐 노출하는 용도."""
    xm: dict = {}
    pb = _read_marina_json(pid, "prebuild.json")
    if isinstance(pb, dict):
        pb = {str(k): v for k, v in pb.items() if isinstance(v, str) and v.strip()}
        if pb:
            xm["prebuild"] = pb
    bj = _read_marina_json(pid, "backing.json")
    if isinstance(bj, dict):
        hf = bj.get("hostForward")                                     # legacy hostForward 도 이전 — 런타임이 읽는 걸 migrate 가 떨구면 통합 뷰 채택 시 설정 소실(셀프 리뷰)
        hf_ports = [str(k).strip() for k in (hf if isinstance(hf, (list, tuple)) else []) if str(k).strip().isdigit()]
        if hf_ports:
            xm["hostForward"] = hf_ports                               # forward 로 승격하지 않는다 — 약한 우선순위(legacy<auto) 보존, export→재채택이 라우팅을 못 바꾸게(코덱스 P2)
        fwd = bj.get("forward")
        if isinstance(fwd, dict) and fwd:
            xm["forward"] = {str(k): v for k, v in fwd.items()}        # 포트 키 string(docker x-* 호환)
        gr = bj.get("gatewayRoutes")
        if isinstance(gr, dict) and gr:
            xm["gateway"] = {"routes": gr}
    lj = _read_marina_json(pid, "links.json")
    links = (lj.get("links", lj) if isinstance(lj, dict) else {}) or {}
    sym = [r["glob"] for r in links.values() if isinstance(r, dict) and r.get("glob")]
    if sym:
        xm["links"] = {"symlink": sym, "copy": []}
    return xm

def unified_compose_yaml(root: Path, project: dict) -> str:
    """stored compose + 유효 x-marina(있으면 그것, 없으면 레거시 마이그레이션) + build-args.json(→build.args)
    을 하나의 compose YAML 로 직렬화 = '하나의 정규 설정'(공유용 복사·고급뷰 단일 소스). PyYAML 필요(쓰기 경로)."""
    pid = str(project.get("id", ""))
    cfile = project.get("composeFile", "docker-compose.yml")
    text = (MARINA_HOME / pid / cfile).read_text(encoding="utf-8")
    mc = _mc()
    data = mc._yaml().safe_load(text) or {}
    services = data.get("services") or {}
    ba = _read_marina_json(pid, "build-args.json")               # 레거시 build-args.json → services[svc].build.args 통합
    if isinstance(ba, dict):
        for svc, args in ba.items():
            if svc in services and isinstance(args, dict) and args:
                b = services[svc].get("build")
                b = {"context": b} if isinstance(b, str) else (b if isinstance(b, dict) else {})
                b.setdefault("args", {})
                b["args"].update({str(k): str(v) for k, v in args.items()})
                services[svc]["build"] = b
    xm = mc.parse_xmarina(text) or _migrate_to_xmarina(pid)      # x-marina(SoT) 우선, 없으면 레거시 마이그레이션
    data["services"] = services                                  # 로드한 문서를 in-place 갱신 — networks/volumes/secrets/include 등 top-level 보존
    if xm:
        data["x-marina"] = mc._stringify_keys(xm)               # x-marina 키 string 화(docker x-* 호환)
    return mc._yaml().safe_dump(data, sort_keys=False, allow_unicode=True, default_flow_style=False)

def merge_xmarina_into_yaml(yaml_text: str, xmarina: dict, build_args: dict = None) -> str:
    """services YAML 텍스트 + x-marina dict (+ build_args {svc:{K:V}}) → 하나의 compose YAML.
    top-level 섹션 보존, x-marina 키 string 화. 위저드 검토단계 미리보기용. PyYAML 필요."""
    mc = _mc()
    data = mc._yaml().safe_load(yaml_text or "") or {}
    if not isinstance(data, dict):
        data = {}
    services = data.get("services") or {}
    for svc, args in (build_args or {}).items():        # build-args → services[svc].build.args (위저드 스텝1 입력)
        if svc in services and isinstance(args, dict) and args:
            b = services[svc].get("build")
            b = {"context": b} if isinstance(b, str) else (b if isinstance(b, dict) else {})
            b.setdefault("args", {})
            b["args"].update({str(k): str(v) for k, v in args.items()})
            services[svc]["build"] = b
    data["services"] = services
    if xmarina:
        data["x-marina"] = mc._stringify_keys(xmarina)
    return mc._yaml().safe_dump(data, sort_keys=False, allow_unicode=True, default_flow_style=False)
