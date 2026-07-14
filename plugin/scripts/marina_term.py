"""marina_term.py — 터미널 탭 백엔드: 워크트리별 PTY 셸 세션 + SSE 스트림.

모델
- 워크트리(root)당 PTY 1개 재사용 — 탭을 떠났다 돌아와도 세션·스크롤백 유지.
- reader 스레드가 master fd → history(링 버퍼, 256KB 캡)로 밀고 Condition 으로 SSE 리스너들을 깨움.
- SSE 접속 시 history 스냅샷(base64) 먼저, 이후 새 출력 청크를 push. 바이너리 안전(UTF-8 경계 무관).
- 보안: 셸 = 원격 코드 실행. 핸들러 쪽에서 게이트웨이 경유(X-Forwarded-*) 요청을 거부한다(로컬 대시보드 전용).
"""
from __future__ import annotations

import base64
import fcntl
import os
import pty
import re
import select
import signal
import struct
import termios
import threading
import time
import uuid
from pathlib import Path
from typing import Any

TERM_SCROLLBACK_BYTES = 256 * 1024
TERM_READ_CHUNK = 8192
TERM_IDLE_TTL = 6 * 3600          # 입출력 없이 6시간 → 정리(reap 스레드)
TERM_HEARTBEAT_S = 15.0           # SSE 유휴 heartbeat — 프록시/브라우저 타임아웃 방지


class _Term:
    def __init__(self, tid: str, root: str, fd: int, pid: int) -> None:
        self.tid, self.root, self.fd, self.pid = tid, root, fd, pid
        self.cond = threading.Condition()
        self.history = bytearray()
        self.base = 0             # history[0] 의 절대 오프셋 — 캡 절단만큼 증가
        self.alive = True
        self.last = time.time()

    def append(self, data: bytes) -> None:
        with self.cond:
            self.history += data
            overflow = len(self.history) - TERM_SCROLLBACK_BYTES
            if overflow > 0:
                del self.history[:overflow]
                self.base += overflow
            self.last = time.time()
            self.cond.notify_all()

    def mark_dead(self) -> None:
        with self.cond:
            self.alive = False
            self.cond.notify_all()


_lock = threading.Lock()
_by_tid: dict[str, _Term] = {}
_by_root: dict[str, _Term] = {}


def _set_winsize(fd: int, cols: int, rows: int) -> None:
    cols = max(10, min(500, int(cols or 80)))
    rows = max(4, min(200, int(rows or 24)))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def _reader(term: _Term) -> None:
    while True:
        try:
            ready, _, _ = select.select([term.fd], [], [], 1.0)
        except OSError:
            break
        if term.fd not in ready:
            continue
        try:
            data = os.read(term.fd, TERM_READ_CHUNK)
        except OSError:
            data = b""
        if not data:
            break
        term.append(data)
    term.mark_dead()
    try:
        os.close(term.fd)
    except OSError:
        pass
    try:
        os.waitpid(term.pid, os.WNOHANG)
    except OSError:
        pass


def _reap_idle() -> None:
    now = time.time()
    with _lock:
        stale = [t for t in _by_tid.values() if t.alive and now - t.last > TERM_IDLE_TTL]
    for t in stale:
        term_kill(t.tid)


# 에이전트 attach(오르카 문법) — 좌측 AGENTS 행에 터미널로 바로 붙는다: 새 PTY 에서 CLI resume.
# 셸 -ilc 경유(rc 로드 → PATH/노드 버전 등 사용자 환경 그대로). sid 는 정규식 검증 후에만 문자열 조립.
# resume 명령을 셸 문자열이 아니라 argv 로 조립 → 셸 인용/인젝션 걱정 원천 제거. `--` 로 옵션 종료해
# sid 가 CLI 플래그로 해석되는 것도 차단(codex P2). sid 정규식은 leading `-` 도 금지(이중 안전).
_AGENT_CLIS = {
    "claude": lambda sid: ["claude", "--resume", "--", sid],
    "codex": lambda sid: ["codex", "resume", "--", sid],
}
_SID_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]{3,63}")


