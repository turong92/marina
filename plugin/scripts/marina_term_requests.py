#!/usr/bin/env python3
"""marina_term_requests.py — 세션이 "형이 터미널에서 직접 실행해 줘" 를 부탁하는 1회용 요청(2026-10-05).

<MARINA_HOME>/term-requests/<token>.json (0600) = {root, command, why, ts}.
대시보드 /term-run 페이지가 token 으로 claim 해 그 워크트리에서 PTY 셸을 열고 명령을 **입력만** 해 둔다 —
실행은 형의 Enter. 그래서 command 에 개행·제어문자는 허용하지 않는다(개행이면 입력과 동시에 실행돼 버린다).
CLI: `marina term-request <command> [--why <text>]` (marina.sh 가 이 파일을 부른다).
"""
from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import unicodedata
from pathlib import Path
from typing import Any, Optional

TTL_SECONDS = 15 * 60
MAX_COMMAND = 1500   # Discord 메시지에 **전체**가 보이게(잘라 보여 주면 보이는 명령 ≠ 실제 명령)
MAX_WHY = 300
_TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{20,64}")
_CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")


def _check_command(command: Any) -> str:
    """입력만 해 둘 명령의 검증 — create 와 claim 이 같이 쓴다. 눈에 안 보이거나 보이는 모양을 속이는 문자(Cc 제어·Cf 서식:
    bidi override U+202E·U+2066-2069, zero-width, C1)는 전부 거부한다 — 사람은 보이는 걸 믿고 Enter 를 친다."""
    if not isinstance(command, str) or not command.strip():
        raise ValueError("명령이 비었어")
    if len(command) > MAX_COMMAND:
        raise ValueError(f"명령은 {MAX_COMMAND}자 이하여야 해(전체가 보여야 안전하다)")
    for ch in command:
        if unicodedata.category(ch) in ("Cc", "Cf"):
            raise ValueError("명령에 개행·제어·보이지 않는 문자를 넣을 수 없어(입력만 해 두는데 개행이면 실행되고, 방향 문자는 보이는 명령을 속인다)")
    return command


def _root_registered(root: str) -> bool:
    """safe_root(대시보드)와 같은 판정 — 등록된 워크트리 root 만. 새 워크트리는 캐시에 아직 없을 수 있어 한 번 강제 재탐색."""
    from marina_registry import discover_all_roots
    target = Path(root).expanduser().resolve()
    if target in {r.resolve() for r in discover_all_roots()}:
        return True
    return target in {r.resolve() for r in discover_all_roots(refresh=True)}


def _dir() -> Path:
    return Path(os.environ.get("MARINA_HOME") or Path.home() / ".marina") / "term-requests"


def _purge_stale(d: Path, now: float) -> None:
    for f in d.glob("*.json"):
        try:
            if now - f.stat().st_mtime > TTL_SECONDS * 2:
                f.unlink()
        except OSError:
            pass


def create(root: str, command: str, why: str = "") -> str:
    root = str(root or "").strip()
    if not root:
        raise ValueError("root 가 비었어")
    _check_command(command)
    if not _root_registered(root):
        raise ValueError(f"등록된 워크트리가 아니야: {root}")
    why = _CTRL_RE.sub(" ", str(why or "")).strip()[:MAX_WHY]
    d = _dir()
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(d, 0o700)
    now = time.time()
    _purge_stale(d, now)
    token = secrets.token_urlsafe(18)
    payload = {"root": root, "command": command, "why": why, "ts": now}
    fd, tmp = tempfile.mkstemp(dir=str(d), prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.rename(tmp, d / f"{token}.json")
    return token


def _valid(data: Any) -> Optional[dict]:
    """읽은 내용이 쓸 만한가 — dict·만료 전·명령 재검증(파일을 직접 만들어 넣어도 위험한 명령은 안 나간다)."""
    if not isinstance(data, dict) or not isinstance(data.get("root"), str) or not data["root"]:
        return None
    try:
        if time.time() - float(data.get("ts") or 0) > TTL_SECONDS:
            return None
        _check_command(data.get("command"))
    except (ValueError, TypeError):
        return None
    return data


def peek(token: Any) -> Optional[dict]:
    """읽기만 한다(소모 안 함) — 권한 확인이 끝난 뒤에야 claim 하려고. 없음·형식 오류·만료·검증 실패는 None."""
    if not isinstance(token, str) or not _TOKEN_RE.fullmatch(token):
        return None
    try:
        return _valid(json.loads((_dir() / f"{token}.json").read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return None


def claim(token: Any) -> Optional[dict]:
    """한 번만 — rename 으로 가져가 지운다. 없음·형식 오류·만료·검증 실패는 None(가져간 파일은 지운다)."""
    if not isinstance(token, str) or not _TOKEN_RE.fullmatch(token):
        return None
    src = _dir() / f"{token}.json"
    mine = _dir() / f".claimed-{token}-{os.getpid()}-{secrets.token_hex(4)}"
    try:
        os.rename(src, mine)        # 원자적 — 동시에 두 요청이 와도 하나만 가져간다
    except OSError:
        return None
    try:
        data = json.loads(mine.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    finally:
        try:
            mine.unlink()
        except OSError:
            pass
    return _valid(data)


def parse_status(text: str) -> dict[str, str]:
    """`marina remote status` 의 key=value 줄."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            out[key.strip()] = value.strip()
    return out


def base_url(status_text: str) -> str:
    st = parse_status(status_text)
    url = st.get("url", "")
    if url.startswith(("http://", "https://")):
        return url.rstrip("/")
    port = st.get("dashboardPort") or os.environ.get("MARINA_CONTROL_PORT") or "3900"
    return f"http://localhost:{port}"


def _remote_status() -> str:
    # MARINA_TERM_REQUEST_REMOTE_STATUS = `marina remote status` 대신 부를 실행 파일(테스트가 가짜 tailscale 상태를 넣는 자리)
    # 경계: runtime 모듈이 marina_remote_cli(remote 플러그인 영역)를 import 하지 않고 **프로세스로** 부른다 — 사용자가 치는
    # `marina remote status` 와 똑같은 출력(url=)을 쓰려는 것이고, 실패하면 localhost 주소로 물러난다.
    override = os.environ.get("MARINA_TERM_REQUEST_REMOTE_STATUS")
    cmd = [override] if override else [sys.executable, str(Path(__file__).resolve().parent / "marina_remote_cli.py"), "status"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout if r.returncode == 0 else ""


def main(argv: list[str]) -> int:
    """marina term-request [--why <text>] [--] <command> — 명령은 인자 **하나**(따옴표로 감싼다). --why 는 명령 앞에서만."""
    root, rest, why = "", list(argv), ""
    if len(rest) >= 2 and rest[0] == "--root":
        root, rest = rest[1], rest[2:]
    if len(rest) >= 2 and rest[0] == "--why":
        why, rest = rest[1], rest[2:]
    if rest[:1] == ["--"]:
        rest = rest[1:]
    if not rest:
        print("usage: marina term-request [--why <text>] <command>   # 명령은 따옴표로 감싼 인자 하나", file=sys.stderr)
        return 2
    if len(rest) > 1:
        print("error: 명령은 인자 하나야 — 따옴표로 감싸 줘 (예: marina term-request 'cloud prod db --admin'). "
              "--why 는 명령 앞에 둬", file=sys.stderr)
        return 2
    try:
        token = create(root, rest[0], why)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(f"{base_url(_remote_status())}/term-run?t={token}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
