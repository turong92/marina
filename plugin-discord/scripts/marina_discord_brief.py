#!/usr/bin/env python3
"""정해진 시각에 방에 글을 넣는 두 가지.
① 예약 브리핑 — ~/.marina/brief.json 의 시각에 launchd(marina.brief)가 `session brief-run` 을 부른다.
② 알림 예약 — ~/.marina/reminders.json 의 한 번만 울리는 알림. 데몬이 주기마다 때를 보고 `session remind-run` 을 띄운다.
둘 다 넣는 길은 marina_discord_wake.say 다."""
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


def due_reminders(rows: list, now: "datetime.datetime") -> bool:
    """때가 된 알림이 하나라도 있나 — 데몬이 주기마다 묻는다(파일만 읽고 아무것도 보내지 않는다).
    실패해서 미뤄 둔 것(nextTryAt)은 그 시각 전엔 세지 않는다."""
    for r in rows:
        try:
            at = ms.parse_when(str(r.get("at")))
        except ms.SessionError:
            return True             # 꼴이 깨진 줄도 치워야 한다
        if at <= now and float(r.get("nextTryAt") or 0) <= now.timestamp():
            return True
    return False


def run_reminders(now: "datetime.datetime | None" = None) -> str:
    """때가 된 알림을 방에 넣는다 — launchd 가 아니라 데몬이 떼어 낸 프로세스로 부른다(`session remind-run`).
    방이 바쁘면 say 가 쉬는 순간까지 기다리므로 데몬 루프 안에서 직접 부르면 안 된다.
    한 건을 보낼 때마다 그 건만 목록에서 지운다 — 중간에 프로세스가 죽어도 보낸 것을 다시 보내지 않는다."""
    import fcntl
    try:
        ms.marina_home().mkdir(parents=True, exist_ok=True)
        lk = open(ms.marina_home() / "reminders-run.lock", "w")
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return "skip:busy"          # 앞 판이 아직 보내는 중(say 가 기다리는 중일 수 있다)
    try:
        return _send_due(now)
    finally:
        lk.close()


def _update_one(rid: str, change: "dict | None") -> None:
    """그 예약 한 건만 고친다(change 가 None 이면 지운다). 목록을 통째로 쓰면 그 사이 방이 만든
    예약이 사라진다 — 보내는 동안 say 가 최대 30분 기다리기 때문이다(리뷰 C1)."""
    with ms.reminders_lock():
        rows = ms.load_reminders()
        out = []
        for r in rows:
            if str(r.get("id")) != rid:
                out.append(r)
            elif change is not None:
                out.append(dict(r, **change))
        ms.save_reminders(out)


def _notice_dropped(r: dict, why: str) -> None:
    """버린 알림을 그 방에 한 줄 알린다 — 조용히 사라지면 이 기능을 만든 이유가 없어진다(리뷰 B).
    say(tmux 로 세션에 넣기)가 아니라 REST 로 — 방을 깨우지도, 모델 턴을 쓰지도 않는다."""
    import marina_discord_bot as mb
    ch = str(r.get("channelId") or "")
    if not ch:
        return                      # 채널을 모르면 알릴 데가 없다(로그에만 남는다)
    at = str(r.get("at") or "").replace("T", " ")
    try:
        cfg = ms.load_config()
        dc = ms.Discord(ms.read_token_file(ms.token_file(cfg, str(r.get("ref") or "").split("/")[0])))
        dc.send_message(ch, f"⏰ 예약해 둔 알림을 보내지 못했어 — {at} 「{str(r.get('text') or '')[:200]}」 ({why})")
    except Exception as exc:
        mb._log(f"알림 실패를 방에 알리지도 못했어: {exc!r}")


