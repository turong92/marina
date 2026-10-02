#!/usr/bin/env bash
# 봇 5: 다음 입력 추천 — Claude Code 가 입력창에 흐리게(ESC[2m) 띄우는 추천을 턴 끝 답장에 [▶ …] 버튼으로
#  - 누르면 세션이 쉬고 입력창이 빌 때 그대로 친다(/compact 등 허용 명령은 그대로, 글은 '[Discord 추천 버튼]' 을 붙여)
#  - 다음 지시가 오면 버튼을 바로 뗀다(늦게 바뀌는 표시 금지)
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

check(mb.ghost_text("\x1b[39m❯\xa0\x1b[2m1 내가 올릴게\x1b[0m") == "1 내가 올릴게", "흐린 추천 글씨 읽기(실측 모양)")
check(mb.ghost_text("\x1b[39m❯\xa0") == "", "추천 없음")
check(mb.ghost_text("❯ 쓰던 초안") == "", "흐리지 않은 글(초안)은 추천이 아니다")

base = ms._tmux_base()
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                       "printf '✻ Worked for 3s\\n────\\n\\033[39m❯\\302\\240\\033[2m1 내가 올릴게\\033[0m\\n────\\n'; exec cat -v"], check=True)
time.sleep(0.5)
n = len(log())
mb.run_suggest(rec["tmux"], ch, "R1", settle=0)
pat = [x for x in log()[n:] if x["m"] == "PATCH" and x["p"] == f"/channels/{ch}/messages/R1"]
btn = pat and pat[0]["b"]["components"][0]["components"][0]
check(btn and btn["label"] == "▶ 1 내가 올릴게" and btn["custom_id"] == f"marina-say:{ch}", f"답장에 추천 버튼: {pat}")
check(json.loads((sd / "suggest.json").read_text()) == {"text": "1 내가 올릴게", "msg": "R1"}, "추천 기억")

# 다음 지시가 오면 바로 뗀다
tag = f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="7100" user="u">\nnext\n</channel>'
n = len(log())
ms.hook_activity({"hook_event_name": "UserPromptSubmit", "prompt": tag, "transcript_path": "/nonexistent"}, min_gap=0)
check(any(x["m"] == "PATCH" and x["p"] == f"/channels/{ch}/messages/R1" and x["b"].get("components") == [] for x in log()[n:]),
      "다음 지시 오면 버튼 뗌")
check(not (sd / "suggest.json").exists(), "추천 기억도 지움")

# 누르면: 글은 '[Discord 추천 버튼]' 을 붙여 입력창에
ms._write_json(sd / "suggest.json", {"text": "1 내가 올릴게", "msg": "R1"})
typed = []
mb._spawn_type = lambda tmux, text, channel, mid, button="": typed.append((tmux, text, channel, mid))
check("권한" in mb.say(ch, "U2", "R1"), "허용 목록 밖은 못 누른다")
n = len(log())
check("지난" in mb.say(ch, "U1", "OLD") and not typed, "(리뷰 I3) 옛 메시지의 버튼은 지금 추천을 치지 않는다")
check(any(x["m"] == "PATCH" and x["p"].endswith("/messages/OLD") for x in log()[n:]), "옛 버튼은 떼 준다")
n = len(log())
out = mb.say(ch, "U1", "R1")
sent = [x for x in log()[n:] if x["m"] == "PATCH" and x["p"].endswith("/messages/R1")]
btn = sent and sent[-1]["b"]["components"][0]["components"][0]
check(btn and btn.get("disabled") is True and "1 내가 올릴게" in btn["label"] and "보냄" in btn["label"],
      f"(실사용) 누른 게 채널에 남는다 — 버튼을 '✓ 보냄' 으로: {sent}")
