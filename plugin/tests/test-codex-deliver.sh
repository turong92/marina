#!/usr/bin/env bash
# 코덱스 방 인바운드 — 살아 있는 방에 글을 입력창으로 넣고 rollout 으로 전달을 확인한다(wake 의 alive 분기).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
export CODEX_HOME="$TMPROOT/real-codex-home-must-not-be-used"
export MARINA_CODEX_SESSIONS="$TMPROOT/codex-sessions"          # 실 ~/.codex/sessions 를 읽지 않는다
export MARINA_CODEX_CONFIRM_TIMEOUT=2 MARINA_ENTER_DELAY=0.3    # 전달 실패 케이스가 8초씩 걸리지 않게
export FD TMPROOT
mkdir -p "$MARINA_HOME/accounts/codex-b" "$MARINA_CODEX_SESSIONS"
echo '{"tokens":{"x":1}}' > "$MARINA_HOME/accounts/codex-b/auth.json"
touch "$TMPROOT/codex-tui"                                      # 가짜 codex 가 가짜 TUI(lib/fake_codex.py)로 뜬다
msess new proj feat/dl --codex --no-start >/dev/null 2>&1 || fail "코덱스 방 만들기 실패"
for _ in $(seq 60); do ls "$MARINA_CODEX_SESSIONS"/*/*/*/rollout-*.jsonl >/dev/null 2>&1 && break; sleep 0.1; done
cat > "$TMPROOT/prelude.py" <<'PY'
import json, os, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_wake as mw
import marina_codex as mc
FD = Path(os.environ["FD"]); T = Path(os.environ["TMPROOT"])
fails = []
def check(c, m):
    if not c: fails.append(m)
def finish():
    if fails:
        print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
