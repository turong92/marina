#!/usr/bin/env bash
# (실사용 2026-10-04) ovation 이 서브에이전트로 일하는데 #상태엔 '대기' —
#  1) 띄운 줄이 기록 끝 2MB 밖(19MB 기록)·팀/중첩 에이전트는 agentId 형식이 아님 → subagents/ 폴더에서 최근 움직인 파일로 본다
#  2) 서브에이전트가 터미널 권한 창(Do you want to proceed?)에서 멈춤 → '대기'가 아니라 작업 중 칸에 🔐
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
rec = ms.find_session("proj/feat/a")
sid = rec.get("sessionId") or "abcdabcd-0000-1111-2222-333344445555"
if not rec.get("sessionId"):
    ms.save_sessions([dict(x, sessionId=sid) if x.get("stateDir") == rec["stateDir"] else x for x in ms.load_sessions()])
    rec = ms.find_session("proj/feat/a")
tr = ms.transcript_path(Path(rec["root"]), sid); tr.parent.mkdir(parents=True, exist_ok=True)
tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": "시작"}}) + "\n")   # 띄운 기록은 없다(2MB 밖)
base = ms._tmux_base()
def pane(text):
    subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
    subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", f"printf '{text}'; exec cat"], check=True)
    time.sleep(0.5)
pane("✻ Worked for 3s\\n────\\n❯ \\n────\\n")
sub = tr.parent / sid / "subagents"; sub.mkdir(parents=True)
(sub / "agent-anest1.jsonl").write_text("{}\n")
(sub / "agent-anest1.meta.json").write_text(json.dumps({"description": "Implement Task G3: dark mode", "spawnDepth": 2}))
(sub / "agent-aold1.jsonl").write_text("{}\n")
old = time.time() - 600; os.utime(sub / "agent-aold1.jsonl", (old, old))
mb.claude_usage = lambda: []
lt = mb.live_tasks(rec)
check([(t["id"], t["kind"], t["desc"]) for t in lt] == [("anest1", "agent", "Implement Task G3: dark mode")],
      f"최근 움직인 서브에이전트 파일 = 도는 중(설명은 meta), 멈춘 건 뺀다: {lt}")
# (리뷰 I2) 끝남 알림이 온 에이전트는 파일이 방금 바뀌었어도 끝난 것
(sub / "agent-adone1.jsonl").write_text("{}\n")
with open(tr, "a") as fh:
    fh.write(json.dumps({"type": "queue-operation", "operation": "enqueue",
                         "content": "<task-notification>\n<task-id>adone1</task-id>\n<status>completed</status>\n</task-notification>"}) + "\n")
check(all(t["id"] != "adone1" for t in mb.live_tasks(rec)), f"끝난 에이전트 제외: {mb.live_tasks(rec)}")
(sub / "agent-abad1.jsonl").write_text("{}\n"); (sub / "agent-abad1.meta.json").write_text("null")
check(any(t["id"] == "abad1" for t in mb.live_tasks(rec)), "(리뷰 I3) 깨진 meta 도 죽지 않는다")
light = next(s for s in mb.snapshot(full=False)["sessions"] if s["ref"] == "proj/feat/a")
check(light["bg"] is True, f"#상태 30초 갱신 대상: {light}")
# 권한 창 — 서브에이전트가 터미널에서 Yes/No 를 기다림
pane("────\\n Bash command · from the general-purpose agent\\n Regenerate all shots\\n Do you want to proceed?\\n ❯ 1. Yes\\n   2. No\\n Esc to cancel · Tab to amend\\n")
snap = mb.snapshot()
me = next(s for s in snap["sessions"] if s["ref"] == "proj/feat/a")
check(me.get("permission") is True, f"권한 창 감지: {me}")
def txt(cs):
    return "\n".join([c.get("content", "") for c in cs if c.get("content")] + [txt(c.get("components") or []) for c in cs])
t = txt(mb.render(snap))
check("### 🔧 작업 중 1" in t and "🔐" in t and "### 💤 대기 0" in t, f"작업 중 칸에 🔐: {t}")
pane("────\\n Edit file\\n Do you want to make this edit to a.py?\\n ❯ 1. Yes\\n   2. No\\n")
check(mb._pane_permission(rec["tmux"]), "(리뷰 I1) Edit 권한 창도")
pane("✻ Worked for 3s\\n────\\n❯ \\n────\\n")
me = next(s for s in mb.snapshot()["sessions"] if s["ref"] == "proj/feat/a")
check(not me.get("permission"), f"평소엔 아님: {me}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-bot-subagents"
