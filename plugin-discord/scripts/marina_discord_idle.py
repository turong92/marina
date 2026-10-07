#!/usr/bin/env python3
"""쉰 방 내리기(스펙 §5) — 훅이 적은 활동 시각으로 쉰 시간을 재고, 안전 재시작과 같은 판정으로 잃을 것이 없을 때만.
모르면 안 내린다: 판정 중 예외·화면을 못 읽음·tmux 가 이상함은 전부 '막는다'."""
from __future__ import annotations

import json
import math
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import marina_session as ms
import marina_discord_bot as mb
import marina_discord_wake as mw

IDLE_DEFAULT_HOURS = 2.0          # 형 결정 ①
IDLE_MIN_HOURS = 2.0              # 프롬프트 캐시(최장 1시간)보다 충분히 길게 — 캐시가 살아 있는 방은 안 내린다
IDLE_TICK_EVERY = 20.0            # 표본 간격 — 모든 방을 이 간격으로 판정한다
IDLE_KILL_EVERY = 60.0            # 내리기는 1분에 하나
IDLE_LOG_MAX = 5 * 1024 * 1024    # discord-idle.log 크기 — 넘으면 앞 절반을 자른다

_SELECT = re.compile(r"^\s*❯\s*\d+\.\s")
_warned: set[str] = set()


def stop_after(cfg: dict[str, Any]) -> float:
    """내리기까지 쉰 시간(초). 0 = 끔. 숫자가 아닌 값(문자열·null·NaN·무한대·불린)은 끔(로그 한 줄), 0 이하도 끔, 0 초과 2 미만은 2시간."""
    if not mw.enabled(cfg):
        return 0.0                # 내리기만 하고 못 깨우면 손해
    raw = cfg.get("idleStopHours", IDLE_DEFAULT_HOURS)
    if isinstance(raw, bool) or not isinstance(raw, (int, float)) or not math.isfinite(raw):
        key = repr(raw)
        if key not in _warned:
            _warned.add(key)
            mb._log(f"idle: idleStopHours 값이 이상해({key[:40]}) — 쉰 방 내리기를 끈다")
        return 0.0
    return 0.0 if raw <= 0 else max(float(raw), IDLE_MIN_HOURS) * 3600.0


def effective_after(hours: "float | None", cfg: dict[str, Any]) -> float:
    """idle-check 용 — --hours 도 같은 하한을 거친다. 설정이 꺼져 있어도 점검은 기본 기준으로 보여 준다."""
    if hours:
        return max(float(hours), IDLE_MIN_HOURS) * 3600.0
    return stop_after(cfg) or IDLE_DEFAULT_HOURS * 3600.0


def last_activity(rec: dict[str, Any]) -> float:
    """세션 기록 mtime 은 쓰지 않는다(재기동·종료로 바뀐다, 실측). 훅이 직접 적는 시각과 tmux 가 뜬 시각만.
    모르면 예외 — 뜬 시각을 못 읽었거나(0 이하) 시각 파일이 깨졌으면 '판정 실패'로 막힌다."""
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    born = mb._session_born(str(rec.get("tmux") or ""))
    if born <= 0:
        raise ValueError("세션이 뜬 시각을 못 읽음")
    vals = [born]
    for name in ("turn-at", "stopped-at"):
        try:
            vals.append(float((sd / name).read_text()))
        except OSError:
            pass
    try:
        vals.append((sd / "activity-at").stat().st_mtime)
    except OSError:
        pass
    vals.append(_transcript_last_ts(rec))     # 훅이 죽어도 대화 중인 방이 턴 사이에 내려가지 않게(기록 마지막 줄의 timestamp)
    return max(vals)


def _transcript_last_ts(rec: dict[str, Any]) -> float:
    """세션 기록 마지막 줄의 timestamp(내용). mtime 이 아니다 — 못 읽으면 0(후보에서만 빠진다)."""
    tr = mb._session_transcript(rec)
    if not tr:
        return 0.0
    try:
        with open(tr, "rb") as fh:
            end = fh.seek(0, 2)
            fh.seek(max(0, end - 65536))
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return 0.0
    for raw in reversed(lines):
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        t = mb._row_time(row) if isinstance(row, dict) else 0.0
        if t:
            return t
    return 0.0


def _attached(name: str) -> bool:
    """tmux client(터미널)가 붙어 있나 — 형이 보고 있을 수 있다."""
    out = (ms._tmux("display-message", "-p", "-t", name, "#{session_attached}").stdout or "").strip()
    return out != "0"             # 못 읽으면 붙어 있다고 본다(내리지 않는 쪽)


def _pane_tail(name: str) -> str:
    return "\n".join((ms._tmux("capture-pane", "-p", "-t", name).stdout or "").rstrip().splitlines()[-15:])


