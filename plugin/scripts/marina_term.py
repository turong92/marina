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
from marina_state import MARINA_HOME

TERM_SCROLLBACK_BYTES = 256 * 1024
TERM_READ_CHUNK = 8192
TERM_IDLE_TTL = 6 * 3600          # 입출력 없이 6시간 → 정리(요청 시 lazy GC — 별도 스레드 없음)
TERM_HEARTBEAT_S = 15.0           # SSE 유휴 heartbeat — 프록시/브라우저 타임아웃 방지


# 전 세션이 한 Condition 을 공유한다 — 멀티플렉스 스트림이 아무 세션 출력에나 깨어나야 하기 때문.
# 조건변수가 하나뿐이라 중첩 획득이 없어 락 순서 문제도 생기지 않는다.
_COND = threading.Condition()


class _Term:
    def __init__(self, tid: str, root: str, fd: int, pid: int,
                 key: str = "", agent: dict[str, str] | None = None,
                 detached: bool = False, pid_start: str = "") -> None:
        self.tid, self.root, self.fd, self.pid = tid, root, fd, pid
        self.key = key            # 재사용 키 — 에이전트 세션만 가짐(셸은 "")
        self.agent = agent        # {"source","sid"} | None
        # detached(adopted): marina-control 재시작 후 디스크 메타에서 복원된 term.
        # 프로세스는 아직 살아있지만 그 PTY master fd 는 옛 프로세스와 함께 죽었다 → fd=-1.
        # reachability(term_list)·reuse-by-key·waiting 승격엔 유효하되 term_input/resize/stream 은 불가.
        self.detached = detached
        # pid 재사용 방어용 프로세스 시작시각 지문(ps -o lstart=). detached term 의 SIGHUP 을
        # 무관 프로세스에 쏘지 않으려 재구성/kill 시 대조한다. "" = 검증 불가(fail-open, os.kill 만).
        self.pid_start = pid_start
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


# ── PTY 레지스트리 영속화 ──────────────────────────────────────────────────
# _by_tid/_by_key 는 프로세스-인메모리라 marina-control 재시작 시 통째로 날아간다. 그러면 아직
# 도는 에이전트 프로세스가 tid 를 잃어 mobile 이 "도달 불가"로 배달을 거부하고, reuse-by-key 가
# 빗나가 resume 이 이중 실행되며, completed→waiting 승격이 깨진다. 그래서 최소 메타를 디스크에
# 남기고 부팅 때 프로세스 생존을 검증해 재구성한다. **모든 IO 는 fail-open** — 영속화가 살아있는
# 터미널 흐름을 절대 깨서는 안 된다.
_reconstructed = False


def _terms_dir() -> Path:
    return MARINA_HOME / "terms"


def _term_meta_path(tid: str) -> Path:
    return _terms_dir() / f"{tid}.json"


def _persist_term(term: _Term) -> None:
    """term 메타를 디스크에 원자적으로(tmp+rename) 기록. fail-open."""
    try:
        d = _terms_dir()
        d.mkdir(parents=True, exist_ok=True)
        agent = term.agent or {}
        meta = {
            "tid": term.tid,
            "cwd": term.root,
            "pid": term.pid,
            "pid_start": term.pid_start or _pid_start(term.pid),   # pid 재사용 방어 지문(fail-open="")
            "source": str(agent.get("source") or ""),
            "sid": str(agent.get("sid") or ""),
            "key": term.key or "",
            "created": term.created,
        }
        p = _term_meta_path(term.tid)
        tmp = p.parent / (p.name + ".tmp")
        tmp.write_text(json.dumps(meta), encoding="utf-8")
        os.replace(tmp, p)
    except OSError:
        pass


def _delete_term_file(tid: str) -> None:
    """term 메타 파일 삭제. fail-open(없어도 무방)."""
    try:
        _term_meta_path(tid).unlink()
    except OSError:
        pass


