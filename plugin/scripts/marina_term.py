"""marina_term.py — 터미널 탭 백엔드: 워크트리 PTY 셸 세션 + SSE 스트림.

모델
- 셸은 매번 새 PTY(같은 워크트리에 N개 가능) — 에이전트 attach 만 키로 재사용(CLI --resume 이중 실행 방지).
- reader 스레드가 master fd → history(링 버퍼, 256KB 캡)로 밀고, 전 세션 공유 Condition 으로 SSE 리스너들을 깨움.
- SSE 는 멀티플렉스 — 한 커넥션에 여러 세션을 싣고 이벤트마다 tid 로 태깅한다(브라우저 오리진당
  6커넥션 한도라 탭마다 스트림을 붙이면 키 입력 fetch 가 굶는다). 세션별로 history 스냅샷(snap)
  먼저, 이후 새 출력 청크(out) → 종료 시 exit. 전부 base64 라 바이너리 안전(UTF-8 경계 무관).
  프론트가 이벤트의 off(절대 오프셋)를 누적해 두면 재접속 때 from 으로 이어받는다.
- 보안: 셸 = 원격 코드 실행. 핸들러 쪽에서 게이트웨이 경유(X-Forwarded-*) 요청을 거부한다(로컬 대시보드 전용).
"""
from __future__ import annotations

import base64
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import subprocess
import termios
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from marina_logtext import redact_text

TERM_SCROLLBACK_BYTES = 256 * 1024
TERM_READ_CHUNK = 8192
TERM_IDLE_TTL = 6 * 3600          # 입출력 없이 6시간 → 정리(요청 시 lazy GC — 별도 스레드 없음)
TERM_HEARTBEAT_S = 15.0           # SSE 유휴 heartbeat — 프록시/브라우저 타임아웃 방지


# 전 세션이 한 Condition 을 공유한다 — 멀티플렉스 스트림이 아무 세션 출력에나 깨어나야 하기 때문.
# 조건변수가 하나뿐이라 중첩 획득이 없어 락 순서 문제도 생기지 않는다.
_COND = threading.Condition()


class _Term:
    def __init__(self, tid: str, root: str, fd: int, pid: int,
                 key: str = "", agent: dict[str, str] | None = None) -> None:
        self.tid, self.root, self.fd, self.pid = tid, root, fd, pid
        self.key = key            # 재사용 키 — 에이전트 세션만 가짐(셸은 "")
        self.agent = agent        # {"source","sid"} | None
        self.cond = _COND         # 공유 — `with term.cond:` 사용부는 그대로 동작
        self.history = bytearray()
        self.base = 0             # history[0] 의 절대 오프셋 — 캡 절단만큼 증가
        self.alive = True
        self.created = time.time()
        self.last = time.time()
        # 사이드바 이름용 — 마지막으로 친 명령. 스크롤백에서 파싱하지 않는 이유:
        # zsh ZLE 가 좁은 칸에서 명령을 CR·EL·커서이동으로 다시 그려서(45칼럼에선 `npm run b`+`uild` 로
        # 두 줄에 걸친다) 어느 한 줄에도 원문이 없다. 복원하려면 터미널 에뮬레이터를 새로 써야 한다.
        # 반면 **형이 친 바이트는 term_input 으로 그대로 들어온다** — 여기서 잡으면 에뮬레이션이 필요 없다.
        self.typed = ""       # 지금 치고 있는 줄
        self.cmd = ""         # 엔터로 확정된 마지막 명령
        self.esc = False      # 이스케이프 시퀀스 도중(↑ 는 \x1b[A — ESC 만 버리면 `[A` 가 이름이 된다)

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
_by_key: dict[str, _Term] = {}    # 에이전트 세션만 — 셸은 매번 새로 연다


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
    """유휴 세션 종료 + 죽은 세션 수거. term_open·term_list 마다 호출된다.

    죽은 term 을 놓아주는 게 중요하다 — 셸이 워크트리당 1개가 아니라 무제한이라
    사용자가 exit 를 칠 때마다 history(최대 256KB)를 문 시체가 쌓인다.
    이미 붙어있는 SSE 스트림은 term 객체를 직접 참조하니 맵에서 빼도 exit 통지는 정상 동작한다.
    """
    now = time.time()
    with _lock:
        stale = [t for t in _by_tid.values() if t.alive and now - t.last > TERM_IDLE_TTL]
        for t in [t for t in _by_tid.values() if not t.alive]:
            _by_tid.pop(t.tid, None)
            if t.key and _by_key.get(t.key) is t:
                _by_key.pop(t.key, None)
    for t in stale:
        try:
            term_kill(t.tid)
        except ValueError:   # 그 사이 자연사→수거됨(다른 요청의 _reap_idle) — 목적은 이미 달성
            pass


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
    """root 워크트리에 새 PTY 세션을 연다(셸은 매번 새로 — 같은 워크트리에 여러 개 가능).
    기본은 $SHELL -il, agent_source/sid 를 주면 그 CLI 세션에 resume 으로 붙는다(살아있으면 재사용 — 이중 실행 방지)."""
    _reap_idle()
    cwd = str(root.resolve())
    if not Path(cwd).is_dir():
        raise ValueError("존재하지 않는 워크트리")
    cmd = ""
    key = ""
    agent = None
    if agent_source:
        if agent_source not in _AGENT_CLIS:
            raise ValueError("unknown agent source")
        if not _SID_RE.fullmatch(agent_sid or ""):
            raise ValueError("invalid session id")
        cmd = _AGENT_CLIS[agent_source](agent_sid)
        key = f"{cwd}::agent:{agent_source}:{agent_sid}"
        agent = {"source": agent_source, "sid": agent_sid}
    with _lock:
        if key:                                  # 에이전트만 재사용 — resume 이중 실행 방지
            existing = _by_key.get(key)
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
        term = _Term(uuid.uuid4().hex[:16], cwd, fd, pid, key, agent)
        _by_tid[term.tid] = term
        if key:
            _by_key[key] = term
        threading.Thread(target=_reader, args=(term,), daemon=True, name=f"term-{term.tid}").start()
        return {"tid": term.tid, "reused": False}


