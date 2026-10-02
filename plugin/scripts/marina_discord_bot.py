"""마리나 Discord 봇 1단계 — 🛑 정지 · #상태 대시보드 · 주간 숫자판 · 작업 중 '입력 중…'.

discord.json 이 있을 때만 마리나 데몬이 run_forever 를 돌린다(선택 기능). 판단·그리기는 전부 여기(파이썬)에 두고,
봇(marina-discord-bot/bot.ts, bun)은 반응 이벤트를 받아 `interrupt` 를 부르는 일만 한다 — 로직을 두 언어로 나누지 않는다.
설계: docs/superpowers/specs/2026-10-02-marina-discord-bot-design.md
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import marina_session as ms

_CONNECT = 1 << 20
_SEND = 1 << 11
_HISTORY = 1 << 16
TYPING_EVERY = 8.0       # Discord '입력 중…' 은 10초면 꺼진다
BUSY_EVERY = 30.0        # 작업 중일 때만 대시보드를 이 간격으로 다시 그린다
WEEKLY_EVERY = 600.0     # 채널 이름 변경은 10분 2회 제한
USAGE_TTL = 120.0
DASHBOARD_NAME = "상태"
BOT_DIR = Path(__file__).resolve().parent / "marina-discord-bot"

mark_dirty = ms.dashboard_signal


def dirty_mtime() -> float:
    try:
        return ms.dashboard_signal_path().stat().st_mtime
    except OSError:
        return 0.0


def should_render(now: float, last: float, dirty: float, busy: bool) -> bool:
    """신호(턴 시작·끝, 세션 켜짐·꺼짐)는 바로, 작업 중이면 30초마다. 쉬는 동안엔 안 그린다(늦게 바뀌는 표시 금지)."""
    return dirty > last or (busy and now - last >= BUSY_EVERY)


# ── 상태 저장(~/.marina/discord-bot.json) ───────────────────────────────────

def _state_path() -> Path:
    return ms.marina_home() / "discord-bot.json"


def _load_state() -> dict[str, Any]:
    try:
        d = json.loads(_state_path().read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_section(key: str, val: dict[str, Any]) -> None:
    d = _load_state()
    d[key] = val
    ms._write_json(_state_path(), d)


# ── 수집 ────────────────────────────────────────────────────────────────────

def owner_ids(cfg: dict[str, Any]) -> list[str]:
    """형 = 개발 프로젝트(chat 제외)의 allow 목록."""
    out: list[str] = []
    for name, pc in (cfg.get("projects") or {}).items():
        if name == ms.CHAT_PROJECT or not isinstance(pc, dict):
            continue
        for u in pc.get("allow") or []:
            if str(u) not in out:
                out.append(str(u))
    return out


def claude_usage() -> list[dict[str, Any]]:
    try:
        import marina_sessions
        return list(marina_sessions.provider_account_usage("claude").get("windows") or [])
    except Exception:
        return []


_usage_cache: dict[str, Any] = {"at": 0.0, "val": []}


def _usage() -> list[dict[str, Any]]:
    now = time.time()
    if now - _usage_cache["at"] > USAGE_TTL:
        _usage_cache.update(at=now, val=claude_usage())
    return _usage_cache["val"]


_SPINNER = re.compile(r"^\S\s+\S.*…\s*\((?:\d|esc to interrupt)")


def _pane_busy(name: str) -> tuple[bool, bool]:
    """(켜짐, 작업 중). 작업 중 = 입력창(❯) 바로 위에 돌아가는 표시 줄('✢ Schlepping… (5m 41s · …)')이 있음.
    화면 전체를 찾으면 대화 내용에 같은 글자가 있을 때 틀린다 — 입력창 바로 위 블록만 본다(실측)."""
    if not ms.tmux_alive(name):
        return False, False
    lines = (ms._tmux("capture-pane", "-p", "-t", name).stdout or "").rstrip().splitlines()
    box = max((i for i, l in enumerate(lines) if l.startswith("❯")), default=-1)
    # 입력창 위로 올라가며 빈 줄·구분선·들여쓴 줄(⎿ 팁·할 일 목록 등, 길이 무관)을 건너뛴 첫 줄이 표시 줄이다(리뷰 M1)
    for line in reversed(lines[:max(box, 0)]):
        if not line.strip() or line.lstrip().startswith("─") or line[:1].isspace():
            continue
        return True, bool(_SPINNER.search(line))
    return True, False


def _ctx_percent(rec: dict[str, Any]) -> float | None:
    sid = str(rec.get("sessionId") or "")
    path = ms.find_transcript(sid) if sid else None
    if not path:
        return None
    try:
        import marina_sessions
        return marina_sessions.agent_usage_from_path(path, "claude").get("contextPercent")
    except Exception:
        return None


def snapshot(full: bool = True) -> dict[str, Any]:
    """full=False: 4초마다 도는 가벼운 판정(작업 중 여부만). ctx·사용량·서버는 그릴 때만."""
    rows = []
    for rec in ms.load_sessions():
        if str(rec.get("kind") or "").endswith("lobby") or not rec.get("channelId"):
            continue
        alive, busy = _pane_busy(str(rec.get("tmux") or ""))
        act = ms._activity_state(Path(str(rec.get("stateDir") or "/nonexistent")))
        rows.append({"ref": f"{rec.get('project')}/{rec.get('task')}", "channelId": str(rec["channelId"]),
                     "alive": alive, "busy": busy, "emoji": str(act.get("emoji") or "") if busy else "",
                     "ctx": _ctx_percent(rec) if alive and full else None})
    if not full:
        return {"sessions": rows, "anyBusy": any(r["busy"] for r in rows)}
    try:
        free = shutil.disk_usage(str(Path.home())).free
    except OSError:
        free = 0
    try:
        load = os.getloadavg()[0]
    except OSError:
        load = 0.0
    return {"usage": _usage(), "diskFree": free, "load": load, "sessions": rows,
            "anyBusy": any(r["busy"] for r in rows)}


def render(snap: dict[str, Any]) -> str:
    """시각 줄을 뺀 본문 — 같으면 메시지를 안 고친다."""
    use = " · ".join(f"{w.get('label')} {round(float(w.get('usedPercent') or 0))}%"
                     for w in snap["usage"] if w.get("key") in ("fiveHour", "weekly"))
    lines = [f"**구독** {use or '알 수 없음'}",
             f"**서버** 디스크 여유 {snap['diskFree'] // (1 << 30)}GB · 부하 {snap['load']:.1f}"]
    rows = sorted(snap["sessions"], key=lambda r: (not r["busy"], not r["alive"], r["ref"]))
    lines.append(f"**작업 중 {sum(r['busy'] for r in rows)} / 세션 {len(rows)}**")
    for r in rows:
        head = f"{r['emoji'] or '🔧'} 작업 중" if r["busy"] else ("💤 대기" if r["alive"] else "⚫ 꺼짐")
        ctx = f" · ctx {round(r['ctx'])}%" if isinstance(r.get("ctx"), (int, float)) else ""
        lines.append(f"{head} · {r['ref']}{ctx} · <#{r['channelId']}>")
    body = "\n".join(lines)
    return body if len(body) <= 1900 else body[:1900] + "\n…"


# ── Discord ─────────────────────────────────────────────────────────────────

def _dc(cfg: dict[str, Any]) -> ms.Discord:
    return ms.Discord(ms.read_token(cfg))


def _owner_channel(dc: ms.Discord, cfg: dict[str, Any], name: str, kind: int) -> str:
    """@everyone 은 막고 형·봇만 연다(만들 때 덮어쓰기 — 봇에 역할 관리 권한이 없어도 된다)."""
    guild = str(cfg["guildId"])
    if kind == 2:   # 음성 = 숫자판: 보이기만, 들어가지 못함
        owner = {"allow": str(ms._VIEW), "deny": str(_CONNECT)}
        everyone_deny = ms._VIEW | _CONNECT
    else:           # #상태: 읽기만
        owner = {"allow": str(ms._VIEW | _HISTORY), "deny": str(_SEND)}
        everyone_deny = ms._VIEW
    ow = [{"id": guild, "type": 0, "allow": "0", "deny": str(everyone_deny)},
          {"id": dc.me(), "type": 1, "allow": str(ms._TALK), "deny": "0"}]
    ow += [dict(owner, id=u, type=1) for u in owner_ids(cfg)]
    r = dc._req("POST", f"/guilds/{guild}/channels",
                {"name": name, "type": kind, "position": 0, "permission_overwrites": ow})
    return str(r["id"])


def dashboard_tick(st: dict[str, Any], snap: dict[str, Any] | None = None) -> None:
    cfg = ms.load_config()
    dc = _dc(cfg)
    if not st:
        st.update(_load_state().get("dashboard") or {})
    snap = snap or snapshot()
    body = render(snap)
    if body == st.get("body") and st.get("messageId"):
        return
    content = f"{body}\n-# <t:{int(time.time())}:R> 갱신"
    msg = {"content": content, "allowed_mentions": {"parse": []}}
    for _ in range(2):
        if not st.get("channelId"):
            st.clear()
            st["channelId"] = _owner_channel(dc, cfg, DASHBOARD_NAME, 0)
            _save_section("dashboard", dict(st))      # 다음 단계가 실패해도 채널을 또 만들지 않게(리뷰 M4)
        try:
            if st.get("messageId"):
                dc._req("PATCH", f"/channels/{st['channelId']}/messages/{st['messageId']}", msg)
            else:
                st["messageId"] = str(dc._req("POST", f"/channels/{st['channelId']}/messages", msg).get("id") or "")
            st["body"] = body
            break
        except ms.DiscordError as exc:
            if exc.code != 404:
                raise
            # 메시지를 지웠으면 새로 올리고, 채널을 지웠으면 채널부터 다시 만든다
            if st.get("messageId"):
                st.pop("messageId", None)
                try:
                    dc._req("GET", f"/channels/{st['channelId']}")
                except ms.DiscordError as gone:
                    if gone.code != 404:      # 일시 오류로 채널을 새로 만들지 않는다(리뷰 M4)
                        raise
                    st.pop("channelId", None)
            else:
                st.pop("channelId", None)
    _save_section("dashboard", dict(st))


def weekly_tick(st: dict[str, Any]) -> None:
    cfg = ms.load_config()
    dc = _dc(cfg)
    if not st:
        st.update(_load_state().get("weekly") or {})
    w = next((x for x in claude_usage() if x.get("key") == "weekly"), None)
    if w is None:
        return
    name = f"📊 주간 {round(float(w.get('usedPercent') or 0))}%"
    if st.get("channelId") and st.get("name") == name:
        return
    # 이름 변경은 10분 2회 제한 — 데몬을 연달아 재시작해도 넘지 않게 마지막 변경 시각을 저장해 둔다(리뷰 M5)
    if st.get("channelId") and time.time() - float(st.get("renamedAt") or 0) < WEEKLY_EVERY:
        return
    if st.get("channelId"):
        try:
            dc._req("PATCH", f"/channels/{st['channelId']}", {"name": name})
        except ms.DiscordError as exc:
            if exc.code != 404:
                raise
            st.clear()
    if not st.get("channelId"):
        st["channelId"] = _owner_channel(dc, cfg, name, 2)
    st.update(name=name, renamedAt=time.time())
    _save_section("weekly", dict(st))


def typing_tick(snap: dict[str, Any], ty: dict[str, float], now: float) -> None:
    busy = [r["channelId"] for r in snap["sessions"] if r["busy"]]
    if not busy:
        return
    dc = _dc(ms.load_config())
    for ch in busy:
        if now - ty.get(ch, 0.0) >= TYPING_EVERY:
            ty[ch] = now
            try:
                dc._req("POST", f"/channels/{ch}/typing")
            except ms.SessionError:
                pass


# ── 🛑 정지 ─────────────────────────────────────────────────────────────────

def _session_transcript(rec: dict[str, Any]) -> Path | None:
    sid = str(rec.get("sessionId") or "")
    if sid:
        return ms.find_transcript(sid)
    d = ms.transcript_path(Path(str(rec.get("root") or "/nonexistent")), "x").parent
    hits = list(d.glob("*.jsonl")) if d.is_dir() else []
    return max(hits, key=lambda p: p.stat().st_mtime) if hits else None


def interrupt(channel: str, user: str, message: str) -> str:
    """🛑 → 그 세션에 Esc. 대상 지시 = 기록의 마지막 메시지(누른 메시지가 스레드 상태 줄·옛 메시지여도, 리뷰 I3).
    진행 훅과 같은 잠금 안에서 한다 — 떼자마자 진행 훅이 다시 달거나, 두 번 눌려 Esc 가 두 번 가지 않게(리뷰 I2·I4)."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec:
        return "모르는 채널이야"
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    try:
        allow = json.loads((sd / "access.json").read_text(encoding="utf-8"))["groups"][str(channel)].get("allowFrom") or []
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        allow = None
    # 허용 목록이 빈 채팅방은 역할로 보이는 사람이 곧 쓸 수 있는 사람이다. 봇 자신(미리 단 🛑)은 제외(리뷰 M8)
    dc = _dc(ms.load_config())
    if allow is None or (allow and str(user) not in [str(a) for a in allow]) or str(user) == dc.me():
        return "멈출 권한이 없어"
    lockf = ms._wait_lock(sd / "activity.lock", timeout=3.0)
    try:
        alive, busy = _pane_busy(str(rec.get("tmux") or ""))
        if not busy:
            return "지금 쉬고 있어"
        tr = _session_transcript(rec)
        ids = ms.inbound_messages(tr, str(channel)) if tr else []
        mid = ids[-1] if ids else ""
        mark = sd / "interrupted"
        try:
            last_mid, last_at = mark.read_text().split()
            if last_mid == mid and time.time() - float(last_at) < 10:
                return "이미 멈췄어"
        except (OSError, ValueError):
            pass
        ms._tmux("send-keys", "-t", str(rec["tmux"]), "Escape")
        if sd.is_dir():
            mark.write_text(f"{mid} {time.time()}\n")
        # Esc 로 끝난 턴엔 Stop 훅이 안 돈다 — 턴 끝과 같은 정리(달아 둔 표시 전부 떼기·끝 표시 전진)를 여기서(리뷰 B-I2)
        ms._clear_locked(rec, sd, dc, ids)
        if mid:
            try:
                dc.add_reaction(str(channel), mid, "⏹️")
            except ms.SessionError:
                pass
    finally:
        if lockf:
            lockf.close()
    mark_dirty()
    return "멈췄어"