def _pid_alive(pid: int) -> bool:
    """os.kill(pid,0) 로 생존 확인 — ProcessLookupError=죽음, PermissionError=살아있음(다른 유저)."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


_pending_reap: set[int] = set()   # 우리가 fork 한 PTY 자식 — 수거될 때까지 들고 있는다


def _reap_children() -> None:
    """끝난 PTY 자식을 거둔다. 못 거둔 건 다음 스윕에서 다시 시도한다.

    EOF 직후 waitpid(WNOHANG) 를 **한 번만** 부르면, 그 순간 자식이 아직 종료 전이면 빈손으로
    돌아오고 그 좀비를 다시 거둘 사람이 없어 프로세스 테이블에 영구히 남는다(실측: 세션을 외부에서
    kill 했더니 <defunct> 잔류). 그래서 등록해두고 폴마다 재시도한다.

    waitpid(-1) 로 싹쓸이하지 않는 이유: marina 는 git/ps 를 subprocess 로 계속 부르는데,
    그 자식을 가로채면 subprocess 쪽이 ECHILD 로 깨진다. 우리 pid 만 지목해서 거둔다.
    """
    for pid in list(_pending_reap):
        try:
            done, _ = os.waitpid(pid, os.WNOHANG)
        except OSError:               # ChildProcessError 포함 — 우리 자식이 아니거나 이미 수거됨
            _pending_reap.discard(pid)
            continue
        if done:
            _pending_reap.discard(pid)


def _register_reap(pid: int) -> None:
    if pid > 1:
        _pending_reap.add(pid)
    _reap_children()


def _pid_start(pid: int) -> str:
    """프로세스 시작시각 지문(ps -o lstart=) — pid 재사용 판별용. fail-open 시 ""(검증 불가)."""
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=2).stdout.strip()
        return out.splitlines()[0].strip() if out else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def _reconstruct_registry() -> None:
    """부팅 시 1회 — terms/*.json 을 읽어 생존 프로세스를 fd 없는(detached) term 으로 재등록.
    첫 term_open/term_list 에서 lazy 하게 한 번만 돈다(import-time 부작용·레이스 회피). fail-open."""
    global _reconstructed
    with _lock:
        if _reconstructed:
            return
        _reconstructed = True
        try:
            files = list(_terms_dir().glob("*.json"))
        except OSError:
            return
        for f in files:
            try:
                meta = json.loads(f.read_text(encoding="utf-8"))
            except ValueError:            # 파싱 불가 JSON — 영영 복원 못 하니 정리(매 부팅 재읽기 방지)
                _delete_term_file_by(f)
                continue
            except OSError:               # 읽기 자체 실패 — 파일은 두고 다음 기회에(fail-open)
                continue
            if not isinstance(meta, dict):
                _delete_term_file_by(f)
                continue
            tid = str(meta.get("tid") or "")
            cwd = str(meta.get("cwd") or "")
            pid = meta.get("pid")
            if not tid or not cwd or not isinstance(pid, int):   # 손상 — 복원 불가
                _delete_term_file_by(f)
                continue
            if tid in _by_tid:                                   # 이미 살아있는 term — 덮지 않는다
                continue
            if not _pid_alive(pid):                              # 죽은 프로세스 — 파일 정리
                _delete_term_file_by(f)
                continue
            pid_start = str(meta.get("pid_start") or "")
            if pid_start and _pid_start(pid) != pid_start:       # pid 재사용 — 무관 프로세스, 복원 금지
                _delete_term_file_by(f)
                continue
            source = str(meta.get("source") or "")
            sid = str(meta.get("sid") or "")
            key = str(meta.get("key") or "")
            agent = {"source": source, "sid": sid} if source else None
            term = _Term(tid, cwd, -1, pid, key, agent, detached=True, pid_start=pid_start)
            created = meta.get("created")
            if isinstance(created, (int, float)):
                term.created = float(created)
            term.last = time.time()   # 복원 시점 기준 — 유휴 TTL 로 살아있는 에이전트를 SIGHUP 하지 않게
            _by_tid[tid] = term
            if key and key not in _by_key:
                _by_key[key] = term


def _delete_term_file_by(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass


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
    _register_reap(term.pid)


def _reap_idle() -> None:
    """유휴 세션 종료 + 죽은 세션 수거. term_open·term_list 마다 호출된다.

    죽은 term 을 놓아주는 게 중요하다 — 셸이 워크트리당 1개가 아니라 무제한이라
    사용자가 exit 를 칠 때마다 history(최대 256KB)를 문 시체가 쌓인다.
    이미 붙어있는 SSE 스트림은 term 객체를 직접 참조하니 맵에서 빼도 exit 통지는 정상 동작한다.
    """
    now = time.time()
    _reap_children()   # 좀비를 먼저 치운다 — 안 그러면 아래 _pid_alive 가 시체를 살아있다고 본다
    with _lock:
        # detached(복원) term 은 reader 스레드가 없어 자연사 통지가 안 온다 — 여기서 pid 를 직접 검증.
        for t in _by_tid.values():
            if t.detached and t.alive and not _pid_alive(t.pid):
                t.mark_dead()
        # 유휴 정리는 마리나가 쥔 실 PTY 에만 — detached 는 입력이 없으니 TTL 로 SIGHUP 하면 안 된다.
        stale = [t for t in _by_tid.values()
                 if t.alive and not t.detached and now - t.last > TERM_IDLE_TTL]
        for t in [t for t in _by_tid.values() if not t.alive]:
            _by_tid.pop(t.tid, None)
            _delete_term_file(t.tid)
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
_SID_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]{3,63}")
_MODEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}")
_EFFORTS = {"low", "medium", "high", "xhigh", "max", "ultra"}


def _claude_cli(sid: str, prompt: str = "", model: str = "", effort: str = "") -> list[str]:
    cmd = ["claude"]
    if model:
        cmd += ["--model", model]
    if effort:
        cmd += ["--effort", effort]
    if sid:                 # sid 없음 = 새 세션(직접 launch) — resume 이 아니다
        cmd += ["--resume", sid]
    if prompt:
        cmd.append(prompt)
    return cmd


def _codex_cli(sid: str, prompt: str = "", model: str = "", effort: str = "") -> list[str]:
    cmd = ["codex", "resume"] if sid else ["codex"]   # sid 없음 = 새 세션(직접 launch)
    if model:
        cmd += ["--model", model]
    if effort:
        cmd += ["-c", f'model_reasoning_effort="{effort}"']
    if sid:
        cmd.append(sid)
    if prompt:
        cmd.append(prompt)
    return cmd


_AGENT_CLIS = {"claude": _claude_cli, "codex": _codex_cli}


def _agent_cli(source: str, sid: str, prompt: str = "", model: str = "", effort: str = "") -> list[str]:
    if source not in _AGENT_CLIS:
        raise ValueError("unknown agent source")
    # sid 빈 값 = **새 세션 직접 launch**(resume 아님). 그 세션의 sid 는 시작 시점엔 알 수 없고,
    # 훅이 남기는 {sid, pid} 를 marina_agent_procs 가 입양할 때 붙는다.
    if sid and not _SID_RE.fullmatch(sid):
        raise ValueError("invalid session id")
    if model and not _MODEL_RE.fullmatch(model):
        raise ValueError("invalid agent model")
    if effort and effort not in _EFFORTS:
        raise ValueError("invalid agent effort")
    return _AGENT_CLIS[source](sid, prompt, model, effort)


def term_open(root: Path, cols: int = 80, rows: int = 24,
              agent_source: str = "", agent_sid: str = "",
              agent_prompt: str = "", agent_model: str = "",
              agent_effort: str = "") -> dict[str, Any]:
    """root 워크트리에 새 PTY 세션을 연다(셸은 매번 새로 — 같은 워크트리에 여러 개 가능).
    기본은 $SHELL -il, agent_source/sid 를 주면 그 CLI 세션에 resume 으로 붙는다(살아있으면 재사용 — 이중 실행 방지)."""
    _reconstruct_registry()
    _reap_idle()
    cwd = str(root.resolve())
    if not Path(cwd).is_dir():
        raise ValueError("존재하지 않는 워크트리")
    cmd = ""
    key = ""
    agent = None
    if agent_source:
        cmd = _agent_cli(agent_source, agent_sid, agent_prompt, agent_model, agent_effort)
        # 재사용 키는 **같은 세션의 이중 resume** 을 막는 장치다. sid 가 없으면(새 세션 launch) 막을
        # 대상 자체가 없으므로 키를 만들지 않는다 — 안 그러면 ＋Claude 두 번이 한 PTY 로 합쳐진다.
        #
        # prompt attach(모바일 전송)는 **매 전송이 새 턴**이라 재사용하지 않는다 — CLI 의 prompt
        # 인자로 시작하므로 이미 돌고 있는 TUI 에 붙일 수가 없다. 그래서 키를 비운다(의도된 동작).
        key = "" if (agent_prompt or not agent_sid) else f"{cwd}::agent:{agent_source}:{agent_sid}"
        agent = {"source": agent_source, "sid": agent_sid}
        if agent_model:
            agent["model"] = agent_model
        if agent_effort:
            agent["effort"] = agent_effort
    retire: list[str] = []
    with _lock:
        if key:                                  # 에이전트만 재사용 — resume 이중 실행 방지
            existing = _by_key.get(key)
            if existing and existing.alive:
                if not existing.detached:   # detached 는 실 fd 가 없다 — reachability 만 재사용, ioctl 생략
                    _set_winsize(existing.fd, cols, rows)
                return {"tid": existing.tid, "reused": True}
        # _by_key 는 **키 있는** term 만 안다. prompt attach(모바일 전송의 resume)는 의도적으로
        # 키가 없어서, 그 PTY 가 살아 있는데 데스크톱이 같은 sid 로 term-open 하면 키 조회가
        # 빈손 → `claude --resume` 이 하나 더 뜬다. 실측(2026-08-16): 그렇게 둘이 된 뒤 옛
        # 프로세스가 좀비로 남아 같은 세션 파일을 물고 있었다. 키와 무관하게 sid 로 훑는다.
        if agent_sid:
            match = next((t for t in _by_tid.values()
                          if t.alive and not t.detached and t.root == cwd
                          and isinstance(getattr(t, "agent", None), dict)
                          and str(t.agent.get("source") or "") == agent_source
                          and str(t.agent.get("sid") or "") == agent_sid), None)
            if match is not None:
                if agent_prompt:
                    # 살아있는 PTY 가 있는데 prompt-resume 을 또 띄우면 위의 이중 실행 그 자체다.
                    # 호출자(mobile_send)는 라이브 tid 를 먼저 쓰므로 여기 오면 경쟁 상황 — 거절이 정답.
                    raise ValueError("이 세션의 PTY 가 이미 살아 있어요 — 잠시 후 다시 보내주세요")
                _set_winsize(match.fd, cols, rows)
                if key:
                    match.key = key            # term_kill/reap 의 _by_key 청소가 찾도록 키를 입양
                    _by_key[key] = match       # 다음부터는 빠른 경로로 잡힌다
                    _persist_term(match)       # 재시작 복원 메타에도 반영
                return {"tid": match.tid, "reused": True}
        # 같은 세션의 **detached** term 은 거둔다. detached = 데몬 재시작으로 master fd 를 잃어
        # 입력을 넣을 수 없는 상태다. 프로세스는 살아있는데 조작이 안 되니 _live_agent_tid 가
        # 빈손을 돌려주고, 호출자는 "PTY 가 없다"며 resume 을 한 번 더 띄운다 — 그래서 한 sid 에
        # `claude --resume` 이 둘 살아남는다. 그다음 조회가 버려진 쪽을 집으면 형이 보낸 메시지가
        # 영영 도착하지 않는다(실측 2026-08-11: 15:59 것과 16:06 것이 공존, 실제 대화는 16:06 쪽).
        #
        # **attached 인 옛 term 은 건드리지 않는다** — 그건 진행 중인 턴일 수 있고, 새 전송이
        # 남의 턴을 죽이면 안 된다(그 계약은 test-term 이 잠근다).
        if agent_sid:
            for other in list(_by_tid.values()):
                info = other.agent if isinstance(getattr(other, "agent", None), dict) else {}
                if (other.alive and other.detached and other.root == cwd
                        and str(info.get("source") or "") == agent_source
                        and str(info.get("sid") or "") == agent_sid):
                    retire.append(other.tid)
    for tid in retire:
        try:
            term_kill(tid)     # pid 재사용 지문 검증까지 하는 정석 정리를 그대로 쓴다
        except Exception:
            pass
    with _lock:
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
        _persist_term(term)   # 재시작 후 reachability 복원용 — fail-open
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
    if term.detached:   # 복원된 term — PTY master fd 가 없다. reuse-by-key 가 계속 이 tid 를 돌려주므로
        # "새로 열기"는 소용없다(같은 detached tid 재사용) — 에이전트가 끝날 때까지 조작 불가.
        raise ValueError("이 세션은 marina 재시작으로 조작할 수 없어요 — 작업이 끝난 뒤 다시 시도하세요")
    os.write(term.fd, data.encode("utf-8"))
    _note_typed(term, data)
    term.last = time.time()
    return {"ok": True}


_ANSI_RE = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]|\x1b[()][A-Za-z0-9]|\x1b[=>]|\r")


def term_tail(tid: str, limit: int = 1800) -> str:
    """PTY 화면의 마지막 부분을 사람이 읽을 수 있게. **진단 전용.**

    셀렉터가 실제로 어떻게 생겼는지 모르면 답 구동은 추측이 된다(실측: 질문 여러 개인 폼이
    계속 실패했는데 화면을 본 적이 없었다). 색·커서 이동 시퀀스를 걷어내고 글자만 남긴다."""
    try:
        term = _get(tid)
    except ValueError:
        return ""
    with term.cond:
        raw = bytes(term.history[-limit * 4:])
    text = _ANSI_RE.sub(b"", raw).decode("utf-8", errors="replace")
    lines = [line.rstrip() for line in text.splitlines()]
    return "\n".join([line for line in lines if line.strip()][-40:])[-limit:]


def term_output_mark(tid: str) -> int:
    """지금까지 이 PTY 가 뱉은 총 바이트 수. 화면이 다시 그려졌는지 재는 기준점.

    **관찰이 실패해도 예외를 던지지 않는다.** 화면을 못 본다고(만료·detached) 답 전송 자체가
    깨지면 안 된다 — 그때는 못 기다릴 뿐 보내기는 해야 한다."""
    try:
        term = _get(tid)
    except ValueError:
        return -1
    with term.cond:
        return term.base + len(term.history)


def term_await_redraw(tid: str, since: int, quiet: float = 0.12,
                      timeout: float = 4.0, min_bytes: int = 32) -> bool:
    """화면이 **다시 그려지고 잠잠해질 때까지** 기다린다.

    왜 시계가 아니라 이걸 보나. 여러 질문짜리 폼은 답을 하나 확정할 때마다 다음 질문을 새로
    그린다. 그 사이를 고정 시간으로 자면 느린 순간엔 그리기 전에 키가 들어가 어긋나고(실측
    2026-08-17: 3개짜리 폼이 첫 시도에 실패), 빠른 순간엔 쓸데없이 기다린다. 출력이 오는 것이
    곧 "그렸다"는 증거다 — 그걸 보고 움직인다.

    quiet: 마지막 출력 이후 이만큼 조용하면 그리기가 끝난 것으로 본다(TUI 는 한 번에 여러
    조각을 뱉는다).

    min_bytes: **에코를 다시 그리기로 착각하지 않기 위한 문턱.** PTY 는 우리가 넣은 키를 그대로
    되돌려준다(실측: Enter 를 넣자 0.22초 만에 출력이 왔는데 그건 에코였다). 선택지 한 판을 다시
    그리면 수백 바이트가 오지만 에코는 한두 바이트다 — 그 차이로 가른다.

    반환: 다시 그려지고 잠잠해졌으면 True, 상한까지 그만한 출력이 안 오면 False."""
    if since < 0:
        return False          # 기준점을 못 잡았다 = 관찰 불가. 기다리지 않고 진행한다.
    try:
        term = _get(tid)
    except ValueError:
        return False
    deadline = time.monotonic() + timeout
    start = since
    saw_output = False
    with term.cond:
        while True:
            current = term.base + len(term.history)
            if current - start >= min_bytes:
                saw_output = True
                since = current
                # 잠잠해질 때까지: 이 대기가 타임아웃으로 끝나면 더 온 게 없다는 뜻이다.
                remaining = max(0.0, deadline - time.monotonic())
                term.cond.wait(min(quiet, remaining))
                if term.base + len(term.history) == since:
                    return True
                continue
            if not term.alive or time.monotonic() >= deadline:
                return saw_output
            term.cond.wait(min(0.1, max(0.0, deadline - time.monotonic())))


def term_resize(tid: str, cols: int, rows: int) -> dict[str, Any]:
    term = _get(tid)
    if term.alive and not term.detached:   # detached 는 실 fd 가 없어 ioctl 불가 — 무시(fail-graceful)
        _set_winsize(term.fd, cols, rows)
    return {"ok": True}


# 사이드바 라벨용 — "셸 1" 은 어느 게 어느 건지 안 알려준다. tmux 가 창 이름을 실행 중인 프로그램으로
# 짓는 것과 같은 이유로, 지금 포그라운드에 있는 명령을 이름으로 쓴다.
_ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
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


_adopt_cache = 0.0
ADOPT_INTERVAL_S = 5.0


def adopt_agent_terms() -> int:
    """PTY 안에서 **손으로** 띄운 에이전트를 사후 등록한다(입양). 붙인 개수를 돌려준다.

    marina 가 직접 띄운 CLI 는 term_open 이 agent 를 찍어주지만, 형이 셸에서 `claude` 를 치면
    그 PTY 는 영영 agent=None 이라 제어(질문 응답·전송)가 막힌다. 훅이 남긴 {sid, pid}
    (marina_agent_procs)에서 pid 조상 체인을 타고 이 PTY 의 셸 pid 에 닿으면 그 term 의 세션이다.
    fail-open: 등록부가 없거나 ps 가 실패하면 아무것도 하지 않는다(기존 동작 유지)."""
    try:
        import marina_agent_procs
    except Exception:
        return 0
    try:
        records = marina_agent_procs.live_records()
        if not records:
            return 0
        table = marina_agent_procs.ps_table()
        # 입양 대상 = 세션을 아직 모르는 term. (a) 손으로 띄운 셸(agent 없음), (b) sid 없이 직접
        # launch 한 에이전트(agent 는 있지만 sid 가 빈 값 — 시작 시점엔 sid 를 알 수 없다).
        with _lock:
            by_pid = {t.pid: t for t in _by_tid.values()
                      if t.alive and not (t.agent or {}).get("sid")}
        if not by_pid:
            return 0
        adopted = 0
        for record in records:
            pid = int(record.get("pid") or 0)
            source, sid = str(record.get("source") or ""), str(record.get("sid") or "")
            if pid <= 1 or not source or not sid:
                continue
            # 에이전트 프로세스 자신부터 위로 — PTY 의 셸(term.pid)이 조상에 있으면 그 term 이다.
            for ancestor in [pid] + marina_agent_procs.ancestors(pid, table):
                term = by_pid.get(ancestor)
                if term is None or (term.agent or {}).get("sid"):
                    continue
                if (term.agent or {}).get("source") not in ("", None, source):
                    continue          # ＋Codex 로 띄운 칸에 claude 기록을 붙이지 않는다
                term.agent = {**(term.agent or {}), "source": source, "sid": sid}
                _persist_term(term)
                adopted += 1
                break
        return adopted
    except Exception:
        return 0


def term_list() -> dict[str, Any]:
    """살아있는 세션 목록 — 프론트가 새로고침 후 tid 를 되찾는 유일한 길(고아 PTY 방지).
    오프셋은 싣지 않는다: 재개(from)의 기준값은 SSE 이벤트의 off 로 프론트가 누적한다.
    fg/cmd/preview 는 사이드바 라벨용 — 뷰가 이 목록을 주기적으로 다시 받아 이름을 신선하게 유지한다."""
    global _adopt_cache
    _reconstruct_registry()
    _reap_idle()
    now = time.time()
    if now - _adopt_cache >= ADOPT_INTERVAL_S:   # 폴링마다 ps 를 두 번 더 띄우지 않게 간격을 둔다
        _adopt_cache = now
        adopt_agent_terms()
    with _lock:
        terms = sorted(_by_tid.values(), key=lambda t: t.created)
    return {"sessions": [{"tid": t.tid, "root": t.root, "agent": t.agent,
                          "fg": _fg_command(t), "cmd": t.cmd, "preview": _preview(t),
                          "created": t.created, "alive": t.alive,
                          "detached": t.detached} for t in terms]}


def term_kill(tid: str) -> dict[str, Any]:
    term = _get(tid)
    # detached(복원) term 은 pid 재사용 위험이 있다 — 시작시각 지문이 어긋나면 그 pid 는 이미 무관
    # 프로세스라 SIGHUP 을 쏘면 안 된다. 지문이 없으면(검증 불가) 기존 동작 유지(fail-open).
    if not (term.detached and term.pid_start and _pid_start(term.pid) != term.pid_start):
        try:
            os.kill(term.pid, signal.SIGHUP)
        except OSError:
            pass
        _register_reap(term.pid)   # SIGHUP 받고 죽는 건 조금 뒤다 — 등록해두고 폴마다 거둔다
    term.mark_dead()
    with _lock:
        _by_tid.pop(term.tid, None)
        if term.key and _by_key.get(term.key) is term:
            _by_key.pop(term.key, None)
    _delete_term_file(term.tid)
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
