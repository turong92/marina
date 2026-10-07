#!/usr/bin/env bash
# 안전 재시작: 화면이 아니라 훅 기록으로 판단한다 — 턴 중(받은 순간~턴 끝)·백그라운드·질문·권한 대기·방금 받은 메시지면 기다린다.
# 안전망: 재시작한 세션이 '받았는데 답 못 한 Discord 메시지' 로 끝나 있으면 알아서 이어서 답하게 입력해 준다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
export MARINA_SH
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a >/dev/null 2>&1 || fail "new"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
os.environ["DISCORD_STATE_DIR"] = str(sd)
sid = rec.get("sessionId") or "abcdabcd-0000-1111-2222-333344445555"
if not rec.get("sessionId"):
    ms.save_sessions([dict(x, sessionId=sid) if x.get("stateDir") == str(sd) else x for x in ms.load_sessions()])
    rec = ms.find_session("proj/feat/a")
tr = ms.transcript_path(Path(rec["root"]), sid); tr.parent.mkdir(parents=True, exist_ok=True)
def tag(mid): return f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="{mid}" user="u">\nhi\n</channel>'
def row(r): return json.dumps(r, ensure_ascii=False) + "\n"
R = "mcp__plugin_discord_discord__reply"
old = time.time() - 300
tr.write_text(row({"type": "user", "message": {"role": "user", "content": tag("1")}})
              + row({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "r", "name": R, "input": {}}]}})
              + row({"type": "system", "subtype": "turn_duration"}))
os.utime(tr, (old, old))
mb.live_tasks = lambda r: []

# ── 막는 이유 ──
(sd / "stopped-at").write_text(str(time.time() - 100))
check(mb.restart_blockers(rec) == [], f"쉬는 세션은 막는 것 없음: {mb.restart_blockers(rec)}")
ms.hook_prompt({"hook_event_name": "UserPromptSubmit", "prompt": tag("2"), "transcript_path": str(tr)})
check("작업 중" in " ".join(mb.restart_blockers(rec)), "받은 순간부터 턴 끝까지는 작업 중(화면이 쉬어 보여도)")
(sd / "turn-at").write_text(str(time.time() - 700))
check("작업 중" not in " ".join(mb.restart_blockers(rec)), "(리뷰 I1) Esc 등으로 턴 끝 기록이 안 남아도 10분 지나고 화면이 쉬면 안 막는다")
ms.hook_prompt({"hook_event_name": "UserPromptSubmit", "prompt": tag("2"), "transcript_path": str(tr)})
(sd / "stopped-at").write_text(str(time.time() + 1))
mb.live_tasks = lambda r: [{"id": "b1", "kind": "shell", "desc": "x"}]
check("백그라운드" in " ".join(mb.restart_blockers(rec)), "백그라운드 셸")
mb.live_tasks = lambda r: []
(sd / "question.json").write_text("{}")
check("질문" in " ".join(mb.restart_blockers(rec)), "질문 버튼 대기"); (sd / "question.json").unlink()
(sd / "perm-aaaaaaaaaaaa.json").write_text("{}")
check("권한" in " ".join(mb.restart_blockers(rec)), "권한 버튼 대기"); (sd / "perm-aaaaaaaaaaaa.json").unlink()
os.utime(tr, None)
check("방금" in " ".join(mb.restart_blockers(rec)), "기록이 막 움직임(방금 받은 메시지)")
os.utime(tr, (old, old))
check(mb.restart_blockers(rec) == [], "다 풀리면 재시작 가능")

# ── (2026-10-07 사고) 기록 기준으로 에이전트·예약을 본다 ──
import datetime
subs = tr.parent / tr.stem / "subagents"; subs.mkdir(parents=True, exist_ok=True)
def agent(name, last, age):
    f = subs / f"agent-a{name}.jsonl"
    f.write_text(row({"type": "user", "message": {"role": "user", "content": "일해"}}) + row(last))
    f.with_suffix(".meta.json").write_text(json.dumps({"name": name, "agentType": name, "customAgentType": "developer", "taskKind": "in_process_teammate"}))
    t = time.time() - age; os.utime(f, (t, t)); return f
