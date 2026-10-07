#!/usr/bin/env python3
"""discord 봇 데몬의 LaunchAgent — 로그인하면 뜨고 죽으면 다시 뜬다(스펙 §3). 맥 + 기본 홈에서만 launchd 가 주인."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import escape

import marina_session as ms

LABEL = "marina.discord"
SUPERVISED_ENV = "MARINA_DISCORD_SUPERVISED"


def plist_path() -> Path:
    return Path(os.environ.get("MARINA_LAUNCH_AGENTS_DIR") or Path.home() / "Library" / "LaunchAgents") / f"{LABEL}.plist"


def is_primary() -> bool:
    return ms.marina_home().resolve() == (Path.home() / ".marina").resolve()


def managed() -> bool:
    """이 홈이 LaunchAgents 에 손댈 자격이 있나 — 기본 홈이거나 격리 디렉터리를 따로 받은 경우만.
    격리 홈이 실제 ~/Library/LaunchAgents 를 지우거나 쓰면 형의 진짜 로그인 항목이 사라진다(runtimed.sh 와 같은 원칙)."""
    return is_primary() or bool(os.environ.get("MARINA_LAUNCH_AGENTS_DIR"))


def off_mark() -> Path:
    """`daemon-uninstall` 이 남기는 끔 표식 — 있으면 ensure_daemon 이 다시 등록하지 않는다."""
    return ms.marina_home() / "discord-daemon.off"


def clear_off() -> None:
    off_mark().unlink(missing_ok=True)


def _launchctl_exe() -> str:
    """격리 홈(테스트·프리뷰)은 실제 launchctl 을 절대 부르지 않는다 — 라벨이 사용자 전역이라 진짜 봇을 내린다."""
    fake = os.environ.get("MARINA_DISCORD_LAUNCHCTL")
    if fake:
        return fake
    return (shutil.which("launchctl") or "") if is_primary() else ""


def supervisor() -> str:
    forced = os.environ.get("MARINA_DISCORD_SUPERVISOR") or ""
    if forced == "nohup" or not _launchctl_exe():
        return "nohup"
    if forced == "launchd":
        return "launchd"
    return "launchd" if sys.platform == "darwin" and is_primary() else "nohup"


def supervised() -> bool:
    return os.environ.get(SUPERVISED_ENV) == "launchd"


def _domain() -> str:
    return f"gui/{os.getuid()}"


def _target() -> str:
    return f"{_domain()}/{LABEL}"


def _launchctl(*args: str) -> "tuple[int, str]":
    exe = _launchctl_exe()
    if not exe:
        return 127, "launchctl 없음"
    try:
        r = subprocess.run([exe, *args], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, str(exc)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def plist_text(program: "list[str]") -> str:
    """home·실행 인자만으로 정해진다 — 누가 써도 같은 내용이라 '다르면 다시 올림' 이 흔들리지 않는다."""
    home = ms.marina_home()
    env = {"PATH": ms.daemon_path(), "MARINA_HOME": str(home), "PYTHONUNBUFFERED": "1",
           "LANG": "en_US.UTF-8", SUPERVISED_ENV: "launchd"}     # launchd 는 LANG 을 안 준다 — tmux 화면 판정이 UTF-8 이어야
    args = "".join("<string>" + escape(a) + "</string>" for a in program)
    envx = "".join("\n    <key>" + escape(k) + "</key><string>" + escape(v) + "</string>" for k, v in env.items())
    log = escape(str(home / "discord-daemon.log"))
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n'
            f'  <key>Label</key><string>{LABEL}</string>\n'
            f'  <key>ProgramArguments</key><array>{args}</array>\n'
            f'  <key>EnvironmentVariables</key>\n  <dict>{envx}\n  </dict>\n'
            f'  <key>WorkingDirectory</key><string>{escape(str(home))}</string>\n'
            f'  <key>StandardOutPath</key><string>{log}</string>\n'
            f'  <key>StandardErrorPath</key><string>{log}</string>\n'
            '  <key>RunAtLoad</key><true/>\n  <key>KeepAlive</key><true/>\n'
            '  <key>AbandonProcessGroup</key><true/>\n'     # 데몬이 끝날 때 진행 중인 새 작업 열기·깨우기를 같이 죽이지 않게
            '</dict>\n</plist>\n')


def status() -> str:
    rc, out = _launchctl("print", _target())
    if rc != 0:
        return "absent"
    return "running" if re.search(r"^\s*state = running\s*$", out, re.M) else "loaded"


def _write_if_changed(text: str) -> bool:
    p = plist_path()
    try:
        if p.read_text(encoding="utf-8") == text:
            return False
    except OSError:
        pass
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(f"{p.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, p)
    return True


def _reload_detached() -> None:
    """bootout → bootstrap 을 떼어 낸 도우미로 — 데몬 자신이 불러도 자기를 내리다 중간에 죽지 않는다."""
    # bootout 직후엔 launchd 가 아직 정리 중일 수 있다 — bootstrap 이 일시 실패하면 두 번 더(1초·2초 뒤)
    script = ('"$1" bootout "$2" >/dev/null 2>&1; sleep 1; '
              '"$1" bootstrap "$3" "$4" >/dev/null 2>&1 || { sleep 1; "$1" bootstrap "$3" "$4" >/dev/null 2>&1; } '
              '|| { sleep 2; "$1" bootstrap "$3" "$4" >/dev/null 2>&1; }')
    subprocess.Popen(["/bin/sh", "-c", script, "sh",
                      _launchctl_exe(), _target(), _domain(), str(plist_path())],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def ensure(program: "list[str]") -> str:
    """plist 를 맞추고 launchd 에 올린다: installed | reloaded | kicked | running | failed:<이유>."""
    if not managed():
        return "failed:격리 홈이라 LaunchAgent 를 건드리지 않는다"
    try:
        changed = _write_if_changed(plist_text(program))
    except OSError as exc:
        return f"failed:{exc}"
    st = status()
    if st == "absent":
        rc, out = _launchctl("bootstrap", _domain(), str(plist_path()))
        return "installed" if rc == 0 else "failed:" + out.strip()[-200:]
    if changed:
        _reload_detached()
        return "reloaded"
    if st == "loaded":
        rc, out = _launchctl("kickstart", _target())
        return "kicked" if rc == 0 else "failed:" + out.strip()[-200:]
    return "running"


def uninstall(permanent: bool = False) -> str:
    """permanent(= daemon-uninstall 명령)면 끔 표식을 남겨 ensure_daemon 이 다시 등록하지 않게 한다."""
    if not managed():
        return "absent"          # 격리 홈: 실제 plist 도 launchctl 도 건드리지 않는다
    if permanent:
        try:
            off_mark().write_text("daemon-uninstall — `marina session daemon-install` 로 다시 켠다\n")
        except OSError:
            pass
    had = plist_path().exists() or status() != "absent"
    _launchctl("bootout", _target())
    try:
        plist_path().unlink()
    except OSError:
        pass
    return "removed" if had else "absent"
