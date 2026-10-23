#!/usr/bin/env bash
# (실사용 2026-10-23) ovation 이 AskUserQuestion 을 띄웠는데 맥 과부하로 질문 훅(10초)이 시간초과에 죽어
#  Discord 에 버튼이 안 갔고, 3시간 동안 아무도 모른 채 터미널 선택창에서 멈췄다
#  → 봇이 주기적으로 화면을 보고: 선택창이 떠 있는데 질문 카드가 없으면
#    ① 기록에 답 안 된 AskUserQuestion 이 있고 화면이 그 질문이면 → 버튼 카드를 대신 올린다(훅이 올릴 틈을 준 뒤)
#    ② 모르는 선택창이 오래 떠 있으면 → 화면 끝을 붙여 "멈춤" 알림 한 번
#  권한 창(Do you want to …)은 pane_perm 이 맡으니 건드리지 않는다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" "$MARINA_HOME" <<'PY'
import json, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
import marina_discord_ask as ask
fd, tmp = Path(sys.argv[1]), Path(sys.argv[2])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()] if (fd / "log.jsonl").exists() else []
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
base = ms._tmux_base()
def pane(text):
    subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
    subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", f"printf '{text}'; exec cat"], check=True)
    time.sleep(0.5)
def posts():
    return [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages"]

Q = {"questions": [{"question": "단계 표시줄의 짧은 이름, 어떻게 할까?", "header": "단계 이름", "multiSelect": False,
                    "options": [{"label": "점만", "description": "a"}, {"label": "명사로", "description": "b"}]}]}
tr = tmp / "t.jsonl"
def transcript(answered):
    rows = [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_Q1", "name": "AskUserQuestion", "input": Q}]}}]
    if answered:
        rows.append({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_Q1", "content": "answered"}]}})
    tr.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
mb._session_transcript = lambda rec: tr
ASK = ("────\\n ☐ 단계 이름\\n\\n 단계 표시줄의 짧은 이름, 어떻게 할까?\\n\\n ❯ 1. 점만\\n   2. 명사로\\n   3. Type something.\\n"
       "\\n Enter to select · ↑/↓ to navigate · Esc to cancel\\n")
IDLE = "✻ Worked\\n────\\n❯ \\n────\\n"

# ① 훅이 못 올린 질문 → 틈(grace) 뒤 카드를 대신 올린다
transcript(False); pane(ASK)
t0 = 1000.0
mb.pane_ask_tick(now=t0)
check(posts() == [], "처음 본 순간엔 훅에게 틈을 준다")
mb.pane_ask_tick(now=t0 + mb.PANE_ASK_GRACE + 1)
ps = posts(); body = json.dumps(ps[-1]["b"], ensure_ascii=False) if ps else ""
check(len(ps) == 1 and "mq:" in body and "단계 표시줄" in body, f"버튼 카드: {body[:300]}")
check(ask._load(sd) is not None, "답 상태(question.json)를 남겨 버튼이 실제로 먹게")
mb.pane_ask_tick(now=t0 + 500)
check(len(posts()) == 1, "같은 선택창이면 한 번만")

# 훅이 이미 카드를 올렸으면 겹치지 않는다
(sd / "question.json").unlink(); pane(IDLE); mb.pane_ask_tick(now=t0 + 600)
ms._write_json(sd / "question.json", {"questions": Q["questions"], "answers": [None], "msg": "1"})
pane(ASK); n = len(posts())
mb.pane_ask_tick(now=t0 + 700); mb.pane_ask_tick(now=t0 + 2000)
check(len(posts()) == n, "훅 카드가 있으면 안 올린다")
(sd / "question.json").unlink()

# ② 기록에 질문이 없고(이미 답함) 모르는 선택창 → 오래 떠 있으면 알림 한 번(버튼 없이)
pane(IDLE); mb.pane_ask_tick(now=t0 + 3000)
transcript(True)
pane("────\\n 모델을 바꿀까?\\n ❯ 1. 바꾸기\\n   2. 그대로\\n Enter to confirm · Esc to cancel\\n")
n = len(posts())
mb.pane_ask_tick(now=t0 + 3001); mb.pane_ask_tick(now=t0 + 3001 + mb.PANE_ASK_GRACE + 1)
check(len(posts()) == n, "모르는 창은 바로 알리지 않는다(사람이 보고 있을 수 있다)")
mb.pane_ask_tick(now=t0 + 3001 + mb.PANE_MENU_ALERT + 1)
ps = posts(); body = json.dumps(ps[-1]["b"], ensure_ascii=False) if ps else ""
check(len(ps) == n + 1 and "모델을 바꿀까" in body and "components" not in body, f"선택창 멈춤 알림: {body[:300]}")
mb.pane_ask_tick(now=t0 + 9000)
check(len(posts()) == n + 1, "알림은 한 번만")
# 풀렸다가 다시 뜨면 다시 센다
pane(IDLE); mb.pane_ask_tick(now=t0 + 9100)
pane("────\\n 모델을 바꿀까?\\n ❯ 1. 바꾸기\\n   2. 그대로\\n Enter to confirm · Esc to cancel\\n")
mb.pane_ask_tick(now=t0 + 9200); mb.pane_ask_tick(now=t0 + 9200 + mb.PANE_MENU_ALERT + 1)
check(len(posts()) == n + 2, "새로 뜬 창은 다시 알린다")

# 권한 창은 pane_perm 몫 — 여기선 안 올린다
pane(IDLE); mb.pane_ask_tick(now=t0 + 10000)
pane("────\\n Bash command\\n Do you want to proceed?\\n ❯ 1. Yes\\n   2. No\\n Esc to cancel\\n"); n = len(posts())
mb.pane_ask_tick(now=t0 + 10001); mb.pane_ask_tick(now=t0 + 20000)
check(len(posts()) == n, "권한 창은 건너뛴다")

# 평범한 화면(입력창에 '1.' 로 시작하는 글)엔 반응하지 않는다
pane("✻ Worked\\n────\\n❯ 1. 이거 해 줘\\n────\\n"); n = len(posts())
mb.pane_ask_tick(now=t0 + 30000); mb.pane_ask_tick(now=t0 + 40000)
check(len(posts()) == n, "입력창 글은 선택창이 아니다")

# (리뷰 I2) 끝 훅까지 죽어 남은 지난 카드가 새 질문을 막지 않는다
pane(IDLE); mb.pane_ask_tick(now=t0 + 50000)
OLD = {"questions": [{"question": "예전 질문이야 이건", "options": [{"label": "x"}]}], "answers": [None], "msg": "77"}
ms._write_json(sd / "question.json", OLD)
transcript(False); pane(ASK); n = len(posts())
mb.pane_ask_tick(now=t0 + 50001); mb.pane_ask_tick(now=t0 + 50001 + mb.PANE_ASK_GRACE + 1)
st = ask._load(sd)
check(len(posts()) == n + 1 and st and st["msg"] != "77", f"지난 카드를 걷고 새 카드: {st}")
check(any(x["m"] == "PATCH" and x["p"].endswith("/77") for x in log()), "지난 카드 버튼을 거둔다")

# (리뷰 I1) 늦게 살아난 훅이 같은 질문을 또 올리면 늦은 쪽을 거둔다
keep = ask._load(sd)["msg"]; n = len(posts())
ask.post_question(str(sd), ch, Q, started=time.time())
check(len(posts()) == n + 1 and ask._load(sd)["msg"] == keep, "먼저 올린 카드가 살아 있다")
check(any(x["m"] == "PATCH" and "중복" in json.dumps(x.get("b"), ensure_ascii=False) for x in log()), "늦은 카드는 중복 표시로 버튼을 뗀다")
(sd / "question.json").unlink()

# (리뷰 I3) 알림 뒤 다른 창이 끊김 없이 이어 뜨면 그 창도 다시 센다
pane(IDLE); mb.pane_ask_tick(now=t0 + 60000); transcript(True)
pane("────\\n 모델을 바꿀까?\\n ❯ 1. 바꾸기\\n   2. 그대로\\n Enter to confirm · Esc to cancel\\n"); n = len(posts())
mb.pane_ask_tick(now=t0 + 60001); mb.pane_ask_tick(now=t0 + 60001 + mb.PANE_MENU_ALERT + 1)
pane("────\\n 정말 지울까?\\n ❯ 1. 지우기\\n   2. 두기\\n Enter to confirm · Esc to cancel\\n")
mb.pane_ask_tick(now=t0 + 60300); mb.pane_ask_tick(now=t0 + 60300 + mb.PANE_MENU_ALERT + 1)
check(len(posts()) == n + 2 and "정말 지울까" in json.dumps(posts()[-1]["b"], ensure_ascii=False), "이어 뜬 창도 알린다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-bot-paneask"
