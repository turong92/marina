#!/usr/bin/env bash
# 쉰 방 내리기(스펙 §5): 훅이 적은 활동 시각으로 쉰 시간을 재고, 안전 재시작과 같은 판정이 60초 이어질 때만,
# 1분에 하나씩 내린다. 모르면 안 내린다. 이 테스트가 죽이는 것은 자기가 만든 tmux 세션(전용 소켓)뿐이다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
export FD
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a >/dev/null 2>&1 || fail "new a"
msess new proj feat/b >/dev/null 2>&1 || fail "new b"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
import marina_discord_idle as mi
import marina_discord_wake as mw
fails = []
def check(c, m):
    if not c: fails.append(m)
assert os.environ["MARINA_TMUX_SOCKET"].startswith("marina-test-"), "전용 소켓이 아니면 죽이는 테스트를 돌리지 않는다"
def row(r): return json.dumps(r, ensure_ascii=False) + "\n"
def prep(ref, sid):
    ms.save_sessions([dict(x, sessionId=sid) if f"{x['project']}/{x['task']}" == ref else x for x in ms.load_sessions()])
    rec = ms.find_session(ref)
    tr = ms.transcript_path(Path(rec["root"]), sid); tr.parent.mkdir(parents=True, exist_ok=True)
    tr.write_text(row({"type": "user", "message": {"role": "user", "content": "hi"}}) + row({"type": "system", "subtype": "turn_duration"}))
    old = time.time() - 9 * 3600; os.utime(tr, (old, old))
    return rec, Path(rec["stateDir"]), tr
a, sda, tra = prep("proj/feat/a", "aaaaaaaa-0000-1111-2222-333344445555")
b, sdb, trb = prep("proj/feat/b", "bbbbbbbb-0000-1111-2222-333344445555")
mb.live_tasks = lambda r: []
empty = [True]; attached = [False]
mb._input_empty = lambda name: empty[0]
real_attached = mi._attached
mi._attached = lambda name: attached[0]
pane = [""]
mi._pane_tail = lambda name: pane[0]
H = 3600.0; now = time.time()
STARTED = now - 100                  # 이 '데몬' 이 뜬 시각 — 그 뒤 글 이벤트(wake)를 받은 표식이 있어야 내린다(B5)
mw.mark_seen()
A = 2 * H                            # 형 결정 ①: 기준 2시간
later = now + 3 * H                  # tmux 가 방금 만들어졌으므로 "3시간 뒤" 로 본다
# ── 설정 ──
check(mi.IDLE_DEFAULT_HOURS == 2.0 and mi.IDLE_MIN_HOURS == 2.0, "기본·하한 2시간(형 결정 ①)")
check(mi.stop_after({}) == 2 * H, "기본 2시간")
check(mi.stop_after({"idleStopHours": 0}) == 0 and mi.stop_after({"idleStopHours": -1}) == 0, "0 이하면 끔")
check(mi.stop_after({"idleStopHours": 1}) == 2 * H, "2시간 미만은 2시간으로(캐시 1시간보다 충분히 길게)")
check(mi.stop_after({"idleStopHours": 12}) == 12 * H, "값")
for bad in ("x", "3", None, float("nan"), float("inf"), -float("inf"), True, [], {}):
    check(mi.stop_after({"idleStopHours": bad}) == 0, f"문자열·null·NaN·무한대·이상한 값은 끔: {bad!r}")