_born = mb._session_born; mb._session_born = lambda n: time.time() - 7200    # 세션이 두 시간 전에 떴다고 — 방금 뜬 테스트 세션은 오래된 에이전트 파일을 '재시작 전 것'으로 거른다
def blockers(): return " ".join(mb.restart_blockers(rec))
check(ms.tmux_alive(rec["tmux"]), "(전제) 테스트 세션이 떠 있다")
doing = {"type": "assistant", "message": {"stop_reason": "tool_use", "content": [{"type": "tool_use", "id": "t", "name": "Bash", "input": {}}]}}
fin = {"type": "assistant", "message": {"stop_reason": "end_turn", "content": [{"type": "text", "text": "끝"}]}}
f1 = agent("stamp-apply", doing, 600)           # 사고: 긴 도구 호출로 5분 넘게 조용한 이름 붙은 팀 에이전트
check("에이전트 1개" in blockers(), f"조용해도 안 끝난 팀 에이전트는 막는다: {blockers()}")
f1.unlink(); f1.with_suffix(".meta.json").unlink()
f2 = agent("stamp-done", fin, 10)
check("에이전트" not in blockers(), f"end_turn 으로 끝난 팀 에이전트는 안 막는다: {blockers()}")
f2.unlink(); f2.with_suffix(".meta.json").unlink()
f3 = agent("stamp-dead", doing, 4000)           # 30분 넘게 아무 기록 없음 = 죽은 것
check("에이전트" not in blockers(), f"한참 조용한 에이전트는 죽은 것: {blockers()}")
f3.unlink(); f3.with_suffix(".meta.json").unlink()

def iso(t): return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
def wake(ago, delay, inp=None):
    return row({"type": "assistant", "timestamp": iso(time.time() - ago), "message": {"content": [
        {"type": "tool_use", "id": "w", "name": "ScheduleWakeup", "input": inp if inp is not None else {"delaySeconds": delay, "reason": "r", "prompt": "p"}}]}})
fire = row({"type": "system", "subtype": "scheduled_task_fire", "timestamp": iso(time.time())})
base_rows = tr.read_text()
def with_rows(extra):
    tr.write_text(base_rows + extra); os.utime(tr, (old, old))
with_rows(wake(10, 900))
check("예약" in blockers(), f"걸어 둔 ScheduleWakeup 이 살아 있으면 막는다: {blockers()}")
with_rows(wake(10, 900) + fire)
check("예약" not in blockers(), f"울린 뒤엔 안 막는다: {blockers()}")
with_rows(wake(10, 900) + wake(5, 0, {"stop": True}))
check("예약" not in blockers(), f"stop 으로 취소했으면 안 막는다: {blockers()}")
with_rows(wake(1200, 600))                       # 10분 전에 울렸어야 — 여유 2분도 넘김 = 죽은 예약
check("예약" not in blockers(), f"예정 시각이 한참 지난 예약은 죽은 것: {blockers()}")
with_rows(wake(660, 600))                        # 1분 지남 — 여유 2분 안
check("예약" in blockers(), f"예정 시각 직후(여유 2분 안)는 아직 막는다: {blockers()}")
tr.write_text(base_rows); os.utime(tr, (old, old))
check(blockers() == "", f"되돌리면 다시 풀린다: {blockers()}")

# E: 세션이 뜨기 전에 건 예약은 죽은 예약
with_rows(wake(8000, 9000))
check("예약" not in blockers(), f"세션 시작(born) 전에 건 예약은 버린다: {blockers()}")
tr.write_text(base_rows); os.utime(tr, (old, old))

