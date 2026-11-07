#!/usr/bin/env python3
"""쉰 방 내리기(스펙 §5) — 훅이 적은 활동 시각으로 쉰 시간을 재고, 안전 재시작과 같은 판정으로 잃을 것이 없을 때만.
모르면 안 내린다: 판정 중 예외·화면을 못 읽음·tmux 가 이상함은 전부 '막는다'."""
from __future__ import annotations

import contextlib
import json
import math
import os
import re
import shutil
import signal
import subprocess
import threading
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


def _user_text(row: dict[str, Any]) -> str:
    c = (row.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    return "\n".join(str(b.get("text") or "") for b in c or [] if isinstance(b, dict) and b.get("type") == "text")


def _transcript_last_ts(rec: dict[str, Any]) -> float:
    """세션 기록 마지막 줄의 timestamp(내용). mtime 이 아니다 — 못 읽으면 0(후보에서만 빠진다).
    마리나가 친 캐시 유지 글·그 답·/compact 기록은 사람이 한 활동이 아니라 건너뛴다(그러지 않으면 쉰 시간이 매번 리셋된다)."""
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
    # 끝에서 거꾸로 턴 단위로 읽는다: user·assistant 줄의 시각을 모으다가 '프롬프트'(글이 있는 user 줄)를 만나면
    #  - 마리나가 친 것(캐시 유지 글·/compact 명령·그 caveat·출력·컴팩트 요약)이면 모은 것을 버리고 더 앞으로,
    #  - 사람(또는 알림·방끼리 글)이면 그 턴의 가장 늦은 시각이 답.
    # api-request·attachment·system 같은 줄은 세지 않는다 — 핑 턴의 user 줄 **앞**에도 찍혀 쉰 시간을 매번 리셋했다(2026-11-08, 8시간 상한에 영영 안 닿고 이틀 핑).
    # 창(끝 64KB)이 핑 턴 중간에서 시작할 수 있어 앞에서부터 읽으면 상태를 모른다 — 그래서 거꾸로.
    pending, saw_bot = 0.0, False
    for raw in reversed(lines):
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(row, dict) or row.get("type") not in ("user", "assistant"):
            continue
        ts = mb._row_time(row) or 0.0
        if row.get("type") == "user":
            text = _user_text(row).lstrip()
            if (row.get("isMeta") or row.get("isCompactSummary") or text.startswith(ms.KEEPALIVE_MARK)
                    or text.startswith(("<local-command-stdout>", "<local-command-caveat>", "<command-name>"))):
                pending, saw_bot = 0.0, True              # 마리나·하네스가 넣은 턴 — 그 뒤 줄들은 사람 활동이 아니다
                continue
            if text.strip():
                return max(pending, ts)                   # 사람(또는 알림)의 진짜 글
        pending = max(pending, ts)                        # 답·도구 결과
    return 0.0 if saw_bot else pending                    # 창 안에 사람 글이 없다 — 마리나 턴이 끼었으면 모른다(0), 아니면 긴 한 턴 안


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
    codex = ms.is_codex(rec)
    if codex:
        import marina_codex
    if not (marina_codex.input_empty(name) if codex else mb._input_empty(name)):
        out.append("입력창이 비어 있지 않음")
    if (marina_codex.selecting(name) if codex else _selecting(name)):
        out.append("선택·계획 승인 창이 떠 있음")
    if out and not full:
        return out
    blockers = mb.restart_blockers(rec)
    if blockers and _work_stale(rec, now, max(after, BACKGROUND_STALE)):
        blockers = [b for b in blockers if not _BACKGROUND.match(b)]
    if not codex and _holding(rec, now, idle):
        out.append("하던 중(진행 문서)")
    return out + blockers


BACKGROUND_STALE = 2 * 3600.0     # 백그라운드가 '일하는 중'이어도 대화·서브에이전트 기록이 이만큼 안 움직였으면 멈춘 것으로 본다
_BACKGROUND = re.compile(r"^(백그라운드 \d+|백그라운드 셸 \d+|팀 에이전트 일하는 중|에이전트 \d+개 일하는 중)$")


def _work_stale(rec: dict[str, Any], now: float, quiet: float = BACKGROUND_STALE) -> bool:
    """(형 2026-10-23) 멈춘 서브에이전트(8시간 무기록)·남은 셸·쉬는 팀 에이전트가 '일하는 중'으로 잡혀 방이 며칠씩 안 잠들었다.
    대화 기록·서브에이전트 기록·백그라운드 셸 출력(tasks/*.output)이 전부 quiet 넘게 안 움직였으면 쉬는 것으로 친다.
    출력을 내는 빌드·요청 로그를 찍는 서버는 살아 있는 것으로 본다(리뷰 I2). 한계: 출력 없이 오래 도는 일은 멈춘 것으로 보인다.
    코덱스 방은 기록 구조가 달라 건드리지 않는다(늘 막는 쪽)."""
    tr = mb._session_transcript(rec)
    if not tr or ms.is_codex(rec):
        return False
    try:
        latest = tr.stat().st_mtime
        sub = tr.with_suffix("") / "subagents"
        files = list(sub.glob("*.jsonl")) if sub.is_dir() else []
        base = Path(os.environ.get("MARINA_CLAUDE_TMP") or "/private/tmp")
        files += list(base.glob(f"claude-*/{tr.parent.name}/{tr.stem}/tasks/*.output"))
        for f in files:
            latest = max(latest, f.stat().st_mtime)
    except OSError:
        return False
    return now - latest >= quiet


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
        self.keep_checked: dict[str, float] = {}     # 방 → 캐시 손쓰기를 마지막으로 무겁게 판정한 시각
        self.sync_checked: dict[str, float] = {}     # 방 → git 맞춤을 마지막으로 판정한 시각
        self.sync_cleaned = False
        self.sync_inline = False                     # 시험: True 면 스레드 없이 그 자리에서
        self.keep_spawned: dict[str, float] = {}     # 방 → 입력 프로세스를 띄운 시각(입력 대기 120초 동안 또 띄우지 않게)

    def _reset(self) -> None:
        self.clear_since.clear()
        self.last_sample.clear()

    def tick(self, now: float, bot_up: bool = True) -> "str | None":
        """20초마다(그보다 자주 불리면 건너뜀) 모든 방을 표본으로 판정하고, 60초 넘게 연속 조용한 방 하나(1분에 하나)만 내린다."""
        if now - self.last_tick < IDLE_TICK_EVERY:
            return None
        try:
            cfg = ms.load_config()
        except ms.SessionError:
            return None
        after = stop_after(cfg)
        self.last_tick = now
        try:
            self.keep_tick(now, cfg)          # 내리기와 별개 — 실패해도 내리기 판정은 계속
        except Exception as exc:
            mb._log(f"cache-keep 실패: {exc!r}")
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

    def keep_tick(self, now: float, cfg: dict[str, Any]) -> list[tuple[str, str]]:
        """모든 방을 보고 컴팩트·캐시 유지 글을 칠 방을 고른다(입력은 mb._spawn_type — 방이 쉬고 입력창이 빈 때만 친다).
        사람이 마지막으로 말한 시각(last_activity)이 바뀌면 계획이 처음부터 다시 시작된다. 반환: [(방, 한 일)].
        기준 시각(compactedFor·lastKeep)은 여기서 안 적는다 — 입력 프로세스가 치는 데 성공한 뒤 keep_done 이 적는다."""
        k = keep_config(cfg)
        if not k or mb.restart_status():
            return []
        every, keep_max = k
        done: list[tuple[str, str]] = []
        recs = ms.load_sessions()
        if not self.sync_cleaned:
            self.sync_cleaned = True                       # 데몬이 뜬 뒤 첫 판: 봇이 중간에 죽어 남은 임시 워크트리 정리
            cleanup_orphan_worktrees({Path(str(r["root"])) for r in recs if r.get("root") and r.get("kind") not in ms.CHAT_KINDS})
        for rec in recs:
            ref = f"{rec.get('project')}/{rec.get('task')}"
            name = str(rec.get("tmux") or "")
            if not name or not _eligible(rec) or not rec.get("stateDir") or not ms.tmux_alive(name):
                continue
            chat = rec.get("kind") in ms.CHAT_KINDS            # 채팅·로비·비서 방: 캐시 유지 글(핑) 없이 컴팩트 규칙만 · git 맞춤은 대상 아님(레포가 아니다)
            try:
                last = last_activity(rec)
                if last - mb._session_born(name) <= 1.0:
                    continue                                   # 뜬 뒤 실제 활동이 없다 — 캐시에 데울 것이 없다
                st = _keep_state(rec)
                if not chat and not ms.is_codex(rec):          # 코덱스 방은 추가 컨텍스트 알림을 확인할 수 없어 제외(조용히 바꾸지 않는다)
                    self._maybe_sync(rec, name, ref, last, st, now, every)
                if ms.is_codex(rec):
                    continue                                   # 코덱스 방은 컴팩트·캐시 유지 글 대상 아님
                if _same(st.get("compactedFor"), last):
                    continue                                   # 이 대화 구간은 이미 컴팩트했다
                touched = max(last, float(st.get("lastKeep") or 0.0))      # 캐시가 마지막으로 데워진 시각
                want = st.get("want")                          # 남아 있으면 지난 시도를 못 쳤다(keep_done 이 지운다) — 그 뒤 잠시 쉰다
                tried = float(want.get("at") or 0.0) if isinstance(want, dict) and isinstance(want.get("at"), (int, float)) else -1e18
                if (now - touched < every or now - self.keep_checked.get(ref, -1e18) < KEEP_RECHECK or now - tried < KEEP_FAIL_BACKOFF
                        or now - self.keep_spawned.get(ref, -1e18) < KEEP_SPAWN_WAIT):
                    continue
                self.keep_checked[ref] = now
                if _attached(name):
                    continue                                   # 형이 터미널로 보는 중 — 끼어들지 않는다
                if mb._pane_busy(name)[1]:
                    continue                                   # 턴을 도는 중 — 캐시를 스스로 쓰고, 띄워도 쉬는 순간이 안 와 헛시도만 한다(형 2026-11-06)
                if chat or piece_done(rec, now):
                    if now - touched >= CACHE_TTL:
                        continue                               # 캐시가 식었다 — 지금처럼 2시간 뒤 내린다
                    action, text = "compact", ms.COMPACT_KEEP_TEXT
                elif now - last >= keep_max:
                    action, text = "compact", ms.COMPACT_KEEP_TEXT
                else:
                    action, text = "keepalive", ms.KEEPALIVE_TEXT
                _keep_save(rec, want={"action": action, "last": last, "at": now})
                self.keep_spawned[ref] = now
                mb._spawn_type(name, text, str(rec.get("channelId") or ""), "")
                _idle_log("{} 시도 {} · 쉰={:.2f}h".format("컴팩트" if action == "compact" else "캐시 유지", ref, (now - last) / 3600))
                done.append((ref, action))
            except Exception as exc:
                mb._log(f"cache-keep {ref}: {exc!r}")
        return done

    def _maybe_sync(self, rec: dict[str, Any], name: str, ref: str, last: float, st: dict[str, Any], now: float, every: float) -> None:
        """일 조각이 끝나고 50분 쉰 방을 origin 기본 브랜치에 맞춘다(활동 시각당 한 번). 계산(fetch·임시 워크트리 rebase)은 느릴 수 있어
        떼어 낸 스레드에서, 잠금은 적용 순간만."""
        if _same(st.get("syncedFor"), last) or now - last < every or now - self.sync_checked.get(ref, -1e18) < KEEP_RECHECK:
            return
        self.sync_checked[ref] = now
        if _attached(name) or not piece_done(rec, now):
            return
        _keep_save(rec, syncedFor=last)
        turn = _read(Path(str(rec["stateDir"])) / "turn-at")
        if self.sync_inline:
            self._sync_room(rec, ref, last, turn, now)
        else:
            threading.Thread(target=self._sync_room, args=(rec, ref, last, turn, now), daemon=True).start()

    @staticmethod
    def _sync_room(rec: dict[str, Any], ref: str, last: float, turn: str, now: float) -> None:
        sd = Path(str(rec.get("stateDir") or "/nonexistent"))

        def still_idle() -> bool:           # 적용 직전: 그 사이 사람이 말했거나(활동·turn-at) 일이 시작됐거나 터미널로 보면 그만둔다
            return (_same(last, last_activity(rec)) and _read(sd / "turn-at") == turn
                    and not _attached(str(rec.get("tmux") or "")) and piece_done(rec, now))
        try:
            res = sync_to_origin(Path(str(rec.get("root") or "/nonexistent")), guard=still_idle, lock=lambda: ms.room_lock(sd))
            if res:
                ms._write_json(sd / "git-sync.json", res)
                mb._log(f"git-sync {ref}: {res}")
        except Exception as exc:
            mb._log(f"git-sync {ref} 실패: {exc!r}")

    def _stop(self, rec: dict[str, Any], after: float, now: float) -> "str | None":
        ref, name = f"{rec.get('project')}/{rec.get('task')}", str(rec.get("tmux") or "")
        sd = Path(str(rec.get("stateDir") or "/nonexistent"))
        with ms.room_lock(sd) as got:
            if not got:
                return None                  # 깨우기·재시작이 이 방을 만지는 중
            ms.tmux_tick_fresh()             # 판 캐시가 아닌 지금 화면으로(리뷰 I1)
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
        threading.Thread(target=self._stop_docker, args=(rec, sd, ref), daemon=True).start()   # 컨테이너 멈춤은 수십 초 — 루프를 붙잡지 않게
        _spawn_wake(str(rec.get("channelId") or ""))      # 내리는 순간과 겹쳐 온 글이 있으면 바로 다시
        return ref


    @staticmethod
    def _stop_docker(rec: dict[str, Any], sd: Path, ref: str) -> None:
        try:
            names = ms.stop_room_docker(rec, sd)
            if names:
                mb._log(f"idle {ref}: 도커 {', '.join(names)} 멈춤(방이 다시 뜰 때 켠다)")
        except Exception as exc:
            mb._log(f"idle {ref}: 도커 멈추기 실패 {exc!r}")


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


# ── 방 캐시(1시간) 손쓰기 ─────────────────────────────────────────────────────
# 일 조각이 끝난 방: 캐시가 살아 있을 때(마지막 접촉 50분 뒤) /compact 한 번 → 그 뒤는 2시간 쉬면 내림.
# 하던 중인 방: 8시간까지 50분마다 내용 없는 글로 캐시를 데운다. 8시간이 지나면 /compact 뒤 내림(그 전엔 2시간에 안 내린다).
# 코덱스 방은 대상이 아니다(캐시 구조가 다르고 컴팩트하면 맥락을 크게 잃는다 — 형 2026-11-05).
KEEP_DEFAULT_MINUTES = 50.0
KEEP_MAX_MINUTES = 59.0           # 간격은 캐시 수명(60분) 안이어야 한다
KEEP_DEFAULT_HOURS = 8.0
CACHE_TTL = 3600.0                # 이 시간이 지난 캐시는 이미 식었다 — 컴팩트로 데울 것이 없다
KEEP_SPAWN_WAIT = 150.0           # 입력 프로세스는 최대 120초 기다린다 — 그동안 같은 방에 또 띄우지 않는다
KEEP_FAIL_BACKOFF = 240.0         # 못 친 시도(방이 안 쉼) 뒤 다시 띄우기까지 — 50~60분 창 안에서 세 번쯤(2.6분마다 헛시도하던 것, 2026-11-06)
KEEP_RECHECK = 60.0              # 한 방을 무겁게 판정하는 최소 간격(입력 못 한 방을 20초마다 다시 보지 않게)
_OPEN_STATUS = re.compile(r"^상태:\s*(진행 중|막힘)")


def keep_config(cfg: dict[str, Any]) -> "tuple[float, float] | None":
    """(캐시 유지 간격 초, 하던 중 방을 붙드는 최대 초). None = 끔(cacheKeep: false). 이상한 값은 기본."""
    if cfg.get("cacheKeep", True) is False:
        return None

    def num(key: str, default: float, hi: float) -> float:
        v = cfg.get(key)
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0 or v > hi:
            return default
        return float(v)
    return (num("cacheKeepMinutes", KEEP_DEFAULT_MINUTES, KEEP_MAX_MINUTES) * 60.0,
            num("cacheKeepHours", KEEP_DEFAULT_HOURS, 24 * 14) * 3600.0)


def progress_open(rec: dict[str, Any]) -> bool:
    """방 작업 폴더의 .superpowers/sdd/*/progress*.md 맨 위 다섯 줄에 '상태: 진행 중|막힘' 이 있나(shared/bin/role-hook 과 같은 규칙)."""
    for f in sorted(Path(str(rec.get("root") or "/nonexistent")).glob(".superpowers/sdd/*/progress*.md")):
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                head = [fh.readline() for _ in range(5)]
        except OSError:
            continue
        if any(_OPEN_STATUS.match(l.strip()) for l in head):
            return True
    return False


def _keep_state(rec: dict[str, Any]) -> dict[str, Any]:
    try:
        d = json.loads((Path(str(rec.get("stateDir") or "/nonexistent")) / "keep.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def _keep_save(rec: dict[str, Any], **kw: Any) -> None:
    ms._write_json(Path(str(rec["stateDir"])) / "keep.json", dict(_keep_state(rec), **kw))


def _read(p: Path) -> str:
    try:
        return p.read_text()
    except OSError:
        return ""


def _same(a: Any, b: float) -> bool:
    return isinstance(a, (int, float)) and abs(float(a) - b) < 1.0


def _holding(rec: dict[str, Any], now: float, idle: float) -> bool:
    """내리기 판정용 — 진행 문서가 열린 방은 8시간까지(그리고 그때 컴팩트를 건 뒤에야) 2시간에 내리지 않는다.
    백그라운드·질문 같은 나머지 '하던 중' 이유는 restart_blockers 가 이미 막는다."""
    try:
        cfg = ms.load_config()
    except ms.SessionError:
        return False
    k = keep_config(cfg)
    if not k or not progress_open(rec):
        return False
    return idle < k[1] or not _same(_keep_state(rec).get("compactedFor"), last_activity(rec))


def piece_done(rec: dict[str, Any], now: float) -> bool:
    """일 조각이 끝났나 — 백그라운드·서브에이전트·팀 에이전트·예약·질문·권한 창이 없고 진행 문서가 열려 있지 않다.
    판정 중 예외는 '하던 중'(애매하면 하던 중 쪽)."""
    try:
        if progress_open(rec):
            return False
        blockers = [b for b in mb.restart_blockers(rec) if b not in ("방금 메시지·작업 기록이 움직임",)]
        if blockers and _work_stale(rec, now, BACKGROUND_STALE):
            blockers = [b for b in blockers if not _BACKGROUND.match(b)]
        return not blockers and not _selecting(str(rec.get("tmux") or ""))
    except Exception:
        return False


def keep_guard(rec: dict[str, Any], text: str) -> bool:
    """치기 직전 확인(입력 프로세스가 부른다): keep_tick 이 정할 때와 같은 일이고, 그 뒤 사람이 말하지 않았고, 터미널로 보고 있지 않다."""
    want = _keep_state(rec).get("want")
    if not isinstance(want, dict):
        return False
    action = "compact" if text == ms.COMPACT_KEEP_TEXT else "keepalive"
    if want.get("action") != action:
        return False
    try:
        return _same(want.get("last"), last_activity(rec)) and not _attached(str(rec.get("tmux") or ""))
    except Exception:
        return False


def keep_done(rec: dict[str, Any]) -> None:
    """입력에 성공했다 — 그제야 컴팩트한 대화 구간(compactedFor) 또는 캐시를 데운 시각(lastKeep)을 적는다."""
    want = _keep_state(rec).get("want")
    if not isinstance(want, dict):
        return
    if want.get("action") == "compact":
        _keep_save(rec, compactedFor=want.get("last"), want=None)
    else:
        _keep_save(rec, lastKeep=want.get("at"), want=None)


# ── 쉬는 방 브랜치를 origin 기본 브랜치에 맞춤 ───────────────────────────────────
# 형의 작업 브랜치를 건드리므로 보수적으로: 살아 있는 작업 트리에서는 rebase/abort 를 하지 않는다. 임시 워크트리에서 새 커밋을 계산하고,
# 적용은 HEAD·index 가 계산 때와 같고 작업 트리가 깨끗할 때만 `git reset --keep <new>` 한 번(방 잠금 안에서, 직전에 활동·piece_done 재확인).

def _git_env() -> dict[str, str]:
    """묻지 않는 환경 — 인증·ssh 질문으로 멈추지 않게."""
    return dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_EDITOR="true", GIT_SSH_COMMAND="ssh -o BatchMode=yes", GCM_INTERACTIVE="never")


def _run(argv: list[str], timeout: "float | None" = 30.0, term_grace: float = 5.0) -> "subprocess.CompletedProcess[str]":
    """stdin 없이, 새 프로세스 그룹으로 — 시간이 넘으면 그룹에 SIGTERM(lock 정리 기회) → term_grace 초 뒤에도 살아 있으면 SIGKILL, TimeoutExpired.
    timeout=None 이면 기다린다(적용용 reset --keep 처럼 중간에 죽이면 안 되는 호출)."""
    p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         env=_git_env(), start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        for sig, wait in ((signal.SIGTERM, term_grace), (signal.SIGKILL, None)):
            try:
                os.killpg(p.pid, sig)
            except OSError:
                pass
            try:
                p.communicate(timeout=wait)
                break
            except subprocess.TimeoutExpired:
                continue
        raise
    return subprocess.CompletedProcess(argv, p.returncode, out, err)


def _git(root: Path, *args: str, timeout: "float | None" = 30.0) -> "subprocess.CompletedProcess[str]":
    return _run(["git", "-C", str(root), *args], timeout=timeout)


def _out(root: Path, *args: str, ok: "tuple[int, ...]" = (0,)) -> str:
    """판정용 git 호출 — 실패하면 예외(sync_to_origin 이 '아무것도 안 함'으로 접는다). 없는 설정처럼 1 이 정상인 호출만 ok 로 넓힌다."""
    r = _git(root, *args)
    if r.returncode not in ok:
        raise OSError(f"git {' '.join(args[:3])} 실패({r.returncode})")
    return r.stdout.strip()


@contextlib.contextmanager
def _no_lock() -> Any:
    yield True


SYNC_WT = "sync-wt"
_BUSY = ("rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer", "BISECT_LOG")


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def cleanup_orphan_worktrees(roots: "list[Path] | set[Path]") -> None:
    """봇이 계산 도중 죽어 남은 임시 워크트리 — sync-wt 아래 것 중 폴더 이름의 pid(<pid>-<시각>)가 죽은 것만 remove --force 한다.
    그 밖의 워크트리(형의 것·살아 있는 프로세스의 임시)는 건드리지 않는다(맨 prune 도 안 한다)."""
    base = ms.marina_home() / SYNC_WT
    prefix = os.path.realpath(str(base)) + os.sep

    def dead(path: str) -> bool:
        head = os.path.basename(path).split("-", 1)[0]
        return head.isdigit() and not _pid_alive(int(head))
    for root in roots:
        try:
            for line in _git(Path(root), "worktree", "list", "--porcelain").stdout.split("\n"):
                if line.startswith("worktree ") and os.path.realpath(line[9:]).startswith(prefix) and dead(line[9:]):
                    _git(Path(root), "worktree", "remove", "--force", line[9:])
        except Exception:
            pass
    try:
        for d in base.iterdir():
            if dead(str(d)):
                shutil.rmtree(d, ignore_errors=True)
    except OSError:
        pass


def _busy(gd: str) -> bool:
    return any(os.path.exists(os.path.join(gd, n)) for n in _BUSY)


def _derived(root: Path, branch: str, base: str) -> bool:
    """방의 커밋(base 위 첫 커밋부터)을 기반으로 한 다른 로컬 브랜치·워크트리(서브에이전트 agent-* 포함)가 있나 — 다시 쓰면 그쪽 기반이 사라진다."""
    first = (_out(root, "rev-list", "--reverse", f"{base}..HEAD").split() or ["HEAD"])[0]
    refs = _out(root, "for-each-ref", "--contains", first, "--format=%(refname)", "refs/heads").split()
    if any(r != "refs/heads/" + branch for r in refs):
        return True
    me = os.path.realpath(str(root))
    for blk in _out(root, "worktree", "list", "--porcelain").split("\n\n"):
        path = sha = ""
        for line in blk.split("\n"):
            if line.startswith("worktree "):
                path = line[9:]
            elif line.startswith("HEAD "):
                sha = line[5:]
        if path and sha and os.path.realpath(path) != me and _git(root, "merge-base", "--is-ancestor", first, sha).returncode == 0:
            return True
    return False


def _ignored_overlap(root: Path, base: str) -> bool:
    """origin 쪽에서 바뀐 경로(와 그 모든 상위 경로)가 방에 untracked(=작업 트리가 깨끗하므로 gitignore 대상)로 이미 있으면 reset --keep 이 지운다."""
    mb_ = _out(root, "merge-base", "HEAD", base)
    changed = [x for x in _git(root, "diff", "--name-only", "-z", mb_, base).stdout.split("\0") if x]
    tracked: set[str] = set()
    for f in _git(root, "ls-files", "-z").stdout.split("\0"):
        while f and f not in tracked:
            tracked.add(f)
            f = os.path.dirname(f)
    for c in changed:
        parts = c.split("/")
        for i in range(1, len(parts) + 1):
            p = "/".join(parts[:i])
            if p not in tracked and os.path.lexists(os.path.join(str(root), p)):
                return True
    return False


def sync_to_origin(root: Path, guard: "Any" = None, lock: "Any" = None) -> "dict[str, Any] | None":
    """방 워크트리 브랜치를 origin 기본 브랜치(origin/HEAD, 없으면 origin/main)에 맞춘다.
    반환: {state: rebased|behind, why(behind 일 때: busy·dirty·pushed·gpg·submodule·derived·ignored·conflict), n: 뒤처진 수, base}.
    할 일이 없거나(최신·본체 체크아웃·분리 HEAD·기본 브랜치 자체·fetch 실패·적용 직전 달라짐·잠금 실패) None. guard: 적용 직전 재확인(활동·piece_done)."""
    guard = guard or (lambda: True)
    lock = lock or _no_lock
    tmp: "Path | None" = None
    try:
        ids = _git(root, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir").stdout.split("\n")
        gd, common = ids[0], (ids[1] if len(ids) > 1 else "")
        if not gd or gd == common:
            return None                                  # 레포가 아니거나 본체 체크아웃(워크트리가 아님)
        branch = _out(root, "symbolic-ref", "-q", "--short", "HEAD", ok=(0, 1))
        if not branch:
            return None                                  # 분리 HEAD
        if _git(root, "fetch", "-q", "origin", timeout=60.0).returncode:
            return None                                  # 오프라인·인증 — 조용히 넘김
        base = _out(root, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD", ok=(0, 1)) or "origin/main"
        if _git(root, "rev-parse", "-q", "--verify", base + "^{commit}").returncode or branch == base.split("/", 1)[-1]:
            return None
        behind = int(_out(root, "rev-list", "--count", f"HEAD..{base}") or 0)
        if behind == 0:
            return None

        def res(why: str, state: str = "behind") -> dict[str, Any]:
            return {"state": state, "why": why, "n": behind, "base": base} if why else {"state": state, "n": behind, "base": base}
        if _busy(gd):
            return res("busy")
        if _out(root, "status", "--porcelain"):
            return res("dirty")
        ahead = int(_out(root, "rev-list", "--count", f"{base}..HEAD") or 0)
        if ahead and int(_out(root, "rev-list", "--count", "HEAD", "--not", "--remotes") or 0) != ahead:
            return res("pushed")                          # 이미 push 한 커밋이 있다 — 다시 쓰면 원격과 갈라진다
        if "true" in (_out(root, "config", "--type=bool", "commit.gpgsign", ok=(0, 1)), _out(root, "config", "--type=bool", "tag.gpgsign", ok=(0, 1))):
            return res("gpg")
        if (root / ".gitmodules").exists():
            return res("submodule")
        if ahead and _derived(root, branch, base):
            return res("derived")
        if _ignored_overlap(root, base):
            return res("ignored")
        head0, tree0 = _out(root, "rev-parse", "HEAD"), _out(root, "write-tree")
        tmp = ms.marina_home() / SYNC_WT / f"{os.getpid()}-{time.time_ns()}"
        tmp.parent.mkdir(parents=True, exist_ok=True)
        if _git(root, "-c", "core.hooksPath=/dev/null", "worktree", "add", "-q", "--detach", str(tmp), head0, timeout=120.0).returncode:
            return None
        if _git(tmp, "-c", "core.hooksPath=/dev/null", "-c", "rebase.updateRefs=false", "-c", "rebase.rebaseMerges=false",
                "-c", "rebase.autoStash=false", "-c", "rebase.autoSquash=false", "rebase", base, timeout=300.0).returncode:
            return res("conflict")                        # 임시만 버린다 — 방 트리는 그대로
        new = _out(tmp, "rev-parse", "HEAD")
        with lock() as got:
            if not got or not guard():
                return None
            if (_out(root, "rev-parse", "HEAD") != head0 or _out(root, "write-tree") != tree0
                    or _out(root, "status", "--porcelain") or _busy(gd)):
                return None                               # 계산하는 동안 방이 움직였다
            if _git(root, "reset", "--keep", new, timeout=None).returncode:     # 중간에 죽이면 안 된다 — 타임아웃 없음
                return None
        return res("", "rebased")
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    finally:
        if tmp is not None:
            try:
                _git(root, "worktree", "remove", "--force", str(tmp))
            except Exception:
                pass
            shutil.rmtree(tmp, ignore_errors=True)
