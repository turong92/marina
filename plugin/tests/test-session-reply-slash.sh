#!/usr/bin/env bash
# 규칙 문구에 기대지 않고 훅으로 기계적으로:
#  - 답장 도구가 reply_to 없이 불리면 그 턴에 받은 마지막 지시 메시지 ID 를 채운다(끝 표시, 형 요청)
#  - Discord 로 온 메시지가 정확히 '/compact' 면 세션이 쉬는 순간 tmux 입력창에 직접 친다(🗜️ → 끝나면 ✅)
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
import marina_discord_bot as mb
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
os.environ["DISCORD_STATE_DIR"] = str(sd)
tr = sd / "t.jsonl"
def tag(mid, body):
    return f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="{mid}" user="u" ts="t">\n{body}\n</channel>'
tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": tag("5001", "fix it")}}) + "\n")

# ── 답장에 reply_to 자동 ──
st = json.loads((sd / "settings.json").read_text())
check(any("hook-reply-to" in h["command"] for e in st["hooks"]["PreToolUse"] for h in e["hooks"]
          if e.get("matcher") == "mcp__plugin_discord_discord__reply"), "답장 도구 훅 등록")
out = ms.hook_reply_to({"tool_name": "mcp__plugin_discord_discord__reply", "transcript_path": str(tr),
                        "tool_input": {"chat_id": ch, "text": "done"}})
upd = (out or {}).get("hookSpecificOutput", {}).get("updatedInput") or {}
check(upd.get("reply_to") == "5001" and upd.get("text") == "done", f"빠진 reply_to 채움: {out}")
check(ms.hook_reply_to({"tool_name": "mcp__plugin_discord_discord__reply", "transcript_path": str(tr),
                        "tool_input": {"chat_id": ch, "text": "x", "reply_to": "4000"}}) is None, "이미 있으면 그대로")
check(ms.hook_reply_to({"tool_name": "mcp__plugin_discord_discord__reply", "transcript_path": str(tr),
                        "tool_input": {"chat_id": "OTHER", "text": "x"}}) is None, "다른 채널(스레드 등)은 그대로")
# 채팅방(여자친구)·로비는 건드리지 않는다(리뷰 I2) — 개발 세션 끝 표시용
items = ms.load_sessions(); real = dict(rec)
ms.save_sessions([dict(x, kind="chat") if x.get("stateDir") == str(sd) else x for x in items])
check(ms.hook_reply_to({"tool_name": "mcp__plugin_discord_discord__reply", "transcript_path": str(tr),
                        "tool_input": {"chat_id": ch, "text": "x"}}) is None, "채팅방 답장은 그대로")
check(ms.hook_prompt({"hook_event_name": "UserPromptSubmit", "prompt": tag("5099", "/compact"), "transcript_path": str(tr)}) is None,
      "채팅방엔 명령 안 연다")
ms.save_sessions(items)
check(ms.hook_reply_to({"tool_name": "mcp__plugin_discord_discord__reply", "transcript_path": "/nonexistent",
                        "tool_input": {"chat_id": ch, "text": "x"}}) is None, "받은 지시가 없으면 그대로")

# ── Discord 로 온 /compact ──
check(ms.slash_command(tag("5002", "/compact")) == ("5002", "/compact"), "정확히 /compact")
check(ms.slash_command(tag("5003", "  /compact  ")) == ("5003", "/compact"), "앞뒤 공백 허용")
check(ms.slash_command(tag("5004", "/compact 해줘")) is None, "다른 글이 붙으면 일반 메시지")
check(ms.slash_command(tag("5005", "/clear")) is None, "허용 목록 밖 명령은 일반 메시지")
check(ms.slash_command("/compact") is None, "터미널에서 친 건 하네스가 직접 처리")
check(ms.slash_command(tag("5007", "/model opus")) == ("5007", "/model opus"), "/model <이름>")
check(ms.slash_command(tag("5008", "/effort high")) == ("5008", "/effort high"), "/effort <단계>")
check(ms.slash_command(tag("5009", "/model a; rm -rf ~")) is None, "인자는 한 단어(영숫자·.-_)만")
check(ms.slash_command(tag("5010", "/model")) is None, "/model 은 인자 필수(없으면 선택 창이 떠 막힌다)")
check(ms.slash_command(tag("5011", "/brainstorming 새 기능")) is None, "스킬은 Claude 가 Skill 도구로(입력창에 안 친다)")
spawned = []
ms._spawn_slash = lambda *a: spawned.append(a)
out = ms.hook_prompt({"hook_event_name": "UserPromptSubmit", "prompt": tag("5002", "/compact"), "transcript_path": str(tr)})
ctx = (out or {}).get("hookSpecificOutput", {}).get("additionalContext") or ""
check("마리나" in ctx and "/compact" in ctx, f"Claude 에겐 짧게 답만 하라고 알린다: {out}")
check(spawned and spawned[0][1:] == ("/compact", "5002"), f"쉬는 순간 칠 대기자 띄움: {spawned}")
check(ms.hook_prompt({"hook_event_name": "UserPromptSubmit", "prompt": tag("5006", "hello"), "transcript_path": str(tr)}) is None,
      "일반 메시지는 그대로")
check(any("hook-prompt" in h["command"] for e in st["hooks"]["UserPromptSubmit"] for h in e["hooks"]), "받은 순간 명령 훅 등록")