# A: 턴 진행 중 = 기록 마지막 의미 있는 줄이 턴 끝 표시가 아니고 user·assistant
tool_res = row({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "content": "ok"}]}})
asst = row({"type": "assistant", "message": {"stop_reason": "tool_use", "content": [{"type": "text", "text": "생각"}]}})
noise = row({"type": "attachment"}) + row({"type": "queue-operation"}) + row({"type": "system", "subtype": "bridge_status"})
with_rows(tool_res)
check("턴 진행 중" in blockers(), f"마지막 줄이 tool_result 면(65초 생각 중이던 사고) 턴 진행 중: {blockers()}")
with_rows(asst + noise)
check("턴 진행 중" in blockers(), f"attachment·queue-operation·bridge_status 는 건너뛴다: {blockers()}")
with_rows(tool_res + row({"type": "system", "subtype": "stop_hook_summary"}) + noise)
check("턴 진행 중" not in blockers(), f"stop_hook_summary 가 마지막 의미 줄이면 끝난 턴: {blockers()}")
with_rows(tool_res + row({"type": "system", "subtype": "turn_duration"}))
check("턴 진행 중" not in blockers(), f"turn_duration 도 끝난 턴: {blockers()}")
with_rows(tool_res + row({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user]"}]}}))
check("턴 진행 중" not in blockers(), f"Esc 로 끊긴 턴은 끝난 것: {blockers()}")
with_rows(row({"type": "assistant", "timestamp": iso(time.time() - 2400), "message": {"content": []}}))
check("턴 진행 중" not in blockers(), f"마지막 줄이 30분 넘게 오래됐으면 막지 않는다: {blockers()}")
with_rows(row({"type": "assistant", "timestamp": iso(time.time() - 1500), "message": {"content": []}}))
check("턴 진행 중" in blockers(), f"25분 전 줄은 아직 막는다: {blockers()}")
# G: 큰 기록도 끝에서부터 — 앞에 큰 덩어리가 있어도 끝 줄로 판정(전체를 읽지 않는다)
tr.write_text(base_rows + ("x" * 5_000_000 + "\n") + tool_res); os.utime(tr, (old, old))
import pathlib
_orig_rb = pathlib.Path.read_bytes
def no_full(self): raise AssertionError("기록을 통째로 읽었다")
pathlib.Path.read_bytes = no_full
try:
    check("턴 진행 중" in blockers(), f"큰 기록 끝에서 판정: {blockers()}")
finally:
    pathlib.Path.read_bytes = _orig_rb
tr.write_text(base_rows); os.utime(tr, (old, old))

# 판정 중 예외 = 모르면 죽이지 않는다
_orig_ar = mb._agents_running
def boom(*a, **k): raise OSError("기록 못 읽음 " + "x" * 200)
mb._agents_running = boom
check("판정 실패(OSError: 기록 못 읽음" in blockers() and "x" * 81 not in blockers(), f"판정 중 예외면 막는다(예외 메시지 앞 80자): {blockers()}")
mb._agents_running = _orig_ar; mb._session_born = _born
# (실사용) SendMessage 로 맡긴 팀 에이전트가 일하는 중 — 화면 아래 에이전트 목록(⏺ main / ◯ …)
base = ms._tmux_base()
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                       "printf '✻ Worked\\n────\\n❯ \\n────\\n  ⏵⏵ bypass · ← for agents\\n  ⏺ main\\n  ◯ general-purpose  카드 효과 만드는 중\\n'; exec cat"], check=True)
time.sleep(0.5)
check("에이전트" in " ".join(mb.restart_blockers(rec)), f"팀 에이전트가 일하면 안 건드린다: {mb.restart_blockers(rec)}")
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
# 터미널 권한 창(perm-*.json 없이 화면에만) — 서브에이전트 것
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                       "printf 'Bash command\\n Do you want to proceed?\\n ❯ 1. Yes\\n   2. No\\n'; exec cat"], check=True)
time.sleep(0.5)
check("권한 창" in " ".join(mb.restart_blockers(rec)), f"화면의 권한 창도 막는다: {mb.restart_blockers(rec)}")
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
ms.cmd_start("proj/feat/a")

# ── 안전 재시작 ──
(sd / "stopped-at").write_text(str(time.time() - 50))
ms.hook_prompt({"hook_event_name": "UserPromptSubmit", "prompt": tag("3"), "transcript_path": str(tr)})
before = subprocess.run(ms._tmux_base() + ["display-message", "-p", "-t", rec["tmux"], "#{session_created}"], capture_output=True, text=True).stdout
done, waiting = mb.safe_restart(["proj/feat/a"], wait=0.5, poll=0.1)
check(waiting == ["proj/feat/a"] and not done, f"작업 중이면 안 한다: {done} {waiting}")
(sd / "stopped-at").write_text(str(time.time() + 1))
time.sleep(1.1)
done, waiting = mb.safe_restart(["proj/feat/a"], wait=3, poll=0.1, quiet=0.2)
after = subprocess.run(ms._tmux_base() + ["display-message", "-p", "-t", rec["tmux"], "#{session_created}"], capture_output=True, text=True).stdout
check(done == ["proj/feat/a"] and not waiting and after != before and ms.tmux_alive(rec["tmux"]), f"풀리면 재시작: {done} {waiting} {before} {after}")

