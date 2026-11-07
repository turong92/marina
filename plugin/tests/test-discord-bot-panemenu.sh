#!/usr/bin/env bash
# (형 2026-11-06) 방이 터미널 번호 선택창(사용량 한도 메뉴 'What do you want to do? ❯ 1. Stop and wait…' 등)을 띄우면
#  Discord 엔 글만 가서 형이 고를 수 없었다
#  → 봇이 화면의 번호 선택창을 보면(훅 질문 카드가 없을 때, 틈을 준 뒤) 질문 줄 + 선택지 버튼을 한 번 올리고,
#    누르면 화면이 아직 같은 창일 때만 그 번호로 커서를 옮겨 Enter. 창이 풀리면 버튼을 거둔다
#  - 화면 원문은 안 올린다(질문 줄·선택지 글자만) · 같은 창은 한 번만 · 권한 창은 pane_perm 몫
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
def menu_files():
    return [json.loads(p.read_text()) for p in sd.glob("menu-*.json")]
keys = []; targets = []
real = ms._tmux
def spy(*a):
    if a and a[0] == "send-keys" and "-X" not in a:
        keys.append(a[-1]); targets.append(a[a.index("-t") + 1]); return subprocess.CompletedProcess(a, 0, "", "")
    return real(*a)
ms._tmux = spy
mb._session_transcript = lambda rec: None

LIMIT = ("────\\n  You\\x27ve hit your usage limit token=sk-abcdef123456\\n\\n What do you want to do?\\n\\n"
         " ❯ 1. Stop and wait for limit to reset\\n   2. Switch to extra usage\\n   3. Upgrade your plan\\n"
         "\\n Enter to confirm · Esc to cancel\\n")
IDLE = "✻ Worked\\n────\\n❯ \\n────\\n"
t0 = 1000.0

# ① 번호 선택창 → 틈 뒤 질문 + 버튼 한 번, 화면 원문은 안 올린다
pane(LIMIT)
mb.pane_ask_tick(now=t0)
check(posts() == [], "처음 본 순간엔 훅에게 틈을 준다")
mb.pane_ask_tick(now=t0 + mb.PANE_ASK_GRACE + 1)
ps = posts(); body = json.dumps(ps[-1]["b"], ensure_ascii=False) if ps else ""
check(len(ps) == 1 and "What do you want to do?" in body, f"질문 줄: {body[:300]}")
check(all(f"mperm:{i}:" in body for i in (1, 2, 3)) and "Switch to extra usage" in body, f"선택지 버튼: {body[:400]}")
check("sk-abcdef" not in body and "usage limit" not in body, f"화면 원문은 안 올린다: {body[:400]}")
mb.pane_ask_tick(now=t0 + 500)
check(len(posts()) == 1, "같은 창이면 한 번만")
files = menu_files()
check(len(files) == 1 and files[0].get("msg"), f"기록: {files}")

# ② 버튼 → 화면이 같을 때만 커서를 옮겨 Enter
tok = files[0]["token"]
r = mb.perm(ch, "U1", tok, False, pick=2)
check(keys == ["Down", "Enter"] and "2" in r, f"2번 → Down Enter: {keys} {r}")
check(targets and all(t == f"={rec['tmux']}:" for t in targets), f"정확한 세션 이름: {targets}")
check(menu_files() == [] and any(x["m"] == "PATCH" for x in log()), "누르면 기록 정리 + 버튼 거둠")

# ③ 화면이 바뀐 뒤 누르면 아무것도 안 친다
keys.clear(); pane(IDLE); mb.pane_ask_tick(now=t0 + 600)
pane(LIMIT); mb.pane_ask_tick(now=t0 + 601); mb.pane_ask_tick(now=t0 + 601 + mb.PANE_ASK_GRACE + 1)
tok = menu_files()[0]["token"]
pane(LIMIT.replace("limit to reset", "something else"))
r = mb.perm(ch, "U1", tok, False, pick=1)
check(keys == [] and "바뀌" in r, f"다른 창이면 안 누른다: {r} {keys}")

# ④ 터미널에서 먼저 풀리면 버튼을 거둔다
pane(IDLE); mb.pane_ask_tick(now=t0 + 650)
pane(LIMIT); mb.pane_ask_tick(now=t0 + 651); mb.pane_ask_tick(now=t0 + 651 + mb.PANE_ASK_GRACE + 1)
check(len(menu_files()) == 1, "다시 뜬 창에 버튼")
pane(IDLE); n = len([x for x in log() if x["m"] == "PATCH"]); mb.pane_ask_tick(now=t0 + 700)
check(menu_files() == [] and len([x for x in log() if x["m"] == "PATCH"]) > n, "풀리면 정리")

# ⑤ 없는 번호는 안 친다
pane(LIMIT); mb.pane_ask_tick(now=t0 + 800); mb.pane_ask_tick(now=t0 + 800 + mb.PANE_ASK_GRACE + 1)
tok = menu_files()[0]["token"]; keys.clear()
r = mb.perm(ch, "U1", tok, False, pick=7)
check(keys == [], f"범위 밖: {keys} {r}")

# ⑥ 권한 창은 pane_perm 몫 — 버튼 안 올린다
pane(IDLE); mb.pane_ask_tick(now=t0 + 900)
pane("────\\n Bash command\\n Do you want to proceed?\\n ❯ 1. Yes\\n   2. No\\n Esc to cancel\\n"); n = len(posts())
mb.pane_ask_tick(now=t0 + 901); mb.pane_ask_tick(now=t0 + 5000)
check(len(posts()) == n and menu_files() == [], "권한 창은 건너뛴다")

# ⑦ 질문(?) 줄이 없는 창 — 그 위 화면 줄(비밀 가능)은 올리지 않는다
pane(IDLE); mb.pane_ask_tick(now=t0 + 6000)
pane("────\\n DB password=hunter2secret\\n ❯ 1. Retry\\n   2. Abort\\n Enter to confirm · Esc to cancel\\n"); n = len(posts())
mb.pane_ask_tick(now=t0 + 6001); mb.pane_ask_tick(now=t0 + 6001 + mb.PANE_ASK_GRACE + 1)
ps = posts(); body = json.dumps(ps[-1]["b"], ensure_ascii=False) if len(ps) > n else ""
check(body and "mperm:1:" in body and "hunter2" not in body and "DB password" not in body, f"질문 줄 없으면 위 줄 안 나감: {body[:300]}")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-bot-panemenu"
