"""marina_runtimed.py — 청소 상주 프로그램(runtime, 분리 A·스펙 5장). 화면 없음.

대시보드 데몬이 품고 있던 실행 쪽 백그라운드 일을 옮겼다 — 대시보드를 안 까는 사람(공개 runtime·팀원)도 필요하다.
  · 게이트웨이 동적 반영: 서비스 포트가 바뀌면 Caddy 라우트를 다시 쓴다(5초, MARINA_GATEWAY_POLL)
  · 도커 GC·유휴 워크트리 자동 정리: 부팅 60초 뒤부터 600초마다(실제 주기는 정책 파일이 정한다)
  · 고아 프로세스 리퍼(스레드)

**자동 삭제는 실제 홈에서만.** 실행 표식 MARINA_RUNTIMED_PRIMARY=1 은 marina-runtimed.sh 가 기본 홈(~/.marina)일 때만
단다. 격리 홈 프리뷰가 실 도커 빌드캐시 9.2GB 를 지운 사고(2026-09-14) 이후의 규칙(도커는 호스트 공유)을 그대로 지킨다.
한 홈에 하나만 돈다(flock) — 업데이트 직후 옛 데몬과 겹쳐도 각 GC 는 자기 상태 파일의 마지막 실행 시각으로 주기를 지킨다.
"""
from __future__ import annotations

import fcntl
import os
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional

import json

from marina_state import CLAUDE_CONFIG_DIR, MARINA_HOME, PLUGIN_ID, _GATEWAY_ON, _env

GC_BOOT_DELAY_S = 60.0
GC_EVERY_S = 600.0


CODE_CHECK_EVERY_S = 60.0
HERE = Path(__file__).resolve().parent


def installed_scripts_dir() -> Optional[Path]:
    try:
        data = json.loads((CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json").read_text(encoding="utf-8"))
        return Path(str(data["plugins"][PLUGIN_ID][0]["installPath"])) / "scripts"
    except Exception:
        return None


def stale_code(running: Path, installed: Optional[Path]) -> bool:
    """설치 경로가 바뀌었으면(플러그인 업데이트) 옛 코드 — 스스로 끝내면 launchd KeepAlive 가 런처로 새 코드를 띄운다.
    설치 기록이 없으면(레포에서 개발 실행) 계속 돈다."""
    if installed is None:
        return False
    try:
        return running.resolve() != installed.resolve()
    except OSError:
        return False


def is_primary() -> bool:
    return os.environ.get("MARINA_RUNTIMED_PRIMARY") == "1"


def _gateway_every() -> float:
    return float(max(2, int(_env("GATEWAY_POLL", "5") or "5")))


def _refresh_gateway() -> None:
    from marina_lifecycle import refresh_gateway
    refresh_gateway()


def _docker_gc(primary: bool) -> None:
    from marina_docker_gc import daemon_tick
    daemon_tick(0, primary=primary)


def _worktree_gc(primary: bool) -> None:
    from marina_worktree_gc import auto_tick
    auto_tick(0, primary=primary)


def _log(line: str) -> None:
    print(time.strftime("%m-%d %H:%M:%S ") + line, flush=True)


class Loop:
    def __init__(self, gateway: Callable[[], None] = _refresh_gateway,
                 docker_gc: Callable[[bool], None] = _docker_gc,
                 worktree_gc: Callable[[bool], None] = _worktree_gc,
                 primary: Optional[bool] = None, gateway_on: Optional[bool] = None) -> None:
        self.gateway, self.docker_gc, self.worktree_gc = gateway, docker_gc, worktree_gc
        self.primary = is_primary() if primary is None else primary
        self.gateway_on = _GATEWAY_ON if gateway_on is None else gateway_on
        self.started: Optional[float] = None
        self.last_gw = float("-inf")
        self.last_gc = float("-inf")
        self.lockf: Any = None

    def own(self) -> bool:
        if self.lockf is not None:
            return True
        try:
            MARINA_HOME.mkdir(parents=True, exist_ok=True)
            fh = open(MARINA_HOME / "runtimed.lock", "w")
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False
        self.lockf = fh
        return True

    def step(self, now: float) -> bool:
        if not self.own():
            return False
        if self.started is None:
            self.started = now
        if self.gateway_on and now - self.last_gw >= _gateway_every():
            self.last_gw = now
            self._safe("gateway", self.gateway)
        if now - self.started >= GC_BOOT_DELAY_S and now - self.last_gc >= GC_EVERY_S:
            self.last_gc = now
            self._safe("docker-gc", lambda: self.docker_gc(self.primary))
            self._safe("worktree-gc", lambda: self.worktree_gc(self.primary))
        return True

    @staticmethod
    def _safe(name: str, fn: Callable[[], Any]) -> None:
        try:
            fn()
        except Exception as exc:          # 청소가 어떻게 실패해도 루프는 산다
            _log(f"{name} 실패(무시): {exc!r}")


def run_forever() -> int:
    if os.environ.get("MARINA_RUNTIMED_NOOP") == "1":     # 테스트용: 프로세스만 살아 있고 아무것도 안 함
        while True:
            time.sleep(3600)
    loop = Loop()
    if not loop.own():
        _log("이미 다른 runtimed 가 돈다 — 끝냄")
        return 0
    _log(f"runtimed 시작 home={MARINA_HOME} primary={loop.primary} gateway={loop.gateway_on}")
    if loop.primary:
        try:
            import marina_reaper
            if marina_reaper.enabled():
                threading.Thread(target=marina_reaper.run_forever, daemon=True, name="marina-reaper").start()
                _log(f"reaper: {marina_reaper.min_age_s() / 3600:g}h 넘은 고아 정리")
        except Exception as exc:
            _log(f"reaper 기동 실패(무시): {exc!r}")
    last_check = time.time()
    while True:
        now = time.time()
        loop.step(now)
        if now - last_check >= CODE_CHECK_EVERY_S:
            last_check = now
            inst = installed_scripts_dir()
            dev = HERE.parent.name == "plugin" and (HERE.parent.parent / ".git").exists()   # 레포에서 개발 실행은 그대로
            if not dev and stale_code(HERE, inst) and inst is not None and (inst / "marina_runtimed.py").is_file():
                _log(f"플러그인이 업데이트됨({HERE} → {inst}) — 끝내고 새 코드로 다시 뜬다")
                return 0
        time.sleep(1.0)


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    sys.exit(run_forever())
