#!/usr/bin/env python3
"""marina_termbridge.py — 세션이 사람에게 "이 명령을 직접 실행해 달라"고 넘기는 터미널(2026-10-06).

설계: docs/superpowers/specs/2026-10-06-terminal-in-discord-and-heavy-queue-design.md 1절. 대시보드와 무관하게 Discord 플러그인이 혼자 한다.
  - 터미널 = tmux 세션 `term-<id>`(작업 폴더가 cwd, 사용자 로그인 셸). 명령은 입력창에 **쳐 두기만** 한다 — Enter 는 사람이.
    tmux 라 Discord 데몬이 다시 떠도 세션이 산다.
  - 기록 <MARINA_HOME>/discord-term/<token>.json (폴더 0700, 파일 0600) = {root, command, why, channel, tmux, createdAt, claimedBy, claimedAt, lastActiveAt}.
    claimedBy 는 처음 연 브라우저 cookie 의 sha256 — 원문은 남기지 않는다.
  - 링크는 처음 연 브라우저에 묶이고(claim), 10분 안에 아무도 안 열면 죽는다. 마지막 활동 30분 뒤엔 세션도 정리한다(sweep).
  - 끝(2026-10-07): watch() 가 5초마다 열린 터미널을 본다. 판정은 tmux 가 주는 값(전경 프로세스)만 — 화면 글자 짐작·셸 설정 개입 없음.
    끝 = (Enter 가 keys 로 들어왔거나 실행 중을 봤고) + 지금 셸이 유휴 + 그 상태가 2초 이상 유지 + 화면 마지막 줄이 묻는 프롬프트가 아님.
    '실행 중을 봤다'는 Enter 가 없을 땐 만든 지 10초 뒤의 연속 두 표본이어야 한다(셸 rc 가 뜨며 잠깐 도는 외부 명령은 실행이 아니다).
    tmux 세션이 사라졌어도(exit·C-d) Enter·sawBusy 가 있었으면 끝. 터미널당 한 번(doneAt), 알린 뒤 notifiedAt.
    끝난 터미널은 max(doneAt, 마지막 키 입력) + 30분에 정리한다. 기록엔 enterAt·sawBusy·busyN·idleSince 도 남아 데몬이 다시 떠도 이어진다.
  - 알려진 한계(오판 가능): 셸 함수·내장 안에서 오래 도는 일(read -t 없이 기다리는 함수, wait 등)은 전경이 셸 자신이라 유휴로 보인다 — Enter 뒤 2초면 끝으로 본다.
    묻는 줄 판정은 '막는' 방향으로만 쓴다(막지 못하는 질문 모양은 끝으로 샌다). 사람이 명령을 지우고 빈 줄에 Enter 를 눌러도 끝으로 본다.
    Enter 기록 없이 5초 표본 사이에 끝나는 짧은 직접 실행은 놓친다(오탐보다 누락을 택했다).
  - 화면 내용은 끝 알림에 안 실린다. 사람이 페이지의 버튼을 눌렀을 때만 share() 가 비밀을 가린 끝 40줄을 파일로 쓴다(호출 쪽이 세션에 알린다).
  - discord 모듈이라 runtime(plugin/scripts) 모듈을 import 하지 않는다(test-discord-boundary). tmux 호출은 marina_session._tmux(테스트 소켓을 따른다).
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import tempfile
import threading
import time
import unicodedata
from pathlib import Path
from typing import Any, Optional

UNCLAIMED_TTL = 600.0        # 만든 지 10분 안에 아무도 안 열면 만료
IDLE_TTL = 1800.0            # 마지막 활동 뒤 30분이면 세션 정리(단 안에서 무언가 실행 중이면 건너뛴다)
MAX_AGE = 12 * 3600.0        # 절대 상한 — 만든 지 이만큼 지나면 실행 중이어도 정리하고, 요청 시점에도 못 쓴다
MAX_COMMAND_BYTES = 1000     # UTF-8 바이트 기준. macOS 정규 입력 모드는 한 줄 1024바이트를 넘으면 조용히 자른다
MAX_TEXT = 2000
_SHELLS = frozenset(("sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"))
SCREEN_LINES = 200
DONE_HOLD = 2.0              # 셸이 이만큼 유휴로 유지돼야 끝(Enter 직후 fork 전 찰나·표본 흔들림을 거른다)
TAIL_LINES = 40              # 세션에 넘기는 화면 끝 줄 수
SETTLE = 10.0                # 만든 지 이만큼 전의 실행 중 표본은 안 센다(셸 rc 가 뜨는 중)
DEAD_GRACE = 600.0           # 세션이 닫혔어도 끝을 아직 못 알렸으면 이만큼은 기록을 둔다
_ASKS = re.compile(
    r"\[nyae\]\?\s*$"                                             # zsh correct
    r"|\b(?:remove|overwrite|replace|delete)\b.*\?\s*$"            # rm·mv·cp 확인
    r"|^(?:\w*quote|heredoc)?>\s*$"                                # dquote>·quote>·heredoc>·> 이어쓰기
    r"|(?:password|passphrase)[^:\n]*:\s*$"
    r"|\[y/n\]\s*\??\s*$"
    r"|\(yes/no(?:/\[fingerprint\])?\)\??\s*$", re.I)
ALLOWED_KEYS = frozenset(("Enter", "C-c", "C-d", "Tab", "Escape", "Up", "Down", "Left", "Right", "BSpace"))
_TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{20,64}")
_lock = threading.Lock()


def _dir() -> Path:
    return Path(os.environ.get("MARINA_HOME") or Path.home() / ".marina").expanduser() / "discord-term"


def _tmux(*args: str) -> "Any":
    import marina_session as ms          # 테스트 소켓(MARINA_TMUX_SOCKET)·launchd PATH 폴백을 한곳에서
    return ms._tmux(*args)


def _write(d: Path, token: str, payload: dict) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(d), prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.rename(tmp, d / f"{token}.json")


def _load(token: Any) -> Optional[dict]:
    if not isinstance(token, str) or not _TOKEN_RE.fullmatch(token):
        return None
    try:
        data = json.loads((_dir() / f"{token}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and isinstance(data.get("tmux"), str) else None


def _load_live(token: Any) -> Optional[dict]:
    """요청 시점 수명 검사 — sweep 이 안 돌아도 절대 상한(12시간)을 넘은 것은 없는 것으로 친다."""
    data = _load(token)
    if data is None or time.time() - float(data.get("createdAt") or 0) > MAX_AGE:
        return None
    return data


def _drop(token: str, data: Optional[dict]) -> None:
    """tmux 세션을 죽이고 기록을 지운다."""
    if data and data.get("tmux"):
        _tmux("kill-session", "-t", "=" + str(data["tmux"]))
    _drop_last(data)
    try:
        (_dir() / f"{token}.json").unlink()
    except OSError:
        pass


def _drop_last(data: Optional[dict]) -> None:
    """세션에 넘긴 화면 끝(term-last*.txt) 정리 — 내가 쓴 그 파일일 때만(다른 터미널이 덮어썼으면 그쪽 것이니 둔다)."""
    path = str((data or {}).get("lastFile") or "")
    if not path or not os.path.basename(path).startswith("term-last"):
        return
    try:
        if os.stat(path).st_mtime_ns == (data or {}).get("lastFileNs"):
            os.unlink(path)
    except OSError:
        pass


def _pane(name: str) -> str:
    """tmux 창 대상 — `=<이름>:` 정확 일치(접두어가 같은 다른 세션으로 새지 않게)."""
    return "=" + name + ":"


def _alive(name: str) -> bool:
    return bool(name) and _tmux("has-session", "-t", "=" + name).returncode == 0


def _fg_other(pid: str) -> bool:
    """터미널의 전경 프로세스 그룹이 이 셸 것이 아닌가 — `cloud …` 같은 셸 스크립트 래퍼는 이름이 bash/sh 로 보여도
    자기 그룹을 전경으로 가져가므로 pane_current_command 만으론 못 잡는다(실측). 알 수 없으면 아니다."""
    try:
        out = subprocess.run(["ps", "-o", "pgid=,tpgid=", "-p", pid], capture_output=True, text=True, timeout=5).stdout.split()
        pgid, tpgid = int(out[0]), int(out[1])
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return False
    return tpgid > 0 and tpgid != pgid


def _busy(name: str) -> bool:
    """셸 밖의 무언가(로그인·빌드 …)가 전경에서 돌고 있나. 알 수 없으면 아니다."""
    r = _tmux("display-message", "-p", "-t", _pane(name), "#{pane_current_command}\t#{pane_pid}")
    cmd, _, pid = (r.stdout or "").strip().partition("\t")
    cmd = cmd.lstrip("-")
    if r.returncode != 0 or not cmd:
        return False
    return os.path.basename(cmd) not in _SHELLS or _fg_other(pid.strip())


def _asks_line(line: str) -> bool:
    """셸·명령이 사람에게 답을 묻는 줄인가 — 끝 판정을 **막는** 쪽으로만 쓴다."""
    return bool(_ASKS.search(line.strip()))


def _asks(name: str) -> bool:
    out = (_tmux("capture-pane", "-p", "-t", _pane(name)).stdout or "").rstrip().splitlines()
    return bool(out) and _asks_line(out[-1])


def _type(name: str, text: str) -> bool:
    """글자 그대로 입력창에 친다. tmux 는 마지막 인자가 `;` 로 끝나면 `-l --` 뒤여도 명령 구분자로 먹고(`\\;` 는 백슬래시를 지운다)
    그래서 끝의 `;` 는 바이트(`send-keys -H 3b`)로 따로 보낸다."""
    body = text.rstrip(";")
    tail = len(text) - len(body)
    if body and _tmux("send-keys", "-t", _pane(name), "-l", "--", body).returncode != 0:
        return False
    return not tail or _tmux("send-keys", "-t", _pane(name), "-H", *(["3b"] * tail)).returncode == 0


def _wait_prompt(name: str, secs: float = 3.0) -> None:
    """셸이 떠 프롬프트가 보일 때까지 잠깐 기다린다(줄 편집기가 켜지기 전에 치면 긴 입력이 잘린다)."""
    end = time.time() + secs
    while time.time() < end:
        if (_tmux("capture-pane", "-p", "-t", _pane(name)).stdout or "").strip():
            return
        time.sleep(0.05)


def _typed_ok(name: str, command: str, secs: float = 5.0) -> bool:
    """친 명령의 끝까지 화면(줄바꿈 이어 붙임 -J)에 들어갔나."""
    end = time.time() + secs
    want = command.rstrip()
    while True:
        out = _tmux("capture-pane", "-p", "-J", "-t", _pane(name)).stdout or ""
        if want in out.replace("\n", ""):
            return True
        if time.time() >= end:
            return False
        time.sleep(0.1)


def _env_utf8() -> bool:
    return any("utf-8" in os.environ.get(k, "").lower() or "utf8" in os.environ.get(k, "").lower() for k in ("LC_ALL", "LC_CTYPE", "LANG"))


def _hash(cookie: Any) -> str:
    return hashlib.sha256(str(cookie).encode("utf-8")).hexdigest()


def _owner(data: dict, cookie: Any) -> bool:
    mine = data.get("claimedBy")
    return isinstance(cookie, str) and bool(cookie) and isinstance(mine, str) and hmac.compare_digest(mine, _hash(cookie))


def _check_command(command: Any) -> str:
    if not isinstance(command, str) or not command.strip():
        raise ValueError("command 가 비었어")
    if len(command.encode("utf-8")) > MAX_COMMAND_BYTES:
        raise ValueError(f"명령은 {MAX_COMMAND_BYTES}바이트(UTF-8)까지야")
    if any(unicodedata.category(c) in ("Cc", "Cf") for c in command):
        raise ValueError("명령에 개행·제어 문자·보이지 않는 문자가 있어")
    return command


def create(root: str, command: str, why: str, channel: str) -> str:
    """tmux 세션을 root 에 띄우고 명령을 입력창에 쳐 둔 뒤(Enter 안 침) 토큰을 돌려준다. 잘못된 입력은 ValueError."""
    command = _check_command(command)
    real = os.path.realpath(str(root or ""))
    if not str(root or "").strip() or not os.path.isdir(real):
        raise ValueError(f"작업 폴더가 없어: {root}")
    token = secrets.token_urlsafe(24)
    name = "term-" + secrets.token_hex(4)
    args = ["new-session", "-d", "-s", name, "-c", real, "-x", "120", "-y", "40"]
    if not _env_utf8():          # launchd 데몬엔 로캘이 없다 — 없으면 셸이 한글 입력을 통째로 버린다
        args += ["-e", "LANG=en_US.UTF-8"]
    r = _tmux(*args)
    if r.returncode != 0:
        raise ValueError(f"터미널(tmux)을 못 띄웠어: {(r.stderr or r.stdout or '').strip()[:200]}")
    try:
        _wait_prompt(name)
        if not _type(name, command) or not _typed_ok(name, command):      # Enter 는 사람이
            raise ValueError("터미널에 명령을 입력하지 못했어")
        d = _dir()
        with _lock:
            d.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(d, 0o700)
            _write(d, token, {"root": real, "command": command, "why": str(why or ""), "channel": str(channel or ""), "tmux": name,
                              "createdAt": time.time(), "claimedBy": None})
    except BaseException:        # 고아 세션을 남기지 않는다
        _tmux("kill-session", "-t", "=" + name)
        raise
    return token


def revoke(token: str) -> None:
    """링크를 만들고도 채널에 못 올렸을 때 — 세션과 기록을 바로 지운다."""
    with _lock:
        _drop(token, _load(token))


def revoke_channel(channel: str) -> int:
    """그 채널에서 만든 터미널을 모두 끊는다(세션 삭제 때) — 끊은 개수."""
    if not channel:
        return 0
    n = 0
    with _lock:
        d = _dir()
        for f in (d.glob("*.json") if d.is_dir() else []):
            data = _load(f.stem)
            if data is not None and data.get("channel") == str(channel):
                _drop(f.stem, data)
                n += 1
    return n


def claim(token: str, cookie: str) -> bool:
    """처음 여는 브라우저에 묶는다. 같은 cookie 는 다시 열어도 True, 다른 cookie 는 False. 10분 넘게 미개봉이면 만료(세션 정리)."""
    if not isinstance(cookie, str) or not cookie:
        return False
    with _lock:
        data = _load_live(token)
        if data is None:
            return False
        if data.get("claimedBy"):
            return _owner(data, cookie)
        now = time.time()
        if now - float(data.get("createdAt") or 0) > UNCLAIMED_TTL:
            _drop(token, data)
            return False
        data.update(claimedBy=_hash(cookie), claimedAt=now, lastActiveAt=now)
        _write(_dir(), token, data)
        return True


def authorize(token: str, cookie: Any) -> Optional[bool]:
    """None = 그런 링크 없음, False = 이 브라우저는 권한 없음, True = 묶인 브라우저."""
    data = _load_live(token)
    if data is None:
        return None
    return _owner(data, cookie)


def meta(token: str, cookie: Any) -> Optional[dict]:
    """페이지 머리에 보일 {command, why, alive} — 권한이 없으면 None."""
    data = _load_live(token)
    if data is None or not _owner(data, cookie):
        return None
    return {"command": data.get("command", ""), "why": data.get("why", ""), "alive": _alive(data["tmux"]),
            "done": bool(data.get("doneAt")), "doneAt": data.get("doneAt")}


def screen(token: str, cookie: str) -> Optional[str]:
    """tmux 글자 화면(끝 200줄). 권한이 없거나 세션이 없으면 None."""
    data = _load_live(token)
    if data is None or not _owner(data, cookie):
        return None
    r = _tmux("capture-pane", "-p", "-t", _pane(data["tmux"]), "-S", f"-{SCREEN_LINES}")
    if r.returncode != 0:
        return None
    return r.stdout.rstrip("\n")


def send(token: str, cookie: str, text: Optional[str] = None, key: Optional[str] = None) -> bool:
    """text 는 글자 그대로(제어 문자는 뺀다, 최대 2000자), key 는 허용 목록만. 보냈으면 True."""
    data = _load_live(token)
    if data is None or not _owner(data, cookie):
        return False
    name = data["tmux"]
    if text is not None and key is None:
        if not isinstance(text, str) or len(text) > MAX_TEXT:
            return False
        text = "".join(c for c in text if unicodedata.category(c) != "Cc")
        if not text:
            return False
        ok = _type(name, text)
    elif key is not None and text is None:
        if not isinstance(key, str) or key not in ALLOWED_KEYS:
            return False
        ok = _tmux("send-keys", "-t", _pane(name), key).returncode == 0
    else:
        return False
    if ok:
        with _lock:
            cur = _load(token)
            if cur is not None:
                cur["lastActiveAt"] = time.time()
                if key == "Enter":
                    cur["enterAt"] = cur["lastActiveAt"]      # 끝 판정의 보조 신호 — 사람이 명령을 실행했다
                _write(_dir(), token, cur)
    return ok


def _sweep_files(now: float) -> None:
    """세션 상태 폴더의 오래된 term-last-*.txt·.tmp-term-last-*(30분 넘은 것) — 터미널 기록이 먼저 사라졌어도 남지 않게."""
    import marina_session as ms
    try:
        dirs = {str(x.get("stateDir")) for x in ms.load_sessions() if x.get("stateDir")}
    except Exception:
        return
    for sd in dirs:
        base = Path(sd)
        for pat in ("term-last-*.txt", ".tmp-term-last-*"):
            try:
                for f in base.glob(pat):
                    try:
                        if now - f.stat().st_mtime > IDLE_TTL:
                            f.unlink()
                    except OSError:
                        pass
            except OSError:
                pass


def sweep(now: Optional[float] = None) -> int:
    """만든 지 10분 넘게 미개봉이거나, 마지막 활동 30분 뒤 셸이 놀고 있거나, 만든 지 12시간이 넘은 것은 세션을 죽이고 기록을 지운다.
    tmux 세션이 이미 없으면 기록만 지운다. 지운 개수."""
    now = time.time() if now is None else now
    d, n = _dir(), 0
    _sweep_files(now)
    if not d.is_dir():
        return 0
    with _lock:
        for f in d.glob("*.json"):
            token = f.stem
            data = _load(token)
            if data is None:
                continue
            too_old = now - float(data.get("createdAt") or 0) > MAX_AGE
            if not _alive(data["tmux"]):
                owed = (data.get("sawBusy") or data.get("enterAt")) and not data.get("notifiedAt")
                if owed and now - float(data.get("lastActiveAt") or data.get("createdAt") or 0) < DEAD_GRACE:
                    continue                  # 닫혔는데 끝을 아직 못 알렸다 — watch 가 알릴 틈을 준다
                _drop(token, data)
                n += 1
                continue
            if data.get("doneAt"):
                # 끝난 터미널은 max(끝난 때, 마지막 키 입력) + 30분 — 끝난 뒤에도 쓰는 터미널·또 돌리는 명령은 안 죽인다
                last_use = max(float(data["doneAt"]), float(data.get("lastActiveAt") or 0))
                stale = too_old or (now - last_use > IDLE_TTL and not _busy(data["tmux"]))
            elif not data.get("claimedBy"):
                stale = now - float(data.get("createdAt") or 0) > UNCLAIMED_TTL
            else:
                last = float(data.get("lastActiveAt") or data.get("claimedAt") or data.get("createdAt") or 0)
                # 무활동 30분이어도 안에서 무언가(로그인·빌드 …)가 돌고 있으면 건너뛴다 — 절대 상한은 예외 없이
                stale = too_old or (now - last > IDLE_TTL and not _busy(data["tmux"]))
            if stale:
                _drop(token, data)
                n += 1
    return n


def _judge(data: dict, now: float) -> bool:
    """끝 판정 한 표본 — data 를 고치고 바뀌었으면 True. 끝이면 doneAt 을 단다."""
    name, changed = data["tmux"], False
    if _busy(name):                       # 실행 중 — 유휴 타이머는 처음부터
        if data.get("enterAt"):
            n = 2
        elif now - float(data.get("createdAt") or 0) < SETTLE:
            n = 0                         # 셸 rc 가 뜨는 중 — 표본으로 안 센다
        else:
            n = min(2, int(data.get("busyN") or 0) + 1)
        if n != int(data.get("busyN") or 0):
            data["busyN"], changed = n, True
        if n >= 2 and not data.get("sawBusy"):
            data["sawBusy"], changed = True, True
        if data.get("idleSince") is not None:
            data["idleSince"], changed = None, True
        return changed
    if data.get("busyN"):
        data["busyN"], changed = 0, True      # 연속이 끊겼다
    if not (data.get("sawBusy") or data.get("enterAt")):
        return changed                    # 사람이 아직 안 돌렸다 — 미리 쳐 둔 명령이 입력창에 있을 뿐
    if _asks(name):                       # 묻는 중(y/N·이어쓰기·Password:) — 아직 끝이 아니다
        if data.get("idleSince") is not None:
            data["idleSince"], changed = None, True
        return changed
    since = data.get("idleSince")
    if since is None:
        data["idleSince"] = now
        return True
    if now - max(float(since), float(data.get("enterAt") or 0)) >= DONE_HOLD:
        data["doneAt"] = now
        return True
    return changed


def watch(now: Optional[float] = None) -> "list[tuple[str, dict]]":
    """열린(끝 안 난) 터미널을 한 번 훑어 끝난 것에 doneAt 을 달고, **끝났는데 아직 알리지 않은** (토큰, 기록)을 돌려준다.
    알린 뒤엔 mark_notified — 알림이 실패하면 다음 훑기에 다시 나온다."""
    now = time.time() if now is None else now
    d, out = _dir(), []
    if not d.is_dir():
        return out
    with _lock:
        for f in sorted(d.glob("*.json")):
            token = f.stem
            data = _load(token)
            if data is None:
                continue
            if not data.get("doneAt"):
                if _alive(data["tmux"]):
                    if _judge(data, now):
                        _write(d, token, data)
                elif data.get("sawBusy") or data.get("enterAt"):      # 사람이 exit·C-d 로 닫았다 — 돌린 적이 있으면 끝
                    data["doneAt"] = now
                    _write(d, token, data)
            if data.get("doneAt") and not data.get("notifiedAt"):
                out.append((token, dict(data)))
    return out


def mark_notified(token: str) -> None:
    with _lock:
        cur = _load(token)
        if cur is not None and not cur.get("notifiedAt"):
            cur["notifiedAt"] = time.time()
            _write(_dir(), token, cur)


def save_tail(token: str, dest: Path, lines: int = TAIL_LINES, clean: "Any" = None) -> Optional[Path]:
    """화면 끝 `lines` 줄을 (clean 을 거쳐) dest 에 0600 으로 쓴다. 기록에 남겨 터미널을 정리할 때 같이 지운다. 임시 파일은 실패해도 남기지 않는다."""
    with _lock:
        data = _load(token)
        if data is None:
            return None
        r = _tmux("capture-pane", "-p", "-t", _pane(data["tmux"]), "-S", f"-{SCREEN_LINES}")
        if r.returncode != 0:
            return None
        text = "\n".join(r.stdout.rstrip("\n").splitlines()[-lines:]) + "\n"
        dest = Path(dest)
        fd, tmp = tempfile.mkstemp(dir=str(dest.parent), prefix=".tmp-term-last-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(clean(text) if clean else text)
            os.chmod(tmp, 0o600)
            os.rename(tmp, dest)
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        data["lastFile"], data["lastFileNs"] = str(dest), dest.stat().st_mtime_ns
        _write(_dir(), token, data)
        return dest