def _selecting(name: str) -> bool:
    """계획 승인·권한·질문 같은 선택 창이 떠 있나('❯ 1. Yes' 줄 또는 계획 승인 문구) — 누군가 답을 기다린다."""
    tail = _pane_tail(name)
    return "Would you like to proceed" in tail or "Do you want to " in tail or any(_SELECT.match(l) for l in tail.splitlines())


def _eligible(rec: dict[str, Any]) -> bool:
    return bool(rec.get("channelId"))     # 형 결정 ②: 로비도 같은 규칙(채널이 있으면 깨울 수 있다)


def _verdict(rec: dict[str, Any], after: float, now: float, full: bool = True) -> list[str]:
    """full=False 면 싼 이유가 하나라도 있을 때 무거운 판정(기록 읽기)을 건너뛴다 — 20초마다 모든 방을 훑는 틱용."""
    name = str(rec.get("tmux") or "")
    if not ms.tmux_alive(name):
        return ["꺼져 있음"]
    if not _eligible(rec):
        return ["대상 아님"]
    idle = now - last_activity(rec)
    if idle < after:
        return ["쉰 지 {:.1f}시간(기준 {:g})".format(idle / 3600, after / 3600)]
    if not mb._session_transcript(rec):
        return ["대화 기록 없음"]
    out = []
    if mw.allow_list(rec) is None:
        out.append("깨울 수 없는 방(멘션 필수·접근 설정 없음)")     # 내리면 글이 와도 안 깨어난다
    if not Path(str(rec.get("root") or "/nonexistent")).is_dir():
        out.append("작업 폴더가 없음(내리면 못 깨운다)")
    if _attached(name):
        out.append("터미널로 보는 중")
    if not mb._input_empty(name):
        out.append("입력창이 비어 있지 않음")
    if _selecting(name):
        out.append("선택·계획 승인 창이 떠 있음")
    if out and not full:
        return out
    return out + mb.restart_blockers(rec)


def verdict(rec: dict[str, Any], after: float, now: float, full: bool = True) -> list[str]:
    """내리지 않는 이유들. 빈 목록 = 내려도 된다. 판정 중 예외는 '막는다' — 모르면 죽이지 않는다."""
    try:
        return _verdict(rec, after, now, full)
    except Exception as exc:
        return ["판정 실패({}: {})".format(type(exc).__name__, str(exc)[:80])]


def _idle_log(line: str) -> None:
    """내린 근거 — discord-bot.log 는 1MB 에서 통째로 지워지므로 별도 파일. 5MB 를 넘으면 앞 절반을 자른다."""
    p = ms.marina_home() / "discord-idle.log"
    try:
        if p.exists() and p.stat().st_size > IDLE_LOG_MAX:
            data = p.read_bytes()
            half = data[len(data) // 2:]
            nl = half.find(b"\n")
            p.write_bytes(half[nl + 1:] if nl >= 0 else b"")
        with open(p, "a", encoding="utf-8") as fh:
            fh.write(time.strftime("%m-%d %H:%M:%S ") + line + "\n")
    except OSError:
        pass


def _times(rec: dict[str, Any]) -> str:
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))

    def one(name: str) -> str:
        try:
            return f"{float((sd / name).read_text()):.0f}"
        except (OSError, ValueError):
            return "-"
    try:
        act = f"{(sd / 'activity-at').stat().st_mtime:.0f}"
    except OSError:
        act = "-"
    return "turn-at={} stopped-at={} activity-at={} born={:.0f}".format(
        one("turn-at"), one("stopped-at"), act, mb._session_born(str(rec.get("tmux") or "")))


