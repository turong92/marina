#!/usr/bin/env bash
# 봇 2: ⏳ 백그라운드 셸·🤖 서브에이전트 — 턴은 끝났는데 뒤에서 도는 일이 '대기'로 보여 헷갈렸다(실사용)
#  - 도는 일 = 세션 기록에서 시작됨(백그라운드 ID·agentId) − 끝남 알림(<task-notification> status)
#  - #상태: '⏳ 백그라운드' 섹션 + 줄 끝 ⏳N 🤖N, [보기] 버튼 → 형에게만 보이는 내용(셸 출력 끝·에이전트 마지막 말)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"
export MARINA_CLAUDE_TMP="$TMPROOT/claudetmp"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
sid = rec.get("sessionId") or "abcdabcd-0000-1111-2222-333344445555"
if not rec.get("sessionId"):
    ms.save_sessions([dict(x, sessionId=sid) if x.get("stateDir") == str(sd) else x for x in ms.load_sessions()])
    rec = ms.find_session("proj/feat/a")
tr = ms.transcript_path(Path(rec["root"]), sid); tr.parent.mkdir(parents=True, exist_ok=True)
def w(*rows):
    with open(tr, "a") as fh:
        for r in rows: fh.write(json.dumps(r, ensure_ascii=False) + "\n")
def use(tid, name, inp):
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]}}
def res(tid, text):
    return {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": text}]}}
def note(task, status):
    return {"type": "queue-operation", "operation": "enqueue",
            "content": f"<task-notification>\n<task-id>{task}</task-id>\n<status>{status}</status>\n</task-notification>"}
w(use("t1", "Bash", {"command": "sleep 999", "description": "prod 정리", "run_in_background": True}),
  res("t1", "Command running in background with ID: bshell1. Output is being written to: x"),
  use("t2", "Agent", {"description": "코드 리뷰", "prompt": "…", "run_in_background": True}),
  res("t2", [{"type": "text", "text": "Async agent launched successfully.\nagentId: aagent1 (internal ID)"}]),
  use("t3", "Bash", {"command": "make", "description": "빌드", "run_in_background": True}),
  res("t3", "Command running in background with ID: bshell2. Output is being written to: y"),
  note("bshell2", "completed"),
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "agentId: afake9 이건 대화 글일 뿐"}]}},
  # (리뷰 I1) 동기 에이전트 결과에도 agentId 가 붙는다 · 파일 내용 속 같은 글자 — 둘 다 백그라운드 아님
  use("t4", "Agent", {"description": "동기 조사", "prompt": "…"}),
  res("t4", [{"type": "text", "text": "결과…\nagentId: async0 (for resuming)"}]),
  use("t5", "Read", {"file_path": "/x"}),
  res("t5", "Command running in background with ID: bfake1"),
  # (실사용) 일반 명령이 10분을 넘겨 하네스가 백그라운드로 옮긴 것
  use("t6", "Bash", {"command": "sleep 9999", "description": "DMS 기다리기"}),
  res("t6", "Command did not complete within its 600s timeout and was moved to the background (ID: bmoved1). Output is being written to: z"))

tasks = mb.background_tasks(tr)
got = {(t["id"], t["kind"], t["desc"]) for t in tasks}
check(got == {("bshell1", "shell", "prod 정리"), ("aagent1", "agent", "코드 리뷰"), ("bmoved1", "shell", "DMS 기다리기")},
      f"도는 일 = 시작 − 끝남(자동으로 옮겨진 것 포함): {tasks}")
w(note("bmoved1", "completed"))

# 셸 출력·에이전트 기록
tdir = Path(os.environ["MARINA_CLAUDE_TMP"]) / "claude-501" / tr.parent.name / sid / "tasks"; tdir.mkdir(parents=True)
(tdir / "bshell1.output").write_text("".join(f"line {i}\n" for i in range(40)) + "\x1b[31mCloud SQL 삭제 대기\x1b[0m\n")
sub = tr.parent / sid / "subagents"; sub.mkdir(parents=True)
(sub / "agent-aagent1.jsonl").write_text(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "diff 3개 파일 읽는 중"}]}}) + "\n")

base = ms._tmux_base()
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", "printf '✻ Cooked for 3s · 1 shell still running\\n────\\n❯ \\n────\\n'; exec cat"], check=True)
time.sleep(0.5)
os.utime(sub / "agent-aagent1.jsonl")      # 세션이 뜬 뒤 움직인 에이전트(실제 순서) — tmux 생성 시각은 초 단위
mb.claude_usage = lambda: []
snap = mb.snapshot()
me = next(s for s in snap["sessions"] if s["ref"] == "proj/feat/a")
check(me["busy"] is False and len(me["tasks"]) == 2, f"쉬는 중 + 도는 일 2: {me}")
comps = mb.render(snap)
def txt(cs):
    return "\n".join([c.get("content", "") for c in cs if c.get("content")] + [txt(c.get("components") or []) for c in cs])
