#!/usr/bin/env bash
# 봇 3: 질문 버튼 — Claude 가 AskUserQuestion 을 쓰면 채널에 질문 메시지(단일=버튼, 다중=드롭다운, [✏️ 기타]=입력 팝업)
#  - 다 답하면 tmux 로 셀렉터를 구동한다: 모바일에서 실측한 키 계약(↓·Enter 토글·→ Submit·Tab·마지막 Enter)
#  - 앱·터미널에서 먼저 답하면(PostToolUse) 메시지를 '답함'으로 정리
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_ask as ask
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
os.environ["DISCORD_STATE_DIR"] = str(sd)

# ── 키 계약(모바일 실측) ──
Q1 = {"question": "방향?", "header": "방향", "multiSelect": False, "options": [{"label": "A"}, {"label": "B"}, {"label": "C"}]}
Q2 = {"question": "범위?", "header": "범위", "multiSelect": True, "options": [{"label": "x"}, {"label": "y"}, {"label": "z"}]}
check(ask.keys_for([Q1], [[2]]) == ["Down", "Down", "Enter"], f"단일: ↓N Enter: {ask.keys_for([Q1], [[2]])}")
check(ask.keys_for([Q2], [[0, 2]]) == ["Enter", "Down", "Down", "Enter", "Right", "Enter"], f"다중: Enter 토글 → Submit: {ask.keys_for([Q2], [[0, 2]])}")
check(ask.keys_for([Q1], [{"text": "직접"}]) == ["Down", "Down", "Down", ("-l", "--", "직접"), "Enter"], "기타(단일): 옵션 다음 줄에 타이핑")
check(ask.keys_for([Q2], [{"text": "직접\n여러 줄"}]) == ["Down", "Down", "Down", ("-l", "--", "직접 여러 줄"), "Tab", "Enter", "Enter"],
      "기타(다중): Tab→Submit→확인 · 줄바꿈은 공백(중간 제출 막기) · '-' 로 시작해도 글로(리뷰 I5)")
check(ask.keys_for([Q1, Q2], [[1], [0]]) == ["Down", "Enter", "WAIT", "Enter", "Right", "Enter", "WAIT", "Enter"],
      f"여러 질문: 사이마다 다시 그림 기다림 + 마지막 Submit Enter: {ask.keys_for([Q1, Q2], [[1], [0]])}")

# ── 질문 메시지 ──
st = json.loads((sd / "settings.json").read_text())
check(any("hook-question" in h["command"] for e in st["hooks"]["PreToolUse"] for h in e["hooks"] if e.get("matcher") == "AskUserQuestion"),
      "질문 훅(PreToolUse)")
check(any("hook-question-done" in h["command"] for e in st["hooks"].get("PostToolUse", []) for h in e["hooks"]), "답함 훅(PostToolUse)")
check("AskUserQuestion" not in ms.claude_argv("proj", "feat/a"), "개발 세션은 AskUserQuestion 다시 켬")
ask.post_question(str(sd), ch, {"questions": [Q1, Q2]}, started=time.time())
post = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages"][-1]["b"]
def walk(cs, out):
    for c in cs or []:
        out.append(c); walk(c.get("components"), out)
    return out
flat = walk(post.get("components"), [])
ids = [c.get("custom_id") for c in flat if c.get("custom_id")]
check(post.get("flags") == 1 << 15, "Components V2")
check(f"mq:{ch}:0:0" in ids and f"mq:{ch}:0:2" in ids and f"mqo:{ch}:0" in ids, f"단일 = 버튼 + 기타: {ids}")
sel = [c for c in flat if c.get("type") == 3]
check(sel and sel[0]["custom_id"] == f"mqm:{ch}:1" and sel[0]["max_values"] == 3, f"다중 = 드롭다운: {sel}")
state = json.loads((sd / "question.json").read_text())
check(state["msg"] == "m-sent" and state["answers"] == [None, None], f"질문 상태: {state}")