check(typed == [(rec["tmux"], "[Discord 추천 버튼] 1 내가 올릴게", ch, "")], f"입력창에 칠 글(봇 답장엔 반응 안 닮): {typed} {out}")
ms._write_json(sd / "suggest.json", {"text": "/compact", "msg": "R2"})
typed.clear(); mb.say(ch, "U1", "R2")
check(typed and typed[0][1] == "/compact", f"허용 명령은 그대로: {typed}")
typed.clear()
check("없어" in mb.say(ch, "U1", "R2") and not typed, "한 번 누르면 끝(두 번 안 친다)")
# (리뷰 I5) 동시에 두 번 눌러도 한 번만
import threading
ms._write_json(sd / "suggest.json", {"text": "go", "msg": "R3"}); typed.clear()
ts = [threading.Thread(target=mb.say, args=(ch, "U1", "R3")) for _ in range(4)]
[t.start() for t in ts]; [t.join() for t in ts]
check(len(typed) == 1, f"동시 누름도 한 번: {typed}")
# (리뷰 I4) 추천 대기자가 늦게 끝나 새 지시가 이미 지웠으면 단 버튼을 되돌린다
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                       "printf '✻ Worked\\n────\\n\\033[39m❯\\302\\240\\033[2m다음\\033[0m\\n────\\n'; exec cat -v"], check=True)
time.sleep(0.5)
(sd / "suggest-cleared-at").write_text(str(time.time() + 5))
n = len(log())
mb.run_suggest(rec["tmux"], ch, "R4", settle=0, started=time.time())
check(not (sd / "suggest.json").exists(), "늦은 대기자는 추천을 남기지 않는다")

# 추천 버튼은 접었다(형 결정 2026-10-02: 봇이 형 이름으로 못 써서 터미널에 대신 치는 게 어색·불안정) — 턴 끝에 버튼을 달지 않는다
spawned = []
ms._spawn_suggest = lambda *a: spawned.append(a)
tr = sd / "t.jsonl"
tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": "<channel source=\"plugin:discord:discord\" chat_id=\"1\" message_id=\"2\">x</channel>"}}) + "\n")
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
check(not spawned, "턴 끝에 추천 버튼 안 단다")
check("[Discord 추천 버튼]" in " ".join(ms.CHANNEL_RULES.splitlines()), "규칙: 추천 버튼 입력은 Discord 로 답")
# (실사용) 누른 추천을 2분 안에 못 쳤으면(세션이 계속 바쁨) 조용히 사라지지 않고 버튼이 '⚠️ 다시' 로 살아난다
os.environ["MARINA_TYPE_TIMEOUT"] = "0.3"
mb._pane_busy = lambda name: (True, True)
n = len(log())
mb.main(["type", rec["tmux"], "[Discord 추천 버튼] 둘다해", ch, "", "R9"])
pat = [x for x in log()[n:] if x["m"] == "PATCH" and x["p"].endswith("/messages/R9")]
b = pat and pat[-1]["b"]["components"][0]["components"][0]
check(b and not b.get("disabled") and "⚠️" in b["label"] and "둘다해" in b["label"] and b["custom_id"] == f"marina-say:{ch}",
      f"못 쳤으면 다시 누를 수 있는 버튼: {pat}")
check(json.loads((sd / "suggest.json").read_text()) == {"text": "둘다해", "msg": "R9"}, "다시 누르면 같은 추천")
# (리뷰 C1) 입력은 됐는데 그 턴이 길어 끝을 못 본 경우 — 되살리지 않는다(두 번 입력 방지)
(sd / "suggest.json").unlink()
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", "printf '✻ Worked\\n────\\n❯ \\n────\\n'; exec cat -v"], check=True)
time.sleep(0.5)
os.environ["MARINA_TYPE_TIMEOUT"] = "5"      # 기다림(3초) 뒤 치고, 그 턴이 끝나기 전에 시간이 다 됨
seq = iter([False] + [True] * 100000)
mb._pane_busy = lambda name: (True, next(seq))
n = len(log())
mb.main(["type", rec["tmux"], "[Discord 추천 버튼] 커밋해", ch, "", "R10"])
check(not any(x["m"] == "PATCH" and x["p"].endswith("/messages/R10") for x in log()[n:]) and not (sd / "suggest.json").exists(),
      "입력된 추천은 되살리지 않는다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-suggest"
