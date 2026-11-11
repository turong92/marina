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
RETURN_HITS = 3                  # 맥 고정인데 박스가 이만큼 연속 닿으면 돌아온 것으로(형 2026-11-11 "붙으면 다시 이사")


def _pinned_stacks(roots):
    """(root, session_dir, host, compose 이름) — 박스에 띄웠다가 박스가 안 닿아 맥 고정된 워크트리."""
    import marina_paths
    import marina_runtime_target as rt
    out = []
    for root in roots:
        try:
            sd = marina_paths.session_dir(Path(root))
        except Exception:
            continue
        host = rt._pinned_from(str(sd))
        if not host or not host.startswith("ssh://"):
            continue
        try:
            name = str(json.loads((sd / "remote-owned.json").read_text(encoding="utf-8")).get("project") or "")
        except (OSError, ValueError, AttributeError):
            name = ""
        out.append((Path(root), sd, host, name))
    return out


def _owned_name(sd: Path) -> str:
    try:
        return str(json.loads((sd / "remote-owned.json").read_text(encoding="utf-8")).get("project") or "")
    except (OSError, ValueError, AttributeError):
        return ""


def _local_running(name: str) -> bool:
    """맥(로컬 도커)에 그 스택 컨테이너가 하나라도 도는가. 모르면 돈다고 본다(자동으로 풀지 않게)."""
    if not name:
        return True
    env = {k: v for k, v in os.environ.items() if k != "DOCKER_HOST"}
    try:
        r = subprocess.run(["docker", "ps", "-q", "--filter", f"label=com.docker.compose.project={name}"],
                           env=env, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return True
    return r.returncode != 0 or bool(r.stdout.strip())


def _notify(root: Path, msg: str) -> None:
    """그 워크트리의 방에 한 줄 남긴다(잠든 방은 보관 — 깨우지 않는다). 방이 없으면 로그만."""
    entry = Path(__file__).resolve().parent / "marina-entrypoint.sh"
    try:
        out = subprocess.run([str(entry), "session", "ls"], capture_output=True, text=True, timeout=30).stdout
        room = next((ln.split("\t")[0] for ln in out.splitlines()
                     if ln.split("\t")[-1:] == [str(root)]), None)
        if room:
            subprocess.run([str(entry), "session", "room-send", room, msg],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass


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


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def reopen_tunnel(sd: Path, spawn=None) -> "int | None":
    """박스는 닿는데 맥으로 돌아오는 터널(ssh -L)만 죽었으면 적어 둔 같은 명령으로 다시 연다. 새 pid 또는 None.
    (2026-11-09 story-chat: 터널 프로세스가 사라져 게이트웨이 502 — 다시 여는 길이 start 뿐이었다)"""
    tun = sd / "remote-tunnel.pid"
    try:
        lines = tun.read_text(encoding="utf-8").splitlines()
        pid = int(lines[0].split()[0])
        argv = json.loads(lines[1]) if len(lines) > 1 else None
    except (OSError, ValueError, IndexError):
        return None
    if _pid_alive(pid) or not (isinstance(argv, list) and argv and argv[0] == "ssh"):
        return None
    spawn = spawn or (lambda a, log: subprocess.Popen(a, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                                      stderr=log, start_new_session=True).pid)
    try:
        with open(sd / "remote-tunnel.log", "a", encoding="utf-8") as log:
            new = spawn(argv, log)
    except OSError:
        return None
    tun.write_text(f"{new}\n{json.dumps(argv)}\n", encoding="utf-8")
    return new


def tick(roots, misses: dict, log=print, reachable=None, start_local=None, reopen=None,
         local_running=None, notify=None) -> list:
    """한 바퀴. 맥으로 옮긴 root 목록을 돌려준다. misses 는 호출자가 들고 있는 연속 실패·성공 수."""
    import marina_runtime_target as rt
    reachable = reachable or _reachable
    start_local = start_local or _start_local
    reopen = reopen or reopen_tunnel
    local_running = local_running or _local_running
    notify = notify or _notify
    moved, seen = [], set()
    # 맥 고정된 스택: 박스가 몇 분 연속 닿으면 돌아온 것 — 맥이 비었으면 고정을 풀고, 돌고 있으면 방에 한 번 알린다
    for root, sd, host, name in _pinned_stacks(roots):
        k = "ret:" + str(root)
        seen.add(k)
        if not reachable(host):
            misses.pop(k, None)
            continue
        misses[k] = misses.get(k, 0) + 1
        if misses[k] < RETURN_HITS:
            continue
        if not local_running(name):
            rt.unpin_local(str(sd))
            misses.pop(k, None)
            log(f"remote-watch: {host} 박스가 돌아왔고 맥엔 {root} 스택이 없어 맥 고정을 풀었어 — 다음 start 부터 박스")
        elif misses[k] == RETURN_HITS:
            notify(root, f"[마리나] 박스({host})가 돌아왔어. 이 워크트리는 지금 맥에서 도는 중 — 쉬는 틈에 "
                         "'marina stop --all' 뒤 'marina start …' 하면 박스로 옮겨져(맥 DB 내용은 안 따라감).")
            log(f"remote-watch: {host} 박스가 돌아왔지만 {root} 가 맥에서 돌아 방에 알림")
    for root, sd, host in _remote_stacks(roots):
        seen.add(str(root))
        if reachable(host):
            misses.pop(str(root), None)
            new = reopen(sd)
            if new:
                log(f"remote-watch: {root} 터널이 죽어 다시 열었어(pid {new})")
            continue
        misses[str(root)] = misses.get(str(root), 0) + 1
        if misses[str(root)] < MISSES:
            continue
        misses.pop(str(root), None)
        rt.pin_local(str(sd), rt.LocalTarget(fallback_from=host))     # 먼저 고정 — 이후 모든 판단이 맥을 본다
        (sd / "remote-tunnel.pid").unlink(missing_ok=True)            # 죽은 터널 기록(다시 감시하지 않게)
        rc = start_local(root)
        log(f"remote-watch: {host} 가 {MISSES}분째 안 닿아 {root} 를 맥에서 다시 띄움(rc={rc})")
        if rc != 0 and not local_running(_owned_name(sd)):
            rt.unpin_local(str(sd))      # 맥에 아무것도 안 떴다 — 고정을 남기면 박스가 멀쩡해져도 다음 start 가 맥 빌드로 빠진다
            log(f"remote-watch: 맥 기동 실패·맥에 뜬 것 없음 — {root} 맥 고정을 남기지 않음")
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
