# SP2 — Caddy 게이트웨이 (호스트 브라우저 진입, 동적 반영) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** marina 가 Caddy 를 호스트 프로세스로 관리해, 호스트 브라우저가 `<워크트리>.<프로젝트>.localhost` 도메인으로 각 워크트리의 compose 서비스에 접근하게 한다. 워크트리 추가/삭제/정지·서비스 start/stop·호스트포트 변경을 **빠짐없이·즉각** 반영한다.

**Architecture:** 새 모듈 `marina-gateway.py` 가 (라이브 스냅샷 → Caddyfile 텍스트) 순수 생성 + diff + `caddy reload`(admin API) + caddy 라이프사이클을 담당. `marina-control.py` 에 **백그라운드 refresher 스레드**(주기 폴링: 스냅샷→diff→변하면 reload, 헤드리스에서도 빠짐없음) + **이벤트 훅**(start/stop/restart_service 에서 즉시 refresh). 라우팅=서비스별 서브도메인(경로 가정 X·범용). caddy 프로세스는 `marina-dashboard.sh` supervisor 패턴(launchd/systemd/nohup) 재사용; :80 은 시스템 데몬(root, 1회 권한 설치).

**Tech Stack:** Python 3 stdlib only (`marina-gateway.py`, `marina-control.py` threading), Caddy 2.x(호스트 바이너리, admin API `localhost:2019`), `docker compose ps`(`parse_ps_ports`), bash 테스트(`importlib` + 실 caddy/docker). 실행: `bash plugin/tests/<name>.sh`. **codex 활용**: 데몬 통합 글루(훅 배선)는 `codex exec` 위임 가능 + `codex review`; 순수 생성/라이프사이클/실 e2e 는 직접 TDD.

**입력 design:** `docs/superpowers/specs/2026-06-25-connectivity-finalization-design.md` (SP2 절 — 동적 반영 강화본).

**전제(Explore 맵, file:line):** 라이브 스냅샷=`marina-control.py` `session_payload(root)`(1840)·`discover_roots()`(500)·`build_compose_services`(1335, `Publishers[].PublishedPort`). 워크트리 id=`session_id(root)`(522), 프로젝트=`project_for(root)`(162)/`project_label`(421). 이벤트 지점=`start_service`(2101)·`stop_service`(1934)·`restart_service`(2128)·start_all/stop_all. 핸들러 dispatch=`do_GET`(2481)/`do_POST`(2762), `send_json`(2463). 프로세스 supervisor=`marina-dashboard.sh` `supervisor()`(127)·plist(89)·systemd(137)·nohup(158), launcher=`marina-resolve.sh` `marina_emit_launcher`(42).

---

## File Structure

| 파일 | 책임 | 태스크 |
|---|---|---|
| `plugin/scripts/marina-gateway.py` | **신규** 게이트웨이 코어 — 스냅샷→Caddyfile 생성(순수)·서브도메인/라우팅·diff·caddy reload·caddy 라이프사이클·CLI 훅 | T1·T2 |
| `plugin/tests/test-gateway-config.sh` | **신규** 생성/서브도메인/diff 단위(importlib + stdin) | T1 |
| `plugin/scripts/marina-control.py` | refresher 스레드 + 이벤트 훅(start/stop/restart) + `/api/gateway-status` | T3 |
| `plugin/scripts/marina-gateway-control.sh` | **신규** caddy 호스트 프로세스 기동·정지·감시(supervisor 재사용), :80 시스템 데몬 설치 | T2·T4 |
| `plugin/tests/test-gateway-e2e.sh` | **신규** 실 caddy 라우팅 + 동적(add/remove/restart/diff) | T5 |
| `plugin/scripts/marina.sh`·`marina-web/` | `marina status`/대시보드에 게이트웨이 URL 표시 | T6 |
| `README.md` | 게이트웨이 문서 | T6 |

데이터 흐름: `discover_roots`→`session_payload`×N = 스냅샷 → `build_caddyfile(snapshot, port)` → diff vs 이전 → 변하면 `caddy reload`(admin). refresher 스레드(주기)+이벤트 훅(start/stop/restart) 둘 다 이 흐름 호출.

---