t = txt(comps)
check("### ⏳ 백그라운드 1" in t and "⏳1 🤖1" in t and "### 💤 대기 0" in t, f"백그라운드 섹션: {t}")
check("-# ⏳ prod 정리 · 🤖 코드 리뷰" in t, f"(실사용) 무슨 일인지 설명도 보인다: {t}")
views = [c for c in comps if c.get("type") == 9 and c["accessory"]["custom_id"] == f"marina-view:{ch}"]
check(views, f"[보기] 버튼: {comps}")
# 작업 중이면서 도는 일도 있으면: [정지] 는 그대로, [보기] 는 아래 버튼 줄
busy_snap = {"usage": [], "sessions": [dict(me, busy=True, emoji="🔧")]}
bc = mb.render(busy_snap)
check(any(c.get("type") == 9 and c["accessory"]["custom_id"].startswith("marina-stop:") for c in bc)
      and any(c.get("type") == 1 and c["components"][0]["custom_id"] == f"marina-view:{ch}" for c in bc), f"정지+보기: {bc}")

out = mb.view(ch, "U1")
check("prod 정리" in out and "Cloud SQL 삭제 대기" in out and "\x1b" not in out and "line 0\n" not in out, f"셸: 설명 + 출력 끝(색 코드 제거): {out}")
check("코드 리뷰" in out and "diff 3개 파일 읽는 중" in out, f"에이전트: 설명 + 마지막 말: {out}")
check(len(out) <= 1900 and out.count("```") % 2 == 0, "Discord 한도 + 코드 펜스 짝")
(tdir / "bshell1.output").write_text("export TOKEN=abcd1234secret\nAuthorization: Bearer xyz.secret\n\x1b]8;;http://x\x1b\\link\x1b[2Kdone\n")
o2 = mb.view(ch, "U1")
check("abcd1234secret" not in o2 and "xyz.secret" not in o2 and "\x1b" not in o2, f"(리뷰 I7) 흔한 비밀 가리기 + 제어문자 제거: {o2}")
# (리뷰 I2) 메시지당 구성요소 40개 한도 — 많아도 넘지 않는다
many = [{"ref": f"p/s{i}", "channelId": str(100 + i), "alive": True, "busy": i % 2 == 0, "emoji": "🔧", "ctx": 10.0,
         "tasks": [{"id": f"b{i}", "kind": "shell", "desc": "x"}]} for i in range(30)]
def count(cs): return sum(1 + count(c.get("components") or []) + (1 if c.get("accessory") else 0) for c in cs)
rc = mb.render({"usage": [], "sessions": many})
check(count(rc) + 1 <= 40, f"40개 이하(꼬리말 포함): {count(rc) + 1}")
check("외" in txt(rc), "잘린 건 '외 N개'로 알린다")
check("권한" in mb.view(ch, "U2"), "허용 목록 밖은 못 본다")
# 기록만 믿으면 틀린다(실측): 세션 재시작으로 죽은 셸은 알림이 안 와 있고, TaskStop 으로 끈 것도 알림이 없다
#  → 셸은 화면 하단의 'N shell' 수만큼만, 에이전트는 기록이 5분 안에 움직였을 때만
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", "printf '✻ Cooked for 3s\n────\n❯ \n────\n  ⏵⏵ bypass permissions on\n'; exec cat"], check=True)
time.sleep(0.5)
old = time.time() - 600; os.utime(sub / "agent-aagent1.jsonl", (old, old))   # 세션(tmux)이 뜨기 전 기록 = 지난 프로세스의 것(재시작으로 죽음)
check(mb.live_tasks(rec) == [], f"화면에 셸 없음 + 에이전트 기록 멈춤 → 도는 일 없음: {mb.live_tasks(rec)}")
w(use("t9", "TaskStop", {"task_id": "bshell1"}))
check(all(t["id"] != "bshell1" for t in mb.background_tasks(tr)), "TaskStop 으로 끈 셸은 끝난 것")
w(note("bshell1", "completed"), note("aagent1", "completed"))
check(mb.background_tasks(tr) == [], "끝나면 사라진다")
check("없어" in mb.view(ch, "U1"), "도는 일이 없으면 그렇게 말한다")
# (실사용) SendMessage 로 맡긴 팀 에이전트 — 화면 아래 에이전트 목록에만 보인다 → 🤖 로, 그리고 바쁜 걸로 쳐서 #상태를 30초마다
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                       "printf '✻ Worked\\n────\\n❯ \\n────\\n  ⏵⏵ bypass · ← for agents\\n  ⏺ main\\n  ◯ wall-mockups-2  Read and follow your brief\\n'; exec cat"], check=True)
time.sleep(0.5)
lt = mb.live_tasks(rec)
check(any(t["kind"] == "agent" and t["id"] == "wall-mockups-2" and "brief" in t["desc"] for t in lt), f"팀 에이전트도 🤖: {lt}")
light = next(s for s in mb.snapshot(full=False)["sessions"] if s["ref"] == "proj/feat/a")
check(light.get("bg") is True and mb.snapshot(full=False)["anyBusy"] is True, f"뒤에서 도는 일이 있으면 #상태 30초 갱신: {light}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-bot-tasks"
