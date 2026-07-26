#!/usr/bin/env python3
"""에이전트 세션(sid) ↔ 프로세스(pid) 등록부 — 훅이 남기고 marina 가 읽는다.

**왜 필요한가.** marina 는 자기가 CLI 를 띄운 PTY 에 대해서만 (source, sid) 를 안다
(`term_open(agent_source=...)`). 형이 marina 터미널에서 셸을 열고 손으로 `claude` 를 치면
그 PTY 안에 어떤 세션이 도는지 알 방법이 없어 제어(질문 응답·메시지 전송)가 통째로 막힌다.
ps argv 에서 sid 를 캐던 옛 방식은 프롬프트의 따옴표에 파싱이 깨져 폐기됐다(유휴 오탐의 뿌리).

**어떻게 푸는가.** 훅 프로세스는 에이전트 CLI 의 자손이라 그 프로세스 트리 안에 있다.
훅이 {source, sid, pid} 를 남겨두면 marina 는 pid 조상 체인만 타고 PTY(tid)를 정확히 찾는다
— 추측도, argv 파싱도 없다.

fail-open: 어떤 예외든 조용히 무시한다(에이전트 흐름을 막지 않는다).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any

_SID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{2,160}")
_AGENT_COMMS = {"claude": "claude", "codex": "codex"}
# 등록 기록이 이보다 오래되면 무시한다 — 훅이 죽은 뒤 pid 가 재사용되는 창을 좁힌다.
# (pid_start 지문이 1차 방어이고, 이건 2차.)
MAX_RECORD_AGE_S = float(os.environ.get("MARINA_AGENT_PROC_MAX_AGE_S", str(24 * 3600)))


def _home() -> Path:
    return Path(os.environ.get("MARINA_HOME") or (Path.home() / ".marina"))


def _dir() -> Path:
    return _home() / "agent-procs"


def _record_path(source: str, sid: str) -> Path:
    return _dir() / f"{source}-{sid}.json"


def _pid_start(pid: int) -> str:
    """pid 재사용 방어용 시작시각 지문 — marina_term._pid_start 와 같은 방식."""
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], check=False,
                             capture_output=True, text=True, timeout=1)
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def ps_table() -> dict[int, tuple[int, str]]:
    """pid → (ppid, comm). 조상 체인 추적용 — 한 번의 ps 로 끝낸다."""
    table: dict[int, tuple[int, str]] = {}
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], check=False,
                             capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.SubprocessError):
        return table
    for line in out.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        table[pid] = (ppid, parts[2].strip())
    return table


def ancestors(pid: int, table: dict[int, tuple[int, str]], limit: int = 40) -> list[int]:
    """pid 의 조상 pid 들(자기 자신 제외, 가까운 순). 순환/고아에 대비해 상한을 둔다."""
    chain: list[int] = []
    seen = {pid}
    current = pid
    for _ in range(limit):
        entry = table.get(current)
        if not entry:
            break
        parent = entry[0]
        if parent <= 1 or parent in seen:
            break
        chain.append(parent)
        seen.add(parent)
        current = parent
    return chain


def _agent_pid(source: str, table: dict[int, tuple[int, str]]) -> int:
    """훅 자신의 조상 중 에이전트 CLI 프로세스를 찾는다.

    빠른 경로로 CLAUDE_PID 를 쓰되, 반드시 '내 조상이 맞는지' 검증한다 — 검증 없이 믿으면
    다른 세션의 pid 를 물려받은 하위 프로세스가 남의 세션을 자기 것으로 등록할 수 있다.
    """
    want = _AGENT_COMMS.get(source, "")
    chain = ancestors(os.getpid(), table)
    env_pid = 0
    try:
        env_pid = int(os.environ.get("CLAUDE_PID") or 0)
    except ValueError:
        env_pid = 0
    if source == "claude" and env_pid in chain:
        return env_pid
    for pid in chain:
        comm = (table.get(pid) or (0, ""))[1]
        if Path(comm).name == want:
            return pid
    return 0


def record_from_hook(payload: Any, source: str = "") -> None:
    """훅 페이로드로 {source, sid, pid} 를 남긴다. 실패는 전부 삼킨다(fail-open).

    source 는 호출자(marina_agent_events._source)가 이미 정규화해 넘긴다 — 판정을 두 벌
    유지하지 않는다. 없으면 페이로드 모양으로만 최소 추정한다.
    """
    try:
        if not isinstance(payload, dict):
            return
        sid = str(payload.get("session_id") or payload.get("thread_id") or "").strip()
        if not _SID_RE.fullmatch(sid):
            return
        if source not in _AGENT_COMMS:
            source = "codex" if payload.get("thread_id") and not payload.get("session_id") else "claude"
        table = ps_table()
        pid = _agent_pid(source, table)
        if pid <= 1:
            return
        directory = _dir()
        directory.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(directory, 0o700)
        except OSError:
            pass
        record = {
            "source": source,
            "sid": sid,
            "pid": pid,
            "pidStart": _pid_start(pid),
            "cwd": str(payload.get("cwd") or ""),
            "ts": time.time(),
        }
        target = _record_path(source, sid)
        tmp = target.with_suffix(".tmp")
        tmp.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, target)
        try:
            os.chmod(target, 0o600)
        except OSError:
            pass
    except Exception:
        pass


def _alive(pid: int, pid_start: str) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    if not pid_start:
        return True                       # 지문 없음 — fail-open(살아있다고 본다)
    return _pid_start(pid) == pid_start    # pid 재사용이면 시작시각이 다르다


def lookup(source: str, sid: str) -> dict[str, Any] | None:
    """살아있는 등록 기록만 돌려준다. 죽었거나 낡았으면 정리하고 None."""
    try:
        path = _record_path(source, sid)
        record = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(record, dict):
            return None
        pid = int(record.get("pid") or 0)
        if time.time() - float(record.get("ts") or 0) > MAX_RECORD_AGE_S:
            path.unlink(missing_ok=True)
            return None
        if not _alive(pid, str(record.get("pidStart") or "")):
            path.unlink(missing_ok=True)
            return None
        return record
    except (OSError, ValueError, TypeError):
        return None


def live_records() -> list[dict[str, Any]]:
    """살아있는 등록 기록 전부 — 입양(adoption)이 훑는 입력."""
    out: list[dict[str, Any]] = []
    try:
        entries = sorted(_dir().iterdir())
    except OSError:
        return out
    for entry in entries:
        if entry.suffix != ".json":
            continue
        try:
            record = json.loads(entry.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(record, dict):
            continue
        source, sid = str(record.get("source") or ""), str(record.get("sid") or "")
        if source not in _AGENT_COMMS or not _SID_RE.fullmatch(sid):
            continue
        if lookup(source, sid) is None:    # 살아있음 검증 + 죽은 기록 정리
            continue
        out.append(record)
    return out


def forget(source: str, sid: str) -> None:
    try:
        _record_path(source, sid).unlink(missing_ok=True)
    except OSError:
        pass