## Task 1: `marina-gateway.py` — Caddyfile 생성 (순수) + 서브도메인 + diff

스냅샷(워크트리×서비스×라이브포트)을 Caddyfile 텍스트로. 순수 함수 → 단위테스트.

**Files:** Create `plugin/scripts/marina-gateway.py`, `plugin/tests/test-gateway-config.sh`

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-gateway-config.sh`:

```bash
#!/usr/bin/env bash
# 게이트웨이 config 생성: 스냅샷 → Caddyfile. 서비스별 서브도메인, 대표 web 은 bare, diff.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"

python3 - "$GW" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("gw", sys.argv[1]); gw=importlib.util.module_from_spec(spec); spec.loader.exec_module(gw)

# 스냅샷: 워크트리 2개, 각 web+api. 라이브 호스트포트.
snap=[
  {"id":"main","projectId":"shop","services":[
      {"service":"web","port":"55001","running":True},
      {"service":"api","port":"55002","running":True}]},
  {"id":"feat-x","projectId":"shop","services":[
      {"service":"web","port":"55003","running":True},
      {"service":"db","port":"","running":True}]},   # 포트 없음(미퍼블리시) → 라우트 X
]
cfg=gw.build_caddyfile(snap, port=80)
# 대표 web → bare 도메인, 그 외 → <id>-<svc>
assert "http://main.shop.localhost:80 {" in cfg, cfg
assert "reverse_proxy 127.0.0.1:55001" in cfg, cfg
assert "http://main-api.shop.localhost:80 {" in cfg and "127.0.0.1:55002" in cfg, cfg
assert "http://feat-x.shop.localhost:80 {" in cfg and "127.0.0.1:55003" in cfg, cfg
assert "db" not in cfg, "포트 없는 서비스는 라우트 없음"
# admin API + auto_https off (localhost)
assert "admin localhost:2019" in cfg and "auto_https off" in cfg, cfg
# 빈 스냅샷 → 사이트 0 (전역 블록만)
empty=gw.build_caddyfile([], port=80)
assert "localhost:80 {" not in empty and "admin localhost:2019" in empty, empty
# 도메인 sanitize — 대문자/언더스코어/슬래시 → 소문자·하이픈
assert gw._domain_label("Feat_Branch/2")=="feat-branch-2", gw._domain_label("Feat_Branch/2")
# 대표 web 선택: web/fe/frontend 우선, 없으면 첫 포트보유 서비스
assert gw._is_primary([{"service":"api","port":"1"},{"service":"web","port":"2"}], "web") is True
assert gw._is_primary([{"service":"api","port":"1"},{"service":"worker","port":"2"}], "api") is True   # web 없음 → 첫(api)
assert gw._is_primary([{"service":"api","port":"1"},{"service":"worker","port":"2"}], "worker") is False
# diff: 같은 config 면 False, 다르면 True (reload 억제용)
import tempfile, os
d=tempfile.mkdtemp(); sp=os.path.join(d,"state")
assert gw.config_changed(cfg, sp) is True      # 최초
gw.write_config(cfg, sp)
assert gw.config_changed(cfg, sp) is False     # 동일 → 변화 없음
assert gw.config_changed(empty, sp) is True    # 달라짐
print("ok gateway-config")
PY
echo "PASS test-gateway-config"
```

- [ ] **Step 2: 실행 → 실패** — Run: `bash plugin/tests/test-gateway-config.sh`. Expected: FAIL (`No such file` / `module 'gw' has no attribute 'build_caddyfile'`).

- [ ] **Step 3: `marina-gateway.py` 작성** — Create `plugin/scripts/marina-gateway.py`:

```python
#!/usr/bin/env python3
"""marina 게이트웨이 — 라이브 스냅샷(워크트리×서비스×호스트포트) → Caddyfile 생성 + diff + caddy reload + 라이프사이클.
순수 생성부(build_caddyfile)는 부수효과 0 — 단위테스트 가능. 호스트 브라우저가 <wt>[-<svc>].<proj>.localhost 로 진입."""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request

ADMIN = "localhost:2019"
WEB_NAMES = ("web", "fe", "frontend", "app", "ui")   # 대표 web 후보(우선순위 순)