# ── 재시작 시점: 막는 이유가 없는 상태가 quiet 초 이어져야, 직전에 한 번 더 확인 ──
import inspect
check(inspect.signature(mb.safe_restart).parameters["wait"].default == 1800.0, "기본 대기 30분")
_o = (ms.find_session, ms.tmux_alive, ms.tmux_stop, ms.cmd_start, mb.restart_blockers)
stops = []
ms.find_session = lambda ref: {"tmux": "x"}; ms.tmux_alive = lambda n: True
ms.tmux_stop = lambda n: stops.append(time.time()); ms.cmd_start = lambda ref: ([ref], None)
mb.restart_blockers = lambda r: []
t0 = time.time(); done, waiting = mb.safe_restart(["r"], wait=5, poll=0.05, quiet=0.5)
check(done == ["r"] and stops and stops[0] - t0 >= 0.5, f"깨끗한 폴링 한 번으로는 안 죽인다(quiet 이상 이어져야): {stops and stops[0] - t0}")
stops.clear(); times = []
def blocked_on_4th(r):
    times.append(time.time()); return ["작업 중"] if len(times) == 4 else []
mb.restart_blockers = blocked_on_4th
done, waiting = mb.safe_restart(["r"], wait=5, poll=0.05, quiet=0.5)
check(done == ["r"] and stops and stops[0] - times[3] >= 0.5, f"4번째 폴링에서 막히면 그때부터 다시 센다: {stops and stops[0] - times[3]}")
stops.clear(); calls = []
def alt(r):
    calls.append(1); return [] if len(calls) % 2 else ["작업 중"]
mb.restart_blockers = alt
done, waiting = mb.safe_restart(["r"], wait=0.4, poll=0.05, quiet=0)
check(not stops and not done and waiting == ["r"], f"tmux_stop 직전에 다시 확인해 막히면 안 죽인다: {stops} {done} {waiting}")
# B: 꺼진 세션은 tmux_stop 없이 cmd_start 만(막는 이유·quiet 검사도 건너뜀)
stops.clear(); started = []
ms.tmux_alive = lambda n: False
ms.cmd_start = lambda ref: (started.append(ref) or [ref], None)
mb.restart_blockers = lambda r: ["작업 중"]
done, waiting = mb.safe_restart(["r"], wait=1, poll=0.05, quiet=30)
check(done == ["r"] and started == ["r"] and not stops, f"꺼진 세션은 tmux_stop 안 하고 시작만: {done} {started} {stops}")
ms.tmux_alive = lambda n: True; ms.cmd_start = lambda ref: ([ref], None)
# F: 포기할 때 세션별 마지막 막은 이유
why = {}
mb.restart_blockers = lambda r: ["작업 중", "예약 기다림"]
done, waiting = mb.safe_restart(["r"], wait=0.2, poll=0.05, reasons=why)
check(waiting == ["r"] and "예약 기다림" in why.get("r", ""), f"못 한 세션의 마지막 이유를 돌려준다: {why}")
# D: 대기자는 한 번에 하나 — 잠금·현황·취소
mb.restart_blockers = lambda r: []
held = mb._acquire_restart_lock(["r"])
try:
    try:
        mb.safe_restart(["r"], wait=0.2, poll=0.05, quiet=0)
        check(False, "이미 도는 대기가 있으면 새로 건 쪽은 실패해야 한다")
    except ms.SessionError as e:
        check("이미 재시작 대기가 돌고 있다(pid %d)" % os.getpid() in str(e), f"안내 문구: {e}")
    st = mb.restart_status()
    check(st and st["pid"] == os.getpid() and st["remaining"] == ["r"] and st.get("startedAt"), f"현황에 pid·시작·남은 세션: {st}")
finally:
    mb._release_restart_lock(held)
check(mb.restart_status() is None, "잠금이 풀리면 현황 없음")
done, waiting = mb.safe_restart(["r"], wait=1, poll=0.05, quiet=0)
check(done == ["r"], f"잠금이 풀리면 다시 돈다: {done}")
check(mb.restart_cancel() is None, "돌고 있는 게 없으면 취소할 것 없음")
child = subprocess.Popen([sys.executable, "-c", "import sys,time,marina_discord_bot as mb; l=mb._acquire_restart_lock(['x']); print('up',flush=True); time.sleep(60)"],
                         stdout=subprocess.PIPE, text=True)