check("idleStopHours" in (ms.marina_home() / "discord-bot.log").read_text(), "이상한 설정값은 로그 한 줄")
check(mi.stop_after({"idleStopHours": 0.5}) == 2 * H and mi.stop_after({"idleStopHours": 1.99}) == 2 * H and mi.stop_after({"idleStopHours": 0}) == 0, "0 초과 2 미만은 2시간, 0 은 끔")
check(mi.stop_after({"idleStopHours": 6, "wake": False}) == 0, "깨우기를 끄면 내리기도 끔")
# ── 마지막 활동: 훅이 적은 시각·tmux 가 뜬 시각 중 가장 늦은 것. 기록 파일 mtime 은 안 본다 ──
born = mb._session_born(a["tmux"])
check(abs(mi.last_activity(a) - born) < 5, "아무 기록 없으면 세션이 뜬 시각")
os.utime(tra, (now + 5 * H, now + 5 * H))
check(abs(mi.last_activity(a) - born) < 5, "세션 기록 mtime 은 활동으로 치지 않는다(재기동·종료로 바뀐다)")
os.utime(tra, (now - 9 * H, now - 9 * H))
(sda / "turn-at").write_text(str(now + 1 * H))
check(mi.last_activity(a) == now + 1 * H, "지시를 받은 순간")
(sda / "stopped-at").write_text(str(now + 2 * H))
check(mi.last_activity(a) == now + 2 * H, "턴 끝")
(sda / "activity-at").touch(); os.utime(sda / "activity-at", (now + 2.5 * H, now + 2.5 * H))
check(mi.last_activity(a) == now + 2.5 * H, "도구 사용")
for f in ("turn-at", "stopped-at", "activity-at"): (sda / f).unlink()
# ── 판정: 조건마다 막는다 ──
check(any("쉰 지" in w for w in mi.verdict(a, A, now + 1 * H)), "기준 시간 안이면 안 내린다")
check(mi.verdict(a, A, later) == [], f"다 맞으면 내려도 된다: {mi.verdict(a, A, later)}")
check(mi.verdict(a, A, later) == mi.verdict(a, A, later), "판정은 읽기만(부작용 없음)")
attached[0] = True
check("터미널로 보는 중" in mi.verdict(a, A, later), "붙어 있는 터미널")
attached[0] = False; empty[0] = False
check("입력창이 비어 있지 않음" in mi.verdict(a, A, later), "쓰다 만 글")
empty[0] = True
for text in ("Would you like to proceed?\n ❯ 1. Yes, and auto-accept edits\n   2. No, keep planning", "Do you want to proceed?\n❯ 1. Yes"):
    pane[0] = text
    check(any("선택" in w for w in mi.verdict(a, A, later)), f"계획 승인·선택 창이 떠 있으면 안 내린다: {text[:20]!r}")
acc = sda / "access.json"; keep_acc = acc.read_text(); d = json.loads(keep_acc)
d["groups"][a["channelId"]]["requireMention"] = True; acc.write_text(json.dumps(d))
check(any("깨울 수 없는 방" in w for w in mi.verdict(a, A, later)), "깨우기가 안 받는 방(멘션 필수)은 내리면 못 돌아오니 안 내린다")
acc.write_text(keep_acc)
pane[0] = "일반 대화 화면\n❯ \n"
check(mi.verdict(a, A, later) == [], "선택 창이 없으면 그대로 통과")
mb.live_tasks = lambda r: [{"id": "b1", "kind": "shell", "desc": "x"}]
check(any("백그라운드" in w for w in mi.verdict(a, A, later)), "restart_blockers 재사용 — 백그라운드 셸")
mb.live_tasks = lambda r: []
(sda / "question.json").write_text("{}")
check("질문 답 기다림" in mi.verdict(a, A, later), "질문 대기")
(sda / "question.json").unlink()
moved = tra.rename(str(tra) + ".x")
check(mi.verdict(a, A, later) == ["대화 기록 없음"], "기록이 없는 세션은 안 내린다")
moved.rename(tra)
mb._input_empty = lambda name: (_ for _ in ()).throw(RuntimeError("tmux 가 이상하다"))
check(any("판정 실패" in w for w in mi.verdict(a, A, later)), "판정 중 예외면 막는다(모르면 안 내린다)")
mb._input_empty = lambda name: empty[0]
real_rb = mb._restart_blockers
mb._restart_blockers = lambda rec: (_ for _ in ()).throw(OSError("기록을 못 읽음"))
check(any("판정 실패" in w for w in mi.verdict(a, A, later)), "restart_blockers 가 예외여도 막는다")
mb._restart_blockers = real_rb
mi._pane_tail = lambda name: (_ for _ in ()).throw(RuntimeError("capture 실패"))
check(any("판정 실패" in w for w in mi.verdict(a, A, later)), "화면을 못 읽어도 막는다")
mi._pane_tail = lambda name: pane[0]
# B8 모름은 막는다: 세션이 뜬 시각을 못 읽거나 시각 파일이 깨졌다
real_born = mb._session_born
mb._session_born = lambda name: 0.0
check(any("판정 실패" in w for w in mi.verdict(a, A, later)), "tmux 가 뜬 시각을 못 읽으면(0) 막는다")
mb._session_born = real_born
(sda / "turn-at").write_text("깨진 값")
check(any("판정 실패" in w for w in mi.verdict(a, A, later)), "시각 파일이 깨졌으면(ValueError) 막는다")
(sda / "turn-at").unlink()
# B12 워크트리 폴더가 사라진 방은 안 내린다(깨우기가 못 띄운다)
root_a = Path(a["root"]); root_a.rename(str(root_a) + ".gone")
check(any("작업 폴더" in w for w in mi.verdict(a, A, later)), "폴더가 없으면 안 내린다")
Path(str(root_a) + ".gone").rename(root_a)
# B1 화면의 'N shell' 은 기록 판정과 별개로 직접 막는다(기록 끝 2MB 밖에서 띄운 셸)
real_ps = mb._pane_shells
mb._pane_shells = lambda name: 2
check("백그라운드 셸 2" in mi.verdict(a, A, later), f"화면에 셸이 보이면 막는다: {mi.verdict(a, A, later)}")
mb._pane_shells = real_ps
# B2 CronCreate 예약: 세션이 뜬 뒤 만들고 CronDelete 가 안 따른 것은 막는다
import datetime
def iso(t): return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
def cron_rows(ts, create_id, job, delete=False, no_result=False):
    rs = [row({"type": "assistant", "timestamp": iso(ts), "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": create_id, "name": "CronCreate", "input": {"cron": "13 * * * *", "prompt": "p"}}]}})]
    if not no_result:
        rs.append(row({"type": "user", "timestamp": iso(ts + 1), "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": create_id, "content": f"Scheduled recurring job {job} (Every hour at :13). Session-only."}]}}))
    if delete:
        rs.append(row({"type": "assistant", "timestamp": iso(ts + 2), "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": create_id + "d", "name": "CronDelete", "input": {"id": job}}]}}))
    return "".join(rs)
