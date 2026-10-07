#!/usr/bin/env python3
"""꺼진 방 깨우기(스펙 §4) — 봇이 글 이벤트를 넘기면 밀린 글을 모아 첫 지시 하나로 세션을 띄운다. Claude 토큰 0."""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import marina_session as ms
import marina_discord_bot as mb

WAKE_RECENT_S = 600.0          # 이번 글 앞 이만큼 안의 못 읽은 글까지 한 지시로(연달아 쓴 글)
WAKE_PROMPT_MAX = 8000         # 바이트 — shlex.quote 로 감싼 뒤의 길이. tmux 가 한 명령으로 받는 길이 한도 안쪽(스펙 §10-3)
WAKE_NOTE = "[마리나] 이 방 세션이 꺼져 있는 동안 온 Discord 메시지야. 위 메시지에 답하고, 답은 Discord reply 로 보내 줘."
_OLDER = " 그 전에도 못 읽은 글이 {n}개 있어 — 필요하면 fetch_messages 로 보되, 지난 지시를 묻지 않고 실행하지는 마."
_DROPPED = " 앞선 글 {n}개는 길어서 뺐어 — fetch_messages 로 읽어."
_UNANSWERED = " 재시작 전에 받고 답하지 못한 메시지가 있으면 그것도 이어서 답해 줘."
_NAME = re.compile(r"[\s\"<>`@\\]+")
_FILE = re.compile(r"[\"<>;]+")


def enabled(cfg: dict[str, Any]) -> bool:
    return cfg.get("wake", True) is not False


def _seen_path() -> Path:
    return ms.marina_home() / "discord-wake-seen"


def mark_seen() -> None:
    """봇이 글 이벤트를 넘겨 이 CLI 가 불렸다는 표식 — '꺼진 방을 깨울 수 있는 경로가 실제로 살아 있다'는 증거(쉰 방 내리기가 본다)."""
    try:
        _seen_path().write_text(f"{time.time()}\n")
    except OSError:
        pass


def seen_at() -> float:
    try:
        return float(_seen_path().read_text())
    except (OSError, ValueError):
        return 0.0


def wake_event(channel: str, user: str = "", message: str = "", thread: str = "") -> str:
    """봇이 넘긴 글 이벤트 처리 — wake() 가 예외 없이 돌아오고 failed:* 가 아닐 때만 수신 표식을 남긴다
    (깨우기가 매번 실패하는데 표식만 열려 쉰 방이 내려가는 일을 막는다)."""
    r = wake(channel, user, message, thread)
    if not r.startswith("failed"):
        mark_seen()
    return r


def snowflake_ts(mid: str) -> float:
    return ((int(mid) >> 22) + 1420070400000) / 1000.0


