"""marina_selfupdate.py — marina 새 버전 받기(runtime). runtimed 가 돌린다.

**왜.** 받아 설치하는 코드가 대시보드 데몬(marina_autoupdate) 안에만 있어서, 대시보드를 안 띄우는 맥(대화는 Discord 로만)은
그 버전에 멈췄다(2026-10-06). 받기·검증 부품을 runtime 으로 옮기고 runtimed 가 tick 으로 직접 받는다.

**재시작은 여기서 안 한다.** runtimed 는 설치 경로가 바뀌면 스스로 끝나 새 코드로 다시 뜬다(marina_runtimed.stale_code).
대시보드가 떠 있으면 자기 틱(marina_autoupdate)이 stale 을 보고 터미널·접속 관문을 거쳐 재시작한다.

**사전 검증은 그대로.** 설치 전에 새 코드를 데몬 인터프리터(이 프로세스 것, 맥이면 시스템 파이썬도)로 격리 홈에서 import 해
보고, 안 뜨면 설치하지 않고 그 SHA 를 기록한다(2026-09-17 3.9 사고가 팀 전체로 퍼지는 걸 막는 장치). 검증 자체를 못 돌린
경우(타임아웃·인터프리터 실행 실패)는 코드 탓이 아니므로 기록하지 않고 다음 주기에 다시 본다.

끄기: MARINA_AUTO_UPDATE=0. 로그: ~/.marina/auto-update.log, 상태: ~/.marina/auto-update-runtimed-state.json
(대시보드 틱과 주기를 서로 뺏지 않게 따로 쓴다).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from marina_state import CLAUDE_CONFIG_DIR, MARINA_HOME, MARKETPLACE, PLUGIN_ID, _bin, _env

STATE_FILE = MARINA_HOME / "auto-update-runtimed-state.json"
LOG_FILE = MARINA_HOME / "auto-update.log"
_SHA = re.compile(r"^[0-9a-f]{7,40}$")
# 데몬이 부팅 때 import 하는 모듈 — 하나라도 실패하면 새 데몬이 안 뜬다
PREFLIGHT_MODULES = ("marina_state", "marina_handler", "marina_compose_svc", "marina_lifecycle", "marina_sessions",
                     "marina_docker_gc", "marina_worktree_gc", "marina_update", "marina_autoupdate",
                     "marina_worktrees", "marina_liveness", "marina_runtimed", "marina_selfupdate")
PREFLIGHT_FILES = ("marina-compose.py", "marina-control.py")   # 하이픈 이름 — 파일로 로드(실행은 안 함)


def _log(line: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"{datetime.now().astimezone().isoformat(timespec='seconds')} {line}\n")
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


UNAVAILABLE = "검증 불가: "      # 이 말로 시작하는 실패 = 검증을 못 돌린 것(코드가 안 뜬 게 아님) — 버전을 막지 않는다
SYSTEM_PYTHON = "/usr/bin/python3"


def unavailable(err: str) -> bool:
    return err.startswith(UNAVAILABLE)


def _probe(python: str) -> "tuple[tuple[int, int], str] | None":
    """그 인터프리터의 (버전, 실제 실행 파일). 못 돌리면 None."""
    try:
        p = subprocess.run([python, "-c", "import os,sys;print(sys.version_info[0],sys.version_info[1],os.path.realpath(sys.executable))"],
                           capture_output=True, text=True, timeout=20)
        major, minor, real = (p.stdout or "").strip().split(" ", 2)
        return ((int(major), int(minor)), real) if p.returncode == 0 else None
    except Exception:
        return None


def preflight_pythons(system: "str | None" = None) -> list[str]:
    """검증에 쓸 인터프리터들. 이 프로세스 것 + 맥의 시스템 파이썬 — runtimed 와 대시보드가 서로 다른 파이썬으로 뜰 수 있다
    (plist PATH 는 start 를 부른 쪽 것이 박힌다). 한쪽만 통과한 버전을 깔면 다른 쪽이 재부팅 뒤 안 뜬다(리뷰 I2).
    시스템 파이썬은 쓸 수 있을 때만: 실행이 안 되거나(CLT 없는 맥의 스텁), 3.9 보다 낮거나, 이 프로세스와 같은 것이면 뺀다 —
    환경 고장을 코드 불량으로 적어 정상 릴리스를 막으면 안 된다(재리뷰 I-1). 맥만(리눅스의 /usr/bin/python3 은 데몬과 무관)."""
    out = [sys.executable]
    system = system or (SYSTEM_PYTHON if sys.platform == "darwin" else "")
    got = _probe(system) if system and os.path.exists(system) else None
    mine = (tuple(sys.version_info[:2]), os.path.realpath(sys.executable))
    if got and got[0] >= (3, 9) and got != mine:
        out.append(system)
    return out


def preflight(scripts: Path, python: str | None = None) -> tuple[bool, str]:
    """새 코드를 데몬 인터프리터(들)로 격리 홈에서 import. (ok, 마지막 에러 줄). python 을 주면 그것 하나로만.
    에러가 UNAVAILABLE 로 시작하면 검증을 못 돌린 것 — unavailable(err) 로 구분한다."""
    if not Path(scripts).is_dir():
        return False, f"검사할 폴더가 없음: {scripts}"      # 모듈을 옮긴 것과 경로가 틀린 것을 구분(재리뷰 M-2)
    for py in ([python] if python else preflight_pythons()):
        ok, err = _preflight_one(scripts, py)
        if not ok:
            return False, err
    return True, ""


def _preflight_one(scripts: Path, python: str) -> tuple[bool, str]:
    # 목록에 있어도 새 코드에 그 파일이 없으면 건너뛴다 — 검증하는 쪽은 늘 옛 버전이라, 목록의 모듈을 옮기거나 지운
    # 릴리스를 옛 버전이 영영 거부하게 된다(리뷰 I3)
    code = (
        "import importlib.util, os, sys\n"
        f"S = {str(scripts)!r}\n"
        "sys.path.insert(0, S)\n"
        f"for m in {PREFLIGHT_MODULES!r}:\n"
        "    if os.path.exists(S + '/' + m + '.py'):\n"
        "        __import__(m)\n"
        f"for f in {PREFLIGHT_FILES!r}:\n"
        "    p = S + '/' + f\n"
        "    if not os.path.exists(p):\n"
        "        continue\n"
        "    compile(open(p, encoding='utf-8').read(), p, 'exec')\n"
        "    s = importlib.util.spec_from_file_location(f.replace('-', '_').replace('.py', '_pre'), p)\n"
        "    m = importlib.util.module_from_spec(s); s.loader.exec_module(m)\n"
        "print('preflight-ok')\n"
    )
    with tempfile.TemporaryDirectory() as home:
        env = {k: v for k, v in os.environ.items() if not k.startswith("MARINA_")}
        env["MARINA_HOME"] = home
        try:
            p = subprocess.run([python, "-c", code], capture_output=True, text=True, timeout=120, env=env, cwd=home)
        except Exception as exc:                      # 타임아웃·인터프리터가 사라짐·fork 실패 — 코드 탓이 아니다(재리뷰 I-2)
            return False, UNAVAILABLE + str(exc)[:250]
    out = ((p.stdout or "") + (p.stderr or "")).strip()
    if p.returncode == 0 and "preflight-ok" in out:
        return True, ""
    lines = [l for l in out.splitlines() if l.strip()]
    return False, (lines[-1] if lines else f"exit {p.returncode}")[:300]


def _update_lock():
    """runtime·discord 자동 업데이트가 같은 마켓플레이스 사본·설치 목록을 동시에 만지지 않게 하는 공용 잠금(리뷰 M3).
    잡혀 있으면 None — 이번엔 미룬다. discord(marina_session.self_update_tick)도 같은 파일을 쓴다."""
    import fcntl
    try:
        MARINA_HOME.mkdir(parents=True, exist_ok=True)
        fh = open(MARINA_HOME / "plugin-update.lock", "w")
    except OSError:
        return None
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.close()
        return None
    return fh


def installed_sha() -> "str | None":
    """설치된 버전 = installPath 의 폴더 이름. Claude 설치 기록이 없거나 SHA 폴더가 아니면 None — 받지 않는다."""
    try:
        data = json.loads((CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json").read_text(encoding="utf-8"))
        name = Path(str(data["plugins"][PLUGIN_ID][0]["installPath"])).name
    except Exception:
        return None
    return name[:12] if _SHA.match(name) else None


def marketplace_sha() -> "str | None":
    """`claude plugin marketplace update` 가 받아 둔 사본의 HEAD."""
    try:                       # stdout 만 — 경고 한 줄이 stderr 로 섞여도 SHA 를 놓치지 않게(리뷰 I4)
        p = subprocess.run(["git", "-C", str(marketplace_scripts_dir().parent.parent), "rev-parse", "HEAD"],
                           capture_output=True, text=True, timeout=15)
    except Exception:
        return None
    out = (p.stdout or "").strip()
    return out[:12] if p.returncode == 0 and _SHA.match(out) else None


def _load() -> dict[str, Any]:
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save(state: dict[str, Any]) -> None:
    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(STATE_FILE)
    except OSError:
        pass


def tick(primary: bool, now: "float | None" = None,
         run_fn: "Callable[[list[str]], tuple[int, str]] | None" = None,
         preflight_fn: "Callable[[Path], tuple[bool, str]] | None" = None,
         installed_fn: "Callable[[], str | None] | None" = None,
         new_fn: "Callable[[], str | None] | None" = None) -> str:
    """runtimed 루프 한 틱 — 새 버전이 있으면 받아 검증하고 설치한다. 예외를 밖으로 안 낸다. 뒤 인자는 테스트 이음매."""
    now = time.time() if now is None else now
    try:
        if not enabled():
            return "skipped:off"
        if not primary:
            return "skipped:not-primary"                 # 격리 홈은 실제 설치를 건드리지 않는다
        state = _load()
        last = state.get("checkedAt")
        if isinstance(last, (int, float)) and now < float(last) + interval_s():
            return "skipped:not-due"
        installed_fn = installed_fn or installed_sha
        installed = installed_fn()
        if not installed:
            return "noop:unknown"                        # Claude 설치본이 아님(Codex 전용 등)
        lock = _update_lock()
        if lock is None:
            return "deferred:lock"                       # 대시보드·discord 업데이트가 만지는 중 — 주기를 소모하지 않는다
        try:
            run_fn, preflight_fn = run_fn or _run, preflight_fn or preflight
            state.update({"checkedAt": now, "installed": installed})
            _save(state)                                 # 먼저 — 아래에서 무슨 일이 나도 이번 주기는 소모(매 틱 재시도 방지)
            claude = _bin("claude")
            rc, out = run_fn([claude, "plugin", "marketplace", "update", MARKETPLACE])
            if rc != 0:
                state["lastError"] = f"marketplace update: {out[-200:]}"
                _save(state)
                _log(f"FAILED marketplace update (runtimed): {out[-200:]}")
                return "failed:marketplace"
            new = (new_fn or marketplace_sha)()
            state["origin"] = new
            if not new:                                  # 조용히 '최신'으로 넘기면 영영 안 받는다(리뷰 I4)
                state["lastError"] = "marketplace 사본의 HEAD 를 못 읽음"
                _save(state)
                _log("FAILED marketplace 사본의 HEAD 를 못 읽음 (runtimed)")
                return "failed:marketplace-sha"
            if new == installed:
                _save(state)
                return "noop:current"
            if new == state.get("badSha"):
                _save(state)
                return "skipped:bad-sha"                 # 검증에 떨어진 버전 — 새 버전이 나올 때까지 안 받는다
            ok, err = preflight_fn(marketplace_scripts_dir())
            if not ok and unavailable(err):              # 검증을 못 돌렸다 — 버전을 막지 않고 다음 주기에 다시
                state["lastError"] = f"preflight: {err}"
                _save(state)
                _log(f"FAILED {new} 검증을 못 돌림, 다음 주기에 다시 (runtimed): {err}")
                return "failed:preflight-unavailable"
            if not ok:
                state.update({"badSha": new, "lastError": f"preflight: {err}"})
                _save(state)
                _log(f"REJECTED {new} — 새 버전이 데몬 인터프리터에서 안 뜬다, 설치 안 함(runtimed): {err}")
                return "rejected:preflight"
            rc, out = run_fn([claude, "plugin", "update", PLUGIN_ID])
            if rc != 0:
                state["lastError"] = f"plugin update: {out[-200:]}"
                _save(state)
                _log(f"FAILED plugin update {new} (runtimed): {out[-200:]}")
                return "failed:plugin-update"
            got = installed_fn()
            if got != new:                               # 명령은 성공했는데 설치본이 안 바뀜 — 허위 기록을 남기지 않는다
                state["lastError"] = f"plugin update 뒤에도 설치본이 {got}"
                _save(state)
                _log(f"FAILED plugin update {new} (runtimed): 설치본이 그대로({got})")
                return "failed:not-applied"
            state.update({"installedAt": now, "updatedFrom": installed, "updatedTo": new, "lastError": None})
            _save(state)
            _log(f"INSTALLED {installed} → {new} (runtimed)")
            return "installed"
        finally:
            lock.close()
    except Exception as exc:
        _log(f"FAILED (runtimed) {exc}")
        return f"failed:{exc}"