def term_open(root: Path, cols: int = 80, rows: int = 24,
              agent_source: str = "", agent_sid: str = "") -> dict[str, Any]:
    """root 워크트리의 PTY 세션 — 살아있으면 재사용(스크롤백 유지).
    기본은 $SHELL -il, agent_source/sid 를 주면 그 CLI 세션에 resume 으로 붙는다(워크트리·에이전트별 별도 세션)."""
    _reap_idle()
    cwd = str(root.resolve())
    if not Path(cwd).is_dir():
        raise ValueError("존재하지 않는 워크트리")
    cmd = ""
    key = cwd
    if agent_source:
        if agent_source not in _AGENT_CLIS:
            raise ValueError("unknown agent source")
        if not _SID_RE.fullmatch(agent_sid or ""):
            raise ValueError("invalid session id")
        cmd = _AGENT_CLIS[agent_source](agent_sid)
        key = f"{cwd}::agent:{agent_source}:{agent_sid}"
    with _lock:
        existing = _by_root.get(key)
        if existing and existing.alive:
            _set_winsize(existing.fd, cols, rows)
            return {"tid": existing.tid, "reused": True}
        pid, fd = pty.fork()
        if pid == 0:  # 자식 — 즉시 exec (스레드 안전을 위해 그 사이 파이썬 코드 최소화)
            try:
                os.chdir(cwd)
            except OSError:
                pass
            shell = os.environ.get("SHELL") or "/bin/zsh"
            env = dict(os.environ, TERM="xterm-256color", MARINA_TERM="1")
            # 로그인 셸 env 는 유지하되 명령은 argv 로 — `-c 'exec "$@"' <sh> <argv…>` 패턴이라
            # sid 가 셸에 재파싱되지 않는다(문자열 조립 인젝션 원천 차단, codex P2).
            argv = [shell, "-il", "-c", 'exec "$@"', shell, *cmd] if cmd else [shell, "-il"]
            try:
                os.execvpe(shell, argv, env)
            except OSError:
                os._exit(127)
        _set_winsize(fd, cols, rows)
        term = _Term(uuid.uuid4().hex[:16], key, fd, pid)
        _by_tid[term.tid] = term
        _by_root[key] = term
        threading.Thread(target=_reader, args=(term,), daemon=True, name=f"term-{term.tid}").start()
        return {"tid": term.tid, "reused": False}


def _get(tid: str) -> _Term:
    term = _by_tid.get(tid or "")
    if not term:
        raise ValueError("터미널 세션이 없어요 (만료/재시작)")
    return term


def term_input(tid: str, data: str) -> dict[str, Any]:
    term = _get(tid)
    if not term.alive:
        raise ValueError("세션이 이미 종료됐어요")
    os.write(term.fd, data.encode("utf-8"))
    term.last = time.time()
    return {"ok": True}


def term_resize(tid: str, cols: int, rows: int) -> dict[str, Any]:
    term = _get(tid)
    if term.alive:
        _set_winsize(term.fd, cols, rows)
    return {"ok": True}


def term_kill(tid: str) -> dict[str, Any]:
    term = _get(tid)
    try:
        os.kill(term.pid, signal.SIGHUP)
    except OSError:
        pass
    term.mark_dead()
    with _lock:
        _by_tid.pop(term.tid, None)
        if _by_root.get(term.root) is term:
            _by_root.pop(term.root, None)
    return {"ok": True}


def term_stream(handler: Any, tid: str) -> None:
    """SSE — event:snap(스크롤백 스냅샷) → data(신규 청크, base64) → event:exit. handler 는 BaseHTTPRequestHandler."""
    term = _get(tid)
    handler.send_response(200)
    handler.send_header("content-type", "text/event-stream")
    handler.send_header("cache-control", "no-cache")
    handler.end_headers()

    def send(event: str | None, payload: bytes) -> bool:
        head = f"event: {event}\n" if event else ""
        try:
            handler.wfile.write(f"{head}data: {base64.b64encode(payload).decode()}\n\n".encode())
            handler.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    with term.cond:
        snapshot = bytes(term.history)
        offset = term.base + len(term.history)
    if not send("snap", snapshot):
        return
    last_beat = time.time()
    while True:
        with term.cond:
            term.cond.wait(timeout=1.0)
            end = term.base + len(term.history)
            if end > offset:
                start = max(offset, term.base)
                chunk = bytes(term.history[start - term.base : end - term.base])
                offset = end
            else:
                chunk = b""
            alive = term.alive
        if chunk:
            if not send(None, chunk):
                return
            last_beat = time.time()
        if not alive:
            send("exit", b"")
            return
        if time.time() - last_beat > TERM_HEARTBEAT_S:
            if not send("ping", b""):
                return
            last_beat = time.time()
