#!/usr/bin/env python3
"""예약 브리핑 — ~/.marina/brief.json 의 시각에 launchd(marina.brief)가 `session brief-run` 을 불러 채팅방에 글을 넣는다(marina_discord_wake.say)."""
from __future__ import annotations

import datetime
import json
import os
import re
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape

import marina_session as ms
import marina_discord_launchd as ld

LABEL = "marina.brief"
DAYS = "일월화수목금토"          # launchd Weekday: 0·7 = 일요일, 1 = 월요일 …


def config_path() -> Path:
    return ms.marina_home() / "brief.json"


def plist_path() -> Path:
    return ld.plist_path().with_name(f"{LABEL}.plist")


def _last_path() -> Path:
    return ms.marina_home() / "brief-last"


def load() -> "dict[str, Any] | None":
    """설정 파일이 없으면 None(= 이 맥에선 브리핑을 안 쓴다). 있는데 틀리면 SessionError."""
    try:
        raw = config_path().read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        c = json.loads(raw)
        if not isinstance(c, dict):
            raise ValueError
    except ValueError:
        raise ms.SessionError(f"{config_path()} 이 올바른 JSON 객체가 아니야")
    ref, msg = str(c.get("ref") or "").strip(), str(c.get("message") or "").strip()
    if not ref or not msg:
        raise ms.SessionError("brief.json 에는 ref(프로젝트/이름)와 message 가 있어야 해")
    try:
        hour, minute = int(c["hour"]), int(c.get("minute", 0))
        days = [int(d) for d in c.get("weekdays", list(range(7)))]
    except (KeyError, TypeError, ValueError):
        raise ms.SessionError("brief.json 의 hour(0~23)·minute(0~59)·weekdays(0~7 숫자 목록)를 확인해")
    if not (0 <= hour <= 23 and 0 <= minute <= 59 and days and all(0 <= d <= 7 for d in days)):
        raise ms.SessionError("brief.json: hour 0~23, minute 0~59, weekdays 는 비지 않은 0~7(0·7 = 일요일)")
    return {"ref": ref, "message": msg, "hour": hour, "minute": minute, "weekdays": sorted({d % 7 for d in days})}


def plist_text(program: "list[str]", cfg: "dict[str, Any]") -> str:
    """RunAtLoad 없음 — 설치하는 순간 바로 돌지 않는다."""
    home = ms.marina_home()
    env = {"PATH": ms.daemon_path(), "MARINA_HOME": str(home), "PYTHONUNBUFFERED": "1", "LANG": "en_US.UTF-8"}
    args = "".join("<string>" + escape(a) + "</string>" for a in program)
    envx = "".join("\n    <key>" + escape(k) + "</key><string>" + escape(v) + "</string>" for k, v in env.items())
    cal = "".join(f"\n    <dict><key>Hour</key><integer>{cfg['hour']}</integer><key>Minute</key><integer>{cfg['minute']}</integer>"
                  f"<key>Weekday</key><integer>{d}</integer></dict>" for d in cfg["weekdays"])
    log = escape(str(home / "brief.log"))
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n'
            f'  <key>Label</key><string>{LABEL}</string>\n'
            f'  <key>ProgramArguments</key><array>{args}</array>\n'
            f'  <key>EnvironmentVariables</key>\n  <dict>{envx}\n  </dict>\n'
            f'  <key>WorkingDirectory</key><string>{escape(str(home))}</string>\n'
            f'  <key>StartCalendarInterval</key>\n  <array>{cal}\n  </array>\n'
            f'  <key>StandardOutPath</key><string>{log}</string>\n'
            f'  <key>StandardErrorPath</key><string>{log}</string>\n'
            '  <key>AbandonProcessGroup</key><true/>\n'     # 띄운 세션(tmux)을 job 이 끝날 때 같이 죽이지 않게
            '</dict>\n</plist>\n')


def _target() -> str:
    return f"{ld._domain()}/{LABEL}"


