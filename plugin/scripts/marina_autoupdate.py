"""marina_autoupdate.py — marina 가 새 버전을 알아서 받고 데몬을 재시작한다(강제 업데이트).

**왜.** 원격 박스(192.168.0.251) dial-stdio 누수 수정(34185c7)을 배포했는데 팀원 맥이 업데이트를 안 해 5일 뒤에도
박스 접속이 시간당 수천 번 그대로였다(2026-09-22 실측). 형: "업데이트 하라고 하면 말 안 들으니까 강제로 한 번에".

**어떻게.** 데몬 GC 루프(10분)가 auto_update_tick 을 부른다. 기록된 데몬만(격리 프리뷰 제외), AUTO_UPDATE_HOURS(기본 1)
마다 update_status 를 보고:
  new   (배포된 게 받아진 것보다 최신) → 마켓플레이스 갱신 → **사전 검증** → `claude plugin update` → 데몬 재시작
  stale (받아진 건 최신, 데몬만 옛 코드)  → 데몬 재시작만
  그 외(current·unknown=레포/dev 실행)    → 아무것도 안 함

**사전 검증이 핵심이다.** 2026-09-17 배포 직후 `str | None` 한 줄로 3.9 데몬에서 marina-compose.py import 가 통째로
실패했다. 자동 업데이트가 그걸 모두에게 퍼뜨리면 팀 전체 대시보드가 동시에 죽는다. 그래서 설치 **전에** 새 코드를 데몬과
같은 인터프리터(sys.executable)로 격리 홈에서 import 해 보고, 실패하면 설치하지 않고 그 SHA 를 기록해 다시 시도하지 않는다.
기동·재시작 중인 서비스(LIFECYCLE_BUSY)가 있으면 재시작을 다음 틱으로 미룬다.

끄기: MARINA_AUTO_UPDATE=0 (환경변수). 로그: ~/.marina/auto-update.log, 상태: ~/.marina/auto-update-state.json.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from marina_state import CLAUDE_CONFIG_DIR, MARINA_HOME, MARKETPLACE, PLUGIN_ID, _bin, _env

STATE_FILE = MARINA_HOME / "auto-update-state.json"
LOG_FILE = MARINA_HOME / "auto-update.log"
# 데몬이 부팅 때 import 하는 모듈 — 하나라도 실패하면 새 데몬이 안 뜬다
PREFLIGHT_MODULES = ("marina_state", "marina_handler", "marina_compose_svc", "marina_lifecycle", "marina_sessions",
                     "marina_docker_gc", "marina_worktree_gc", "marina_update", "marina_autoupdate")
PREFLIGHT_FILES = ("marina-compose.py", "marina-control.py")   # 하이픈 이름 — 파일로 로드(실행은 안 함)
MAX_RESTART_TRIES = 3            # 재시작해도 serving 이 installed 로 안 바뀌면 여기서 멈춘다(매시간 재시작 루프 방지)
MAX_CLIENT_DEFER_S = 6 * 3600    # 대시보드·폰이 붙어 있으면 재시작을 미루되 이만큼까지만


def _now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _log(line: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"{_now_iso()} {line}\n")
    except OSError:
        pass


def load_state() -> dict[str, Any]:
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save_state(state: dict[str, Any]) -> None:
    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(STATE_FILE)
    except OSError:
        pass


def enabled() -> bool:
    return str(os.environ.get("MARINA_AUTO_UPDATE", "1")).strip().lower() not in ("0", "off", "false", "no")


def interval_s() -> float:
    try:
        return max(0.1, float(_env("AUTO_UPDATE_HOURS", "1") or "1")) * 3600
    except ValueError:
        return 3600.0


def marketplace_scripts_dir() -> Path:
    """`claude plugin marketplace update` 가 새 코드를 받아 두는 곳 — 설치(plugin update) 전에 여기서 검증한다."""
    return CLAUDE_CONFIG_DIR / "plugins" / "marketplaces" / MARKETPLACE / "plugin" / "scripts"


def _run(argv: list[str], timeout: float = 180) -> tuple[int, str]:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip()
    except Exception as exc:
        return 1, str(exc)


def preflight(scripts: Path, python: str | None = None) -> tuple[bool, str]:
    """새 코드를 데몬과 같은 인터프리터로 격리 홈에서 import. (ok, 마지막 에러 줄)."""
    python = python or sys.executable
    code = (
        "import importlib.util, sys\n"
        f"sys.path.insert(0, {str(scripts)!r})\n"
        f"for m in {PREFLIGHT_MODULES!r}:\n"
        "    __import__(m)\n"
        f"for f in {PREFLIGHT_FILES!r}:\n"
        f"    p = {str(scripts)!r} + '/' + f\n"
        "    src = open(p, encoding='utf-8').read()\n"
        "    compile(src, p, 'exec')\n"
        "for name, f in (('mc_pre', 'marina-compose.py'), ('ctl_pre', 'marina-control.py')):\n"
        "    s = importlib.util.spec_from_file_location(name, " + repr(str(scripts)) + " + '/' + f)\n"
        "    m = importlib.util.module_from_spec(s); s.loader.exec_module(m)\n"
        "print('preflight-ok')\n"
    )
    with tempfile.TemporaryDirectory() as home:
        env = {k: v for k, v in os.environ.items() if not k.startswith("MARINA_")}
        env["MARINA_HOME"] = home
        try:
            p = subprocess.run([python, "-c", code], capture_output=True, text=True, timeout=120, env=env, cwd=home)
        except Exception as exc:
            return False, str(exc)
    out = ((p.stdout or "") + (p.stderr or "")).strip()
    if p.returncode == 0 and "preflight-ok" in out:
        return True, ""
    lines = [l for l in out.splitlines() if l.strip()]
    return False, (lines[-1] if lines else f"exit {p.returncode}")[:300]


def _lifecycle_busy() -> bool:
    try:
        from marina_state import LIFECYCLE_BUSY
        return any("error" not in v for v in LIFECYCLE_BUSY.values())
    except Exception:
        return False


def _clients_connected() -> bool:
    """대시보드 SSE·등록된 폰이 붙어 있나 — 재시작하면 그 연결이 끊긴다(터미널 프로세스는 pty 라 산다)."""
    try:
        from marina_events import event_bus
        return event_bus().subscriber_count() > 0
    except Exception:
        return False


def installed_scripts_dir() -> Path | None:
    try:
        data = json.loads((CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json").read_text(encoding="utf-8"))
        return Path(str(data["plugins"][PLUGIN_ID][0]["installPath"])) / "scripts"
    except Exception:
        return None


def _default_restart() -> tuple[int, str]:
    """설치된(새) 경로의 marina-dashboard.sh restart — launchd 헬퍼가 1초 뒤 재시작한다(대시보드 버튼과 같은 방식)."""
    try:
        data = json.loads((CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json").read_text(encoding="utf-8"))
        ip = Path(str(data["plugins"][PLUGIN_ID][0]["installPath"]))
    except Exception as exc:
        return 1, f"installPath 를 못 읽음: {exc}"
    return _run(["bash", str(ip / "scripts" / "marina-dashboard.sh"), "restart"], timeout=60)


def _gated_restart(state: dict[str, Any], now: float, installed: str | None, busy_fn, clients_fn, preflight_fn,
                   restart_fn, installed_dir_fn) -> str:
    """재시작 직전 게이트. 반환: restarted / deferred:* / rejected:installed / gave-up / failed:restart."""
    if busy_fn():
        return "deferred:busy"                                      # 빌드·기동 중 — 끊지 않는다
    if clients_fn():
        since = state.get("clientDeferSince") or now
        state["clientDeferSince"] = since
        if now - float(since) < MAX_CLIENT_DEFER_S:
            return "deferred:clients"                               # 보는 중 — 최대 6시간까지 미룬다
    tries = state.get("restartTries") or {}
    key = str(installed or "?")
    if int(tries.get(key, 0)) >= MAX_RESTART_TRIES:
        return "gave-up"                                            # 이 버전으론 재시작이 수렴 안 함 — 새 버전까지 멈춤
    d = installed_dir_fn()
    ok, err = preflight_fn(d) if d else (False, "installPath 를 못 읽음")
    if not ok:                                                      # 설치된 코드가 실제로 뜨는지 — 검증과 설치 사이 경합까지 막는다
        state.update({"badSha": installed, "lastError": f"installed preflight: {err}"})
        _log(f"REJECTED installed {installed} — 재시작하지 않음(옛 데몬 유지): {err}")
        return "rejected:installed"
    state["restartTries"] = {key: int(tries.get(key, 0)) + 1}
    state.pop("clientDeferSince", None)
    rc, out = restart_fn()
    if rc != 0:
        state["lastError"] = f"restart: {out[-200:]}"
        return "failed:restart"
    return "restarted"


def auto_update_tick(port: int, now: float | None = None, primary: bool | None = None,
                     status_fn: Callable[[], dict] | None = None,
                     run_fn: Callable[[list[str]], tuple[int, str]] | None = None,
                     preflight_fn: Callable[[Path], tuple[bool, str]] | None = None,
                     restart_fn: Callable[[], tuple[int, str]] | None = None,
                     busy_fn: Callable[[], bool] | None = None,
                     clients_fn: Callable[[], bool] | None = None,
                     installed_dir_fn: Callable[[], Path | None] | None = None) -> str:
    """데몬 루프 한 틱. 예외를 밖으로 안 낸다. 나머지 인자는 테스트 이음매."""
    now = time.time() if now is None else now
    try:
        if not enabled():
            return "skipped:off"
        if primary is None:
            from marina_docker_gc import recorded_daemon_port
            recorded = recorded_daemon_port()
            primary = recorded is not None and recorded == int(port)
        if not primary:
            return "skipped:not-primary"
        state = load_state()
        last = state.get("checkedAt")
        if isinstance(last, (int, float)) and now < float(last) + interval_s():
            return "skipped:not-due"
        if status_fn is None:
            from marina_update import _status_cache, update_status
            _status_cache.clear()                                   # 1시간에 한 번이니 캐시 말고 지금 값
            status_fn = update_status
        run_fn = run_fn or _run
        preflight_fn = preflight_fn or preflight
        restart_fn = restart_fn or _default_restart
        busy_fn = busy_fn or _lifecycle_busy
        clients_fn = clients_fn or _clients_connected
        installed_dir_fn = installed_dir_fn or installed_scripts_dir
        gate = lambda inst: _gated_restart(state, now, inst, busy_fn, clients_fn, preflight_fn, restart_fn, installed_dir_fn)
        keep_due = lambda: {**state, "checkedAt": last if isinstance(last, (int, float)) else 0}   # 미룰 땐 주기를 소모하지 않는다

        st = status_fn() or {}
        kind, origin = st.get("state"), st.get("origin")
        state.update({"checkedAt": now, "lastState": kind, "serving": st.get("serving"), "origin": origin})

        if kind == "new":
            if origin and origin == state.get("badSha"):
                _save_state(state)
                return "skipped:bad-sha"                            # 검증에 떨어진 버전 — 새 버전이 나올 때까지 안 받는다
            if busy_fn():
                _save_state({**state, "checkedAt": last if isinstance(last, (int, float)) else 0})
                return "deferred:busy"                              # 기동 중 — 다음 틱에 다시(주기를 소모하지 않음)
            claude = _bin("claude")
            rc, out = run_fn([claude, "plugin", "marketplace", "update", MARKETPLACE])
            if rc != 0:
                state["lastError"] = f"marketplace update: {out[-200:]}"
                _save_state(state); _log(f"FAILED marketplace update {origin}: {out[-200:]}")
                return "failed:marketplace"
            ok, err = preflight_fn(marketplace_scripts_dir())
            if not ok:
                state.update({"badSha": origin, "lastError": f"preflight: {err}"})
                _save_state(state)
                _log(f"REJECTED {origin} — 새 버전이 데몬 인터프리터에서 안 뜬다, 설치 안 함: {err}")
                return "rejected:preflight"
            rc, out = run_fn([claude, "plugin", "update", PLUGIN_ID])
            if rc != 0:
                state["lastError"] = f"plugin update: {out[-200:]}"
                _save_state(state); _log(f"FAILED plugin update {origin}: {out[-200:]}")
                return "failed:plugin-update"
            state.update({"installedAt": now, "updatedFrom": st.get("serving"), "updatedTo": origin, "lastError": None})
            res = gate(origin)
            if res.startswith("deferred"):
                _save_state(keep_due()); _log(f"INSTALLED {origin} — 재시작은 미룸({res})")
                return f"installed:{res}"
            _save_state(state)
            _log(f"UPDATED {st.get('serving')} → {origin} ({res})")
            return "updated" if res == "restarted" else f"installed:{res}"

        if kind == "stale":
            inst = st.get("installed")
            if inst and inst == state.get("badSha"):
                _save_state(state)
                return "skipped:bad-sha"
            res = gate(inst)
            if res.startswith("deferred"):
                _save_state(keep_due())
                return res
            state["restartedAt"] = now if res == "restarted" else state.get("restartedAt")
            _save_state(state)
            if res != "gave-up" or not state.get("gaveUpLogged") == inst:
                _log(f"STALE {st.get('serving')} → {inst}: {res}")
                if res == "gave-up":
                    state["gaveUpLogged"] = inst; _save_state(state)
            return res

        _save_state(state)
        return f"noop:{kind}"
    except Exception as exc:
        _log(f"FAILED {exc}")
        return f"failed:{exc}"