def _domain_label(s: str) -> str:
    """DNS 라벨로 안전화 — 소문자, [a-z0-9-] 외 → '-', 중복/양끝 '-' 정리."""
    out = re.sub(r"[^a-z0-9-]+", "-", str(s).lower()).strip("-")
    out = re.sub(r"-{2,}", "-", out)
    return out or "x"


def _is_primary(services: list, svc_name: str) -> bool:
    """svc_name 이 이 워크트리의 대표 web 인가 — WEB_NAMES 중 첫 매칭, 없으면 포트 보유 첫 서비스."""
    have = [s for s in services if str((s or {}).get("port") or "").strip()]
    for w in WEB_NAMES:
        for s in have:
            if (s.get("service") or "") == w:
                return (svc_name == w)
    return bool(have) and (have[0].get("service") == svc_name)


def build_caddyfile(snapshot: list, port: int = 80) -> str:
    """스냅샷 → Caddyfile. 워크트리×(포트 보유 서비스)마다 서브도메인 site 블록.
    대표 web → <wt>.<proj>.localhost, 그 외 → <wt>-<svc>.<proj>.localhost → reverse_proxy 127.0.0.1:<hostport>.
    경로 가정 안 함(범용). admin API 로 무중단 reload, auto_https off(localhost 는 TLS 불요)."""
    lines = ["{", f"    admin {ADMIN}", "    auto_https off", "}", ""]
    for wt in (snapshot or []):
        wid = _domain_label((wt or {}).get("id") or "")
        pid = _domain_label((wt or {}).get("projectId") or "")
        svcs = (wt or {}).get("services") or []
        for s in svcs:
            hostport = str((s or {}).get("port") or "").strip()
            if not hostport.isdigit():
                continue                                    # 미퍼블리시/미실행 → 라우트 없음
            name = _domain_label((s or {}).get("service") or "")
            sub = f"{wid}.{pid}" if _is_primary(svcs, (s or {}).get("service") or "") else f"{wid}-{name}.{pid}"
            lines += [f"http://{sub}.localhost:{port} {{",
                      f"    reverse_proxy 127.0.0.1:{hostport}",
                      "}", ""]
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
    return shutil.which("caddy")


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


def apply(snapshot: list, port: int, state_path: str) -> bool:
    """스냅샷 → config → 변했으면 write+reload. 반환=reload 했는지(diff-reload)."""
    cfg = build_caddyfile(snapshot, port)
    if not config_changed(cfg, state_path):
        return False
    write_config(cfg, state_path)
    return reload_caddy(state_path)


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
```

- [ ] **Step 4: 실행 → 통과** — Run: `bash plugin/tests/test-gateway-config.sh` → `PASS test-gateway-config`. 전체 스위트도 FAILED 없음.

- [ ] **Step 5: 커밋**
```bash
git add plugin/scripts/marina-gateway.py plugin/tests/test-gateway-config.sh
git commit -m "feat(gateway): Caddyfile 생성 코어 — 스냅샷→서비스별 서브도메인 + diff + reload (순수, 단위테스트)"
```

---

## Task 2: caddy 라이프사이클 + 제어 스크립트

caddy(PATH) 탐색·기동·정지·감시. 비권한 포트(테스트/개발)로 먼저 — :80 시스템데몬은 T4.

**Files:** Create `plugin/scripts/marina-gateway-control.sh`; extend `marina-gateway.py`(status/start/stop CLI 훅)

- [ ] **Step 1: 제어 스크립트 작성** — `marina-gateway-control.sh` (supervisor 패턴은 `marina-dashboard.sh` 재사용):

```bash
#!/usr/bin/env bash
# marina 게이트웨이 caddy 호스트 프로세스 제어. nohup 기본(개발), :80 은 시스템 데몬(T4).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MARINA_HOME="${MARINA_HOME:-$HOME/.marina}"
GW_DIR="$MARINA_HOME/gateway"; CFG="$GW_DIR/Caddyfile"; PID="$GW_DIR/caddy.pid"; LOG="$GW_DIR/caddy.log"
PORT="${MARINA_GATEWAY_PORT:-80}"
mkdir -p "$GW_DIR"

caddy_bin() { command -v caddy || true; }

