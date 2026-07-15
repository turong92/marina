#!/usr/bin/env python3
"""marina-compose.py — compose-kind 실행 헬퍼 (런타임 경로는 stdlib only).

예외: x-marina 파싱/직렬화(parse_xmarina·serialize_xmarina)는 PyYAML 을 쓴다(보편 설치).
런타임 읽기(xmarina_for_stored)는 PyYAML 없거나 파싱 실패해도 {} 로 best-effort —
실행 흐름을 절대 깨지 않는다. 쓰기 경로(import/wizard)에서만 PyYAML 부재가 명시 에러로 드러난다.

워크트리별 격리 docker compose. 포트는 marina 가 정하지도 기록하지도 않는다:
정적 overlay 로 published 를 ephemeral(127.0.0.1::<target>)로 덮어 → Docker 가 빈 호스트포트 자동할당,
marina 는 `docker compose ps` 로 실제 포트를 *그때그때* 읽는다(기록 파일 없음 = stale·secret 잔류 없음).
inter-service 는 컨테이너 DNS(주입 0), marina 는 compose 불투명 실행.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

try:   # profile 후보 변수 판정(런타임 env 미러링용). importlib 로드(테스트)에서도 sibling 해석되게.
    from marina_dockerfile import is_profile_var
    from marina_build_inputs import (
        attach_image_identities,
        build_decision,
        build_input_snapshot,
        load_build_input_key,
        merge_build_baseline,
        read_build_baseline,
        read_build_input_snapshot,
        write_build_input_snapshot,
    )
    from marina_logtext import redact_text
    import marina_prebuild
except ImportError:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from marina_dockerfile import is_profile_var
    from marina_build_inputs import (
        attach_image_identities,
        build_decision,
        build_input_snapshot,
        load_build_input_key,
        merge_build_baseline,
        read_build_baseline,
        read_build_input_snapshot,
        write_build_input_snapshot,
    )
    from marina_logtext import redact_text
    import marina_prebuild


def compose_project_name(project_id: str, session: str) -> str:
    """docker compose -p 값. 소문자 + [a-z0-9_-] 만, 양끝 -/_ 정리. 빈 값이면 'marina'."""
    name = re.sub(r"[^a-z0-9_-]+", "-", f"{project_id}-{session}".lower()).strip("-_")
    return name or "marina"


# ── x-marina 확장 ───────────────────────────────────────────────────────────
# 프로젝트 marina 설정(prebuild·links·forward·gateway)을 compose YAML 의 top-level
# `x-marina` 키에 담는다. docker 는 `x-*` 를 무시 → 유효 compose, marina 만 읽는다.
# 공유 단위 = compose+x-marina 한 블록(팀원 복붙). 파싱은 PyYAML 직접 = docker 비의존
# (붙여넣기 blob 을 docker 없이 검증·왕복).

def _yaml():
    """PyYAML lazy import. 없으면 명확한 에러(x-marina 는 YAML 직렬화 필요)."""
    try:
        import yaml  # noqa: PLC0415 — 선택 의존, 호출 시점 import
        return yaml
    except ImportError:
        raise RuntimeError("x-marina 처리에 PyYAML 필요 — `pip install pyyaml`")


def parse_xmarina(compose_text: str) -> dict:
    """compose YAML 텍스트의 top-level `x-marina` 블록 → dict. 없으면 {}."""
    data = _yaml().safe_load(compose_text or "") or {}
    if not isinstance(data, dict):
        return {}
    xm = data.get("x-marina")
    return xm if isinstance(xm, dict) else {}


def parse_expose_token(val: str):
    """expose 값 파싱. 'gateway:svc'→('gateway',svc), 'origin:svc'→('origin',svc). 그 외/토큰아님→None.
    주: `$` 접두 토큰(${...})은 `docker compose config` 가 보간을 시도해 거부한다(x-marina 값도 보간 대상) → `$` 없는 순수 토큰."""
    m = re.fullmatch(r"(gateway|origin):(.+)", (val or "").strip())
    return (m.group(1), m.group(2).strip()) if m else None


def resolve_expose_env(expose: dict, wt: str, proj: str, gwport: int, services: list, gw_mod, primary: str = "") -> dict:
    """expose 선언 → {consumer:{ENV:value}}. gateway 모드=be 게이트웨이 URL, origin 모드=''(상대).
    services 는 대표 판정용([{service,port,running}]). gw_mod=marina-gateway 모듈(service_domain/_is_primary 재사용).
    primary(명시 x-marina.gateway.primary)가 있으면 그걸 우선, 없으면 gw 자동판정."""
    out = {}
    for consumer, envmap in (expose or {}).items():
        for var, val in (envmap or {}).items():
            tok = parse_expose_token(str(val))
            if not tok:
                continue
            mode, target = tok
            if mode == "origin":
                out.setdefault(consumer, {})[var] = ""
            else:
                is_prim = (target == primary) if primary else gw_mod._is_primary(services, target)
                out.setdefault(consumer, {})[var] = gw_mod.service_domain(wt, proj, target, is_prim, gwport)
    return out


def _gw_module():
    """marina-gateway.py 를 모듈로 로드(service_domain/_is_primary 재사용). 파일명 하이픈이라 import 불가 → importlib."""
    import importlib.util
    p = os.path.join(os.path.dirname(__file__), "marina-gateway.py")
    s = importlib.util.spec_from_file_location("marina_gateway", p)
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


def _gateway_port_for_up() -> int:
    """게이트웨이 포트(expose URL 주입용): MARINA_GATEWAY_PORT env → $MARINA_HOME/gateway/port → 빈 포트 선점.
    up 이 gateway-ensure 보다 먼저 돌므로, 파일이 없으면 여기서 빈 포트를 골라 **선기록**한다 —
    직후 ensure_gateway 가 같은 파일을 재사용해 주입 URL 과 실제 기동 포트가 일치(코덱스 P2).
    미기동 + 파일 포트가 이미 점유(타 프로세스)면 그 값도 못 쓰므로 새로 골라 갱신."""
    v = os.environ.get("MARINA_GATEWAY_PORT")
    if v and v.isdigit():
        return int(v)
    home = os.environ.get("MARINA_HOME") or os.path.expanduser("~/.marina")
    gw_dir = os.path.join(home, "gateway")
    pf = os.path.join(gw_dir, "port")
    import socket

    def _free(p):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", p))
                return True
            except OSError:
                return False

    gw_alive = False                                       # 게이트웨이(caddy)가 살아있으면 파일 포트가 곧 실포트(점유돼 보여도 신뢰)
    try:
        pid = int(open(os.path.join(gw_dir, "caddy.pid"), encoding="utf-8").read().strip())
        os.kill(pid, 0)
        gw_alive = True
    except Exception:
        pass
    try:
        with open(pf, encoding="utf-8") as f:
            p = int(f.read().strip())
        if 0 < p < 65536 and (gw_alive or _free(p)):
            return p
    except Exception:
        pass
    port = next((p for p in range(3902, 3952) if _free(p)), 3902)
    try:
        os.makedirs(gw_dir, exist_ok=True)
        with open(pf, "w", encoding="utf-8") as f:
            f.write(str(port))
    except OSError:
        pass
    return port


def _stringify_keys(obj):
    """x-marina 안 모든 dict 키를 문자열로 — docker compose config 는 x-* 확장의 맵 키가
    string 이 아니면 거부한다('non-string key in x-marina.forward: 6379'). forward 의 포트 키(6379)
    같은 int 키를 string 으로 강제해 stored compose 가 docker-valid 하게 유지."""
    if isinstance(obj, dict):
        return {str(k): _stringify_keys(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_stringify_keys(v) for v in obj]
    return obj


def serialize_xmarina(services: dict, xmarina: dict) -> str:
    """(services, x-marina) → compose YAML 문자열. x-marina 비면 키 생략. x-marina 키는 전부
    문자열로(_stringify_keys) — docker compose config 가 확장 맵의 비-string 키를 거부하기 때문.
    왕복 불변: parse_xmarina(serialize_xmarina(s, x)) == _stringify_keys(x)."""
    doc = {"services": services or {}}
    if xmarina:
        doc["x-marina"] = _stringify_keys(xmarina)
    return _yaml().safe_dump(doc, sort_keys=False, allow_unicode=True, default_flow_style=False)


def _edit_xmarina_block(stored: str, mutate) -> bool:
    """보관 compose 의 x-marina 블록만 파싱 → mutate(xm) 제자리 수정 → 재직렬화. 위쪽 services/volumes
    텍스트(=사용자 주석)는 원본 보존(ruamel 없이 주석 살림). 대시보드의 x-marina 편집(links·gateway) 공용."""
    with open(stored, encoding="utf-8") as f:
        lines = f.read().splitlines(keepends=True)
    xi = next((i for i, l in enumerate(lines) if l.startswith("x-marina:")), None)
    xj = len(lines)
    if xi is not None:
        for i in range(xi + 1, len(lines)):
            l = lines[i]
            if l.strip() and not l[0].isspace() and not l.lstrip().startswith("#"):
                xj = i
                break
        xm = parse_xmarina("".join(lines[xi:xj]))
        head, tail = "".join(lines[:xi]), "".join(lines[xj:])
    else:
        xm = {}
        head, tail = "".join(lines), ""
        if head and not head.endswith("\n"):
            head += "\n"
    mutate(xm)
    new_block = _yaml().safe_dump({"x-marina": _stringify_keys(xm)}, sort_keys=False, allow_unicode=True, default_flow_style=False) if xm else ""
    with open(stored, "w", encoding="utf-8") as f:
        f.write(head + new_block + (tail if not tail.startswith("\n") else tail))
    return True

def set_xmarina_link(stored: str, subrepo: str, glob: str, mode: str = "symlink", remove: bool = False) -> bool:
    """x-marina.links 편집(SoT). 리스트에 글롭 있으면 적용·없으면 안 함(켜짐/꺼짐 별도 상태 없음).
      remove=True → 글롭 빼기(✕; symlink/copy 양쪽서 제거)  ·  그 외 → 글롭 추가(mode 리스트에)"""
    glob = (glob or "").strip()
    if not glob:
        return False
    key = "copy" if mode == "copy" else "symlink"
    sub = subrepo or "."
    def _m(xm):
        links = xm.setdefault("links", {})
        is_global = isinstance(links, dict) and ("symlink" in links or "copy" in links)
        node = links if is_global else links.setdefault(sub, {})
        if remove:
            for kk in ("symlink", "copy"):
                if isinstance(node.get(kk), list):
                    node[kk] = [g for g in node[kk] if g != glob]
                    if not node[kk]:
                        node.pop(kk, None)
            if not is_global and not node:
                links.pop(sub, None)
            if not links:
                xm.pop("links", None)
        else:
            lst = node.setdefault(key, [])
            if glob not in lst:
                lst.append(glob)
    return _edit_xmarina_block(stored, _m)


def set_xmarina_forward(stored: str, port: str, target: str = "host", remove: bool = False) -> bool:
    """x-marina.forward 편집(SoT) — 대시보드 연결 탭에서 호스트 인프라(localhost:<port> → host) 추가/삭제.
      remove=True → 그 포트 항목 제거  ·  그 외 → forward[port]=target(기본 'host'). 서비스↔서비스 포트는 자동(여기 안 건드림).
    forward 변경은 컨테이너 기동 때 세팅되므로 재시작해야 적용된다(호출측이 안내)."""
    port = str(port or "").strip()
    if not port.isdigit():
        return False
    tgt = (target or "host").strip() or "host"

    def _m(xm):
        fwd = xm.get("forward")
        if not isinstance(fwd, dict):
            fwd = xm["forward"] = {}
        if remove:
            fwd.pop(port, None)
            fwd.pop(int(port), None)   # 파서가 정수 키로 뒀을 수도
            if not fwd:
                xm.pop("forward", None)
        else:
            for k in list(fwd.keys()):   # 같은 포트 중복 키(str/int) 정리
                if str(k) == port:
                    fwd.pop(k, None)
            fwd[port] = tgt
    return _edit_xmarina_block(stored, _m)


def set_xmarina_expose(stored: str, consumer: str, var: str, target: str = "", mode: str = "gateway",
                       remove: bool = False) -> bool:
    """x-marina.gateway.expose 편집(SoT) — 연결 탭의 서비스↔서비스 배선.
      expose={consumer:{ENV:'gateway:target'|'origin:target'}} — 타겟 서비스 URL 을 consumer 컨테이너의 env 로 주입.
      remove=True → consumer.ENV 제거(비면 consumer/expose/gateway 도 정리)  ·  그 외 → consumer[ENV]='<mode>:<target>'.
    env 는 컨테이너 기동 때 주입되므로 재시작해야 적용된다(호출측이 안내). mode: gateway=타겟 게이트웨이 URL · origin=''(상대경로)."""
    consumer, var = (consumer or "").strip(), (var or "").strip()
    if not consumer or not var:
        return False
    if not remove:
        target = (target or "").strip()
        mode = "origin" if mode == "origin" else "gateway"
        if not target:
            return False

    def _m(xm):
        gw = xm.get("gateway")
        if not isinstance(gw, dict):
            gw = xm["gateway"] = {}
        exp = gw.get("expose")
        if not isinstance(exp, dict):
            exp = gw["expose"] = {}
        node = exp.get(consumer)
        if not isinstance(node, dict):
            node = exp[consumer] = {}
        if remove:
            node.pop(var, None)
            if not node:
                exp.pop(consumer, None)
            if not exp:
                gw.pop("expose", None)
            if not gw:
                xm.pop("gateway", None)
        else:
            node[var] = f"{mode}:{target}"
    return _edit_xmarina_block(stored, _m)


def xmarina_for_stored(stored: str) -> dict:
    """보관 compose 파일 경로 → x-marina dict. forward·prebuild·gateway 소비처가 이걸로 읽는다.
    best-effort — 어떤 실패든(파일 없음·PyYAML 없음·YAML 파싱 에러·compose 커스텀 태그 !reset/!override
    같은 ConstructorError) {} 로 떨어져 실행 흐름(marina start)을 절대 깨지 않는다. 그래서 의도적으로
    광범위 except: x-marina 미적용은 허용되는 degrade 지만 start 크래시는 안 된다."""
    try:
        with open(stored, encoding="utf-8") as f:
            return parse_xmarina(f.read())
    except Exception:
        return {}


def isolation_breakers(config: dict):
    """워크트리 격리를 깨는 설정 → (errors, warnings). errors 는 reject 대상."""
    errors, warnings = [], []
    services = (config or {}).get("services") or {}
    for n in sorted(services):
        s = services[n] or {}
        if s.get("container_name"):   # 막지 않음 — overlay 가 !reset 으로 제거(워크트리별 자동명명)
            warnings.append(f"service '{n}': container_name 무시 — 워크트리 격리 위해 marina 가 자동 명명.")
        nm = s.get("network_mode")
        if isinstance(nm, str) and nm.startswith("host"):
            errors.append(f"service '{n}': network_mode: host — 포트 forward·격리 무력화. 제거.")
    for kind in ("networks", "volumes"):
        for nm, spec in ((config or {}).get(kind) or {}).items():
            if isinstance(spec, dict) and spec.get("external"):
                warnings.append(f"{kind}.{nm}: external — 워크트리 간 상태 공유 가능(의도면 무시).")
    return errors, warnings


def build_dockerfile_paths(config: dict, skip_external: bool = True) -> dict:
    """build 서비스 → 기대 Dockerfile 절대경로 {svc: dfpath} (존재 여부는 안 봄 — 경로만, 파일 I/O 없음 → 캐시 친화적).
    `docker compose config` 가 build.context 를 절대경로로 해석해 둠.
    skip_external=True 면 .workspace/external(검증·대시보드 시점엔 아직 attach 안 됨) 제외 — 기동(cmd_up)은
    ensure_external_worktrees 후라 skip_external=False 로 외부 Dockerfile 도 확인(코덱스 리뷰 #1)."""
    out = {}
    services = (config or {}).get("services") or {}
    for n in sorted(services):
        b = (services[n] or {}).get("build")
        if not b:
            continue
        if isinstance(b, str):
            ctx, df = b, "Dockerfile"
        else:
            ctx, df = b.get("context", "."), b.get("dockerfile", "Dockerfile")
        if skip_external and ".workspace/external" in str(ctx).replace(os.sep, "/"):
            continue
        out[n] = df if os.path.isabs(df) else os.path.join(ctx, df)
    return out


def missing_dockerfile_services(config: dict, skip_external: bool = True) -> dict:
    """build 서비스 중 Dockerfile 이 실제로 없는 것 → {서비스명: 없는 Dockerfile 절대경로}.
    compose-kind 는 build 서비스에 Dockerfile 필수지만 하나가 없다고 전체를 막진 않는다 —
    검증은 경고로(부분 등록 허용), 기동은 그 서비스만 건너뛴다(나머지는 정상).
    검증(compose_validate)·기동(startable_services)·대시보드(_compose_config_maps)의 단일 출처."""
    return {n: p for n, p in build_dockerfile_paths(config, skip_external).items() if not os.path.exists(p)}


def _depends_on(svc: dict) -> list:
    """서비스 depends_on → 의존 서비스명 리스트 (list 형식과 {svc:{condition}} dict 형식 모두 지원)."""
    d = (svc or {}).get("depends_on")
    if isinstance(d, dict):
        return list(d.keys())
    if isinstance(d, list):
        return list(d)
    return []


def start_group_requested(xm: dict, requested, services) -> tuple:
    """전체 시작(requested 비어있음) + x-marina.startGroup 선언 → 시작 그룹만 기동 대상.
    개별 서비스 지정(requested 있음)은 그대로(자율). 반환 (targets, unknown[선언됐지만 미정의]).
    startGroup 전부 미정의면 ([], unknown) → 호출측이 전체 기동 폴백(경고와 함께)."""
    if requested:
        return list(requested), []
    raw = xm.get("startGroup")
    if not isinstance(raw, (list, tuple)):   # 스칼라(문자열) 선언은 문자 단위로 쪼개지는 함정 — 무시(방어)
        return [], []
    auto = [str(s) for s in raw if isinstance(s, (str, int))]
    if not auto:
        return [], []
    known = [s for s in auto if s in (services or {})]
    return known, [s for s in auto if s not in (services or {})]


def startable_services(config: dict, requested) -> tuple:
    """기동할 서비스 = (요청 또는 전체) − Dockerfile 없는 build 서비스 − 그걸 depends_on 으로 (간접) 의존하는 서비스.
    depends_on 으로 끌려온 degraded 가 `docker compose up` 을 통째로 실패시키지 않게 closure 까지 제외(코덱스 리뷰 #3).
    기동은 external attach 후라 skip_external=False. 반환 (startable[list 정렬], skipped{svc: 사유}). cmd_up·테스트 공유."""
    services = (config or {}).get("services") or {}
    blocked = {n: f"Dockerfile 없음 ({p})"
               for n, p in missing_dockerfile_services(config, skip_external=False).items()}
    changed = True
    while changed:                                          # depends_on closure — degraded 를 (간접) 의존하면 같이 제외
        changed = False
        for n, svc in services.items():
            if n in blocked:
                continue
            for d in _depends_on(svc):
                if d in blocked:
                    blocked[n] = f"의존 서비스 '{d}' 비활성"
                    changed = True
                    break
    req = list(requested) if requested else sorted(services.keys())
    startable = [s for s in req if s not in blocked]
    skipped = {s: blocked[s] for s in req if s in blocked}
    return startable, skipped


def service_dependency_closure(config: dict, requested: list[str]) -> list[str]:
    """Return requested services plus their transitive Compose dependencies."""
    services = (config or {}).get("services") or {}
    seeds = list(requested) if requested else sorted(services)
    seen: set[str] = set()
    closure: list[str] = []

    def visit(name: str) -> None:
        if name in seen:
            return
        seen.add(name)
        closure.append(name)
        service = services.get(name)
        if not isinstance(service, dict):
            return
        for dependency in _depends_on(service):
            if dependency in services:
                visit(dependency)

    for seed in seeds:
        visit(seed)
    return closure


def resolved_start_targets(config: dict, xm: dict, requested: list[str]) -> tuple:
    """Resolve explicit/startGroup services and implicit dependencies."""
    grouped, unknown = start_group_requested(
        xm, requested, config.get("services") or {}
    )
    expanded = service_dependency_closure(config, grouped)
    startable, skipped = startable_services(config, expanded)
    return startable, skipped, unknown


def _port_targets(svc: dict):
    """서비스의 모든 호스트-publish 포트 → [(target, protocol)].
    `docker compose config` 의 services[*].ports[] 엔트리는 전부 호스트로 publish 되는 포트다 —
    고정(3000:80, published 있음)이든 auto(8000, published 없음)든. 내부 전용은 `expose` 로 표현돼
    ports[] 에 없으니 여기서 안 잡힌다(컨테이너 DNS 로만 도달). 범위 target 은 거부(P6)."""
    out = []
    for p in (svc.get("ports") or []):
        if not isinstance(p, dict):
            continue
        tgt = p.get("target")
        if tgt is None:
            continue
        if "-" in str(tgt):
            raise ValueError(f"포트 범위 target={tgt} 는 compose-kind v1 미지원 (단일 포트만).")
        out.append((int(tgt), str(p.get("protocol") or "tcp")))
    return out


def _dockerfile_case_fix(build):
    """build.context 안에서 선언된(또는 기본 'Dockerfile')이 케이스만 달라 데몬이 못 찾을 때 실제 파일명(컨텍스트 상대).
    데몬(리눅스 VM)은 케이스 민감 → listdir 정확 매칭으로 판단(os.path.isfile 은 macOS 케이스무시라 오판).
    이미 정확히 있거나 변형도 없으면 None. 외부 레포 자체 compose(include)의 DockerFile 도 이걸로 자동 보정."""
    if not isinstance(build, dict):
        return None
    ctx = build.get("context")
    if not ctx or not os.path.isdir(ctx):
        return None
    rel = build.get("dockerfile") or "Dockerfile"
    full = os.path.normpath(os.path.join(ctx, rel))
    d, base = os.path.dirname(full), os.path.basename(full)
    try:
        names = os.listdir(d)
    except OSError:
        return None
    if base in names:          # 케이스 민감하게 정확히 존재 → 데몬도 찾음, 손 안 댐
        return None
    want = base.lower()
    for fn in names:
        if fn.lower() == want and os.path.isfile(os.path.join(d, fn)):
            sub = os.path.dirname(rel)
            return (sub + "/" + fn) if sub else fn   # 컨텍스트 상대 경로로 복원
    return None


def _served_ports(svc: dict) -> set:
    """서비스가 여는 TCP 포트(str) 집합 — 호스트 published ports[] + 내부 전용 expose[].
    UDP 는 엮기(socat 가 TCP 만)의 대상이 아니라 제외 — 안 그러면 53/udp 가 잘못된 TCP 사이드카가 됨(코덱스 리뷰 P2)."""
    out = set()
    for port, proto in _port_targets(svc or {}):
        if proto == "tcp":
            out.add(str(port))
    for e in ((svc or {}).get("expose") or []):
        s = str(e)
        if "/" in s and not s.lower().endswith("/tcp"):          # "53/udp" 등 비-TCP 접미사 → 제외 ("8080"·"8080/tcp" 는 TCP)
            continue
        m = re.match(r"^\s*(\d+)", s)
        if m:
            out.add(m.group(1))
    return out


def _forward_for_service(forward: dict, svc: str, own_ports=()):
    """그 서비스의 엮기 사이드카가 받을 [(port, target)]. **그 서비스가 자기 서빙하는 포트(own_ports)** 와 타겟이 자기자신인 포트는 제외 —
    이미 localhost:port 가 자기 컨테이너에 닿고, socat TCP-LISTEN 이 그 포트를 두면 자기 listener 와 충돌하기 때문
    (같은 포트를 다른 서비스가 타겟이어도 마찬가지 — 코덱스 리뷰 P2). 포트 오름차순."""
    own = {str(p) for p in own_ports}
    out = []
    for port in sorted((p for p in forward if str(p).isdigit()), key=int):
        if port in own:                  # 자기가 서빙 → 자기 컨테이너 localhost 가 이미 닿고 socat 충돌
            continue
        target = forward[port]
        if target == svc:
            continue
        out.append((port, target))
    return out


def _bind_script(pairs):
    """[(port, target)] → 엮기 사이드카의 `sh -c` 스크립트. target=host → host.docker.internal(없으면 리눅스
    default gateway 폴백 — network_mode:service 라 extra_hosts 무시), 그 외 → 같은 compose 서비스명(컨테이너 DNS).
    포트별 socat 1개를 백그라운드로 띄우고 wait. $$ = compose 가 리터럴 $ 로(변수확장 회피)."""
    lines = []
    if any(t == "host" for _, t in pairs):
        lines.append('H=host.docker.internal; nslookup "$$H" >/dev/null 2>&1 || '
                     "H=$$(ip route 2>/dev/null | awk '/default/{print $$3; exit}')")
    for port, target in pairs:
        dst = '"$$H"' if target == "host" else target
        lines.append(f'socat TCP-LISTEN:{port},fork,reuseaddr TCP:{dst}:{port} &')
    lines.append("wait")
    return "\n".join(lines)


def _auto_service_forward(config: dict) -> dict:
    """resolved compose config → {port(str): service}. 각 서비스가 여는 포트(호스트 published ports[] + 내부 전용 expose[])를
    그 서비스 DNS 타겟으로 자동 매핑(localhost:8081 → be). marina 스캐폴드/LLM 은 보통 expose 를 쓰므로 expose 도 본다.
    같은 포트 두 서비스면 경고 후 먼저(정렬) 것 사용(SPEC 동일포트 한계). 사람은 host 타겟만 선언."""
    out: dict = {}
    services = (config or {}).get("services") or {}
    for name in sorted(services):
        for p in sorted(_served_ports(services[name] or {}), key=int):
            if p in out and out[p] != name:
                sys.stderr.write(f"warning: 포트 {p} 를 여러 서비스({out[p]}·{name})가 서빙 — 엮기 자동타겟 모호, '{out[p]}' 사용. compose 에서 포트 분리 권장.\n")
                continue
            out[p] = name
    return out


def build_overlay(config: dict, bind_host: str = "127.0.0.1", build_args: dict = None,
                  connectivity: dict = None, expose_env: dict = None) -> str:
    """resolved config → overlay YAML. 워크트리 격리를 위해 *비침투적으로* 덮는다(앱·외부 레포 불변):
    ① published ports → 127.0.0.1::<target> (호스트포트 Docker 자동할당)
    ② container_name → 제거(!reset, 워크트리별 자동명명 — 다중 인스턴스 충돌 방지)
    ③ build dockerfile 케이스 보정(데몬 케이스민감 — DockerFile 등 실제 파일명 명시; include 서비스 포함)
    ④ build args 주입(build_args={svc:{K:V}}; BUILD_ENV 등 — include 서비스에도 머지, app compose 불변)
    ⑤ 엮기(connectivity={forward:{port:target}}): 앱(build) 서비스마다 socat 사이드카 1개로 그 컨테이너의
       localhost:<port> 를 타겟(host=host.docker.internal / 서비스명=컨테이너 DNS)으로 중계. 자기 서빙 포트 제외.
    덮을 게 하나도 없으면 빈 문자열. 포트값·비밀번호는 안 들어감."""
    services = (config or {}).get("services") or {}
    build_args, connectivity, expose_env = build_args or {}, connectivity or {}, expose_env or {}
    out, any_ = ["services:"], False
    for name in sorted(services):
        svc = services[name] or {}
        body = []
        specs = _port_targets(svc)
        if specs:
            entries = ", ".join(
                f'"{bind_host}::{t}"' if proto == "tcp" else f'"{bind_host}::{t}/{proto}"'
                for t, proto in specs
            )
            body.append(f"    ports: !override [{entries}]")
        if svc.get("container_name"):
            body.append("    container_name: !reset null")
        build_block = []                                   # dockerfile 보정 + args 를 한 build: 블록으로
        bcfg = svc.get("build") if isinstance(svc.get("build"), dict) else {}
        df = _dockerfile_case_fix(svc.get("build"))
        margs = build_args.get(name) or {}
        if (df or margs) and bcfg.get("context"):          # scalar `build: ./dir` 병합 시 context 유실 방지 — resolved context 명시
            build_block.append(f"      context: {json.dumps(str(bcfg['context']))}")
        if df:
            build_block.append(f"      dockerfile: {df}")
        if margs:
            build_block.append("      args:")
            for k in sorted(margs):
                build_block.append(f"        {k}: {json.dumps(str(margs[k]))}")
        if build_block:
            body += ["    build:", *build_block]
        # profile 후보 build arg 는 런타임 environment 로도 미러링 — stored 의 하드코딩 env 를
        # overlay 머지에서 덮어 profile 이 런타임에도 적용되게(ai-api 케이스). stored compose 불변.
        prof_env = {k: margs[k] for k in margs if is_profile_var(k)}
        env_pairs = dict(prof_env)                          # profile 후보 env
        for k, v in (expose_env.get(name) or {}).items():   # ⑥ expose 주입(브라우저 fe→be 배선) — profile 보다 우선
            env_pairs[k] = v
        if env_pairs:
            body.append("    environment:")
            for k in sorted(env_pairs):
                body.append(f"      {k}: {json.dumps(str(env_pairs[k]))}")
        if body:
            any_ = True
            out += [f"  {name}:", *body]
    forward = connectivity.get("forward") or {}                  # ⑤ 엮기 — {port: target}. target=host(호스트 redis/db) 또는 같은 compose 서비스명(DNS).
    for fname in sorted(services):                               # 앱(build) 서비스마다 사이드카 1개가 그 컨테이너의 모든 localhost 의존성 포트를 한 번에 받음
        if not (services[fname] or {}).get("build"):             # image-only(redis 자체 등)는 사이드카 불요 — DNS 로 바로 닿음
            continue
        pairs = _forward_for_service(forward, fname, _served_ports(services[fname] or {}))   # self(자기서빙 포트) 제외
        if not pairs:
            continue
        out += [f"  {fname}-bind:",                              # 앱 0수정·언어무관: 앱이 localhost:port 그대로 쓰고 socat 이 타겟으로 중계
                "    image: alpine/socat",
                f'    network_mode: "service:{fname}"',          # 그 컨테이너의 localhost 를 가로챔
                '    entrypoint: ["sh", "-c"]',
                f"    command: [{json.dumps(_bind_script(pairs))}]",
                "    restart: unless-stopped"]
        any_ = True
    return ("\n".join(out) + "\n") if any_ else ""


def _parse_build_args(items):
    """'svc=KEY=VAL' 목록 → {svc: {KEY: VAL}}. 형식 안 맞으면 스킵(svc·KEY 필수)."""
    out = {}
    for it in (items or []):
        svc, sep, rest = it.partition("=")
        if not svc or not sep or "=" not in rest:
            continue
        k, _, v = rest.partition("=")
        if k:
            out.setdefault(svc, {})[k] = v
    return out


def _legacy_host_forward(conn: dict) -> dict:
    """legacy top-level hostForward(["6379"]) → {"6379":"host"}. README 가 안내해 온 포맷이라 계속 읽되
    (조용한 무시 금지), 자동 서비스타겟보다 **약하다** — redis 등을 나중에 compose 서비스로 옮긴 뒤 남은
    스테일 hostForward 가 auto 라우트를 덮어 엮기를 깨지 않게 (코덱스/셀프 리뷰)."""
    hf = conn.get("hostForward")
    out: dict = {}
    for port in (hf if isinstance(hf, (list, tuple)) else []):
        p = str(port).strip()
        if p.isdigit():
            out[p] = "host"
    return out


def _normalize_forward(conn: dict) -> dict:
    """backing.json/x-marina 의 **명시** forward 선언 → {port(str): target(str)}. target="host"(host.docker.internal)
    또는 같은 compose 서비스명(DNS). 소스: top-level forward({port:{target:svc|host}} 또는 {port:"svc"|"host"}).
    legacy hostForward 는 _legacy_host_forward 소관(우선순위가 다름 — auto 보다 약함)."""
    fwd: dict = {}
    for port, spec in (conn.get("forward") or {}).items():
        p = str(port).strip()
        if not p.isdigit():
            continue
        tgt = spec.get("target") if isinstance(spec, dict) else spec
        tgt = str(tgt or "").strip()
        if tgt:
            fwd[p] = tgt
    # 옛 services.<svc>.endpoints(삭제된 모달 저장분)·서비스별 hostForward 는 무시한다 — 서비스타겟은 _auto_service_forward 가,
    # host 타겟은 top-level 로 선언한다. 전역 승격은 서비스별 스코프가 깨져 auto 라우트를 잘못 덮는다(코덱스 리뷰 P1). 발견 시 경고는 cmd_up.
    return fwd


def _forward_summary(forward: dict) -> str:
    """{port:target} → '엮기: localhost:6379→host · localhost:8081→be' (빈 dict 는 ''). start 성공 출력용 — 적용 상태 가시화."""
    if not forward:
        return ""
    return "엮기: " + " · ".join(f"localhost:{p}→{forward[p]}" for p in sorted(forward, key=int))


def _applied_forward(services: dict, names, forward: dict) -> dict:
    """실제 사이드카가 받는 (port→target) 합집합 — names 중 build 서비스만, 자기서빙 포트 제외
    (_forward_for_service 와 동일 규칙). 선언만 있고 어느 컨테이너에도 안 붙는 포워드는 요약에 안 나온다
    — 요약이 '적용 상태'를 말하게 (셀프 리뷰: 선언 맵 출력은 image-only 구성에서 거짓 성공 표시)."""
    applied: dict = {}
    for n in names:
        svc = services.get(n) or {}
        if not svc.get("build"):
            continue
        for p, t in _forward_for_service(forward, n, _served_ports(svc)):
            applied[p] = t
    return applied


def parse_ps_ports(ps_text: str):
    """`docker compose ps --format json` (JSON 배열 or 줄별 JSON) → {service: [hostports]}.
    Publishers[].PublishedPort 중 0 아닌 것만, int 정규화·dedup·정렬."""
    s = (ps_text or "").strip()
    if not s:
        return {}
    rows = []
    try:
        v = json.loads(s)
        rows = v if isinstance(v, list) else [v]
    except json.JSONDecodeError:
        rows = [json.loads(ln) for ln in s.splitlines() if ln.strip()]
    out = {}
    for r in rows:
        svc = r.get("Service") or r.get("Name") or "?"
        for p in (r.get("Publishers") or []):
            if not isinstance(p, dict) or not p.get("PublishedPort"):
                continue
            try:
                hp = int(p["PublishedPort"])           # 버전에 따라 int/str → 정규화
            except (TypeError, ValueError):
                continue
            out.setdefault(svc, set()).add(hp)          # 컨테이너 여러 개여도 dedup
    return {svc: sorted(ports) for svc, ports in out.items()}


def _json_rows(value: str) -> list[dict]:
    text = (value or "").strip()
    if not text:
        return []
    try:
        parsed = json.loads(text)
        rows = parsed if isinstance(parsed, list) else [parsed]
    except json.JSONDecodeError:
        rows = [json.loads(line) for line in text.splitlines() if line.strip()]
    return [row for row in rows if isinstance(row, dict)]


def up_argv(stored, overlay, project_dir, project_name, services, build=False):
    a = ["docker", "compose", "-f", stored]
    if overlay and os.path.exists(overlay) and os.path.getsize(overlay) > 0:   # 빈 overlay 는 -f 안 함(docker 실패 방지)
        a += ["-f", overlay]
    a += ["--project-directory", project_dir, "-p", project_name, "up", "-d"]
    if build:
        a.append("--build")
    a.append("--remove-orphans")
    return a + list(services)


def watchable_services(config: dict, requested: list[str]) -> list[str]:
    """Compose develop.watch가 선언된 요청 서비스만 결정적으로 반환한다."""
    services = config.get("services") if isinstance(config.get("services"), dict) else {}
    names = requested or list(services)
    out = []
    for name in names:
        service = services.get(name)
        develop = service.get("develop") if isinstance(service, dict) else None
        watch = develop.get("watch") if isinstance(develop, dict) else None
        if isinstance(watch, list) and watch:
            out.append(name)
    return sorted(set(out))


WATCH_ACTION_MIN = {
    "sync": (2, 22, 0),
    "rebuild": (2, 22, 0),
    "sync+restart": (2, 23, 0),
    "restart": (2, 32, 0),
    "sync+exec": (2, 32, 0),
}


def compose_version_tuple(value: str) -> tuple[int, int, int]:
    numbers = [int(part) for part in re.findall(r"\d+", value or "")[:3]]
    return tuple((numbers + [0, 0, 0])[:3])


def watch_version_errors(config: dict, selected: list[str], version: str) -> list[str]:
    current = compose_version_tuple(version)
    services = config.get("services") if isinstance(config.get("services"), dict) else {}
    errors = []
    for name in selected:
        service = services.get(name)
        develop = service.get("develop") if isinstance(service, dict) else None
        rules = develop.get("watch") if isinstance(develop, dict) else None
        for rule in rules if isinstance(rules, list) else []:
            if not isinstance(rule, dict):
                continue
            action = str(rule.get("action") or "")
            required = WATCH_ACTION_MIN.get(action)
            if action == "sync+exec" and "exec" in rule:
                required = max(required or (0, 0, 0), (2, 32, 2))
            if required and current < required:
                minimum = ".".join(str(part) for part in required)
                errors.append(
                    f"service '{name}' Watch action '{action}' requires Compose "
                    f"{minimum}+; current {version}"
                )
    return errors


def watch_argv(stored, overlay, project_dir, project_name, services):
    """기존 up과 같은 Compose model로 여러 service를 단일 watcher로 감시한다."""
    argv = ["docker", "compose", "-f", stored]
    if overlay and os.path.exists(overlay) and os.path.getsize(overlay) > 0:
        argv += ["-f", overlay]
    return argv + ["--project-directory", project_dir, "-p", project_name,
                   "watch", "--no-up", *services]


def label_argv(project_name, verb_args):
    """파일 없이 -p 라벨로 동작하는 lifecycle 명령 (down/stop/restart/ps/logs)."""
    return ["docker", "compose", "-p", project_name] + list(verb_args)


def docker_config_json(stored, project_dir, project_name, env) -> dict:
    """stored compose 완전 해석(상대→절대, ${VAR} 보간). env 가 보간에 쓰임(P1). 출력은 저장 안 함."""
    out = subprocess.check_output(
        ["docker", "compose", "-f", stored, "--project-directory", project_dir,
         "-p", project_name, "config", "--format", "json"],
        text=True, env=env)
    return json.loads(out)


def _overlay_path(session_dir):
    return os.path.join(session_dir, "marina-overlay.yml")


def _env_with(overrides):
    env = dict(os.environ)
    for kv in overrides:
        k, _, v = kv.partition("=")
        if k:
            env[k] = v
    return env


def _show_ports(project_name):
    try:
        out = subprocess.check_output(label_argv(project_name, ["ps", "--format", "json"]), text=True)
    except subprocess.CalledProcessError:
        return
    ports = parse_ps_ports(out)
    if ports:
        print("ports (docker 자동할당):")
        for svc in sorted(ports):
            print("  " + svc + "=" + ",".join(str(p) for p in ports[svc]))


BUILD_INPUT_CAPTURE_TIMEOUT_SEC = 0.5
UNKNOWN_BUILD_INPUTS = {"version": 1, "status": "unknown"}


def _publish_build_input_handoff(payload):
    handoff = os.environ.get("MARINA_BUILD_INPUT_SNAPSHOT", "").strip()
    if handoff:
        try:
            write_build_input_snapshot(Path(handoff), payload)
        except OSError:
            pass


def _write_build_input_handoff(path, project_dir, config, requested, build_args, ignored_paths=None):
    try:
        home = Path(os.environ.get("MARINA_HOME") or (Path.home() / ".marina"))
        payload = build_input_snapshot(
            Path(project_dir), config, requested, build_args, load_build_input_key(home),
            ignored_paths=ignored_paths,
        )
    except Exception:
        payload = {"version": 1, "status": "unknown"}
    try:
        write_build_input_snapshot(Path(path), payload)
    except OSError:
        pass


def _capture_build_inputs(a, config, requested, build_args):
    session_dir = Path(a.session_dir)
    private_path = ""
    fd = None
    try:
        session_dir.mkdir(parents=True, exist_ok=True)
        fd, private_path = tempfile.mkstemp(prefix=".build-input-capture.", dir=str(session_dir))
        os.fchmod(fd, 0o600)
        os.close(fd)
        fd = None
        os.unlink(private_path)
    except OSError:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if private_path:
            try:
                os.unlink(private_path)
            except OSError:
                pass
        payload = dict(UNKNOWN_BUILD_INPUTS)
        _publish_build_input_handoff(payload)
        return payload

    payload = dict(UNKNOWN_BUILD_INPUTS)
    try:
        try:
            pid = os.fork()
        except (AttributeError, OSError):
            pid = None
        if pid == 0:
            try:
                _write_build_input_handoff(
                    private_path, a.project_dir, config, requested, build_args,
                    ignored_paths=[session_dir],
                )
            finally:
                os._exit(0)
        if pid is not None:
            deadline = time.monotonic() + BUILD_INPUT_CAPTURE_TIMEOUT_SEC
            reaped = False
            status = 1
            try:
                while time.monotonic() < deadline:
                    try:
                        waited, status = os.waitpid(pid, os.WNOHANG)
                    except ChildProcessError:
                        reaped = True
                        status = 0 if Path(private_path).is_file() else 1
                        break
                    if waited == pid:
                        reaped = True
                        break
                    time.sleep(min(0.01, max(0.0, deadline - time.monotonic())))
            finally:
                if not reaped:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except OSError:
                        pass
                    try:
                        waited, status = os.waitpid(pid, os.WNOHANG)
                        reaped = waited == pid
                    except (ChildProcessError, OSError):
                        pass
            if reaped and status == 0:
                payload = read_build_input_snapshot(Path(private_path))

        _publish_build_input_handoff(payload)
        return payload
    finally:
        try:
            os.unlink(private_path)
        except FileNotFoundError:
            pass


def _build_reason_text(reason):
    service = " ".join(str(reason.get("service") or "").split())
    label = " ".join(str(reason.get("label") or "build 입력").split())
    change = " ".join(str(reason.get("change") or "changed").split())
    subject = " ".join(value for value in (service, label) if value)
    return redact_text(f"{subject} {change}".strip())


def _inspect_baseline_images(baseline, services):
    baseline_services = baseline.get("services") if isinstance(baseline, dict) else {}
    if not isinstance(baseline_services, dict):
        return {}
    identities = {}
    for service in services:
        inputs = baseline_services.get(service)
        image = inputs.get("image") if isinstance(inputs, dict) else None
        ref = image.get("ref") if isinstance(image, dict) else ""
        if not isinstance(ref, str) or not ref:
            continue
        try:
            image_id = subprocess.check_output(
                ["docker", "image", "inspect", "--format={{.Id}}", ref],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip().splitlines()[0]
        except (FileNotFoundError, IndexError, subprocess.CalledProcessError):
            image_id = "missing"
        identities[service] = {"ref": ref, "id": image_id or "missing"}
    return identities


def _compose_image_identities(stored, overlay, project_dir, project_name, services, env):
    base = ["docker", "compose", "-f", stored]
    if overlay and os.path.exists(overlay) and os.path.getsize(overlay) > 0:
        base += ["-f", overlay]
    base += ["--project-directory", project_dir, "-p", project_name]
    identities = {}
    for service in services:
        try:
            output = subprocess.check_output(
                base + ["images", "--format", "json", service],
                text=True,
                stderr=subprocess.DEVNULL,
                env=env,
            ).strip()
            rows = _json_rows(output)
        except (FileNotFoundError, json.JSONDecodeError, subprocess.CalledProcessError):
            continue
        row = next((item for item in rows if isinstance(item, dict) and item.get("ID")), None)
        if not row:
            continue
        repository = str(row.get("Repository") or "")
        tag = str(row.get("Tag") or "")
        if not repository or repository == "<none>":
            continue
        ref = repository if not tag or tag == "<none>" else f"{repository}:{tag}"
        identities[service] = {"ref": ref, "id": str(row["ID"])}
    return identities


@contextmanager
def _build_service_locks(session_dir, services):
    lock_dir = Path(session_dir) / ".build-locks"
    lock_dir.mkdir(parents=True, exist_ok=True)
    handles = []
    try:
        for service in sorted(set(services)):
            key = hashlib.sha256(service.encode("utf-8")).hexdigest()[:20]
            path = lock_dir / f"{key}.lock"
            fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
            os.chmod(path, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            handles.append(fd)
        yield
    finally:
        for fd in reversed(handles):
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


def _run_up_locked(a, env, name, config, xm, overlay_text, overlay_conn, build_args):
    grouped, _ = start_group_requested(
        xm, list(a.service or []), config.get("services") or {}
    )
    requested, skipped, unknown_auto = resolved_start_targets(
        config, xm, list(a.service or [])
    )
    if unknown_auto:
        sys.stderr.write(f"warning: x-marina.startGroup 의 미정의 서비스 무시: {', '.join(unknown_auto)}\n")
    if grouped and not a.service:
        print("startGroup: 시작 그룹만 기동 — " + ", ".join(requested) + " (그 외는 대시보드/CLI 에서 개별 시작)")
    for service, why in skipped.items():
        sys.stderr.write(f"skip: 서비스 '{service}' 건너뜀 — {why}. 나머지는 기동합니다.\n")
    if not requested:
        sys.stderr.write("error: 기동 가능한 서비스가 없습니다 — build 서비스의 Dockerfile 이 모두 없습니다.\n")
        return 2

    svc_cfg = config.get("services") or {}
    build_services = [
        service for service in requested
        if isinstance((svc_cfg.get(service) or {}).get("build"), dict)
    ]
    with _build_service_locks(a.session_dir, build_services):
        os.makedirs(a.session_dir, exist_ok=True)
        overlay = _overlay_path(a.session_dir)
        if overlay_text.strip():
            with open(overlay, "w", encoding="utf-8") as handle:
                handle.write(overlay_text)
        else:
            try:
                os.remove(overlay)
            except OSError:
                pass
            overlay = None

        forward = overlay_conn.get("forward") or {}
        sidecars = [
            f"{service}-bind"
            for service in requested
            if (svc_cfg.get(service) or {}).get("build")
            and _forward_for_service(
                forward, service, _served_ports(svc_cfg.get(service) or {})
            )
        ]
        current_inputs = _capture_build_inputs(a, config, requested, build_args)
        baseline_path = Path(a.session_dir) / "build-baseline.json"
        baseline = read_build_baseline(baseline_path)
        decision_inputs = attach_image_identities(
            current_inputs,
            _inspect_baseline_images(baseline, current_inputs.get("services") or {}),
        )
        effective_build, build_reasons = build_decision(
            decision_inputs,
            baseline,
            explicit=bool(a.build),
        )
        if current_inputs.get("status") != "ok":
            if a.build:
                sys.stderr.write("warning: build 입력을 확인하지 못했습니다; Rebuild는 계속하지만 baseline은 갱신하지 않습니다.\n")
            else:
                sys.stderr.write("warning: build 입력을 확인하지 못해 기존 이미지로 시작합니다; 문제가 있으면 Rebuild를 실행하세요.\n")
        elif effective_build and not a.build:
            for reason in build_reasons:
                print(f"stale image: {_build_reason_text(reason)}; Start에 --build 자동 적용")
        argv = up_argv(
            a.stored, overlay, a.project_dir, name, requested + sidecars,
            build=effective_build,
        )
        print("compose: " + " ".join(argv))
        rc = subprocess.call(argv, env=env)
        if rc == 0:
            if effective_build and current_inputs.get("status") == "ok":
                try:
                    identities = _compose_image_identities(
                        a.stored, overlay, a.project_dir, name,
                        current_inputs.get("services") or {}, env,
                    )
                    merge_build_baseline(
                        baseline_path,
                        attach_image_identities(current_inputs, identities),
                    )
                    missing_images = sorted(set(current_inputs.get("services") or {}) - set(identities))
                    if missing_images:
                        sys.stderr.write(
                            "warning: build 이미지 ID 확인 실패; 다음 Start에서 다시 build합니다: "
                            + ", ".join(missing_images) + "\n"
                        )
                except OSError as exc:
                    sys.stderr.write(f"warning: build baseline 저장 실패; 다음 Start에서 다시 확인합니다: {exc}\n")
            summary = _forward_summary(_applied_forward(svc_cfg, requested, forward))
            if summary:
                print(summary)
            _show_ports(name)
        return rc


def cmd_up(a):
    env = _env_with(a.env)                                          # P1: env first
    name = compose_project_name(a.project_id, a.session)
    try:
        config = docker_config_json(a.stored, a.project_dir, name, env)  # 비밀번호 in-memory only, 저장 안 함
    except FileNotFoundError:
        sys.stderr.write("error: docker 미설치 — compose-kind 는 Docker 필요.\n")
        return 2
    except subprocess.CalledProcessError:                          # 잘못된 YAML/include 미해석 → traceback 대신 깔끔한 에러(코덱스 감사 #3)
        sys.stderr.write("error: docker compose config 실패 — compose/include YAML 을 확인하세요 (위 docker 메시지 참고).\n")
        return 2
    except json.JSONDecodeError as e:
        sys.stderr.write(f"error: compose config 출력 파싱 실패: {e}\n")
        return 2
    errors, warnings = isolation_breakers(config)                   # P5
    for w in warnings:
        sys.stderr.write(f"warning: {w}\n")
    if errors:
        for e in errors:
            sys.stderr.write(f"error: {e}\n")
        return 2
    conn: dict = {}                                                 # 엮기 선언(backing.json): host 타겟 등 명시 forward
    conn_path = getattr(a, "connectivity", None)
    if conn_path and os.path.exists(conn_path):
        try:
            conn = json.load(open(conn_path, encoding="utf-8"))
        except (ValueError, OSError) as e:
            sys.stderr.write(f"warning: connectivity({conn_path}) 읽기 실패 — 엮기 선언 건너뜀: {e}\n")
            conn = {}
    if any((_sc or {}).get("endpoints") for _sc in (conn.get("services") or {}).values()):   # 옛 service-redirect 잔재 — 무시되니 안내(코덱스 리뷰: silent 회피)
        sys.stderr.write("warning: backing.json 의 옛 service-redirect endpoints 는 이제 무시됩니다(엮기로 일원화). "
                         "host 타겟(redis/db 등)은 x-marina.forward 로 선언하세요 — 서비스↔서비스는 자동.\n")
    if any((_sc or {}).get("hostForward") for _sc in (conn.get("services") or {}).values()):   # 서비스별 hostForward — 조용한 무시 금지
        sys.stderr.write("warning: services.*.hostForward 는 지원되지 않습니다 — top-level forward 또는 x-marina.forward 로 선언하세요.\n")
    xm = xmarina_for_stored(a.stored)                                # x-marina 가 forward/prebuild/gateway 의 새 SoT — backing.json(레거시) 위에 우선
    try:
        forward = {**_legacy_host_forward(conn), **_legacy_host_forward(xm),
                   **_auto_service_forward(config),
                   **_normalize_forward(conn), **_normalize_forward(xm)}   # legacy hostForward < 자동 서비스타겟 < 명시 forward(backing.json < x-marina). _port_targets 포트범위 ValueError 가능 → try 안(코덱스 리뷰 P3)
        _xm_all = {**_legacy_host_forward(xm), **_normalize_forward(xm)}
        _conn_all = {**_legacy_host_forward(conn), **_normalize_forward(conn)}
        if any(forward.get(p) == t and _xm_all.get(p) != t for p, t in _conn_all.items()):   # backing.json 이 실효 소스일 때만 — 이전 완료 사용자에게 영구 반복 안 함(셀프 리뷰)
            sys.stderr.write("notice: 엮기 선언을 backing.json 에서 읽었습니다 — x-marina.forward 로 compose 파일 하나에 모으는 걸 권장합니다.\n")
        overlay_conn = {"forward": forward}
        gw_gateway = xm.get("gateway") or {}                          # ⑥ expose(fe→be 브라우저 배선) → environment 주입
        exp_env = {}
        if gw_gateway.get("expose"):
            gw_mod = _gw_module()
            gwport = _gateway_port_for_up()
            # 대표 판정 후보 = published(ports 선언) 서비스만 — 게이트웨이 라우팅 대상과 동일 집합.
            # 전 서비스를 후보로 넣으면 미퍼블리시 서비스(db 등)가 대표로 뽑혀 주입 URL 이
            # 라우팅 없는 도메인을 가리킬 수 있다(코덱스 P2). 순서 무관: _effective_primary 폴백이 이름 정렬.
            snap_services = [{"service": k, "port": "1", "running": True}
                             for k, sv in (config.get("services") or {}).items() if (sv or {}).get("ports")]
            exp_env = resolve_expose_env(gw_gateway.get("expose") or {}, a.session, a.project_id, gwport,
                                         snap_services, gw_mod, primary=str(gw_gateway.get("primary") or ""))
        build_args = _parse_build_args(getattr(a, "build_arg", []))
        overlay_text = build_overlay(config, build_args=build_args,
                                     connectivity=overlay_conn, expose_env=exp_env)  # P2/P3/P4 + build args + 엮기 + expose
    except ValueError as e:
        sys.stderr.write(f"error: {e}\n")
        return 2
    return _run_up_locked(
        a, env, name, config, xm, overlay_text, overlay_conn, build_args,
    )


def cmd_prebuild_run(a):
    env = _env_with(a.env)
    name = compose_project_name(a.project_id, a.session)
    try:
        config = docker_config_json(a.stored, a.project_dir, name, env)
    except FileNotFoundError:
        sys.stderr.write("error: docker 미설치 — prebuild 대상을 해석할 수 없습니다.\n")
        return 2
    except subprocess.CalledProcessError:
        sys.stderr.write("error: docker compose config 실패 — prebuild 대상을 해석할 수 없습니다.\n")
        return 2
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"error: compose config 출력 파싱 실패: {exc}\n")
        return 2

    xm = xmarina_for_stored(a.stored)
    targets, _, unknown = resolved_start_targets(config, xm, list(a.service or []))
    if unknown:
        sys.stderr.write(
            "warning: x-marina.startGroup 의 미정의 서비스 무시: "
            + ", ".join(unknown)
            + "\n"
        )
    version_errors = watch_version_errors(config, targets, a.compose_version)
    if version_errors:
        for error in version_errors:
            sys.stderr.write(f"error: {error}\n")
        return 2
    raw = xm.get("prebuild")
    if not raw and a.legacy_prebuild and os.path.isfile(a.legacy_prebuild):
        try:
            with open(a.legacy_prebuild, encoding="utf-8") as handle:
                raw = json.load(handle)
        except (OSError, ValueError) as exc:
            sys.stderr.write(f"error: legacy prebuild 설정 읽기 실패: {exc}\n")
            return 2
    try:
        jobs = marina_prebuild.plan_prebuild_jobs(
            raw, config, targets, Path(a.project_dir)
        )
    except marina_prebuild.PrebuildConfigError as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 2
    return marina_prebuild.run_prebuild_jobs(jobs, Path(a.project_dir), env)


def cmd_watchable(a):
    env = _env_with(a.env)
    name = compose_project_name(a.project_id, a.session)
    try:
        config = docker_config_json(a.stored, a.project_dir, name, env)
    except (FileNotFoundError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"error: Compose Watch 서비스 판정 실패: {exc}\n")
        return 2
    for service in watchable_services(config, list(a.service or [])):
        print(service)
    return 0


def cmd_watch(a):
    env = _env_with(a.env)
    name = compose_project_name(a.project_id, a.session)
    argv = watch_argv(a.stored, _overlay_path(a.session_dir), a.project_dir, name, a.service)
    print("compose watch: " + " ".join(argv), flush=True)
    try:
        os.execvpe(argv[0], argv, env)
    except FileNotFoundError:
        sys.stderr.write("error: docker 미설치 — Compose Watch를 시작할 수 없습니다.\n")
        return 2


def cmd_down(a):  # 전체 teardown (stop --all). --volumes 요청 시 compose named volume 도 제거
    name = compose_project_name(a.project_id, a.session)
    verb = ["down", "--remove-orphans"] + (["--volumes"] if getattr(a, "volumes", False) else [])
    return subprocess.call(label_argv(name, verb))  # P7/P8


def cmd_stop(a):  # 선택 서비스만 정지 — 컨테이너 유지
    name = compose_project_name(a.project_id, a.session)
    return subprocess.call(label_argv(name, ["stop", *a.service]))          # P7


def cmd_restart(a):  # 선택 서비스만 재시작 (quick bounce, config 재해석 안 함)
    name = compose_project_name(a.project_id, a.session)
    return subprocess.call(label_argv(name, ["restart", *a.service]))       # P7


def cmd_status(a):
    name = compose_project_name(a.project_id, a.session)
    try:
        out = subprocess.check_output(label_argv(name, ["ps", "--format", "json"]), text=True)
    except subprocess.CalledProcessError:
        print("(not running)")
        return 0
    for svc, ports in sorted(parse_ps_ports(out).items()):
        print(svc + "=" + ",".join(str(p) for p in ports))
    if a.ports_only:
        return 0
    return subprocess.call(label_argv(name, ["ps"]))               # 사람용 표


def cmd_logs(a):
    name = compose_project_name(a.project_id, a.session)
    verb = ["logs"] + ([] if a.no_follow else ["-f"]) + list(a.service)
    return subprocess.call(label_argv(name, verb))                 # P7


# ---- test hooks (stdin) ----

def cmd_name(a):
    print(compose_project_name(a.project_id, a.session))
    return 0


def cmd_overlay(a):  # stdin = config json → overlay text
    try:
        print(build_overlay(json.load(sys.stdin)), end="")
    except ValueError as e:
        sys.stderr.write(f"error: {e}\n")
        return 2
    return 0


def cmd_psports(a):  # stdin = ps json → {service:[ports]}
    print(json.dumps(parse_ps_ports(sys.stdin.read())))
    return 0


def cmd_xmarina(a):  # 보관 compose 의 x-marina(또는 그 안 --key) 를 JSON 으로 — bash 소비처(prebuild 등)용
    xm = xmarina_for_stored(a.stored)
    out = xm.get(a.key) if a.key else xm
    print(json.dumps(out if out is not None else {}))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="marina-compose")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def name_args(p):
        p.add_argument("--project-id", required=True)
        p.add_argument("--session", required=True)

    p = sub.add_parser("name"); name_args(p); p.set_defaults(fn=cmd_name)
    p = sub.add_parser("overlay"); p.set_defaults(fn=cmd_overlay)
    p = sub.add_parser("psports"); p.set_defaults(fn=cmd_psports)
    p = sub.add_parser("xmarina"); p.add_argument("--stored", required=True); p.add_argument("--key"); p.set_defaults(fn=cmd_xmarina)
    p = sub.add_parser("up"); name_args(p); p.add_argument("--stored", required=True); p.add_argument("--project-dir", required=True); p.add_argument("--session-dir", required=True); p.add_argument("--service", action="append", default=[]); p.add_argument("--env", action="append", default=[]); p.add_argument("--build-arg", action="append", default=[], dest="build_arg"); p.add_argument("--connectivity"); p.add_argument("--build", action="store_true"); p.set_defaults(fn=cmd_up)
    p = sub.add_parser("prebuild-run"); name_args(p); p.add_argument("--stored", required=True); p.add_argument("--project-dir", required=True); p.add_argument("--service", action="append", default=[]); p.add_argument("--env", action="append", default=[]); p.add_argument("--legacy-prebuild"); p.add_argument("--compose-version", required=True); p.set_defaults(fn=cmd_prebuild_run)
    p = sub.add_parser("watchable"); name_args(p); p.add_argument("--stored", required=True); p.add_argument("--project-dir", required=True); p.add_argument("--service", action="append", default=[]); p.add_argument("--env", action="append", default=[]); p.set_defaults(fn=cmd_watchable)
    p = sub.add_parser("watch"); name_args(p); p.add_argument("--stored", required=True); p.add_argument("--project-dir", required=True); p.add_argument("--session-dir", required=True); p.add_argument("--service", action="append", required=True); p.add_argument("--env", action="append", default=[]); p.set_defaults(fn=cmd_watch)
    p = sub.add_parser("down"); name_args(p); p.add_argument("--volumes", action="store_true"); p.set_defaults(fn=cmd_down)
    p = sub.add_parser("stop"); name_args(p); p.add_argument("--service", action="append", default=[]); p.set_defaults(fn=cmd_stop)
    p = sub.add_parser("restart"); name_args(p); p.add_argument("--service", action="append", default=[]); p.set_defaults(fn=cmd_restart)
    p = sub.add_parser("status"); name_args(p); p.add_argument("--ports-only", action="store_true"); p.set_defaults(fn=cmd_status)
    p = sub.add_parser("logs"); name_args(p); p.add_argument("--service", action="append", default=[]); p.add_argument("--no-follow", action="store_true"); p.set_defaults(fn=cmd_logs)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