# 대기자: 쉬는 순간 tmux 입력창에 친다 → 압축이 끝나면 🗜️ → ✅
base = ms._tmux_base()
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", "printf '✻ Worked for 3s\\n────\\n❯ \\n────\\n'; exec cat -v"], check=True)
time.sleep(0.5)
states = iter([True, False, True, True, False])   # 일하는 중 → 쉼(여기서 친다) → 압축 중 → 끝
seen_at_type = []
real_busy = mb._pane_busy
def fake_busy(name):
    v = next(states, False); seen_at_type.append(v); return (True, v)
mb._pane_busy = fake_busy
n = len(log())
mb.run_slash(rec["tmux"], "/compact", ch, "5002", poll=0.05, settle=0)
time.sleep(0.3)
pane = subprocess.run(base + ["capture-pane", "-p", "-t", rec["tmux"]], capture_output=True, text=True).stdout
check("/compact" in pane, f"입력창에 쳤다: {pane!r}")
check(len(seen_at_type) >= 5, f"친 뒤 압축이 돌다 끝나는 것까지 기다렸다: {seen_at_type}")
check(any(x["m"] == "PUT" and "/messages/5002/reactions/%F0%9F%97%9C" in x["p"] for x in log()[n:]), "대기자가 🗜️ 를 단다(리뷰 I5)")
check(any(x["m"] == "PUT" and "/messages/5002/reactions/%E2%9C%85" in x["p"] for x in log()[n:])
      and any(x["m"] == "DELETE" and "/messages/5002/reactions/%F0%9F%97%9C" in x["p"] for x in log()[n:]), "끝나면 🗜️ → ✅")
# 입력창이 정말 비었을 때만 친다 — 권한 확인창(❯ 1. Yes)에 Enter 가 가면 승인돼 버린다, 쓰던 초안 뒤에 붙지 않게(리뷰 I1)
check(mb._input_empty_text("❯ \x1b[2m/compact\x1b[22m") is True, "흐린 추천 글씨는 빈 입력창")
check(mb._input_empty_text("❯ ") is True, "빈 입력창")
check(mb._input_empty_text("❯ 1. Yes") is False, "선택·권한 창")
check(mb._input_empty_text("❯ 쓰던 초안") is False, "쓰던 초안")
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                       "printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n'; exec cat -v"], check=True)
time.sleep(0.5)
mb._pane_busy = lambda name: (True, False)
n = len(log())
mb.run_slash(rec["tmux"], "/compact", ch, "5003", poll=0.05, settle=0, timeout=0.5)
time.sleep(0.3)
pane = subprocess.run(base + ["capture-pane", "-p", "-t", rec["tmux"]], capture_output=True, text=True).stdout
check("/compact" not in pane and "^M" not in pane, f"권한 창엔 아무 키도 안 보낸다: {pane!r}")
check(any(x["m"] == "PUT" and "/messages/5003/reactions/%E2%9A%A0" in x["p"] for x in log()[n:])
      and any(x["m"] == "DELETE" and "/messages/5003/reactions/%F0%9F%97%9C" in x["p"] for x in log()[n:]),
      "못 치고 끝나면 🗜️ 떼고 ⚠️(리뷰 I4)")
# 동시에 두 대기자 — 잠금으로 하나씩(리뷰 I6)
import threading
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", "printf '✻ Worked\n────\n❯ \n────\n'; exec cat -v"], check=True)
time.sleep(0.5)
active = [0]; overlap = [False]
orig_tmux = ms._tmux
def spy(*a):
    if a[:1] == ("send-keys",):
        active[0] += 1; overlap[0] |= active[0] > 1; time.sleep(0.05); active[0] -= 1
    return orig_tmux(*a)
ms._tmux = spy
ts = [threading.Thread(target=mb.run_slash, args=(rec["tmux"], c, ch, m), kwargs=dict(poll=0.02, settle=0, timeout=2))
      for c, m in (("/compact", "6001"), ("/effort high", "6002"))]
[t.start() for t in ts]; [t.join(10) for t in ts]
ms._tmux = orig_tmux
check(not overlap[0], "두 대기자가 동시에 치지 않는다")
# (실사용 원인) tmux 창이 보기 모드(run-shell 출력·스크롤)면 친 키가 Claude 가 아니라 보기 모드로 간다 — 먼저 빠져나온다
mb._pane_busy = real_busy
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", "printf '✻ Worked\\n────\\n❯ \\n────\\n'; exec cat -v"], check=True)
time.sleep(0.5)
subprocess.run(base + ["copy-mode", "-t", rec["tmux"]], check=True)
check(subprocess.run(base + ["display", "-p", "-t", rec["tmux"], "#{pane_in_mode}"], capture_output=True, text=True).stdout.strip() == "1", "준비: 보기 모드")
os.environ["MARINA_ENTER_DELAY"] = "0.1"
ok = mb.run_slash(rec["tmux"], "/compact", ch, "", poll=0.05, settle=0, timeout=3)
time.sleep(0.3)
pane = subprocess.run(base + ["capture-pane", "-p", "-t", rec["tmux"]], capture_output=True, text=True).stdout
check(ok and "/compact" in pane, f"보기 모드에서 빠져나와 입력: {ok} {pane!r}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-reply-slash"