def _room_moved(r: dict) -> bool:
    """예약할 때 적어 둔 채널과 지금 그 이름의 방이 다른가 — 방을 지우고 같은 이름으로 다시 열었을 때
    엉뚱한 방에 알림이 가지 않게(리뷰 S10)."""
    want = str(r.get("channelId") or "")
    if not want:
        return False                # 이 칸이 없던 때 만든 예약 — 이름만 믿는다
    try:
        now_ch = str(ms.find_session(str(r.get("ref"))).get("channelId") or "")
    except ms.SessionError:
        return False                # 방을 못 찾으면 say 가 알려 준다(여기서 버리지 않는다)
    return bool(now_ch) and now_ch != want


def _send_due(now: "datetime.datetime | None" = None) -> str:
    """now 를 주면 그 시각으로 고정한다(테스트). 안 주면 **건마다 다시 재는** 게 맞다 —
    앞 건의 say 가 오래 기다렸으면 그 사이 늦음·포기 판정이 달라진다(리뷰 S8)."""
    fixed = now is not None
    import marina_discord_wake as mw
    import marina_discord_bot as mb
    with ms.reminders_lock():
        rows = ms.load_reminders()
    if not rows:
        return "none"
    sent = dropped = 0
    for r in rows:
        rid, ref = str(r.get("id") or ""), str(r.get("ref") or "")
        if not fixed:
            now = datetime.datetime.now()   # 건마다 다시 — 앞 건이 오래 기다렸을 수 있다(리뷰 S8)
        try:
            at = ms.parse_when(str(r.get("at")))
        except ms.SessionError:
            _update_one(rid, None)
            dropped += 1
            continue
        if at > now or float(r.get("nextTryAt") or 0) > now.timestamp():
            continue
        late = (now - at).total_seconds()
        if late > ms.REMIND_GIVEUP_S or _room_moved(r):
            _update_one(rid, None)
            dropped += 1
            mb._log(f"알림 버림({'너무 지남' if late > ms.REMIND_GIVEUP_S else '방이 바뀜'}): "
                    f"{ref} {r.get('at')} {str(r.get('text'))[:60]}")
            continue
        text = str(r.get("text") or "")
        if late > ms.REMIND_LATE_S:
            text = f"(늦었어 — {at:%m월 %d일 %H:%M} 에 알리려던 거야) " + text
        with ms.reminders_lock():       # 보내는 사이에 취소했으면 보내지 않는다(리뷰 C)
            if not any(str(x.get("id")) == rid for x in ms.load_reminders()):
                continue
        try:
            out = mw.say(ref, text, source="remind")
        except Exception as exc:            # SessionError 만 잡으면 그 밖의 예외에 함수가 터져
            out = f"failed:{exc!r}"         # tries 도 못 늘리고 매분 다시 보낸다(리뷰 I3)
        if out in ("started", "delivered"):
            _update_one(rid, None)
            sent += 1
            mb._log(f"알림 보냄: {ref} {r.get('at')} {text[:60]}")
            continue
        tries = int(r.get("tries") or 0) + 1
        typed = int(r.get("typed") or 0) + (1 if out == "typed" else 0)
        # typed = 쳤는데 입력창에 남아 보임 — 화면을 못 읽어도 typed 라 **들어갔는데도** 나올 수 있다.
        # 그래서 한 번만 다시 해 본다(알림은 안 오는 것보다 두 번 오는 게 더 눈에 띈다, 리뷰 I2)
        if typed > 1 or tries >= ms.REMIND_TRIES:
            _update_one(rid, None)
            dropped += 1
            gave = "확인 못 함 두 번" if typed > 1 else f"{tries}번 실패"
            mb._log(f"알림 버림({gave}): {ref} {r.get('at')} — {out}")
            _notice_dropped(r, gave)        # 약속한 알림이 조용히 사라지지 않게
            continue
        wait = min(ms.REMIND_BACKOFF_S * (2 ** (tries - 1)), ms.REMIND_BACKOFF_MAX_S)
        _update_one(rid, {"tries": tries, "typed": typed, "nextTryAt": now.timestamp() + wait})
    with ms.reminders_lock():
        left = len(ms.load_reminders())
    return f"sent:{sent} drop:{dropped} keep:{left}"