# ── 답하기 ──
driven = []
ask._spawn_drive = lambda tmux, channel: driven.append((tmux, channel))
check("권한" in ask.answer(ch, "U2", 0, picks=[1], message="m-sent"), "허용 목록 밖은 답 못 함")
check("지난" in ask.answer(ch, "U1", 0, picks=[1], message="OLD"), "(리뷰 C1) 지난 질문 메시지의 버튼은 지금 질문에 답하지 않는다")
out = ask.answer(ch, "U1", 0, picks=[1], message="m-sent")
check(json.loads((sd / "question.json").read_text())["answers"] == [[1], None] and not driven, f"하나 답함, 아직 안 침: {out}")
check(any(x["m"] == "PATCH" and x["p"] == f"/channels/{ch}/messages/m-sent" for x in log()), "메시지에 고른 답 표시")
check("없" in ask.answer(ch, "U1", 5, picks=[0], message="m-sent"), "없는 질문 번호 거절")
check("고를" in ask.answer(ch, "U1", 0, picks=[9], message="m-sent"), "없는 선택지 거절")
ask.answer(ch, "U1", 1, text="직접 쓴 범위", message="m-sent")
check(driven == [(rec["tmux"], ch)], f"다 답하면 셀렉터 구동: {driven}")
check("이미" in ask.answer(ch, "U1", 1, picks=[0], message="m-sent") and len(driven) == 1, "(리뷰 I1) 다 답한 뒤 또 눌러도 한 번만 구동")

# ── 구동: 셀렉터가 떠 있을 때만 키를 보낸다 ──
base = ms._tmux_base()
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                       "printf '방향?\\n❯ 1. A\\n  2. B\\nEnter to select\\n'; read x; printf '범위?\\n❯ 1. [ ] x\\nEnter to select\\n'; exec cat -v"], check=True)
time.sleep(0.5)
sent = []
orig = ms._tmux
ms._tmux = lambda *a: (sent.append(a) if a[:1] == ("send-keys",) else None) or orig(*a)
ask.drive(rec["tmux"], ch, pause=0.01)
ms._tmux = orig
keys = [a[3:] for a in sent]
check(keys[:2] == [("Down",), ("Enter",)] and ("-l", "--", "직접 쓴 범위") in keys and keys[-1] == ("Enter",), f"키 전송(질문마다 화면 확인): {keys}")
# 셀렉터가 없으면(이미 앱에서 답함 등) 아무 키도 안 보낸다
(sd / "question.json").write_text(json.dumps(dict(json.loads((sd / "question.json").read_text()) if (sd / "question.json").exists() else state,
                                                   answers=[[0], [0]])))
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                       "printf 'Do you want to proceed?\\n❯ 1. Yes\\n  2. No\\n'; exec cat -v"], check=True)
time.sleep(0.5)
sent.clear(); ms._tmux = lambda *a: (sent.append(a) if a[:1] == ("send-keys",) else None) or orig(*a)
ask.drive(rec["tmux"], ch, pause=0.01)
ms._tmux = orig
check(not sent, f"(리뷰 C2) 이 질문 문구가 안 보이면(권한 창 등) 키 안 보냄: {sent}")
check(not (sd / "question.json").exists(), "(리뷰 I6) 포기하면 상태 지움")
check(any(x["m"] == "PATCH" and "터미널" in json.dumps(x["b"], ensure_ascii=False) for x in log()), "포기했다고 메시지에 알림")

# ── 앱·터미널에서 먼저 답함(PostToolUse) → 메시지 정리 ──
ask.post_question(str(sd), ch, {"questions": [Q1]}, started=time.time())
n = len(log())
ms._spawn_question_done = lambda sdir, channel: ask.done(Path(sdir), channel)
ms.hook_question_done({"tool_name": "AskUserQuestion", "tool_input": {"questions": [Q1]}})
pat = [x for x in log()[n:] if x["m"] == "PATCH" and x["p"] == f"/channels/{ch}/messages/m-sent"]
check(pat and not any(c.get("custom_id") for c in walk(pat[-1]["b"].get("components"), [])), f"버튼 없앤 '답함' 메시지: {pat}")
check(not (sd / "question.json").exists(), "질문 상태 지움")
# (리뷰 I2) 앱에서 먼저 답해 done 이 post 보다 먼저 끝났으면, 늦게 올라온 질문 메시지는 바로 '답함'
t0 = time.time(); ask.done(sd, ch); n = len(log())
ask.post_question(str(sd), ch, {"questions": [Q1]}, started=t0 - 1)
check(not (sd / "question.json").exists() and any(x["m"] == "PATCH" for x in log()[n:]), "늦은 질문 메시지는 남기지 않는다")
# (리뷰 C2) 다음 지시가 오면 지난 질문은 정리(취소돼 PostToolUse 가 안 온 경우)
ask.post_question(str(sd), ch, {"questions": [Q1]}, started=time.time())
tag = f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="8800" user="u">\nnext\n</channel>'
ms.hook_activity({"hook_event_name": "UserPromptSubmit", "prompt": tag, "transcript_path": "/nonexistent"}, min_gap=0)
check(not (sd / "question.json").exists(), "새 지시 오면 지난 질문 정리")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-ask"
