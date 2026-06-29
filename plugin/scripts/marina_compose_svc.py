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

from marina_state import MARINA_HOME, _SUBREPO_MAP_CACHE, _mc
from marina_dockerfile import _detect_injections, _prebuild_suggest, detect_profile_var, is_profile_var
from marina_paths import log_run_payload, service_log, session_id

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
                ["docker", "compose", "-f", str(f), "--project-directory", str(project_dir),
                 "config", "--format", "json"],
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
        out.append({
            "service": svc,
            "port": str(min(pubs)) if pubs else None,
            "running": health is not None,
            "health": health,
            "trackedPid": None,
            "trackedAlive": False,
            "listenerPids": [],
            "rssMb": None,
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
            ["docker", "compose", "-p", project_name, "ps", "--all", "--format", "json"],
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

def _compose_config_maps(root: Path, project: dict) -> tuple[dict, dict]:
    """보관 compose 를 `docker compose config` 로 한 번 해석 → (서비스→서브레포 라벨 맵, degraded 맵{svc: 없는 Dockerfile 경로}).
    config 결과(submap·build Dockerfile 경로)는 보관 compose mtime 으로 캐시(폴링마다 docker 안 돌림).
    degraded(파일 존재)는 매 poll 재판정 — Dockerfile 추가/삭제를 즉시 반영(코덱스 리뷰 #2). config 실패(미attach 등) → 직전 캐시/빈."""
    try:
        sp = MARINA_HOME / str(project["id"]) / project.get("composeFile", "docker-compose.yml")
        mtime = sp.stat().st_mtime
    except (OSError, KeyError):
        return {}, {}
    key = str(sp)
    hit = _SUBREPO_MAP_CACHE.get(key)
    if hit and hit[0] == mtime and hit[1]:
        submap, build_paths = hit[1], hit[2]
    else:
        submap, build_paths = {}, {}
        try:
            out = subprocess.check_output(
                ["docker", "compose", "-f", str(sp), "--project-directory", str(root),
                 "config", "--format", "json"],
                text=True, stderr=subprocess.DEVNULL, timeout=8)
            config = json.loads(out)
            for sname, svc in (config.get("services") or {}).items():
                b = (svc or {}).get("build")
                ctx = b.get("context") if isinstance(b, dict) else (b if isinstance(b, str) else None)
                submap[sname] = _subrepo_label_from_context(ctx, root)
            build_paths = _mc().build_dockerfile_paths(config)   # 경로만(존재 여부 X) → 캐시 가능
        except Exception:
            if not hit:
                return {}, {}
            submap, build_paths = hit[1], hit[2]                 # config 실패 → 직전 캐시 유지
        if submap:
            _SUBREPO_MAP_CACHE[key] = (mtime, submap, build_paths)
    degraded = {svc: p for svc, p in build_paths.items() if not os.path.exists(p)}   # 매 poll 재판정(Dockerfile 추가/삭제 즉시 반영)
    return submap, degraded

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


def compose_resolved_view(root: Path, project: dict) -> dict:
    """읽기전용 구성 뷰 — `docker compose config` 로 해석한 서비스별 구성: 빌드 컨텍스트·Dockerfile(내용 포함)·
    포트·env 키(값은 비밀 우려로 숨김)·command·출처(직접/ include). config 실패 → {ok:False, error}."""
    try:
        sp = MARINA_HOME / str(project["id"]) / project.get("composeFile", "docker-compose.yml")
    except KeyError:
        return {"ok": False, "error": "project id 없음"}
    if not sp.exists():
        return {"ok": False, "error": f"보관 compose 없음: {sp}"}
    try:   # stdout/stderr 분리 — docker 경고(version obsolete 등)가 JSON 에 섞이면 안 됨
        proc = subprocess.run(
            ["docker", "compose", "-f", str(sp), "--project-directory", str(root),
             "config", "--format", "json"],
            capture_output=True, text=True, timeout=12)
    except FileNotFoundError:
        return {"ok": False, "error": "docker 미설치"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "docker compose config 시간 초과"}
    if proc.returncode != 0:
        return {"ok": False, "error": ((proc.stderr or proc.stdout or "").strip()[:800] or "docker compose config 실패")}
    try:
        cfg = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"ok": False, "error": "config json 파싱 실패"}
    direct = set(_compose_defined_services(project))   # 보관 compose 직접 정의 — 나머지는 include 출처
    try:   # marina 가 주입할 build args(레지스트리=각자 로컬) — ⓘ 모달에서 편집
        ba_all = json.loads((MARINA_HOME / str(project["id"]) / "build-args.json").read_text(encoding="utf-8"))
    except Exception:
        ba_all = {}
    try:   # pre-build 명령(서브레포별, B) — x-marina.prebuild(보관 compose=SoT, 실행되는 것) 우선,
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
            "prebuild": (pb_all.get(sub_label, "") if sub_label else ""),
            "prebuildSuggest": (_prebuild_suggest(pb_dir) if (pb_dir and pb_dir.is_dir()) else ""),
            **_service_profile(_inj["args"], _mba, _stored_ba),
        })
    return {"ok": True, "services": services}

def _compose_services(root: Path, project: dict) -> list:
    """compose-kind 워크트리 서비스 = docker compose ps 라이브 + 정의됐지만 미실행 서비스(보관 compose)도 표시.
    중지 서비스도 행으로 보여 ▶ 시작 가능. log/logRuns 는 네이티브 헬퍼 재사용 → 로그 뷰어 그대로. /api/sessions 절대 500 금지."""
    try:
        name = _mc().compose_project_name(project.get("id", ""), session_id(root))
        live_rows = compose_ps(root, name)
        live_names = {(r.get("Service") or r.get("Name")) for r in live_rows
                      if isinstance(r, dict) and (r.get("Service") or r.get("Name"))}
        submap, degraded = _compose_config_maps(root, project)  # 서비스→서브레포(빌드 컨텍스트) + Dockerfile 없는 서비스(비활성). include 해석분 포함.
        defined = set(_compose_defined_services(project)) | set(submap)   # 직접 정의 + include 해석분(정지 상태도 표시)
        stub_rows = [{"Service": s, "State": "stopped"}        # 미실행 정의 서비스 → OFF 행(▶)
                     for s in sorted(defined) if s not in live_names]
        svcs = build_compose_services([*live_rows, *stub_rows])
        ba_all = _read_marina_json(project.get("id", ""), "build-args.json")   # 명시 설정된 profile(글랜스 칩용)
        if not isinstance(ba_all, dict):
            ba_all = {}
        for s in svcs:
            s["subrepo"] = submap.get(s["service"], "")
            s["degraded"] = s["service"] in degraded   # Dockerfile 없음 → 기동 시 건너뜀(대시보드 '비활성' 배지)
            s["log"] = str(service_log(root, s["service"]))
            s["logRuns"] = log_run_payload(root, s["service"])
            _svc_ba = ba_all.get(s["service"]) if isinstance(ba_all.get(s["service"]), dict) else {}
            s["profile"] = _profile_value(_svc_ba)
        return svcs
    except Exception:
        return []

def _read_marina_json(pid, name):
    try:
        return json.loads((MARINA_HOME / str(pid) / name).read_text(encoding="utf-8"))
    except Exception:
        return None

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
    xm = mc.parse_xmarina(text) or _migrate_to_xmarina(pid)      # stored x-marina 우선, 없으면 레거시 합침
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