def _get(tid: str) -> _Term:
    term = _by_tid.get(tid or "")
    if not term:
        raise ValueError("터미널 세션이 없어요 (만료/재시작)")
    return term


def _note_typed(term: _Term, data: str) -> None:
    """친 글자를 모아 엔터에서 명령으로 확정 — 사이드바 이름의 근거(_Term.typed/cmd 주석 참조).

    화살표·히스토리(↑) 같은 제어 시퀀스는 못 따라간다 — 그때는 마지막으로 **친** 명령이 남는다.
    틀린 이름을 지어내는 것보다 낫고, 실행 중이면 어차피 fg(ps)가 정확하다.
    """
    for ch in data:
        if term.esc:                  # 시퀀스 끝(최종 바이트)까지 통째로 버린다
            if ch.isalpha() or ch == "~":
                term.esc = False
            continue
        if ch == "\x1b":              # ↑ 는 \x1b[A — ESC 만 버리면 `[A` 가 이름이 된다(테스트가 잡았다)
            term.esc = True
        elif ch in ("\r", "\n"):
            line = term.typed.strip()
            if line:
                term.cmd = redact_text(line)[:60]
            term.typed = ""
        elif ch in ("\x7f", "\b"):
            term.typed = term.typed[:-1]
        elif ch == "\x03":            # Ctrl-C — 치던 줄을 버린다
            term.typed = ""
        elif ch >= " ":               # 그 외 제어문자는 무시
            term.typed += ch


def term_input(tid: str, data: str) -> dict[str, Any]:
    term = _get(tid)
    if not term.alive:
        raise ValueError("세션이 이미 종료됐어요")
    os.write(term.fd, data.encode("utf-8"))
    _note_typed(term, data)
    term.last = time.time()
    return {"ok": True}


def term_resize(tid: str, cols: int, rows: int) -> dict[str, Any]:
    term = _get(tid)
    if term.alive:
        _set_winsize(term.fd, cols, rows)
    return {"ok": True}


# 사이드바 라벨용 — "셸 1" 은 어느 게 어느 건지 안 알려준다. tmux 가 창 이름을 실행 중인 프로그램으로
# 짓는 것과 같은 이유로, 지금 포그라운드에 있는 명령을 이름으로 쓴다.
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")   # 터미널 제목 설정 등 — 화면에 안 보이는 것
# 뒤에 아무것도 안 붙은 프롬프트("… %", "… $", "…>") — 입력 대기 상태라 부제로 쓸 값이 없다
_BARE_PROMPT_RE = re.compile(r"[%$#>]\s*$")
# 명령을 친 줄에서 프롬프트 접두사를 뗀다("user@host dir % npm run dev" → "npm run dev").
# 사이드바가 178px 라 안 떼면 잘려서 호스트명만 보인다. 앵커를 user@host 형태로 좁게 잡아
# 출력 줄("Progress: 50% done")이 걸려들지 않게 했다 — 안 맞으면 줄을 그대로 둔다(degrade).
_PROMPT_PREFIX_RE = re.compile(r"^\S+@\S+\s+\S+\s*[%$#]\s+")