def _woke(rec: dict[str, Any]) -> dict[str, Any]:
    try:
        d = json.loads((Path(str(rec.get("stateDir") or "/nonexistent")) / "woke.json").read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_woke(sd: Path, **kv: Any) -> None:
    d = _woke({"stateDir": str(sd)})
    d.update(kv)
    ms._write_json(sd / "woke.json", d)


def allow_list(rec: dict[str, Any]) -> "list[str] | None":
    """이 방 글을 받을 사람들 — 채널 플러그인의 gate() 와 같은 규칙. 빈 목록 = 채널을 보는 모두.
    None = 판단 못 함·멘션 필수 방 → 깨우지 않는다(켜져 있었어도 세션이 안 받았을 글)."""
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    try:
        g = json.loads((sd / "access.json").read_text(encoding="utf-8"))["groups"][str(rec["channelId"])]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not isinstance(g, dict) or g.get("requireMention", True):
        return None
    return [str(a) for a in g.get("allowFrom") or []]


def seen_ids(rec: dict[str, Any]) -> set[str]:
    tr = mb._session_transcript(rec)
    if not tr:
        return set()
    try:
        return {m.group(2) for m in ms._CHANNEL_TAG.finditer(mb._tail_text(tr))}
    except OSError:
        return set()


def base_id(rec: dict[str, Any]) -> str:
    tr = mb._session_transcript(rec)
    ids = [i for i in (ms.inbound_messages(tr, str(rec["channelId"])) if tr else []) if i.isdigit()]
    cands = [int(i) for i in ids[-1:]]
    b = str(_woke(rec).get("baseId") or "")
    if b.isdigit():
        cands.append(int(b))
    return str(max(cands)) if cands else ""


def _ok(m: dict[str, Any], allow: list[str], seen: set[str]) -> bool:
    a = m.get("author") or {}
    return bool(str(m.get("id") or "").isdigit() and not a.get("bot") and m.get("type") in (0, 19)
                and (not allow or str(a.get("id")) in allow) and str(m["id"]) not in seen
                and (m.get("content") or m.get("attachments")))


def missed(rec: dict[str, Any], dc: Any, since: float, trigger: str = "", thread: str = "") -> tuple[list[dict[str, Any]], int]:
    """(넘길 글들 — since 뒤, 오래된 것부터 · 그보다 오래된 못 읽은 글 수). 기준(마지막으로 읽은 글)이 없으면 이번 글만."""
    allow = allow_list(rec)
    if allow is None:
        return [], 0
    ch, seen, base = str(rec["channelId"]), seen_ids(rec), base_id(rec)
    rows = dc.get_messages(ch, base) if base else []
    if trigger and not any(str(r.get("id")) == str(trigger) for r in rows):
        one = dc.get_message(thread or ch, trigger)
        if one.get("author"):
            rows.append(dict(one, channel_id=str(one.get("channel_id") or thread or ch)))
    keep = sorted((m for m in rows if _ok(m, allow, seen)), key=lambda m: int(m["id"]))
    fresh = [m for m in keep if snowflake_ts(str(m["id"])) >= since]
    return fresh, len(keep) - len(fresh)


def _tag(m: dict[str, Any], default_channel: str = "") -> str:
    """공식 채널 플러그인과 같은 속성 — user 는 고유 username(표시 이름은 겹칠 수 있다), user_id 는 숫자만."""
    a = m.get("author") or {}
    who = _NAME.sub(" ", str(a.get("username") or "")).strip()[:40] or "user"
    uid = re.sub(r"[^A-Za-z0-9_-]", "", str(a.get("id") or ""))
    atts = [x for x in m.get("attachments") or [] if isinstance(x, dict)]
    body = (str(m.get("content") or "") or ("(attachment)" if atts else "")).replace("</channel", "<\u200b/channel")
    extra = ""
    if atts:
        names = "; ".join("{} ({}, {}KB)".format(_FILE.sub("_", str(x.get("filename") or "file")),
                                                 _FILE.sub("_", str(x.get("content_type") or "unknown")), int(x.get("size") or 0) // 1024) for x in atts)
        extra = ' attachment_count="{}" attachments="{}"'.format(len(atts), names)
    ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(snowflake_ts(str(m["id"]))))
    chat = str(m.get("channel_id") or default_channel)
    return ('<channel source="plugin:discord:discord" chat_id="{}" message_id="{}" user="{}" user_id="{}" ts="{}"{}>\n{}\n</channel>'
            .format(chat, m["id"], who, uid, ts, extra, body))


def wake_prompt(msgs: list[dict[str, Any]], older: int = 0, unanswered: bool = False) -> str:
    """채널 플러그인이 넘기는 것과 같은 태그 — 받은 순간 👀·🛑·reply_to 훅이 켜져 있던 방과 똑같이 돈다."""
    tail = (_OLDER.format(n=older) if older else "") + (_UNANSWERED if unanswered else "")
    keep = list(msgs)
    while keep:
        dropped = len(msgs) - len(keep)
        text = "\n".join(_tag(m) for m in keep) + "\n" + WAKE_NOTE + (_DROPPED.format(n=dropped) if dropped else "") + tail
        if len(shlex.quote(text).encode("utf-8")) <= WAKE_PROMPT_MAX:
            return text
        keep.pop(0)
    last = msgs[-1]
    return ("[마리나] 이 방 세션이 꺼져 있는 동안 Discord 메시지 {}개가 왔어(마지막 message_id={}, chat_id={}). "
            "fetch_messages 로 읽고 답해 줘. 답은 Discord reply 로.".format(len(msgs), last["id"], last.get("channel_id") or "")) + tail


WAKE_EMOJI = "⏰"
WAKE_SETTLE_S = 45.0           # 깨운 뒤 이만큼 지나 한 번 본다(플러그인이 접속할 시간, 스펙 §10-6)
WAKE_LATE_AGE_S = 15.0         # 이보다 갓 온 글은 플러그인이 아직 받을 수 있다
WAKE_NOTICE_EVERY = 600.0
WAKE_FAIL_NOTICE = "⚠️ 이 방을 깨우지 못했어 — 맥에서 확인이 필요해"
WAKE_LATE_TEXT = ("[마리나] 깨어나는 동안 이 채널에 메시지가 더 왔는데 받지 못했어. "
                  "fetch_messages 로 방금 몇 분 안에 온 메시지만 읽고, 그중 아직 답하지 않은 것만 답해 줘(그보다 오래된 지시는 실행하지 마). 답은 Discord reply 로.")


def _react(dc: Any, ch: str, mid: str, add: str = "", remove: str = "") -> None:
    for fn, e in ((dc.remove_reaction, remove), (dc.add_reaction, add)):
        if e:
            try:
                fn(ch, mid, e)
            except ms.SessionError:
                pass


def _spawn_settle(channel: str, started: float) -> None:
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "settle", str(channel), str(started)],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def wake(channel: str, user: str = "", message: str = "", thread: str = "", since: "float | None" = None) -> str:
    """꺼진 방에 글이 왔다(또는 훑기·내린 뒤 확인). 방마다 한 번에 하나만(잠금)."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec:
        return "ignored:unknown"
    try:
        cfg = ms.load_config()
    except ms.SessionError:
        return "ignored:noconfig"
    if not enabled(cfg):
        return "ignored:off"
    allow = allow_list(rec)
    if allow is None or (user and allow and str(user) not in allow):
        return "ignored:not-allowed"
    name = str(rec.get("tmux") or "")
    if ms.tmux_alive(name):
        return "alive"                       # 그 세션의 채널 플러그인이 직접 받는다
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    if not sd.is_dir():
        return "failed:상태 폴더가 없어"
    with ms.room_lock(sd) as got:
        if not got:
            try:                             # 재시작(stop→start) 중이었다면 끝난 뒤 이 글을 한 번 더 본다(marina_discord_bot._settle_after_restart)
                (sd / "wake-busy-at").write_text(f"{time.time()}\n")
            except OSError:
                pass
            return "busy"
        if ms.tmux_alive(name):
            return "alive"
        return _wake_locked(rec, cfg, sd, str(message or ""), str(thread or ""), since)


def _start_with_launch_env(ref: str, sd: Path, first: str) -> tuple[list[str], list[str]]:
    """마지막으로 띄운 환경(PATH·LANG·LC_ALL)으로 cmd_start — 끝나면 이 프로세스의 환경을 되돌린다(데몬 안에서 불려도 안전)."""
    keep = {k: os.environ.get(k) for k in ms._LAUNCH_ENV_KEYS}
    try:
        ms.apply_launch_env(sd)
        return ms.cmd_start(ref, first=first)
    finally:
        for k, v in keep.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def _wake_locked(rec: dict[str, Any], cfg: dict[str, Any], sd: Path, message: str, thread: str, since: "float | None") -> str:
    dc, now = mb._dc(cfg), time.time()
    ch, name = str(rec["channelId"]), str(rec.get("tmux") or "")
    if since is None:
        since = (snowflake_ts(message) if message.isdigit() else now) - WAKE_RECENT_S
    try:
        msgs, older = missed(rec, dc, since, trigger=message, thread=thread)
    except ms.SessionError as exc:
        mb._log(f"wake {ch}: Discord 읽기 실패 {exc}")
        return "failed:discord"
    if not msgs:
        return "nothing"
    last = msgs[-1]
    lch, lid = str(last.get("channel_id") or ch), str(last["id"])
    _react(dc, lch, lid, add=WAKE_EMOJI)
    try:
        dc._req("POST", f"/channels/{ch}/typing")
    except ms.SessionError:
        pass
    ref = f"{rec.get('project')}/{rec.get('task')}"
    try:
        started, failed = _start_with_launch_env(ref, sd, wake_prompt(msgs, older, interrupted(rec, now)))
    except Exception as exc:
        started, failed = [], [f"{ref}: {exc}"]
    if started or ms.tmux_alive(name):        # 같은 순간 다른 쪽(restart 대기자·형)이 띄웠어도 실패가 아니다
        _react(dc, lch, lid, remove=WAKE_EMOJI)
        _save_woke(sd, at=now, ok=True, delivered=[str(m["id"]) for m in msgs] if started else [])
        _spawn_settle(ch, now)
        mb._log(f"wake {ref}: 깨움({len(msgs)}개)" if started else f"wake {ref}: 이미 떠 있음")
        return "woke" if started else "alive"
    why = failed[0].split(": ", 1)[-1] if failed else "알 수 없는 이유"
    _react(dc, lch, lid, add="⚠️", remove=WAKE_EMOJI)
    notice_at = float(_woke(rec).get("noticeAt") or 0)
    if now - notice_at >= WAKE_NOTICE_EVERY:
        try:
            dc.send_message(ch, WAKE_FAIL_NOTICE)         # 원문(로컬 경로 등)은 채널에 올리지 않는다 — 로그에만
            notice_at = now
        except ms.SessionError:
            pass
    _save_woke(sd, at=now, ok=False, why=why[:300], noticeAt=notice_at)
    mb._log(f"wake {ref}: 실패 {why[:200]}")
    return "failed:" + why


def wake_settle(channel: str, started: float, wait: bool = True) -> str:
    """깨어나는 동안(첫 지시를 모은 뒤 ~ 플러그인 접속 전) 온 글은 아무도 못 받는다 — 한 번 보고, 있으면 고정 문구로 읽게 한다."""
    if wait:
        time.sleep(max(0.0, float(started) + WAKE_SETTLE_S - time.time()))
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec or not ms.tmux_alive(str(rec.get("tmux") or "")):
        return "dead"
    delivered = set(_woke(rec).get("delivered") or [])
    try:
        msgs, _ = missed(rec, mb._dc(ms.load_config()), since=float(started) - 5.0)
    except ms.SessionError:
        return "ok"
    now = time.time()
    late = [m for m in msgs if str(m["id"]) not in delivered and now - snowflake_ts(str(m["id"])) >= WAKE_LATE_AGE_S]
    if not late:
        return "ok"
    _save_woke(Path(str(rec["stateDir"])), baseId=str(late[-1]["id"]))
    mb._spawn_type(str(rec["tmux"]), WAKE_LATE_TEXT, str(channel), "")
    return "nudged"


SWEEP_MAX_AGE_S = 12 * 3600.0     # 이보다 오래된 글은 스스로 실행하지 않는다(밤새 꺼 둔 맥은 되고 일주일은 안 된다)
SWEEP_COOLDOWN_S = 600.0
SWEEP_MAX_ROOMS = 3               # 한 번에 깨우는 방 — 재부팅 직후 열두 방이 한꺼번에 claude 를 띄우지 않게
SWEEP_RETRIES = 5
SWEEP_RETRY_S = 60.0
RESUME_INTERRUPTED = True         # 형 결정 ③: 재부팅 순간 일하던 방을 다시 켜서 이어받게(재부팅 뒤 첫 훑기만)


def interrupted(rec: dict[str, Any], now: float) -> bool:
    """턴 도중 끊겼나 — resume_unanswered 와 같은 기준(1시간 안에 받은 Discord 지시에 답을 못 함)."""
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))

    def num(name: str) -> float:
        try:
            return float((sd / name).read_text())
        except (OSError, ValueError):
            return 0.0
    turn = num("turn-at")
    if not (turn > num("stopped-at") and now - turn < 3600):
        return False
    tr = mb._session_transcript(rec)
    return bool(tr and ms.unanswered(tr))


def wake_after_idle(channel: str) -> str:
    """쉰 방을 내린 직후의 확인 — 밀린 글이 없는데(nothing) 내리는 순간 턴이 시작돼 끊겼다면(interrupted) 다시 켜서 이어받는다."""
    r = wake(channel)
    if r != "nothing":
        return r
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    now = time.time()
    if rec and not ms.tmux_alive(str(rec.get("tmux") or "")) and interrupted(rec, now) and _resume_interrupted(rec, now):
        return "woke"
    return r


def _resume_interrupted(rec: dict[str, Any], now: float) -> bool:
    """끊긴 방을 켜서 이어받게 — 방 잠금 안에서, 마지막으로 띄운 환경으로, 이어받기 문구를 첫 지시로(sessionId 없는 개발 방도)."""
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    ref = f"{rec.get('project')}/{rec.get('task')}"
    if not sd.is_dir():
        return False
    with ms.room_lock(sd) as got:
        if not got or ms.tmux_alive(str(rec.get("tmux") or "")):
            return False
        started, _failed = _start_with_launch_env(ref, sd, ms.RESUME_TEXT)
        if started:
            _save_woke(sd, at=now, ok=True, delivered=[])
        return bool(started)


def _sweep_pass(since: float, now: float, resume: bool, limit: int) -> "tuple[list[str], bool]":
    """(깨운 방들, 다시 훑어야 하나). 한 번에 깨우는 방은 limit 개 — 나머지는 다음 훑기."""
    out: list[str] = []
    retry = False
    for rec in ms.load_sessions():
        ch, ref = str(rec.get("channelId") or ""), f"{rec.get('project')}/{rec.get('task')}"
        if not ch or ms.tmux_alive(str(rec.get("tmux") or "")):
            continue
        if now - float(_woke(rec).get("at") or 0) < SWEEP_COOLDOWN_S:
            continue
        if len(out) >= limit:
            retry = True
            break
        try:
            r = wake(ch, since=since)
            if r == "failed:discord":
                retry = True
            if r == "nothing" and resume and RESUME_INTERRUPTED and interrupted(rec, now):
                if _resume_interrupted(rec, now):
                    r = "woke"
        except Exception as exc:
            mb._log(f"sweep {ref} 실패: {exc!r}")
            continue
        if r == "woke":
            out.append(ref)
    return out, retry


def sweep(since: float, now: "float | None" = None, resume: bool = False, limit: int = SWEEP_MAX_ROOMS) -> list[str]:
    """봇이 꺼져 있던 동안(since~지금) 온 글을 꺼진 방마다 한 번 본다. 방 하나씩 차례로, 한 번에 최대 limit 방.
    resume(= 재부팅 뒤 첫 훑기)일 때만 턴 도중 끊긴 방도 다시 켠다."""
    now = time.time() if now is None else now
    return _sweep_pass(max(float(since), now - SWEEP_MAX_AGE_S), now, resume, limit)[0]


def run_sweep(since: float, resume: bool = False) -> list[str]:
    """훑기 한 번 + Discord 실패·방 수 제한으로 남았으면 1분 뒤부터 최대 5번 다시. 전역 잠금으로 동시에 하나만."""
    import fcntl
    try:
        ms.marina_home().mkdir(parents=True, exist_ok=True)
        lk = open(ms.marina_home() / "sweep.lock", "w")
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return []
    try:
        woke: list[str] = []
        for i in range(1 + SWEEP_RETRIES):
            now = time.time()
            out, retry = _sweep_pass(max(float(since), now - SWEEP_MAX_AGE_S), now, resume, SWEEP_MAX_ROOMS)
            woke += out
            if not retry:
                break
            if i < SWEEP_RETRIES:
                time.sleep(SWEEP_RETRY_S)
        return woke
    finally:
        lk.close()


def main(argv: list[str]) -> int:
    import argparse
    p = argparse.ArgumentParser(prog="marina_discord_wake")
    sub = p.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("wake")
    w.add_argument("--channel", required=True); w.add_argument("--user", default="")
    w.add_argument("--message", default=""); w.add_argument("--thread", default="")
    w.add_argument("--after-idle", action="store_true")
    s = sub.add_parser("settle")
    s.add_argument("channel"); s.add_argument("started", type=float)
    sw = sub.add_parser("sweep")
    sw.add_argument("since", type=float)
    sw.add_argument("--resume", action="store_true")
    a = p.parse_args(argv)
    # 봇이 띄운 python 의 PATH 는 짧다(<bun>:/usr/bin:/bin) — claude·tmux·git 을 찾게 데몬과 같은 경로로 보강
    os.environ["PATH"] = ms.daemon_path() + ":" + os.environ.get("PATH", "")
    try:
        if a.cmd == "wake":
            if a.after_idle:
                print(wake_after_idle(a.channel))
            elif a.message:
                print(wake_event(a.channel, a.user, a.message, a.thread))     # 봇이 넘긴 글 이벤트
            else:
                print(wake(a.channel, a.user, a.message, a.thread))
        elif a.cmd == "sweep":
            print(" ".join(run_sweep(a.since, a.resume)) or "nothing")
        else:
            print(wake_settle(a.channel, a.started))
    except Exception as exc:              # 원문은 로그에만
        mb._log(f"wake {a.cmd} 실패: {exc!r}")
        print("failed:error")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