ensure_config() { [[ -f "$CFG" ]] || printf '{\n    admin localhost:2019\n    auto_https off\n}\n' > "$CFG"; }

gw_running() { [[ -f "$PID" ]] && kill -0 "$(cat "$PID")" 2>/dev/null; }

case "${1:-}" in
  start)
    cb="$(caddy_bin)"; [[ -n "$cb" ]] || { echo "caddy 미설치 — 'brew install caddy'(mac) 또는 'apt install caddy'(linux) 후 다시. 게이트웨이 없이 나머지 marina 는 정상." >&2; exit 3; }
    gw_running && { echo "이미 실행 중 (pid $(cat "$PID"))"; exit 0; }
    ensure_config
    MARINA_GATEWAY_PORT="$PORT" nohup "$cb" run --config "$CFG" --adapter caddyfile >>"$LOG" 2>&1 &
    echo $! > "$PID"; echo "게이트웨이 기동 (pid $!, :$PORT, admin :2019)" ;;
  stop)
    gw_running && { kill "$(cat "$PID")" 2>/dev/null || true; rm -f "$PID"; echo "게이트웨이 정지"; } || echo "실행 중 아님" ;;
  status)
    gw_running && echo "running pid=$(cat "$PID") port=$PORT" || echo "stopped" ;;
  *) echo "usage: marina-gateway-control.sh {start|stop|status}" >&2; exit 1 ;;
esac
```

- [ ] **Step 2: caddy 가용 시 기동/리로드 스모크** — Run:
```bash
command -v caddy >/dev/null && { MARINA_HOME="$(mktemp -d)" MARINA_GATEWAY_PORT=8899 bash plugin/scripts/marina-gateway-control.sh start && sleep 1 && curl -s -o /dev/null -w "admin=%{http_code}\n" localhost:2019/config/ && MARINA_HOME="$MARINA_HOME" bash plugin/scripts/marina-gateway-control.sh stop; } || echo "SKIP (caddy 미설치)"
```
Expected: caddy 있으면 `admin=200` + 기동/정지 메시지. 없으면 SKIP.

- [ ] **Step 3: 커밋**
```bash
git add plugin/scripts/marina-gateway-control.sh
git commit -m "feat(gateway): caddy 호스트 프로세스 제어(start/stop/status) — nohup 기본, caddy 미설치 안내"
```

---

## Task 3: 동적 반영 — refresher 스레드 + 이벤트 훅 (codex 위임 가능)

데몬이 라이브 스냅샷을 주기적으로(빠짐없음) + 이벤트 즉시(즉각) 게이트웨이에 반영.

**Files:** Modify `plugin/scripts/marina-control.py`

- [ ] **Step 1: 스냅샷 어댑터 + refresh 함수 추가** — `marina-control.py` 에 게이트웨이 연동부. `_mc()`(marina-compose import) 패턴처럼 `_gw()` 로 marina-gateway 로드. 핵심:

```python
def _gw():
    global _GW
    try:
        return _GW
    except NameError:
        import importlib.util
        spec = importlib.util.spec_from_file_location("marina_gateway", str(SCRIPT_DIR / "marina-gateway.py"))
        _GW = importlib.util.module_from_spec(spec); spec.loader.exec_module(_GW)
        return _GW

_GATEWAY_STATE = str(MARINA_HOME / "gateway" / "Caddyfile")
_GATEWAY_PORT = int(_env("MARINA_GATEWAY_PORT", "80"))
_GATEWAY_ON = _env("MARINA_GATEWAY", "") not in ("", "0", "off", "false")   # 켜짐 옵트인

def _gateway_snapshot():
    """모든 워크트리 → {id, projectId, services:[{service,port,running}]} 스냅샷(라이브 포트)."""
    out = []
    for root in discover_roots():
        try:
            p = session_payload(root)
        except Exception:
            continue
        out.append({"id": p.get("id"), "projectId": p.get("projectId"),
                    "services": [{"service": s.get("service"), "port": s.get("port"), "running": s.get("running")}
                                 for s in (p.get("services") or [])]})
    return out