base_tr = tra.read_text(); born_a = mb._session_born(a["tmux"])
def put(text):
    tra.write_text(text); os.utime(tra, (now - 9 * H, now - 9 * H))
put(base_tr + cron_rows(born_a + 5, "tuC1", "job11111"))
check("예약 기다림(cron)" in mi.verdict(a, A, later), f"CronCreate 가 살아 있으면 막는다: {mi.verdict(a, A, later)}")
put(base_tr + cron_rows(born_a + 5, "tuC1", "job11111", delete=True))
check("예약 기다림(cron)" not in mi.verdict(a, A, later), "CronDelete 가 따르면 안 막는다")
put(base_tr + cron_rows(born_a - 3600, "tuC1", "job11111"))
check("예약 기다림(cron)" not in mi.verdict(a, A, later), "세션이 뜨기 전 만든 예약은 그 세션과 함께 죽었다")
put(base_tr + cron_rows(born_a + 5, "tuC1", "job11111", no_result=True))
check("예약 기다림(cron)" in mi.verdict(a, A, later), "결과를 못 찾아도(id 모름) 있으면 막는다")
put(base_tr + cron_rows(born_a + 5, "tuC1", "job11111", delete=True) + cron_rows(born_a + 9, "tuC2", "job22222"))
check("예약 기다림(cron)" in mi.verdict(a, A, later), "다른 예약의 CronDelete 로는 안 풀린다")
put(base_tr)
# 끝난 예약은 막지 않는다: 만든 지 7일 지난 것(Auto-expires after 7 days) · 한 번짜리(recurring:false)는 예정 시각이 지났거나 그 뒤 fire 가 있으면
def cron_rows2(ts, create_id, job, **inp):
    return (row({"type": "assistant", "timestamp": iso(ts), "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": create_id, "name": "CronCreate", "input": dict({"cron": "13 * * * *", "prompt": "p"}, **inp)}]}})
            + row({"type": "user", "timestamp": iso(ts + 1), "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": create_id, "content": f"Scheduled recurring job {job} (Every hour at :13). Session-only. Auto-expires after 7 days."}]}}))