# ── 봇 프로세스·데몬 루프 ────────────────────────────────────────────────────

def _bun() -> str:
    found = shutil.which("bun")
    if found:
        return found
    for cand in ("/opt/homebrew/bin/bun", str(Path.home() / ".bun/bin/bun"), "/usr/local/bin/bun"):
        if os.access(cand, os.X_OK):
            return cand
    return ""


def bot_command(cfg: dict[str, Any]) -> dict[str, Any] | None:
    bun = _bun()
    if not bun:
        return None
    env = {k: v for k, v in os.environ.items() if k.startswith("MARINA_") or k in ("HOME", "USER", "LANG", "TMPDIR")}
    env.update(PATH=f"{Path(bun).parent}:/usr/bin:/bin", DISCORD_BOT_TOKEN=ms.read_token(cfg),
               MARINA_GUILD=str(cfg["guildId"]), MARINA_PY=sys.executable, MARINA_BOT_PY=str(Path(__file__).resolve()),
               MARINA_PARENT_PID=str(os.getpid()))
    return {"argv": [bun, "bot.ts"], "cwd": str(BOT_DIR), "env": env, "bun": bun}


def _log(msg: str) -> None:
    p = ms.marina_home() / "discord-bot.log"
    try:
        if p.exists() and p.stat().st_size > 1 << 20:
            p.unlink()
        with open(p, "a", encoding="utf-8") as fh:
            fh.write(time.strftime("%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


_spawn = subprocess.Popen


class Loop:
    """마리나 데몬 스레드 한 바퀴(4초). discord.json 이 없으면 봇을 내리고 아무것도 안 한다(생기면 그때 시작)."""

    def __init__(self) -> None:
        self.dash: dict[str, Any] = {}
        self.week: dict[str, Any] = {}
        self.ty: dict[str, float] = {}
        self.last_render = -1.0          # 데몬이 막 떴으면 한 번은 그린다
        self.last_weekly = -WEEKLY_EVERY
        self.proc: subprocess.Popen | None = None
        self.next_start, self.backoff, self.started = 0.0, 5.0, 0.0
        self.lockf: Any = None
        self.last_err = ""

    def own(self) -> bool:
        """같은 마리나 홈에선 한 인스턴스만(프리뷰 데몬이 실 ~/.marina 를 공유해도 봇이 둘 뜨지 않게, 리뷰 I1)."""
        if self.lockf:
            return True
        import fcntl
        try:
            f = open(ms.marina_home() / "discord-bot.lock", "w")
        except OSError:
            return False
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            f.close()
            return False
        self.lockf = f
        return True

    def stop_bot(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def supervise(self, cfg: dict[str, Any], now: float) -> None:
        if self.proc is not None and self.proc.poll() is None:
            return
        if self.proc is not None:        # 죽었다 — 1분 안에 또 죽으면 간격을 늘린다
            self.backoff = min(self.backoff * 2, 300.0) if now - self.started < 60 else 5.0
            _log(f"bot exited {self.proc.returncode}, restart in {self.backoff:.0f}s")
            self.proc = None
            self.next_start = now + self.backoff
            return
        if now < self.next_start:
            return
        cmd = bot_command(cfg)
        if not cmd:
            return
        if not (BOT_DIR / "node_modules").is_dir():
            # 설치 스크립트엔 토큰을 넘기지 않고, 잠금 파일에 적힌 버전만 받는다(리뷰 M2)
            env = {k: v for k, v in cmd["env"].items() if k != "DISCORD_BOT_TOKEN"}
            subprocess.run([cmd["bun"], "install", "--no-summary", "--frozen-lockfile"], cwd=cmd["cwd"], env=env,
                           capture_output=True, timeout=300)
        with open(ms.marina_home() / "discord-bot.log", "a") as logf:
            self.proc = _spawn(cmd["argv"], cwd=cmd["cwd"], env=cmd["env"], stdout=logf, stderr=logf,
                                         stdin=subprocess.DEVNULL)
        self.started = now

    def step(self, now: float) -> bool:
        """설정이 있으면 True."""
        try:
            cfg = ms.load_config()
        except ms.SessionError:
            self.stop_bot()
            return False
        if not self.own():
            return False
        for name, fn in (("bot", lambda: self.supervise(cfg, now)), ("view", lambda: self.view(now))):
            try:
                fn()
            except Exception as exc:     # 데몬 스레드는 죽으면 안 된다 — 남기되 같은 오류는 한 번만(리뷰 M3)
                err = f"{name} failed: {exc!r}"
                if err != self.last_err:
                    _log(err)
                self.last_err = err
        return True

    def view(self, now: float) -> None:
        light = snapshot(full=False)
        typing_tick(light, self.ty, now)
        if should_render(now, self.last_render, dirty_mtime(), light["anyBusy"]):
            self.last_render = now
            dashboard_tick(self.dash)
        if now - self.last_weekly >= WEEKLY_EVERY:
            self.last_weekly = now
            weekly_tick(self.week)


def run_forever() -> None:
    loop = Loop()
    while True:
        time.sleep(4 if loop.step(time.time()) else 30)


def main(argv: list[str]) -> int:
    import argparse
    p = argparse.ArgumentParser(prog="marina_discord_bot")
    sub = p.add_subparsers(dest="cmd", required=True)
    it = sub.add_parser("interrupt")
    it.add_argument("--channel", required=True)
    it.add_argument("--user", required=True)
    it.add_argument("--message", required=True)
    a = p.parse_args(argv)
    try:
        print(interrupt(a.channel, a.user, a.message))
        return 0
    except ms.SessionError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