child.stdout.readline()
check(mb.restart_status()["pid"] == child.pid, "다른 프로세스가 쥔 잠금도 보인다")
check(mb.restart_cancel() == child.pid, "취소는 그 pid 를 끝낸다")
try: child.wait(5)
except Exception: child.kill()
check(child.returncode is not None and mb.restart_status() is None, f"끝난 뒤 잠금 풀림: {child.returncode}")
(ms.find_session, ms.tmux_alive, ms.tmux_stop, ms.cmd_start, mb.restart_blockers) = _o

# ── 못 답한 메시지 이어받기 ──
check(ms.unanswered(tr) is False, "답한 뒤면 이어받을 것 없음")
tr.write_text(row({"type": "user", "message": {"role": "user", "content": tag("1")}})
              + row({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "r", "name": R, "input": {}}]}})
              + row({"type": "user", "message": {"role": "user", "content": tag("9")}})
              + row({"type": "assistant", "message": {"content": [{"type": "text", "text": "생각 중…"}]}}))
check(ms.unanswered(tr) is True, "받은 뒤 답장 없이 끝남 = 이어받기")
typed = []
mb._spawn_type = lambda tmux, text, channel, mid, button="": typed.append(text)
(sd / "stopped-at").write_text(str(time.time() - 100)); (sd / "turn-at").write_text(str(time.time() - 50))
ms.resume_unanswered(rec)
check(typed and typed[0].startswith("[마리나]") and mb.typeable(typed[0]), f"턴 도중 끊겼으면 이어서 답하라고 입력: {typed}")
typed.clear(); ms.resume_unanswered(rec)
check(not typed, "(리뷰 I3) 이미 이어받기를 걸었으면 또 안 건다")
(sd / "resume-at").unlink()
(sd / "stopped-at").write_text(str(time.time() - 10)); (sd / "turn-at").write_text(str(time.time() - 50))
typed.clear(); ms.resume_unanswered(rec)
check(not typed, "(리뷰 I2) 턴이 끝난 뒤 멈춘 세션(일부러 stop·반응만 한 답)은 건드리지 않는다")
(sd / "stopped-at").write_text(str(time.time() - 9000)); (sd / "turn-at").write_text(str(time.time() - 8000))
typed.clear(); ms.resume_unanswered(rec)
check(not typed, "(리뷰 I2) 오래된 끊김은 건드리지 않는다")
(sd / "stopped-at").write_text(str(time.time() - 100)); (sd / "turn-at").write_text(str(time.time() - 50))
tr.write_text(row({"type": "user", "message": {"role": "user", "content": "터미널에서 친 말"}}))
typed.clear(); ms.resume_unanswered(rec)
check(not typed, "터미널 지시는 건드리지 않는다")

# ── --force: 사람이 시킨 강제 재시작(막는 이유는 찍고 무시, 대기·조용한 시간 없음, 잠금은 지킨다) ──
def created():
    return subprocess.run(ms._tmux_base() + ["display-message", "-p", "-t", rec["tmux"], "#{session_created}"], capture_output=True, text=True).stdout
def cli(*args, inside=False):
    env = {k: v for k, v in os.environ.items() if inside or k != "DISCORD_STATE_DIR"}     # 기본: 세션 밖(사람 터미널)에서 친 것처럼
    return subprocess.run(["bash", os.environ["MARINA_SH"], "session", *args], capture_output=True, text=True, timeout=60, env=env)
ms.cmd_start("proj/feat/a")
(sd / "question.json").write_text("{}")
check(mb.restart_blockers(rec) != [], "(전제) 질문 대기로 막힌 세션")
b4 = created(); time.sleep(1.1)
r = cli("restart", "proj/feat/a", "--force")
check(r.returncode == 0, f"--force 는 막힌 세션도 재시작: rc={r.returncode} {r.stderr}")
check("강제 재시작: proj/feat/a — 무시한 것: " in r.stdout and "질문 답 기다림" in r.stdout, f"무시한 이유를 찍는다: {r.stdout!r}")
check(created() != b4 and ms.tmux_alive(rec["tmux"]), "tmux 세션이 새로 떴다")
(sd / "question.json").unlink(missing_ok=True)
tr.write_text(base_rows); (sd / "stopped-at").write_text(str(time.time() - 100)); (sd / "turn-at").write_text("0")
os.utime(tr, (old, old))
time.sleep(1.1)
r = cli("restart", "proj/feat/a", "--force")
check(r.returncode == 0 and "무시한 것: 막는 이유 없음" in r.stdout, f"막는 이유 없으면 그렇게 찍는다: {r.stdout!r} {r.stderr}")
r = cli("restart", "--all", "--force")
check(r.returncode != 0 and "--force" in r.stderr, f"--all --force 는 거절: rc={r.returncode} {r.stderr!r}")
r = cli("restart", "--force")
check(r.returncode != 0, f"ref 없는 --force 도 거절: rc={r.returncode}")
b4 = created()
held = mb._acquire_restart_lock(["other"])
try:
    r = cli("restart", "proj/feat/a", "--force")
    check(r.returncode != 0 and "이미 재시작 대기가 돌고 있다" in (r.stderr + r.stdout), f"잠금이 잡혀 있으면 거절: rc={r.returncode} {r.stderr!r}")
    check(created() == b4, "거절되면 세션을 안 건드린다")