def _spawn_wake(channel: str) -> None:
    wake_py = Path(__file__).resolve().with_name("marina_discord_wake.py")
    subprocess.Popen([sys.executable, str(wake_py), "wake", "--channel", str(channel), "--after-idle"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


class Idler:
    def __init__(self, started: "float | None" = None) -> None:
        self.started = time.time() if started is None else started    # 이 데몬이 뜬 시각 — 그 뒤 글 이벤트를 받은 표식이 있어야 내린다
        self.clear_since: dict[str, float] = {}      # 방 → 막는 이유가 없던 상태가 이어진 시작 시각
        self.last_sample: dict[str, float] = {}
        self.last_tick = -1e18
        self.last_kill = -1e18

    def _reset(self) -> None:
        self.clear_since.clear()
        self.last_sample.clear()

    def tick(self, now: float, bot_up: bool = True) -> "str | None":
        """20초마다(그보다 자주 불리면 건너뜀) 모든 방을 표본으로 판정하고, 60초 넘게 연속 조용한 방 하나(1분에 하나)만 내린다."""
        if now - self.last_tick < IDLE_TICK_EVERY:
            return None
        try:
            after = stop_after(ms.load_config())
        except ms.SessionError:
            return None
        self.last_tick = now
        if not after or not bot_up or mb.restart_status() or mw.seen_at() <= self.started:
            self._reset()                    # 깨울 수 있는지 모르면(봇 없음·글 이벤트 수신 미확인) 내리지 않는다
            return None
        recs = ms.load_sessions()
        live_refs = set()
        ready: list[tuple[float, dict[str, Any]]] = []
        for rec in recs:
            ref = f"{rec.get('project')}/{rec.get('task')}"
            live_refs.add(ref)
            if verdict(rec, after, now, full=False):
                self.clear_since.pop(ref, None)
                self.last_sample.pop(ref, None)
                continue
            prev = self.last_sample.get(ref)
            if ref not in self.clear_since or prev is None or now - prev > 2.5 * IDLE_TICK_EVERY:
                self.clear_since[ref] = now              # 처음이거나 표본이 끊겼다 — 이어진 시간으로 치지 않는다
            self.last_sample[ref] = now
            if now - self.clear_since[ref] >= mb.RESTART_QUIET:
                ready.append((self.clear_since[ref], rec))
        for ref in [r for r in self.clear_since if r not in live_refs]:
            self.clear_since.pop(ref, None)
            self.last_sample.pop(ref, None)
        if not ready or now - self.last_kill < IDLE_KILL_EVERY:
            return None
        for _since, rec in sorted(ready, key=lambda x: x[0]):
            done = self._stop(rec, after, now)
            if done:
                return done
        return None

    def _stop(self, rec: dict[str, Any], after: float, now: float) -> "str | None":
        ref, name = f"{rec.get('project')}/{rec.get('task')}", str(rec.get("tmux") or "")
        sd = Path(str(rec.get("stateDir") or "/nonexistent"))
        with ms.room_lock(sd) as got:
            if not got:
                return None                  # 깨우기·재시작이 이 방을 만지는 중
            why = verdict(rec, after, now)   # 죽이기 직전 한 번 더 — 마지막 활동 시각도 여기서 다시 읽는다
            if why:
                self.clear_since.pop(ref, None)
                return None
            idle_h = (now - last_activity(rec)) / 3600
            _idle_log("내림 {} · 쉰={:.2f}h 기준={:g}h · {}".format(ref, idle_h, after / 3600, _times(rec)))   # 죽이기 전에 근거를 남긴다
            ms.tmux_stop(name)
            self._reset()
            self.last_kill = now
            try:
                (sd / "idle-stopped-at").write_text(f"{time.time()}\n")
            except OSError:
                pass
            try:                             # 내린 방에 남은 [▶ 추천] 버튼은 눌러도 소용없다
                ms.clear_suggest(sd, str(rec.get("channelId") or ""), mb._dc(ms.load_config()))
            except Exception as exc:
                mb._log(f"idle {ref}: 추천 버튼 지우기 실패 {exc!r}")
            mb._log("idle {}: {:.1f}시간 쉬어 내림(글이 오면 깨운다)".format(ref, idle_h))
        _spawn_wake(str(rec.get("channelId") or ""))      # 내리는 순간과 겹쳐 온 글이 있으면 바로 다시
        return ref


def daemon_started() -> "float | None":
    """discord-daemon.pid 가 적힌 시각 = 데몬이 뜬 때(idle-check 가 '깨우기 수신 확인'을 판단할 기준)."""
    try:
        return ms.daemon_pid_path().stat().st_mtime
    except OSError:
        return None


def summary(hours: "float | None" = None, started: "float | None" = None) -> str:
    """idle-check 첫 줄 — 지금 실효 상태(켜짐/꺼짐·기준 시간·깨우기 수신 확인 여부·봇 상태)."""
    try:
        cfg = ms.load_config()
    except ms.SessionError:
        cfg = {}
    on = bool(stop_after(cfg))
    after = effective_after(hours, cfg)
    since = daemon_started() if started is None else started
    confirmed = since is not None and mw.seen_at() > since
    try:
        daemon = "켜짐" if ms._daemon_alive() else "꺼짐"
    except Exception:
        daemon = "알 수 없음"
    return "내리기 {} · 기준 {:g}시간 · {} · 봇 데몬 {}".format(
        "켜짐" if on else "꺼짐(idleStopHours·wake 설정)", after / 3600,
        "깨우기 수신 확인" if confirmed else "깨우기 수신 미확인 — 내림 보류", daemon)


def check_all(hours: "float | None" = None) -> list[dict[str, Any]]:
    """읽기만 — 방마다 내릴 대상인지·아니면 왜. 아무것도 죽이지 않는다."""
    try:
        cfg = ms.load_config()
    except ms.SessionError:
        cfg = {}
    after = effective_after(hours, cfg)
    now, rows = time.time(), []
    for rec in ms.load_sessions():
        name = str(rec.get("tmux") or "")
        alive = ms.tmux_alive(name)
        why = verdict(rec, after, now)
        try:
            idle_h: "float | None" = round((now - last_activity(rec)) / 3600, 1) if alive else None
        except Exception:
            idle_h = None
        rows.append({"ref": f"{rec.get('project')}/{rec.get('task')}", "alive": alive, "idleHours": idle_h,
                     "afterHours": after / 3600, "stop": alive and not why, "why": why})
    return rows