def refresh_gateway():
    """스냅샷 → diff → 변하면 caddy reload. 게이트웨이 꺼졌거나 caddy 없으면 no-op. 절대 예외 안 던짐(서비스 흐름 안 깸)."""
    if not _GATEWAY_ON or not _gw().caddy_bin():
        return
    try:
        _gw().apply(_gateway_snapshot(), _GATEWAY_PORT, _GATEWAY_STATE)
    except Exception as e:
        sys.stderr.write(f"gateway refresh 실패(무시): {e}\n")
```

(주의: `session_payload`/`discover_roots`/`SCRIPT_DIR`/`MARINA_HOME`/`_env` 는 기존 심볼 — 실제 위치 확인해 맞춤. `_GW`/`_GATEWAY_*` 모듈 전역.)

- [ ] **Step 2: 백그라운드 refresher 스레드 — 데몬 main 에 등록** — `main()`(server.serve_forever 직전, marina-control.py:3429 부근)에 추가:

```python
    if _GATEWAY_ON:
        import threading, time
        def _gw_loop():
            while True:
                refresh_gateway()
                time.sleep(int(_env("MARINA_GATEWAY_POLL", "4")))   # 4s 주기 — diff 라 변화 없으면 reload 안 함
        threading.Thread(target=_gw_loop, daemon=True).start()
```

- [ ] **Step 3: 이벤트 즉시 훅 — start/stop/restart/all 에 refresh 추가** — `start_service`(2101)·`stop_service`(1934)·`restart_service`(2128)·`start_all`·`stop_all` 의 **return 직전**에 `refresh_gateway()` 한 줄(예외 안전, 위에서 보장). codex 위임 예:
  `codex exec "marina-control.py 의 start_service·stop_service·restart_service·start_all·stop_all 함수가 결과를 return 하기 직전에 refresh_gateway() 호출을 추가하라(각 함수 1줄). refresh_gateway 는 예외를 안 던지니 try 불요. 다른 로직·반환값 변경 금지."` → `codex review` → 내 검토.

- [ ] **Step 4: `/api/gateway-status` 핸들러** — `do_GET`(2481)에 추가(`send_json` 사용):

```python
        if parsed.path == "/api/gateway-status":
            self.send_json({"enabled": _GATEWAY_ON, "caddy": bool(_gw().caddy_bin()),
                            "port": _GATEWAY_PORT, "routes": _gw().build_caddyfile(_gateway_snapshot(), _GATEWAY_PORT)})
            return
```

- [ ] **Step 5: 구문·기동 스모크** — Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read()); print('ok')"`. 그리고 `MARINA_GATEWAY=` (꺼짐)으로 데몬 기동 → `/api/sessions` 200(게이트웨이 off 영향 0). `MARINA_GATEWAY=1 MARINA_GATEWAY_PORT=8899`(caddy 있으면)로 기동 → `/api/gateway-status` 200·routes 포함. 전체 스위트 FAILED 없음(test-dashboard-launch 등).

- [ ] **Step 6: 커밋**
```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(gateway): 동적 반영 — refresher 스레드(주기 diff-reload)+이벤트 훅(start/stop/restart)+/api/gateway-status (codex 일부)"
```

---

## Task 4: :80 시스템 데몬 (1회 권한 설치)

:80 바인드 = root. macOS LaunchDaemon / Linux systemd system unit(또는 setcap). 1회 sudo, 이후 자율.

**Files:** Extend `plugin/scripts/marina-gateway-control.sh` (`install`/`uninstall` 서브커맨드)

- [ ] **Step 1: install/uninstall 추가** — macOS: `/Library/LaunchDaemons/com.marina.gateway.plist`(root, RunAtLoad), `caddy run --config <cfg>` 실행. Linux: `/etc/systemd/system/marina-gateway.service` 또는 `setcap cap_net_bind_service=+ep $(command -v caddy)` 후 nohup. 둘 다 `sudo` 필요 — 스크립트가 명령을 **출력하고 사용자가 실행**(또는 `sudo` 직접; 환경에 따라). 정확한 plist/unit 템플릿은 `marina-dashboard.sh:89-156` 패턴 복제.

