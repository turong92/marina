#!/usr/bin/env python3
"""원격 박스에 띄운 스택을 지켜보다 박스가 꺼지면 맥에서 다시 띄운다 — 형 2026-11-05 "중간에 꺼지는 것도 다 해".

집 윈도우 박스는 늘 켜 두지 않는다. 스택이 박스에 떠 있는 동안 박스가 꺼지면 컨테이너가 같이 사라지고
게이트웨이 도메인은 죽은 터널을 가리킨다. runtimed 가 1분마다:
  1) 박스에 띄운 기록(remote-owned.json)과 살아 있던 터널 기록(remote-tunnel.pid)이 있는 워크트리를 찾고
  2) 그 박스에 ssh 로 붙어 본다(캐시 없이)
  3) 두 번 연속 안 닿으면 그 워크트리를 '맥 고정'(runtime-fallback.json)으로 바꾸고 `marina start --all` 로 맥에서 띄운다
     — 고정은 stop --all 때 풀린다(marina_runtime_target). 한 번 끊김은 넘긴다(순간 끊김).
옵트아웃: MARINA_REMOTE_WATCH=0. 로그: runtimed.log.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

EVERY_S = 60.0
MISSES = 2                       # 연속 이만큼 안 닿아야 맥으로 — 순간 끊김에 넘어가지 않게


def enabled() -> bool:
    return os.environ.get("MARINA_REMOTE_WATCH", "1") != "0"


def _remote_stacks(roots):
    """(root, session_dir, host) — 박스에 띄웠고 아직 맥 고정이 아닌 워크트리."""
    import marina_paths
    import marina_runtime_target as rt
    out = []
    for root in roots:
        try:
            sd = marina_paths.session_dir(Path(root))
        except Exception:
            continue
        owned, tun = sd / "remote-owned.json", sd / "remote-tunnel.pid"
        if not (owned.is_file() and tun.is_file()) or (sd / rt.PIN_NAME).is_file():
            continue
        try:
            host = str(json.loads(owned.read_text(encoding="utf-8")).get("host") or "")
        except (OSError, ValueError, AttributeError):
            continue
        if host.startswith("ssh://"):
            out.append((Path(root), sd, host))
    return out


def _reachable(host: str) -> bool:
    import marina_runtime_target as rt
    d = rt._ssh_dest(host)
    return True if d is None else rt._probe(*d, wait=5)


def _start_local(root: Path) -> int:
    entry = Path(__file__).resolve().parent / "marina-entrypoint.sh"
    return subprocess.call([str(entry), "start", "--all"], cwd=str(root),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1800)


def tick(roots, misses: dict, log=print, reachable=None, start_local=None) -> list:
    """한 바퀴. 맥으로 옮긴 root 목록을 돌려준다. misses 는 호출자가 들고 있는 연속 실패 수."""
    import marina_runtime_target as rt
    reachable = reachable or _reachable
    start_local = start_local or _start_local
    moved, seen = [], set()
    for root, sd, host in _remote_stacks(roots):
        seen.add(str(root))
        if reachable(host):
            misses.pop(str(root), None)
            continue
        misses[str(root)] = misses.get(str(root), 0) + 1
        if misses[str(root)] < MISSES:
            continue
        misses.pop(str(root), None)
        rt.pin_local(str(sd), rt.LocalTarget(fallback_from=host))     # 먼저 고정 — 이후 모든 판단이 맥을 본다
        (sd / "remote-tunnel.pid").unlink(missing_ok=True)            # 죽은 터널 기록(다시 감시하지 않게)
        rc = start_local(root)
        log(f"remote-watch: {host} 가 {MISSES}분째 안 닿아 {root} 를 맥에서 다시 띄움(rc={rc})")
        moved.append(root)
    for k in list(misses):
        if k not in seen:
            misses.pop(k, None)
    return moved


def run_forever(log=print) -> None:
    from marina_registry import discover_roots
    misses: dict = {}
    while True:
        try:
            tick(list(discover_roots()), misses, log=log)
        except Exception as exc:
            log(f"remote-watch 오류(무시): {exc!r}")
        time.sleep(EVERY_S)