finally:
    mb._release_restart_lock(held)

# ── 리뷰 반영 ──
# 1) 별칭+정식 이름으로 같은 세션을 두 번 줘도 자기 세션은 빠진다(--force·안전 경로 모두)
b4 = created()
r = cli("restart", "feat/a", "proj/feat/a", "--force", inside=True)
check(r.returncode != 0 and created() == b4 and "자기 세션" in r.stderr, f"중복 ref 로 자기 세션이 뚫렸다(force): rc={r.returncode} {r.stderr!r}")
r = cli("restart", "feat/a", "proj/feat/a", "--wait", "1", inside=True)
check(r.returncode != 0 and created() == b4 and "자기 세션" in r.stderr, f"중복 ref 로 자기 세션이 뚫렸다(안전): rc={r.returncode} {r.stderr!r}")
# 3) 대기자 거절 안내에 취소 방법
held = mb._acquire_restart_lock(["other"])
try:
    r = cli("restart", "proj/feat/a", "--force")
    check("marina session restart --cancel" in (r.stderr + r.stdout), f"거절 메시지에 --cancel 안내: {r.stderr!r}")
finally:
    mb._release_restart_lock(held)
# 4) 강제 stop 뒤 남은 질문·권한 기록 정리
(sd / "question.json").write_text(json.dumps({"questions": [{"header": "h", "question": "q", "options": [{"label": "a"}]}], "answers": [None], "msg": "123"}))
(sd / "perm-aaaaaaaaaaaa.json").write_text(json.dumps({"token": "aaaaaaaaaaaa", "msg": ""}))
(sd / "perm-aaaaaaaaaaaa.answer").write_text("allow")
time.sleep(1.1)
r = cli("restart", "proj/feat/a", "--force")
check(r.returncode == 0, f"(전제) 강제 재시작: {r.stderr!r}")
check(not (sd / "question.json").exists() and not list(sd.glob("perm-*")), f"남은 질문·권한 기록을 정리: {sorted(x.name for x in sd.iterdir())}")
# 2) start 실패 사유를 버리지 않는다 — 끝 줄에 어떻게 켜는지
root_dir = Path(rec["root"]); moved = root_dir.with_name(root_dir.name + ".moved"); root_dir.rename(moved)
try:
    time.sleep(1.1)
    r = cli("restart", "proj/feat/a", "--force")
    check(r.returncode == 1, f"start 실패면 종료 코드 1: {r.returncode}")
    check("워크트리가 없어 건너뜀" in r.stderr and "지금 꺼져 있다: marina session start proj/feat/a" in r.stderr, f"실패 사유+켜는 법: {r.stderr!r}")
finally:
    moved.rename(root_dir)
ms.cmd_start("proj/feat/a")
# 2) cmd_start 예외는 ref 단위로 잡고 나머지는 계속
_o2 = (ms.find_session, ms.tmux_alive, ms.tmux_stop, ms.cmd_start)
ms.find_session = lambda ref: {"tmux": "x", "stateDir": "/nonexistent", "channelId": "1"}; ms.tmux_alive = lambda n: False; ms.tmux_stop = lambda n: None
def _cs(ref):
    if ref == "bad": raise RuntimeError("boom")
    return ([ref], [])
ms.cmd_start = _cs
done, failed = mb.force_restart(["bad", "good"], log=lambda *_: None)
check(done == ["good"] and len(failed) == 1 and "bad" in failed[0] and "boom" in failed[0] and "marina session start bad" in failed[0], f"예외는 ref 단위로 잡는다: {done} {failed}")
(ms.find_session, ms.tmux_alive, ms.tmux_stop, ms.cmd_start) = _o2
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-safe-restart"