```bash
  install)
    cb="$(caddy_bin)"; [[ -n "$cb" ]] || { echo "caddy 먼저 설치"; exit 3; }
    ensure_config
    case "$(uname -s)" in
      Darwin)
        PL=/Library/LaunchDaemons/com.marina.gateway.plist
        cat <<PLIST | sudo tee "$PL" >/dev/null
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.marina.gateway</string>
  <key>ProgramArguments</key><array><string>$cb</string><string>run</string><string>--config</string><string>$CFG</string><string>--adapter</string><string>caddyfile</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$LOG</string><key>StandardOutPath</key><string>$LOG</string>
</dict></plist>
PLIST
        sudo launchctl bootstrap system "$PL" 2>/dev/null || sudo launchctl load "$PL"
        echo "게이트웨이 시스템 데몬 설치(:80, root). 끄기: marina-gateway-control.sh uninstall" ;;
      Linux)
        echo "Linux: 아래 중 하나 — (a) sudo setcap cap_net_bind_service=+ep $cb && marina-gateway-control.sh start  (b) systemd system unit." ;;
    esac ;;
  uninstall)
    case "$(uname -s)" in
      Darwin) sudo launchctl bootout system/com.marina.gateway 2>/dev/null || sudo launchctl unload /Library/LaunchDaemons/com.marina.gateway.plist 2>/dev/null || true; sudo rm -f /Library/LaunchDaemons/com.marina.gateway.plist; echo "제거" ;;
      Linux) echo "setcap 되돌리기: sudo setcap -r $(caddy_bin); 또는 systemctl disable --now marina-gateway" ;;
    esac ;;
```

- [ ] **Step 2: 검증(문서적 — sudo 필요)** — 자동 e2e 는 :80/sudo 회피(T5 는 비권한 포트). install/uninstall 은 plist/unit 생성 로직만 구문 확인(`bash -n marina-gateway-control.sh`) + README 에 1회 설치 절차 명시. 실제 :80 기동은 사람이 1회 `marina-gateway-control.sh install` 후 브라우저로 확인.

- [ ] **Step 3: 커밋**
```bash
git add plugin/scripts/marina-gateway-control.sh
git commit -m "feat(gateway): :80 시스템 데몬 install/uninstall (macOS LaunchDaemon·Linux setcap/systemd, 1회 권한)"
```

---

## Task 5: 실 caddy e2e — 정적 라우팅 + 동적 반영

실 caddy(비권한 포트)로 라우팅 + add/remove/restart/diff 검증. mock 백엔드(python http.server) — 풀 marina 워크트리 불요.

**Files:** Create `plugin/tests/test-gateway-e2e.sh`

- [ ] **Step 1: e2e 작성** — `test-gateway-e2e.sh`:

