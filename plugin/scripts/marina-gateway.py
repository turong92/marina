#!/usr/bin/env python3
"""marina 게이트웨이 — 라이브 스냅샷(워크트리×서비스×호스트포트) → Caddyfile 생성 + diff + caddy reload + 라이프사이클.
순수 생성부(build_caddyfile)는 부수효과 0 — 단위테스트 가능. 호스트 브라우저가 <wt>[-<svc>].<proj>.localhost 로 진입."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ADMIN = "localhost:2021"   # marina 전용 admin(caddy 기본 2019 회피) — 다른 caddy 인스턴스 config 안 건드림(코덱스 P2)
WEB_NAMES = ("web", "fe", "frontend", "app", "ui")   # 대표 web 후보(우선순위 순)


def _domain_label(s: str) -> str:
    """DNS 라벨로 안전화 — 소문자, [a-z0-9-] 외 → '-', 중복/양끝 '-' 정리."""
    out = re.sub(r"[^a-z0-9-]+", "-", str(s).lower()).strip("-")
    out = re.sub(r"-{2,}", "-", out)
    return out or "x"


def origin_for(sub: str, port: int) -> str:
    """<sub>.localhost 의 브라우저 origin. :80 은 브라우저가 Origin 헤더에서 생략하므로 함께 생략 —
    CORS 는 문자열 일치라 :80 을 붙이면 credentialed 요청이 깨진다(코덱스 P2)."""
    return f"http://{sub}.localhost" + ("" if int(port) == 80 else f":{port}")


def _cors_headers_204(fe_origin: str) -> list:
    """preflight 응답 헤더 + 204 (handle 블록 내부). credentialed(특정 origin),
    Allow-Headers 는 요청 헤더 echo(Authorization 등 커스텀 범용). caddy v2 문법."""
    return [
        f'        header Access-Control-Allow-Origin "{fe_origin}"',
        "        header Access-Control-Allow-Credentials true",
        '        header Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"',
        '        header Access-Control-Allow-Headers "{http.request.header.Access-Control-Request-Headers}"',
        "        header Access-Control-Max-Age 600",
        "        respond 204",
    ]


def _cors_preflight_lines(fe_origin: str, tag: str = "", origin_exact: str = "") -> list:
    """be 서브도메인 preflight 처리 — 허용 origin 의 진짜 preflight(OPTIONS + 그 Origin +
    Access-Control-Request-Method 존재)만 caddy 가 204 자체응답. 그 외 OPTIONS(앱의 정당한
    엔드포인트·비허용 origin)는 be 로 통과(코덱스 P2). tag=origin 별 매처 이름 분리."""
    m = f"@cors_pre{tag}"
    return [f"    {m} {{",
            "        method OPTIONS",
            f'        header Origin "{origin_exact or fe_origin}"',
            "        header Access-Control-Request-Method *",
            "    }",
            f"    handle {m} {{"] + _cors_headers_204(fe_origin) + ["    }"]


def _cors_origins(wid: str, pid: str, prim: str, svc: dict, port: int) -> list:
    """expose 도메인 모드 타겟의 CORS 허용 origin 목록 — corsConsumers(consumer 서비스명들) 각각의
    도메인(대표=bare, 그 외=<wt>-<consumer>)을 origin 으로. 레거시 스냅샷(cors:true 만)은 대표 origin 폴백.
    비대표 consumer(admin 등)의 Origin 도 통과해야 하므로 대표 고정이 아니라 consumer 기준(코덱스 P2)."""
    consumers = list((svc or {}).get("corsConsumers") or [])
    if not consumers and (svc or {}).get("cors"):
        consumers = [prim]                                  # 레거시 bool — 대표가 consumer 라고 가정
    out = []
    for c in consumers:
        sub = f"{wid}.{pid}" if (c or "") == prim else f"{wid}-{_domain_label(c)}.{pid}"
        o = origin_for(sub, port)
        if o not in out:
            out.append(o)
    return out


def service_domain(wt: str, proj: str, svc: str, is_primary: bool, port: int) -> str:
    """이 워크트리 서비스의 게이트웨이 URL. 대표(primary)=<wt>.<proj>.localhost, 그 외=<wt>-<svc>.<proj>.localhost.
    도메인 스킴 SoT — build_caddyfile 과 expose resolve 가 라벨 규칙을 공유(DRY). :80 은 생략(origin 문자열 일치)."""
    w, p, s = _domain_label(wt), _domain_label(proj), _domain_label(svc)
    sub = f"{w}.{p}" if is_primary else f"{w}-{s}.{p}"
    return origin_for(sub, port)


def _effective_primary(services: list, explicit: str = "") -> str:
    """이 워크트리의 대표 도메인 서비스명 — x-marina.gateway.primary(명시) 우선, 없으면 WEB_NAMES 중 첫 매칭,
    그것도 없으면 포트 보유 첫 서비스. (포트 있고 running 인 것 중에서만)"""
    have = [s for s in (services or []) if str((s or {}).get("port") or "").strip() and (s or {}).get("running")]
    if explicit and any((s.get("service") or "") == explicit for s in have):
        return explicit
    for w in WEB_NAMES:
        for s in have:
            if (s.get("service") or "") == w:
                return w
    # 최후 폴백은 이름 정렬로 결정적 — 호출측(라이브 스냅샷 vs cmd_up 합성 리스트)의 순서 차이로
    # 대표가 갈리면 expose 주입 URL 이 라우팅 없는 도메인을 가리킨다(코덱스 P2).
    return min((s.get("service") or "" for s in have), default="")

def _is_primary(services: list, svc_name: str) -> bool:
    return _effective_primary(services) == svc_name


def build_caddyfile(snapshot: list, port: int = 80) -> str:
    """스냅샷 → Caddyfile. 워크트리×(포트 보유 서비스)마다 서브도메인 site 블록.
    대표 web → <wt>.<proj>.localhost, 그 외 → <wt>-<svc>.<proj>.localhost → reverse_proxy 127.0.0.1:<hostport>.
    서비스가 routes(경로 prefix)를 선언하면 대표 도메인에 그 경로를 해당 서비스로 path 라우팅 —
    호스트 브라우저가 상대주소로 be 를 부를 때(fe baseURL='') `<wt>.<proj>.localhost/v1/*`→be (limit#1 해소).
    선언 없으면 경로 가정 안 함(범용). 로컬 전용이라 loopback 바인드(127.0.0.1 ::1, 코덱스 P1). admin API 무중단 reload, auto_https off."""
    lines = ["{", f"    admin {ADMIN}", "    auto_https off", "}", ""]
    used = set()
    for wt in (snapshot or []):
        wid_raw = (wt or {}).get("id") or ""
        pid_raw = (wt or {}).get("projectId") or ""
        wid = _domain_label(wid_raw)
        pid = _domain_label(pid_raw)
        svcs = (wt or {}).get("services") or []
        prim = _effective_primary(svcs, (wt or {}).get("primary") or "")   # 대표: x-marina.gateway.primary 명시 우선
        for s in svcs:
            hostport = str((s or {}).get("port") or "").strip()
            if not hostport.isdigit() or not (s or {}).get("running"):
                continue                                    # 미퍼블리시·미실행(stop) → 라우트 없음(죽은 컨테이너로 안 보냄, 코덱스 P2)
            svc_raw = (s or {}).get("service") or ""
            name = _domain_label(svc_raw)
            is_primary = (svc_raw == prim)
            sub = f"{wid}.{pid}" if is_primary else f"{wid}-{name}.{pid}"
            if sub in used:                                 # sanitize 충돌(feat_x vs feat-x 등) → 원본 해시로 유니크화. 한 워크트리가 전체 config reject 막지 않게(코덱스 P2)
                hashed = f"{sub}-{hashlib.sha1(f'{wid_raw}|{pid_raw}|{svc_raw}'.encode()).hexdigest()[:6]}"
                # expose(service_domain)는 해시 전 라벨로 URL 을 만들므로 이 서비스에 expose 를 걸면 불일치(코덱스 P3) — 이름 분리 권장
                sys.stderr.write(f"gateway: 도메인 라벨 충돌 {sub} → {hashed} (expose 주입 URL 과 불일치 가능 — 서비스/워크트리 이름 분리 권장)\n")
                sub = hashed
            used.add(sub)
            block = [f"http://{sub}.localhost:{port} {{",
                     "    bind 127.0.0.1 ::1"]              # 로컬 전용 — LAN 노출 방지(코덱스 P1)
            if is_primary:                                  # 대표 도메인에 형제 서비스 선언 routes(브라우저→be path) 부착. handle=catch-all reverse_proxy 보다 먼저 매칭
                for sib in svcs:
                    sp = str((sib or {}).get("port") or "").strip()
                    if sib is s or not sp.isdigit() or not (sib or {}).get("running"):
                        continue
                    for rp in ((sib or {}).get("routes") or []):
                        rc = "/" + str(rp).strip().strip("/")
                        if rc != "/":
                            block += [f"    handle {rc}/* {{", f"        reverse_proxy 127.0.0.1:{sp}", "    }"]
            origins = _cors_origins(wid, pid, prim, s, port)
            if origins:                                     # expose 도메인 모드 타겟 → 게이트웨이가 CORS 전담(consumer origin 별 exact-match 분기, 코덱스 P2)
                # 허용 origin 요청만 Origin 제거+ACAO — 그 외 Origin 은 손대지 않고 통과시켜 be 의
                # Origin 기반 거부(CSRF 방어)가 그대로 동작하게(코덱스 P2: 무조건 strip 은 우회가 됨).
                for i, o in enumerate(origins):
                    block += _cors_preflight_lines(o, tag=str(i), origin_exact=o)
                for i, o in enumerate(origins):
                    block += [f'    @cors_from{i} header Origin "{o}"',
                              f"    handle @cors_from{i} {{",
                              f"        reverse_proxy 127.0.0.1:{hostport} {{",
                              "            header_up -Origin",                                        # be(예: Spring Security)가 Origin 보고 'Invalid CORS request' 403 내는 것 방지 — 이 분기(허용 origin)는 게이트웨이가 CORS 전담
                              f'            header_down Access-Control-Allow-Origin "{o}"',           # be 응답 ACAO replace(중복 방지)
                              "            header_down Access-Control-Allow-Credentials true",
                              "        }", "    }"]
                block += ["    handle {", f"        reverse_proxy 127.0.0.1:{hostport}", "    }", "}", ""]   # 그 외 Origin/무Origin → 원형 통과(CORS 헤더 없음)
            else:
                block += [f"    reverse_proxy 127.0.0.1:{hostport}", "}", ""]
            lines += block
    return "\n".join(lines).rstrip() + "\n"


def summarize_gateway(snapshot: list, port: int = 80) -> list:
    """스냅샷 → 유효 라우팅/CORS 요약(관측용). [{domain, service, hostport, cors_origin|None, routes}].
    build_caddyfile 과 같은 순회(대표=bare, cors 는 대표 origin 허용) — 블랙박스 방지(marina gateway config)."""
    out = []
    used = set()
    for wt in (snapshot or []):
        wid = _domain_label((wt or {}).get("id") or "")
        pid = _domain_label((wt or {}).get("projectId") or "")
        svcs = (wt or {}).get("services") or []
        prim = _effective_primary(svcs, (wt or {}).get("primary") or "")
        for s in svcs:
            hostport = str((s or {}).get("port") or "").strip()
            if not hostport.isdigit() or not (s or {}).get("running"):
                continue
            name = _domain_label((s or {}).get("service") or "")
            is_primary = ((s or {}).get("service") or "") == prim
            sub = f"{wid}.{pid}" if is_primary else f"{wid}-{name}.{pid}"
            if sub in used:
                sub = f"{sub}-{hashlib.sha1(f'{wid}|{pid}|{name}'.encode()).hexdigest()[:6]}"
            used.add(sub)
            origins = _cors_origins(wid, pid, prim, s, port)
            out.append({"domain": f"{sub}.localhost:{port}", "service": (s or {}).get("service"),
                        "hostport": hostport, "cors_origin": origins[0] if origins else None,
                        "cors_origins": origins,
                        "routes": list((s or {}).get("routes") or [])})
    return out


def write_config(text: str, state_path: str) -> None:
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    with open(state_path, "w", encoding="utf-8") as f:
        f.write(text)


def config_changed(text: str, state_path: str) -> bool:
    """이전에 쓴 config 와 다른가 — 같으면 False(reload 억제)."""
    try:
        return open(state_path, encoding="utf-8").read() != text
    except OSError:
        return True


def caddy_bin():
    # 데몬(launchd) 최소 PATH 엔 homebrew 등이 없어 which 가 놓친다 → 흔한 설치 위치도 폴백(docker 처럼).
    b = shutil.which("caddy")
    if b:
        return b
    for c in (os.path.expanduser("~/.local/bin/caddy"), "/opt/homebrew/bin/caddy", "/usr/local/bin/caddy"):
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def reload_caddy(config_path: str) -> bool:
    """실행 중 caddy 에 새 config 적용(admin API, 무중단). caddy 없거나 reload 실패면 False."""
    cb = caddy_bin()
    if not cb:
        return False
    try:
        subprocess.run([cb, "reload", "--config", config_path, "--adapter", "caddyfile"],
                       check=True, capture_output=True, text=True, timeout=15)
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False


def apply(snapshot: list, port: int, config_path: str, applied_path: str = None) -> bool:
    """스냅샷 → desired config. config_path 는 항상 최신(caddy start 가 읽음). reload 성공한 것만 applied_path 에 기록 —
    reload 실패(예: caddy admin 아직 미준비) 시 applied 미갱신 → 다음 폴링이 재시도. 반환=이번에 reload 성공했는지(코덱스 P2)."""
    if applied_path is None:
        applied_path = config_path + ".applied"
    cfg = build_caddyfile(snapshot, port)
    write_config(cfg, config_path)                  # caddy start 가 읽는 파일은 항상 최신 desired
    if not config_changed(cfg, applied_path):       # 이미 성공 적용된 것과 같으면 reload 불요
        return False
    if reload_caddy(config_path):
        write_config(cfg, applied_path)             # 성공한 것만 applied 로 마킹
        return True
    return False                                    # reload 실패 → applied 미갱신 → 다음 폴링 재시도


def main(argv=None):
    ap = argparse.ArgumentParser(prog="marina-gateway")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")                 # stdin=snapshot json → stdout Caddyfile (테스트/디버그)
    g.add_argument("--port", type=int, default=80)
    c = sub.add_parser("config")              # stdin=snapshot json → stdout 요약 JSON (라우팅+CORS, 관측)
    c.add_argument("--port", type=int, default=80)
    args = ap.parse_args(argv)
    if args.cmd == "gen":
        print(build_caddyfile(json.load(sys.stdin), args.port), end="")
    elif args.cmd == "config":
        print(json.dumps(summarize_gateway(json.load(sys.stdin), args.port), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
