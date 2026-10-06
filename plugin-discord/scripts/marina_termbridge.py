#!/usr/bin/env python3
"""marina_termbridge.py — 세션이 사람에게 "이 명령을 직접 실행해 달라"고 넘기는 터미널(2026-10-06).

설계: docs/superpowers/specs/2026-10-06-terminal-in-discord-and-heavy-queue-design.md 1절. 대시보드와 무관하게 Discord 플러그인이 혼자 한다.
  - 터미널 = tmux 세션 `term-<id>`(작업 폴더가 cwd, 사용자 로그인 셸). 명령은 입력창에 **쳐 두기만** 한다 — Enter 는 사람이.
    tmux 라 Discord 데몬이 다시 떠도 세션이 산다.
  - 기록 <MARINA_HOME>/discord-term/<token>.json (폴더 0700, 파일 0600) = {root, command, why, channel, tmux, createdAt, claimedBy, claimedAt, lastActiveAt}.
    claimedBy 는 처음 연 브라우저 cookie 의 sha256 — 원문은 남기지 않는다.
  - 링크는 처음 연 브라우저에 묶이고(claim), 10분 안에 아무도 안 열면 죽는다. 마지막 활동 30분 뒤엔 세션도 정리한다(sweep).
  - discord 모듈이라 runtime(plugin/scripts) 모듈을 import 하지 않는다(test-discord-boundary). tmux 호출은 marina_session._tmux(테스트 소켓을 따른다).
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
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
    try:
        (_dir() / f"{token}.json").unlink()
    except OSError:
        pass


def _pane(name: str) -> str:
    """tmux 창 대상 — `=<이름>:` 정확 일치(접두어가 같은 다른 세션으로 새지 않게)."""
    return "=" + name + ":"


def _alive(name: str) -> bool:
    return bool(name) and _tmux("has-session", "-t", "=" + name).returncode == 0


def _busy(name: str) -> bool:
    """셸이 아닌 무언가(로그인·빌드 …)가 돌고 있나. 알 수 없으면 아니다."""
    r = _tmux("display-message", "-p", "-t", _pane(name), "#{pane_current_command}")
    cmd = (r.stdout or "").strip().lstrip("-")
    return r.returncode == 0 and bool(cmd) and os.path.basename(cmd) not in _SHELLS


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
    return {"command": data.get("command", ""), "why": data.get("why", ""), "alive": _alive(data["tmux"])}


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
                _write(_dir(), token, cur)
    return ok


def sweep(now: Optional[float] = None) -> int:
    """만든 지 10분 넘게 미개봉이거나, 마지막 활동 30분 뒤 셸이 놀고 있거나, 만든 지 12시간이 넘은 것은 세션을 죽이고 기록을 지운다.
    tmux 세션이 이미 없으면 기록만 지운다. 지운 개수."""
    now = time.time() if now is None else now
    d, n = _dir(), 0
    if not d.is_dir():
        return 0
    with _lock:
        for f in d.glob("*.json"):
            token = f.stem
            data = _load(token)
            if data is None:
                continue
            if not data.get("claimedBy"):
                stale = now - float(data.get("createdAt") or 0) > UNCLAIMED_TTL
            else:
                last = float(data.get("lastActiveAt") or data.get("claimedAt") or data.get("createdAt") or 0)
                too_old = now - float(data.get("createdAt") or 0) > MAX_AGE
                # 무활동 30분이어도 안에서 무언가(로그인·빌드 …)가 돌고 있으면 건너뛴다 — 절대 상한은 예외 없이
                stale = too_old or (now - last > IDLE_TTL and not _busy(data["tmux"]))
            if stale or not _alive(data["tmux"]):
                _drop(token, data)
                n += 1
    return n