rec = ms.find_session("proj/feat/dl"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
now = time.time()
def snow(t): return str((int(t * 1000) - 1420070400000) << 22)
def msg(t, text, user="U1"):
    return {"id": snow(t), "type": 0, "content": text, "channel_id": ch, "author": {"id": user, "username": "sumin", "bot": False}, "attachments": []}
def seed(*rows): (FD / "messages.json").write_text(json.dumps({ch: list(rows)}))
def rollout(): return next(Path(os.environ["MARINA_CODEX_SESSIONS"]).glob("*/*/*/rollout-*.jsonl"))
def user_msgs():
    out = []
    for l in rollout().read_text().splitlines()[1:]:
        o = json.loads(l)
        if o["type"] == "event_msg" and o["payload"]["type"] == "user_message":
            out.append(o["payload"]["message"])
    return out
def count(mid): return sum(m.count(f'message_id="{mid}"') for m in user_msgs())
def woke(): return json.loads((sd / "woke.json").read_text()) if (sd / "woke.json").exists() else {}
def puts(): return [json.loads(l)["p"] for l in (FD / "log.jsonl").read_text().splitlines() if '"PUT"' in l]
PY
run() { PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$@"; }

# 1) 정상 — 입력창에 넣고 rollout 확인, delivered 기록
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
m1 = msg(now - 5, "첫 글")
seed(m1)
r = mw.wake(ch, "U1", m1["id"])
check(r == "delivered", f"wake 결과: {r}")
check(count(m1["id"]) == 1, f"rollout 에 m1 한 번: {count(m1['id'])}")
check(woke().get("delivered") == [m1["id"]], f"woke.delivered: {woke()}")
check(ms.tmux_alive(rec["tmux"]), "방은 그대로 떠 있다")
finish()
PY

# 2) 두 wake 가 동시에 와도 각 글은 정확히 한 번
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
m2, m3 = msg(now - 4, "둘째"), msg(now - 3, "셋째")
m1 = json.loads((FD / "messages.json").read_text())[ch][0]
seed(m1, m2, m3)
import subprocess
code = f'''
import marina_discord_wake as mw
print(mw.wake({ch!r}, "U1", {{mid}}))
'''
ps = [subprocess.Popen([sys.executable, "-c", code.replace("{mid}", repr(x["id"]))], stdout=subprocess.PIPE, text=True) for x in (m2, m3)]
outs = [p.communicate()[0].strip() for p in ps]
check(all(o in ("delivered", "nothing") for o in outs) and "delivered" in outs, f"동시 wake 결과: {outs}")
check(count(m2["id"]) == 1 and count(m3["id"]) == 1, f"m2·m3 각각 정확히 한 번: {count(m2['id'])} {count(m3['id'])}")
finish()
PY

# 3) 삼킨 글 — 전달 확인 실패: ⚠️ 반응, delivered 에 안 적고, 다음 글 때 같이 다시 간다
touch "$TMPROOT/codex-ctl/swallow"
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
rows = json.loads((FD / "messages.json").read_text())[ch]
m4 = msg(now - 2, "삼켜질 글")
seed(*rows, m4)
r = mw.wake(ch, "U1", m4["id"])
check(r == "failed:unconfirmed", f"삼킨 글 결과: {r}")
check(any(f"/messages/{m4['id']}/reactions/" in p and "%E2%9A%A0" in p for p in puts()), f"m4 에 ⚠️ 반응: {puts()[-3:]}")
check(m4["id"] not in woke().get("delivered", []), "delivered 에 m4 없음")
check(count(m4["id"]) == 0, "rollout 에 m4 없음")
finish()
PY
rm -f "$TMPROOT/codex-ctl/swallow"
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
rows = json.loads((FD / "messages.json").read_text())[ch]
m4 = rows[-1]
m5 = msg(now - 1, "다섯째")
seed(*rows, m5)
r = mw.wake(ch, "U1", m5["id"])
check(r == "delivered", f"m5 결과: {r}")
check(count(m4["id"]) == 1 and count(m5["id"]) == 1, f"m4·m5 둘 다 한 번씩: {count(m4['id'])} {count(m5['id'])}")
check({m4["id"], m5["id"]} <= set(woke().get("delivered", [])), "delivered 에 m4·m5")
finish()
PY

# 4) 바쁠 때 — 그래도 넣는다(steer). 화면의 대기 목록에 보이면 접수됨
touch "$TMPROOT/codex-ctl/busy"
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
rows = json.loads((FD / "messages.json").read_text())[ch]
m6 = msg(now, "바쁠 때 끼어들기")
seed(*rows, m6)
r = mw.wake(ch, "U1", m6["id"])
check(r == "delivered", f"바쁠 때 결과: {r}")
screen = ms._tmux("capture-pane", "-p", "-t", rec["tmux"]).stdout
check("Messages to be submitted" in screen and m6["id"] in screen, "화면 대기 목록에 m6")
check(m6["id"] in woke().get("delivered", []), "delivered 에 m6")
finish()
PY
# 4b) 바쁠 때 — 긴 글(접힘)·두 글 묶음(둘째 id 가 미리보기에 안 보임)도 접수로 보고, 다음 글 때 다시 넣지 않는다(두 번 실행 금지)
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
rows = json.loads((FD / "messages.json").read_text())[ch]
m7 = msg(now + 1, "긴 글 " + "가나다라 " * 400)
seed(*rows, m7)
r = mw.wake(ch, "U1", m7["id"])
check(r == "delivered", f"긴 글(접힘) 바쁠 때 결과: {r}")
m8, m9 = msg(now + 2, "묶음 첫째\n둘째 줄"), msg(now + 3, "묶음 셋째")
seed(*rows, m7, m8, m9)
r = mw.wake(ch, "U1", m9["id"])
check(r == "delivered", f"두 글 묶음 바쁠 때 결과: {r}")
m10 = msg(now + 4, "다음 글")
seed(*rows, m7, m8, m9, m10)
r = mw.wake(ch, "U1", m10["id"])
check(r == "delivered", f"m10 결과: {r}")
screen = ms._tmux("capture-pane", "-p", "-t", rec["tmux"]).stdout
check(mc.queued_count(screen) == 4, f"대기열 글 수 = 넣은 횟수(m6, m7, m8+m9, m10) — 중복 입력 없음: {mc.queued_count(screen)}")
check(all(x["id"] in woke().get("delivered", []) for x in (m7, m8, m9, m10)), "모두 delivered")
finish()
PY
rm -f "$TMPROOT/codex-ctl/busy"

# 5) 허용 목록 밖 사용자 — 입력 0
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
before = len(user_msgs())
rows = json.loads((FD / "messages.json").read_text())[ch]
r = mw.wake(ch, "U9", rows[-1]["id"])
check(r == "ignored:not-allowed", f"허용 밖: {r}")
check(len(user_msgs()) == before, "입력 0")
finish()
PY
echo "PASS test-codex-deliver"