mb._session_born = lambda name: 1.0                       # 아주 오래 떠 있는 세션인 것처럼
put(base_tr + cron_rows2(now - 8 * 86400, "tuE1", "jobold01"))
check("예약 기다림(cron)" not in mi.verdict(a, A, later), "7일 지난 예약은 이미 만료")
put(base_tr + cron_rows2(now - 1 * 86400, "tuE2", "jobnew01"))
check("예약 기다림(cron)" in mi.verdict(a, A, later), "7일 안이면 살아 있다")
import time as _t
def cron_at(t):                                           # 로컬 시각 t 에 한 번 도는 크론 식
    lt = _t.localtime(t); return f"{lt.tm_min} {lt.tm_hour} {lt.tm_mday} {lt.tm_mon} *"
put(base_tr + cron_rows2(now - 7200, "tuO1", "joboneA1", cron=cron_at(now - 3600), recurring=False))
check("예약 기다림(cron)" not in mi.verdict(a, A, later), "한 번짜리: 예정 시각이 지났으면 끝")
put(base_tr + cron_rows2(now - 7200, "tuO2", "joboneB1", cron=cron_at(now + 3600), recurring=False))
check("예약 기다림(cron)" in mi.verdict(a, A, later), "한 번짜리: 예정 시각 전이면 기다리는 중")
put(base_tr + cron_rows2(now - 7200, "tuO3", "joboneC1", cron=cron_at(now + 3600), recurring=False)
    + row({"type": "system", "subtype": "scheduled_task_fire", "timestamp": iso(now - 3000)}))
check("예약 기다림(cron)" not in mi.verdict(a, A, later), "한 번짜리: 그 뒤 scheduled_task_fire 가 있으면 끝")
put(base_tr + cron_rows2(now - 7200, "tuO4", "joboneD1", cron="*/5 * * * *", recurring=False))
check("예약 기다림(cron)" in mi.verdict(a, A, later), "식을 못 풀면 살아 있다고 본다(fire·7일이 아니면)")
# Monitor 도구로 건 감시: 'Monitor started (task <id>, timeout Nms)' — 끝남 알림·TaskStop·만료 시각 경과를 본다
def mon_rows(ts, tid, task, timeout_ms):
    return (row({"type": "assistant", "timestamp": iso(ts), "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": tid, "name": "Monitor", "input": {"command": "tail -f x", "description": "감시"}}]}})
            + row({"type": "user", "timestamp": iso(ts + 1), "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": tid, "content": f"Monitor started (task {task}, timeout {timeout_ms}ms). You will be notified on each event."}]}}))
mb._session_born = real_born
born_a = mb._session_born(a["tmux"])
put(base_tr + mon_rows(born_a + 2, "tuM1", "mon11111", 3600000))
check("감시 중(Monitor)" in mi.verdict(a, A, later), f"Monitor 가 돌고 있으면 막는다: {mi.verdict(a, A, later)}")
put(base_tr + mon_rows(born_a + 2, "tuM1", "mon11111", 3600000)
    + row({"type": "queue-operation", "content": "<task-notification>\n<task-id>mon11111</task-id>\n<status>completed</status>\n<summary>stream ended</summary>\n</task-notification>"}))
check("감시 중(Monitor)" not in mi.verdict(a, A, later), "끝남 알림이 오면 안 막는다")
put(base_tr + mon_rows(born_a + 2, "tuM1", "mon11111", 3600000)
    + row({"type": "queue-operation", "content": "<task-notification>\n<task-id>mon11111</task-id>\n<summary>Monitor event: x</summary>\n</task-notification>"}))