def status() -> str:
    rc, out = ld._launchctl("print", _target())
    if rc != 0:
        return "absent"
    return "running" if re.search(r"^\s*state = running\s*$", out, re.M) else "loaded"


def describe() -> str:
    try:
        cfg = load()
    except ms.SessionError as exc:
        return f"{LABEL}: 설정 오류 — {exc}"
    st = status()
    if cfg is None:
        return f"{LABEL}: {st} · 설정 없음({config_path()})"
    days = "".join(DAYS[d] for d in cfg["weekdays"])
    return f"{LABEL}: {st} · {cfg['hour']:02d}:{cfg['minute']:02d} ({days}) → {cfg['ref']}"


def install(program: "list[str]") -> str:
    """none(설정 없음 — 아무것도 안 함) | installed | failed:<이유>. 다시 부르면 새 설정으로 내렸다 올린다."""
    cfg = load()
    if cfg is None:
        return "none"
    if not ld.managed():
        return "failed:격리 홈이라 LaunchAgent 를 건드리지 않는다"
    p = plist_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(f"{p.name}.{os.getpid()}.tmp")
        tmp.write_text(plist_text(program, cfg), encoding="utf-8")
        os.replace(tmp, p)
    except OSError as exc:
        return f"failed:{exc}"
    ld._launchctl("bootout", _target())
    rc, out = ld._launchctl("bootstrap", ld._domain(), str(p))
    return "installed" if rc == 0 else "failed:" + out.strip()[-200:]


def uninstall() -> str:
    if not ld.managed():
        return "absent"
    had = plist_path().exists() or status() != "absent"
    ld._launchctl("bootout", _target())
    try:
        plist_path().unlink()
    except OSError:
        pass
    return "removed" if had else "absent"


# 예정 시각 기준 허용 창. launchd 는 잠든 맥이 깨면 밀린 job 을 그때 돌린다 — 새벽 0:05 에 깬 job 이 그날 몫을 먹으면 정시 몫이 skip:done 이 된다.
# 이른 쪽 10분: launchd 시각 오차·손으로 조금 일찍 돌려 보는 정도만. 늦은 쪽 2시간: "7:30 까지 도착"하려는 브리핑이라
# 출근길을 지난 뒤(9시 넘어) 도착하는 아침 브리핑은 쓸모가 없다 — 보내지 말고 정시 몫이 아닌 채로 넘긴다(기록도 안 한다).
EARLY = datetime.timedelta(minutes=10)
LATE = datetime.timedelta(hours=2)


def run(now: "datetime.datetime | None" = None) -> str:
    """launchd 가 부른다: none | skip:weekday | skip:early | skip:late | skip:done | sent | unconfirmed.
    같은 날 한 번 — launchd 가 잠든 맥에서 밀린 걸 몰아 돌려도 안 겹친다.
    보내기에 실패하면 SessionError 가 그대로 올라가고, 입력창에 글이 남은 채 들어간 게 확인 안 되면(unconfirmed) 기록하지 않는다(다음 기회에 다시)."""
    cfg = load()
    if cfg is None:
        return "none"
    now = now or datetime.datetime.now()
    if now.isoweekday() % 7 not in cfg["weekdays"]:
        return "skip:weekday"                # 금요일 몫이 주말에 늦게 깨어나 돌지 않게
    due = now.replace(hour=cfg["hour"], minute=cfg["minute"], second=0, microsecond=0)
    if now < due - EARLY:
        return "skip:early"
    if now > due + LATE:
        return "skip:late"
    today = now.strftime("%Y-%m-%d")
    try:
        if _last_path().read_text().strip() == today:
            return "skip:done"
    except OSError:
        pass
    import marina_discord_wake as mw
    if mw.say(cfg["ref"], cfg["message"], source="brief") == "typed":
        return "unconfirmed"
    _last_path().write_text(today + "\n")
    return "sent"