def _apply_bs(text: str) -> str:
    """백스페이스를 실제로 적용 — zsh 자동완성이 `s\\bsleep` 처럼 쓰고 지운다.
    그냥 제거하면 `ssleep` 이 된다."""
    out: list[str] = []
    for ch in text:
        if ch == "\b":
            if out:
                out.pop()
        else:
            out.append(ch)
    return "".join(out)


def _fg_command(term: _Term) -> str:
    """포그라운드 프로세스 그룹의 명령. 셸 자신이면 빈 문자열(zsh 를 이름으로 쓰면 알아볼 게 없다)."""
    try:
        pgid = os.tcgetpgrp(term.fd)
    except OSError:
        return ""
    if pgid <= 0 or pgid == term.pid:      # 셸 자신 = 유휴
        return ""
    try:
        out = subprocess.run(["ps", "-o", "command=", "-p", str(pgid)],
                             capture_output=True, text=True, timeout=2).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.splitlines()[0][:60] if out else ""


def _preview(term: _Term) -> str:
    """사이드바 부제 — 마지막으로 **의미 있는** 출력 줄.

    그냥 마지막 줄을 집으면 유휴 세션은 늘 빈 프롬프트(`user@host dir %`)라 아무것도 못 알려준다.
    눈이 하는 대로 끝의 빈 프롬프트는 건너뛰고 그 앞(=명령의 답)을 집는다.

    **출력 줄에만 쓴다.** 명령 이름은 여기서 파싱하지 않는다 — zsh ZLE 가 명령 에코를 CR·EL 로 다시
    그려서 복원하려면 에뮬레이터가 필요하다(_Term.typed 주석). 반면 프로그램 출력은 그런 재렌더를
    안 거쳐서 이 정도 정리로 충분하다.

    끝 4KB 만 본다(링버퍼 전체를 매 폴링마다 디코드하면 256KB×세션수).
    **redact_text 를 반드시 태운다** — 셸 스크롤백엔 비밀값이 섞이고, 사이드바는 늘 떠 있다.
    """
    with term.cond:
        tail = bytes(term.history[-4096:])
    text = _OSC_RE.sub("", _ANSI_RE.sub("", tail.decode("utf-8", "replace"))).replace("\r", "\n")
    lines = [_apply_bs(ln).strip() for ln in text.splitlines()]
    for ln in reversed(lines):
        if not ln or _BARE_PROMPT_RE.search(ln):   # 빈 줄·입력 대기 중인 프롬프트 — 넘긴다
            continue
        return redact_text(_PROMPT_PREFIX_RE.sub("", ln))[:80]
    return ""


def term_list() -> dict[str, Any]:
    """살아있는 세션 목록 — 프론트가 새로고침 후 tid 를 되찾는 유일한 길(고아 PTY 방지).
    오프셋은 싣지 않는다: 재개(from)의 기준값은 SSE 이벤트의 off 로 프론트가 누적한다.
    fg/cmd/preview 는 사이드바 라벨용 — 뷰가 이 목록을 주기적으로 다시 받아 이름을 신선하게 유지한다."""
    _reap_idle()
    with _lock:
        terms = sorted(_by_tid.values(), key=lambda t: t.created)
    return {"sessions": [{"tid": t.tid, "root": t.root, "agent": t.agent,
                          "fg": _fg_command(t), "cmd": t.cmd, "preview": _preview(t),
                          "created": t.created, "alive": t.alive} for t in terms]}


def term_kill(tid: str) -> dict[str, Any]:
    term = _get(tid)
    try:
        os.kill(term.pid, signal.SIGHUP)
    except OSError:
        pass
    term.mark_dead()
    with _lock:
        _by_tid.pop(term.tid, None)
        if term.key and _by_key.get(term.key) is term:
            _by_key.pop(term.key, None)
    return {"ok": True}


