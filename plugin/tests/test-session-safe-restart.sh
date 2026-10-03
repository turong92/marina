#!/usr/bin/env bash
# 안전 재시작: 화면이 아니라 훅 기록으로 판단한다 — 턴 중(받은 순간~턴 끝)·백그라운드·질문·권한 대기·방금 받은 메시지면 기다린다.
# 안전망: 재시작한 세션이 '받았는데 답 못 한 Discord 메시지' 로 끝나 있으면 알아서 이어서 답하게 입력해 준다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
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
              + row({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "r", "name": R, "input": {}}]}}))
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
# (실사용) SendMessage 로 맡긴 팀 에이전트가 일하는 중 — 화면 아래 에이전트 목록(⏺ main / ◯ …)
base = ms._tmux_base()
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                       "printf '✻ Worked\\n────\\n❯ \\n────\\n  ⏵⏵ bypass · ← for agents\\n  ⏺ main\\n  ◯ general-purpose  카드 효과 만드는 중\\n'; exec cat"], check=True)
time.sleep(0.5)
check("에이전트" in " ".join(mb.restart_blockers(rec)), f"팀 에이전트가 일하면 안 건드린다: {mb.restart_blockers(rec)}")
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
done, waiting = mb.safe_restart(["proj/feat/a"], wait=3, poll=0.1)
after = subprocess.run(ms._tmux_base() + ["display-message", "-p", "-t", rec["tmux"], "#{session_created}"], capture_output=True, text=True).stdout
check(done == ["proj/feat/a"] and not waiting and after != before and ms.tmux_alive(rec["tmux"]), f"풀리면 재시작: {done} {waiting} {before} {after}")

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
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-safe-restart"
