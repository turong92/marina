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
    return have[0].get("service") if have else ""

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
                sub = f"{sub}-{hashlib.sha1(f'{wid_raw}|{pid_raw}|{svc_raw}'.encode()).hexdigest()[:6]}"
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
            block += [f"    reverse_proxy 127.0.0.1:{hostport}", "}", ""]
            lines += block
    return "\n".join(lines).rstrip() + "\n"


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
    args = ap.parse_args(argv)
    if args.cmd == "gen":
        print(build_caddyfile(json.load(sys.stdin), args.port), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