def term_stream(handler: Any, tids: list[str], froms: dict[str, int] | None = None) -> None:
    """멀티플렉스 SSE — 한 커넥션에 여러 세션을 싣는다(브라우저 오리진당 6커넥션 한도 회피).

    event: snap → {"tid","b64","off"}   스크롤백 스냅샷(최초 구독, 또는 from 이 잘려나간 갭)
    event: out  → {"tid","b64","off"}   신규 청크
    event: exit → {"tid"}               그 세션 종료
    handler 는 BaseHTTPRequestHandler.
    """
    froms = froms or {}
    if isinstance(tids, str):   # str 도 iterable — 그냥 두면 글자 단위로 순회해 200 OK 에
        raise TypeError("tids 는 list[str] — 문자열이면 글자 단위로 순회된다")   # 글자마다 가짜 exit 을 뱉는다
    # 중복 tid 제거(순서 유지) — 같은 tid 가 둘이면 terms 는 2, exited(집합)는 1 이라 종료 조건이
    # 영영 안 맞아 스트림이 안 끝난다(스레드·커넥션 슬롯 누수). 쿼리스트링은 신뢰할 수 없다.
    tids = list(dict.fromkeys(tids or []))
    if not tids:
        raise ValueError("tid 가 없어요")
    # 모르는 tid 는 건너뛰고 exit 으로 통지한다 — raise 하면 썩은 tid 하나가 살아있는 터미널 전부의
    # 스트림을 400 으로 죽이고, 프론트는 캐시된 목록으로 재연결을 되풀이해 영구히 물린다
    # (SSE 끊긴 사이 세션이 죽고 다른 요청의 _reap_idle 이 수거하면 발생 — 노트북 sleep/wake 조합).
    # 한 번만 순회해 스냅샷(found)을 뜬다 — terms·gone 이 같은 스냅샷에서 파생돼야 서로소다.
    # 따로 두 번 읽으면 그 사이 _reap_idle 이 떨군 tid 가 양쪽에 들어가 exit 이 두 번 나간다.
    # 락은 필요 없다: 서로소를 만드는 건 단일 pass 지 락이 아니고, tid 간 전역 원자 뷰를 요구하는
    # 불변식도 없다(스트림은 tid 별로 독립). 해석 직후 reap 된 term 은 t.alive 로 걸러져 exit 된다.
    # 여기서 _lock 을 잡으면 스트림 셋업이 term_open 의 pty.fork() 보유 구간에 묶이기까지 한다.
    found = [(x, _by_tid.get(x)) for x in tids]
    terms = [t for _, t in found if t]
    gone = [x for x, t in found if t is None]
    handler.send_response(200)
    handler.send_header("content-type", "text/event-stream")
    handler.send_header("cache-control", "no-cache")
    handler.end_headers()

    def send(event: str, obj: dict[str, Any]) -> bool:
        try:
            handler.wfile.write(f"event: {event}\ndata: {json.dumps(obj)}\n\n".encode())
            handler.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    def chunk_ev(tid: str, event: str, payload: bytes, off: int) -> bool:
        return send(event, {"tid": tid, "b64": base64.b64encode(payload).decode(), "off": off})

    offsets: dict[str, int] = {}
    initial: list[tuple[str, str, bytes, int]] = []
    for t in terms:
        with _COND:            # tid 마다 잡았다 놓는다 — 스트림끼리 독립이라 전역 원자 스냅샷이 필요 없고,
            end = t.base + len(t.history)      # 8세션×256KB 를 한 번에 들고 복사하면 그동안 모든 PTY reader 가 멈춘다
            frm = froms.get(t.tid)
            if frm is None or frm < t.base or frm > end:      # 최초 구독이거나 링버퍼에서 잘려나간 갭
                initial.append((t.tid, "snap", bytes(t.history), end))
            elif end > frm:
                initial.append((t.tid, "out", bytes(t.history[frm - t.base:]), end))
            offsets[t.tid] = end
    for tid, event, payload, off in initial:
        if not chunk_ev(tid, event, payload, off):
            return
    for tid in gone:                    # 이미 사라진 tid — 프론트가 목록에서 쳐내도록
        if not send("exit", {"tid": tid}):
            return
    if not terms:
        return

    exited: set[str] = set()
    last_beat = time.time()
    while True:
        with _COND:
            _COND.wait(timeout=1.0)
            pending: list[tuple[str, str, bytes, int]] = []
            for t in terms:
                end = t.base + len(t.history)
                off = offsets[t.tid]
                if end > off:
                    start = max(off, t.base)
                    pending.append((t.tid, "out", bytes(t.history[start - t.base:end - t.base]), end))
                    offsets[t.tid] = end
            dead = [t.tid for t in terms if not t.alive and t.tid not in exited]
        for tid, event, payload, off in pending:               # 출력 먼저, exit 나중 — 마지막 줄이 잘리지 않게
            if not chunk_ev(tid, event, payload, off):
                return
            last_beat = time.time()
        for tid in dead:
            exited.add(tid)
            if not send("exit", {"tid": tid}):
                return
        if len(exited) == len(terms):
            return
        if time.time() - last_beat > TERM_HEARTBEAT_S:
            if not send("ping", {}):
                return
            last_beat = time.time()