```bash
#!/usr/bin/env bash
# 실 caddy E2E(비권한 포트): 스냅샷→Caddyfile→caddy reload→Host 헤더 라우팅 + 동적(add/remove/restart/diff).
# caddy 없으면 SKIP. mock 백엔드=python http.server.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"
command -v caddy >/dev/null 2>&1 || { echo "SKIP test-gateway-e2e (caddy 미설치)"; exit 0; }

TMP="$(mktemp -d)"; GP=8898; CFG="$TMP/Caddyfile"
# 빈 호스트포트 2개 확보
P1="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
P2="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
mkdir -p "$TMP/a" "$TMP/b"; echo "AAA" > "$TMP/a/index.html"; echo "BBB" > "$TMP/b/index.html"
( cd "$TMP/a" && python3 -m http.server "$P1" >/dev/null 2>&1 & echo $! > "$TMP/a.pid" )
( cd "$TMP/b" && python3 -m http.server "$P2" >/dev/null 2>&1 & echo $! > "$TMP/b.pid" )
CADDY_PID=""
cleanup(){ [ -n "$CADDY_PID" ] && kill "$CADDY_PID" 2>/dev/null || true; kill "$(cat "$TMP/a.pid" 2>/dev/null)" "$(cat "$TMP/b.pid" 2>/dev/null)" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

gen() { python3 "$GW" gen --port "$GP" > "$CFG"; }   # stdin=snapshot
# 스냅샷 A+B 둘 다
snap_both(){ printf '[{"id":"main","projectId":"shop","services":[{"service":"web","port":"%s","running":true}]},{"id":"feat","projectId":"shop","services":[{"service":"web","port":"%s","running":true}]}]' "$P1" "$P2"; }
snap_a(){ printf '[{"id":"main","projectId":"shop","services":[{"service":"web","port":"%s","running":true}]}]' "$P1"; }

snap_both | gen
caddy run --config "$CFG" --adapter caddyfile >"$TMP/caddy.log" 2>&1 & CADDY_PID=$!
for _ in $(seq 1 30); do curl -s -o /dev/null localhost:2019/config/ && break; sleep 0.3; done

# 정적: Host 로 라우팅
a="$(curl -s -H 'Host: main.shop.localhost' "localhost:$GP/")"; echo "$a" | grep -q AAA || { echo "FAIL: main→A: [$a]"; cat "$TMP/caddy.log"; exit 1; }
b="$(curl -s -H 'Host: feat.shop.localhost' "localhost:$GP/")"; echo "$b" | grep -q BBB || { echo "FAIL: feat→B: [$b]"; exit 1; }

# 동적 remove: B 빼고 reload → feat 사라짐(502/connrefused 아닌 5xx/404)
snap_a | gen; caddy reload --config "$CFG" --adapter caddyfile >/dev/null 2>&1; sleep 0.5
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: feat.shop.localhost' "localhost:$GP/")"
[ "$code" != "200" ] || { echo "FAIL: remove 후에도 feat 200"; exit 1; }
curl -s -H 'Host: main.shop.localhost' "localhost:$GP/" | grep -q AAA || { echo "FAIL: remove 후 main 깨짐"; exit 1; }

# 동적 add 복귀 + restart/port-change: B 를 새 포트로
kill "$(cat "$TMP/b.pid")" 2>/dev/null || true
P3="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
( cd "$TMP/b" && python3 -m http.server "$P3" >/dev/null 2>&1 & echo $! > "$TMP/b.pid" )
printf '[{"id":"main","projectId":"shop","services":[{"service":"web","port":"%s","running":true}]},{"id":"feat","projectId":"shop","services":[{"service":"web","port":"%s","running":true}]}]' "$P1" "$P3" | gen
caddy reload --config "$CFG" --adapter caddyfile >/dev/null 2>&1; sleep 0.5
b2="$(curl -s -H 'Host: feat.shop.localhost' "localhost:$GP/")"; echo "$b2" | grep -q BBB || { echo "FAIL: restart/port-change 후 feat 새 포트 재지정 안 됨: [$b2]"; exit 1; }

echo "PASS test-gateway-e2e (정적 라우팅 + 동적 add/remove/port-change)"
```

- [ ] **Step 2: 실행 → 통과(또는 SKIP)** — Run: `bash plugin/tests/test-gateway-e2e.sh` → `PASS ...`(caddy 있으면) / SKIP. 실패 시 caddy.log 로 디버그.

- [ ] **Step 3: 커밋**
```bash
git add plugin/tests/test-gateway-e2e.sh
git commit -m "test(gateway): 실 caddy e2e — Host 라우팅 + 동적 add/remove/port-change(reload)"
```

---

## Task 6: marina status / 대시보드 게이트웨이 URL + README

**Files:** Modify `plugin/scripts/marina.sh`(status), `marina-web/`(URL 표시), `README.md`

- [ ] **Step 1: `marina status` 게이트웨이 URL** — status 출력에 게이트웨이 켜졌을 때 워크트리별 `http://<wt>.<proj>.localhost[:port]` 표시. `/api/gateway-status` 또는 marina-gateway 직접 호출로 도메인 산출. (정확한 status 함수 위치는 marina.sh 확인.)

- [ ] **Step 2: 대시보드 게이트웨이 패널(선택)** — 워크트리 카드에 게이트웨이 URL 링크. `/api/gateway-status` 소비. codex 위임 가능.

- [ ] **Step 3: README 게이트웨이 문서** — `## 게이트웨이` 절: 켜기(`MARINA_GATEWAY=1` + `marina-gateway-control.sh install` 1회 sudo for :80), `<wt>.<proj>.localhost` 접근, 동적 반영, fe 절대주소→상대경로 1줄 안내(잔여 한계). caddy 미설치 시 안내.