check("감시 중(Monitor)" in mi.verdict(a, A, later), "이벤트 알림(상태 없음)은 끝이 아니다")
put(base_tr + mon_rows(born_a + 2, "tuM1", "mon11111", 3600000)
    + row({"type": "assistant", "timestamp": iso(born_a + 9), "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "tuS", "name": "TaskStop", "input": {"task_id": "mon11111"}}]}}))
check("감시 중(Monitor)" not in mi.verdict(a, A, later), "TaskStop 으로 끈 감시는 안 막는다")
put(base_tr + mon_rows(born_a + 1, "tuM2", "mon22222", 1))
check("감시 중(Monitor)" not in mi.verdict(a, A, later), "만료 시각이 지난 감시는 안 막는다")
put(base_tr + mon_rows(born_a - 3600, "tuM3", "mon33333", 99999999))
check("감시 중(Monitor)" not in mi.verdict(a, A, later), "세션이 뜨기 전 감시는 그 세션과 함께 죽었다")
# 유휴 시각 후보에 기록 마지막 줄의 timestamp — 훅이 죽어도 대화 중인 방이 턴 사이에 내려가지 않게
put(base_tr + row({"type": "assistant", "timestamp": iso(later - 600), "message": {"role": "assistant", "content": "대화 중"}}))
check(abs(mi.last_activity(a) - (later - 600)) < 2, f"기록 마지막 줄의 timestamp 도 활동: {mi.last_activity(a) - later}")
check(any("쉰 지" in w for w in mi.verdict(a, A, later)), "훅 기록이 없어도 방금 대화한 방은 안 내린다")
put(base_tr + "깨진 줄 {\n")
check(abs(mi.last_activity(a) - born_a) < 5, "마지막 줄을 못 읽으면 후보에서만 뺀다(다른 후보로)")
put(base_tr)
# 팀 에이전트: 쉬고 있는 팀 에이전트가 목록에 남은 세션은 restart_blockers 가 막는다(의도) — 화면 파싱을 가짜로 줘서 확인
real_tmux = ms._tmux
class R:
    def __init__(s, out): s.stdout = out; s.returncode = 0
def fake_tmux(*args, **kw):
    if args[:1] == ("capture-pane",):
        return R("대화\n⏺ main\n  ◯ reviewer  쉬는 중\n❯ \n")
    return real_tmux(*args, **kw)
ms._tmux = fake_tmux
check("팀 에이전트 일하는 중" in mi.verdict(a, A, later), "팀 에이전트가 목록에 남아 있으면 자동으로는 안 내린다(의도된 동작)")
ms._tmux = real_tmux
# _attached 자체: tmux 가 0 이라고 하면 아님, 1 이상·못 읽음은 붙어 있다
mi._attached = real_attached
class D:
    def __init__(s, out): s.stdout = out; s.returncode = 0
for out, want in (("0\n", False), ("1\n", True), ("2\n", True), ("", True)):
    ms._tmux = lambda *a, _o=out, **k: D(_o)
    check(mi._attached("x") is want, f"session_attached {out!r} → {want}")
ms._tmux = real_tmux
mi._attached = lambda name: attached[0]
# ── 틱: 20초마다 모든 방을 표본으로 · 60초 넘게 연속 조용한 방 하나만 · 직전 재확인(방 잠금 안) ──
woke = []
orig_spawn_wake = mi._spawn_wake
mi._spawn_wake = lambda channel: woke.append(channel)
T = mi.IDLE_TICK_EVERY
check(T == 20.0, "표본 간격 20초")
(sdb / "suggest.json").write_text(json.dumps({"text": "다음 할 일", "msg": "555"}))
idler = mi.Idler(started=STARTED)
check(idler.tick(later) is None and ms.tmux_alive(a["tmux"]) and ms.tmux_alive(b["tmux"]), "처음 본 순간엔 안 내린다(조용한 시간 재기 시작)")
check(idler.tick(later + 5) is None and idler.last_tick == later, "20초 안의 틱은 건너뛴다(속도 제한은 Idler 안)")
mb.live_tasks = lambda r: [{"id": "b1", "kind": "shell", "desc": "x"}] if r["task"] == "feat/a" else []
check(idler.tick(later + T) is None and "proj/feat/a" not in idler.clear_since and "proj/feat/b" in idler.clear_since, "20초 — 막힌 방은 리셋, 조용한 방은 이어진다")
mb.live_tasks = lambda r: []
check(idler.tick(later + 2 * T) is None and idler.clear_since["proj/feat/a"] == later + 2 * T, "풀린 방은 그때부터 다시 잰다")
log_path = ms.marina_home() / "discord-idle.log"
at_kill = []
real_stop = ms.tmux_stop
ms.tmux_stop = lambda name: (at_kill.append(log_path.read_text() if log_path.exists() else ""), real_stop(name))[1]
check(idler.tick(later + 3 * T) == "proj/feat/b" and not ms.tmux_alive(b["tmux"]) and ms.tmux_alive(a["tmux"]),
      "60초 연속 조용했던 b 하나만 내린다 — a 는 처음엔 조용했지만 중간에 막혀 20초뿐이라 남는다(clear_since 리셋)")
ms.tmux_stop = real_stop
check(woke == [b["channelId"]] and (sdb / "idle-stopped-at").exists(), f"내린 직후 그 방에 밀린 글 확인 + 기록: {woke}")
check(at_kill and "proj/feat/b" in at_kill[0] and all(k in at_kill[0] for k in ("turn-at=", "stopped-at=", "activity-at=", "born=", "쉰=")),
      f"죽이기 전에 판정 근거를 discord-idle.log 에: {at_kill}")
check(idler.clear_since == {} and idler.last_kill == later + 3 * T, "내린 뒤 clear_since 를 비우고 시각을 적는다")
check(not (sdb / "suggest.json").exists(), "내릴 때 남은 추천 버튼은 지운다(clear_suggest)")
fdlog = [json.loads(l) for l in (Path(os.environ["FD"]) / "log.jsonl").read_text().splitlines()]
check(any(x["m"] == "PATCH" and x["p"].endswith("/messages/555") for x in fdlog), "추천 메시지의 버튼을 뗐다(PATCH)")
log = (ms.marina_home() / "discord-bot.log").read_text()
check("idle proj/feat/b" in log and "시간 쉬어 내림" in log, f"내린 것은 로그에 남긴다: {log[-200:]}")
check(idler.tick(later + 4 * T) is None and ms.tmux_alive(a["tmux"]), "a 는 풀린 지 40초 — 아직")
# 내려간 방에서 추천·슬래시를 누르면 잠들어 있다고 답한다(B13)
check("잠들어" in mb.say(b["channelId"], "U1") and "깨어나" in mb.say(b["channelId"], "U1"), f"꺼진 방의 추천 버튼: {mb.say(b['channelId'], 'U1')}")
check("잠들어" in mb.slash(b["channelId"], "U1", "compact") and "잠들어" in mb.slash(b["channelId"], "U1", "stop"), "꺼진 방의 슬래시 명령")
# 죽이기 직전에 한 번 더 본다 — 방 잠금 안에서, 마지막 활동 시각을 다시 읽는다
seen = [0]
real_v = mi.verdict
def flip(rec, after, t, full=True):
    if rec["task"] != "feat/a": return ["꺼져 있음"]
    seen[0] += 1
    return [] if seen[0] == 1 else ["방금 막힘"]
mi.verdict = flip
idler2 = mi.Idler(started=STARTED); idler2.clear_since["proj/feat/a"] = later - 120; idler2.last_sample["proj/feat/a"] = later + 180
check(idler2.tick(later + 200) is None and ms.tmux_alive(a["tmux"]) and seen[0] == 2, f"직전 재확인에서 막히면 안 내린다: {seen[0]}")
def activity_between(rec, after, t, full=True):
    r = real_v(rec, after, t, full=full)
    if rec["task"] == "feat/a": (sda / "turn-at").write_text(str(t - 5))      # 표본 직후 지시가 들어왔다
    return r
mi.verdict = activity_between
idler2b = mi.Idler(started=STARTED); idler2b.clear_since["proj/feat/a"] = later - 120; idler2b.last_sample["proj/feat/a"] = later + 180
check(idler2b.tick(later + 200) is None and ms.tmux_alive(a["tmux"]), "표본과 죽이기 사이에 활동이 생기면(마지막 활동 시각을 다시 읽어) 안 내린다")
(sda / "turn-at").unlink(missing_ok=True)
mi.verdict = real_v
# 방 잠금(깨우기·재시작이 쥐고 있는 동안)은 건드리지 않는다
import fcntl
idler2c = mi.Idler(started=STARTED); idler2c.clear_since["proj/feat/a"] = later - 120; idler2c.last_sample["proj/feat/a"] = later + 180
lk = open(sda / "wake.lock", "w"); fcntl.flock(lk, fcntl.LOCK_EX)
check(idler2c.tick(later + 200) is None and ms.tmux_alive(a["tmux"]), "방 잠금을 누가 쥐고 있으면 내리지 않는다")
lk.close()
# 깨우기 수신 표식이 없으면(봇이 글 이벤트를 한 번도 안 넘겼다 = 깨울 수 있는지 모른다) 내리지 않는다(B5)
seen_file = ms.marina_home() / "discord-wake-seen"; keep_seen = seen_file.read_text()
seen_file.unlink()
idler3 = mi.Idler(started=STARTED); idler3.clear_since["proj/feat/a"] = later - 120; idler3.last_sample["proj/feat/a"] = later + 280
check(idler3.tick(later + 300) is None and ms.tmux_alive(a["tmux"]), "표식이 없으면 안 내린다")
seen_file.write_text(f"{STARTED - 50}\n")
check(idler3.tick(later + 300) is None and ms.tmux_alive(a["tmux"]), "표식이 데몬이 뜨기 전 것이면 안 내린다")
check("깨우기 수신 미확인 — 내림 보류" in mi.summary(started=STARTED), f"idle-check 첫 줄: {mi.summary(started=STARTED)}")
seen_file.write_text(keep_seen)
check("깨우기 수신 확인" in mi.summary(started=STARTED) and "켜짐" in mi.summary(started=STARTED) and "기준 2시간" in mi.summary(started=STARTED), f"실효 상태 줄: {mi.summary(started=STARTED)}")
check("기준 2시간" in mi.summary(hours=1, started=STARTED), "--hours 도 하한 2시간")
# 봇이 죽어 있으면(깨울 수 없으면) 내리지 않는다 · 안전 재시작 대기가 돌면 내리지 않는다 · 꺼 두면 안 내린다
idler3.clear_since["proj/feat/a"] = later - 120; idler3.last_sample["proj/feat/a"] = later + 280
check(idler3.tick(later + 300, bot_up=False) is None and ms.tmux_alive(a["tmux"]), "봇이 없으면 안 내린다")
idler3.clear_since["proj/feat/a"] = later - 120; idler3.last_sample["proj/feat/a"] = later + 320
mb.restart_status = lambda: {"pid": 1, "remaining": ["x"]}
check(idler3.tick(later + 340) is None and ms.tmux_alive(a["tmux"]), "재시작 대기 중이면 안 내린다")
mb.restart_status = lambda: None
cfgp = ms.config_path(); cfg0 = cfgp.read_text()
cfgp.write_text(json.dumps(dict(json.loads(cfg0), idleStopHours=0)))
idler3.clear_since["proj/feat/a"] = later - 120; idler3.last_sample["proj/feat/a"] = later + 340
check(idler3.tick(later + 360) is None and ms.tmux_alive(a["tmux"]), "idleStopHours 0 이면 안 내린다")
check("꺼짐" in mi.summary(started=STARTED), "꺼 두면 첫 줄이 꺼짐")
cfgp.write_text(cfg0)
# 표본이 끊기면(데몬이 멈췄다 돌아옴) 이어진 시간으로 치지 않는다
idler5 = mi.Idler(started=STARTED); idler5.clear_since["proj/feat/a"] = later - 600; idler5.last_sample["proj/feat/a"] = later - 400
check(idler5.tick(later + 400) is None and idler5.clear_since["proj/feat/a"] == later + 400 and ms.tmux_alive(a["tmux"]), "표본 사이가 너무 벌어지면 처음부터 다시")
# 읽기만 하는 점검
rows = {r["ref"]: r for r in mi.check_all()}
check(rows["proj/feat/b"]["alive"] is False and rows["proj/feat/a"]["stop"] is False and rows["proj/feat/a"]["why"], f"idle-check: {rows}")
check(mi.check_all(hours=1)[0]["afterHours"] == 2.0 and mi.check_all()[0]["afterHours"] == 2.0, "--hours 도 하한 2시간을 거친다")
check(ms.tmux_alive(a["tmux"]), "점검은 아무것도 안 죽인다")
# 한 틱에 하나, 1분에 하나(last_kill 은 Idler 안): 둘 다 내려도 되는 상태여도
real_rb2 = mb.restart_blockers
mb.restart_blockers = lambda r: []
ms.cmd_start("proj/feat/b")
idler6 = mi.Idler(started=STARTED)
for ref in ("proj/feat/a", "proj/feat/b"):
    idler6.clear_since[ref] = later + 600 - 120; idler6.last_sample[ref] = later + 680
woke.clear()
r1 = idler6.tick(later + 700)
alive_now = [ms.tmux_alive(a["tmux"]), ms.tmux_alive(b["tmux"])]
check(r1 is not None and alive_now.count(True) == 1, f"한 번에 하나만 내린다: {r1} {alive_now}")
other = "proj/feat/b" if r1 == "proj/feat/a" else "proj/feat/a"
idler6.clear_since[other] = later + 600; idler6.last_sample[other] = later + 700
check(idler6.tick(later + 720) is None and alive_now.count(True) == 1 and [ms.tmux_alive(a["tmux"]), ms.tmux_alive(b["tmux"])].count(True) == 1,
      "1분에 하나 — 20초 뒤엔 나머지가 준비돼 있어도 안 내린다(last_kill)")
idler6.last_sample[other] = later + 760
r2 = idler6.tick(later + 761)
check(r2 == other and not ms.tmux_alive(a["tmux"]) and not ms.tmux_alive(b["tmux"]), f"1분 뒤에 나머지: {r2}")
check(len(woke) == 2, f"내릴 때마다 그 방 밀린 글을 확인: {woke}")
mb.restart_blockers = real_rb2
# 로그 파일: 5MB 가 넘으면 앞 절반을 자른다
log_path.write_text("x" * (6 * 1024 * 1024) + "\n")
mi._idle_log("마지막 줄")
check(log_path.stat().st_size < 4 * 1024 * 1024 and log_path.read_text().rstrip().endswith("마지막 줄"), f"5MB 넘으면 앞 절반을 잘라 낸다: {log_path.stat().st_size}")
# _spawn_wake 는 '내린 직후' 표시를 단다(nothing 이면 끊긴 방을 다시 켜게)
argvs = []
class FP:
    def __init__(self, argv, **kw): argvs.append(argv)
real_popen = mi.subprocess.Popen; mi.subprocess.Popen = FP
orig_spawn_wake("1234")
check(argvs and "--after-idle" in argvs[0] and "1234" in argvs[0], f"내린 직후 확인 표시: {argvs}")
mi.subprocess.Popen = real_popen
# ── 연결부: Loop.view 를 두 번 불러도 한 번만 내리고, idle 모듈이 깨져도 #상태·typing 은 계속 ──
mi._spawn_wake = lambda channel: None
mb.live_tasks = lambda r: []; mb.restart_blockers = lambda r: []; mb.restart_status = lambda: None
mi._attached = lambda name: False; mb._input_empty = lambda name: True; mi._pane_tail = lambda name: ""
for r_ in ("proj/feat/a", "proj/feat/b"):
    ms.cmd_start(r_)
ran = []
mb.panel_tick = lambda last, now: last; mb.snapshot = lambda full=False: {"anyBusy": False, "sessions": []}
mb.typing_tick = lambda *a, **k: ran.append("typing"); mb.pane_perm_tick = lambda: ran.append("perm"); mb.role_events_tick = lambda: ran.append("role")
mb.agent_words_tick = lambda *a, **k: {}; mb.should_render = lambda *a, **k: False; ms.reconcile_gone = lambda now: []
loop = mb.Loop(); loop.proc = type("P", (), {"poll": lambda self: None})()
loop.idler = mi.Idler(started=0.0)
for ref in ("proj/feat/a", "proj/feat/b"):
    loop.idler.clear_since[ref] = later + 1000 - 120; loop.idler.last_sample[ref] = later + 980
loop.view(later + 1000); loop.view(later + 1001)
check([ms.tmux_alive(a["tmux"]), ms.tmux_alive(b["tmux"])].count(True) == 1, f"Loop.view 를 연달아 불러도 한 번만 내린다: {[ms.tmux_alive(a['tmux']), ms.tmux_alive(b['tmux'])]}")
ran.clear(); real_mod = sys.modules.get("marina_discord_idle")
sys.modules["marina_discord_idle"] = None          # import 가 깨진 것처럼
loop2 = mb.Loop(); loop2.proc = loop.proc
loop2.view(later + 2000)
sys.modules["marina_discord_idle"] = real_mod
check("typing" in ran and "perm" in ran and "role" in ran, f"idle 모듈이 깨져도 #상태·typing·권한 창은 계속: {ran}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
out="$(msess idle-check 2>&1)" || fail "idle-check 명령"
echo "$out" | head -1 | grep -q "내리기" || fail "idle-check 첫 줄은 실효 상태: $(echo "$out" | head -1)"
echo "PASS test-discord-idle"