- [ ] **Step 4: 검증 + 커밋** — 대시보드 프리뷰(게이트웨이 URL 렌더·콘솔 에러 0), `marina status` 출력 확인, README 펜스 균형.
```bash
git add plugin/scripts/marina.sh plugin/scripts/marina-web/ README.md
git commit -m "feat(gateway): marina status/대시보드 게이트웨이 URL + README 문서"
```

---

## Self-Review

**1. Spec coverage (SP2 절):**
- SP2-(a) 바이너리 조달(PATH+안내) → T2 Step1(caddy_bin·미설치 안내). ✅
- SP2-(b) 프로세스 관리(:80 시스템데몬) → T2(nohup 기동) + T4(LaunchDaemon/systemd install). ✅
- SP2-(c) config 생성 **+ 동적 반영**(폴링 diff-reload + 이벤트) → T1(생성·diff) + T3(refresher 스레드 + 이벤트 훅). ✅
- SP2-(d) 라우팅(서비스별 서브도메인, 대표 web bare) → T1(`build_caddyfile`·`_is_primary`). ✅
- SP2-(e) 검증(정적 + 동적 add/remove/restart/port-change/diff) → T5(실 caddy e2e) + T1(diff 단위). ✅
- `marina status` 도메인 표시 → T6. ✅

**2. Placeholder scan:** T1·T5 전 코드/명령/기대출력 exact. T3·T4·T6 의 데몬/marina.sh 통합은 기존 심볼(session_payload·discover_roots·start_service·status 함수)을 file:line 으로 지목 + 훅 코드 제시 + "실제 위치 확인" 단서(SP1 의 cull 위임과 동일 수준) + codex 지시문. :80 e2e 는 sudo 회피(비권한 포트)가 의도 — 명시.

**3. Type/이름 일관성:**
- `build_caddyfile(snapshot, port)->str` — T1 정의, T3(`_gw().build_caddyfile`)·T5(`gen`) 동일. ✅
- `config_changed`/`write_config`/`apply(snapshot,port,state_path)`/`reload_caddy`/`caddy_bin` — T1 정의, T3 `refresh_gateway` 가 `apply` 호출. ✅
- 스냅샷 스키마 `{id, projectId, services:[{service,port,running}]}` — T1 테스트·T3 `_gateway_snapshot`·T5 e2e 동일. ✅
- 서브도메인 `<wt>[-<svc>].<proj>.localhost` — T1 생성·T5 Host 헤더·T6 표시 일치. ✅
- 환경변수 `MARINA_GATEWAY`(옵트인)·`MARINA_GATEWAY_PORT`·`MARINA_GATEWAY_POLL` — T2·T3 동일. ✅

**4. 위험/주의:**
- **refresh 예외 안전**: `refresh_gateway` 는 절대 예외 안 던짐 — start/stop 흐름·데몬 안 깨짐(게이트웨이 장애 격리).
- **diff-reload**: 변화 없으면 reload 안 함 → caddy admin 부하·churn 억제. 4s 폴링도 diff 라 사실상 무비용.
- **:80 권한**: 자동 e2e 는 비권한 포트. :80 은 1회 시스템데몬 설치(sudo) — 문서+install 커맨드. 자율 기동과 분리.
- **caddy 미설치**: 게이트웨이 전체 no-op + 안내, 나머지 marina 정상(옵트인 `MARINA_GATEWAY`).
- **잔여 물리한계**: fe 절대주소(상대경로 1줄)·동일포트 — 게이트웨이가 못 풂(원 SPEC). README 명시.

---

## Execution Handoff

**codex 활용**: T1·T2·T5(코어·라이프사이클·실 e2e)는 직접 TDD + 실 caddy 증거. T3·T6 의 데몬/대시보드 글루(훅 배선·status 표시)는 `codex exec` 위임 + `codex review` + 내 통합·검증. 매 태스크 green, SC 누적, 형 마지막 검토.

실행: `superpowers:subagent-driven-development`(권장) 또는 `superpowers:executing-plans`. SP2 완료 후 connectivity 재설계 3축(엮기+게이트웨이) 완성 → stage3(선언 완전자동·fe 절대주소 감지·동일포트 검출)는 별도.
