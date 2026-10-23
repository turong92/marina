#!/usr/bin/env bash
# marina session room-send <대상 방> <글> — 개발 방(클로드·코덱스)끼리 말을 건다. 알림만 마리나로 입력하고 긴 내용은 레포 공통 파일.
# 대상이 떠 있으면 입력창에(코덱스는 rollout 으로 전달 확인, 클로드는 쉬는 순간), 잠들어 있으면 그 글을 첫 지시로 깨운다.
# 보낸 방은 DISCORD_STATE_DIR 로 찾고(없으면 터미널), 대상 채널에 `📨 …` 한 줄을 남긴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
export CODEX_HOME="$TMPROOT/real-codex-home-must-not-be-used"
export MARINA_CODEX_SESSIONS="$TMPROOT/codex-sessions"
export MARINA_CODEX_CONFIRM_TIMEOUT=2 MARINA_ENTER_DELAY=0.3
export FD TMPROOT
mkdir -p "$MARINA_HOME/accounts/codex-b" "$MARINA_CODEX_SESSIONS"
echo '{"tokens":{"x":1}}' > "$MARINA_HOME/accounts/codex-b/auth.json"
printf '{"projects":{"/elsewhere":{"hasTrustDialogAccepted":true}},"keep":1}\n' > "$MARINA_CLAUDE_JSON"
touch "$TMPROOT/codex-tui"
msess new chat shopping >/dev/null 2>&1 || fail "new chat"
msess new proj feat/a >/dev/null 2>&1 || fail "new dev a"
msess new proj feat/b >/dev/null 2>&1 || fail "new dev b"
msess new proj feat/cx --codex >/dev/null 2>&1 || fail "new codex"
for _ in $(seq 60); do ls "$MARINA_CODEX_SESSIONS"/*/*/*/rollout-*.jsonl >/dev/null 2>&1 && break; sleep 0.1; done

cat > "$TMPROOT/prelude.py" <<'PY'
import json, os, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_wake as mw
import marina_discord_bot as mb
FD = Path(os.environ["FD"])
fails = []
def check(c, m):
    if not c: fails.append(m)
def finish():
    if fails:
        print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
def rec(ref): return ms.find_session(ref)
def posts(ch):
    out = []
    for l in (FD / "log.jsonl").read_text().splitlines():
        o = json.loads(l)
        if o["m"] == "POST" and o["p"] == f"/channels/{ch}/messages":
            out.append((o.get("b") or {}).get("content", ""))
    return out
def has_line(ch, head, tail):
    return any(p.startswith(head) and p.endswith(tail) for p in posts(ch))
def rollout(): return next(Path(os.environ["MARINA_CODEX_SESSIONS"]).glob("*/*/*/rollout-*.jsonl"))
def user_msgs():
    out = []
    for l in rollout().read_text().splitlines()[1:]:
        o = json.loads(l)
        if o["type"] == "event_msg" and o["payload"]["type"] == "user_message":
            out.append(o["payload"]["message"])
    return out
PY
run() { PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$@"; }
sdir_of() { run <<PY
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
print(rec("$1")["stateDir"])
PY
}
A_SD="$(sdir_of proj/feat/a)"; CX_SD="$(sdir_of proj/feat/cx)"

# ── 거부: 없는 방·채팅방·자기 자신·너무 긴 글 — 모두 exit 1 + 이유 ──
out="$(DISCORD_STATE_DIR="$A_SD" msess room-send nope/none 안녕 2>&1)" && fail "없는 방이 성공함"
echo "$out" | grep -q "세션을 찾지 못했어" || fail "없는 방 안내: $out"
out="$(DISCORD_STATE_DIR="$A_SD" msess room-send chat/shopping 안녕 2>&1)" && fail "채팅방이 성공함"
echo "$out" | grep -q "개발 방이 아니야" || fail "채팅방 안내: $out"
out="$(DISCORD_STATE_DIR="$A_SD" msess room-send proj/feat/a 안녕 2>&1)" && fail "자기 자신이 성공함"
echo "$out" | grep -q "자기 자신" || fail "자기 자신 안내: $out"
long="$(python3 -c 'print("가" * 1300)')"
out="$(DISCORD_STATE_DIR="$A_SD" msess room-send proj/feat/cx "$long" 2>&1)" && fail "너무 긴 글이 성공함"
echo "$out" | grep -q "너무 길어" || fail "긴 글 안내: $out"
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
check(not any("📨" in p for p in posts(rec("proj/feat/cx")["channelId"])), "거부된 글이 대상 채널에 남음")
finish()
PY

# ── 코덱스 방(떠 있음): 입력창에 넣고 rollout 으로 확인 · 채널에 한 줄 ──
out="$(DISCORD_STATE_DIR="$A_SD" msess room-send proj/feat/cx '계약을 정했어. docs/handoff/x.md 를 읽어 줘' 2>&1)" || fail "코덱스 전달 실패: $out"
[ "$(echo "$out" | wc -l | tr -d ' ')" = 1 ] || fail "출력은 한 줄: $out"
echo "$out" | grep -q "전달" || fail "전달 안내: $out"
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
got = [m for m in user_msgs() if "계약을 정했어" in m]
check(len(got) == 1, f"rollout 에 정확히 한 번: {user_msgs()}")
m = got[0] if got else ""
check(m.startswith("[마리나 · proj/feat/a 방에서] 계약을 정했어. docs/handoff/x.md 를 읽어 줘"), f"머리말: {m!r}")
check(m.rstrip().endswith('(답은: marina session room-send proj/feat/a "…")'), f"답하는 법 꼬리: {m!r}")
check("\n" not in m.strip(), f"한 줄: {m!r}")
ch = rec("proj/feat/cx")["channelId"]
check(has_line(ch, "📨 proj/feat/a 방에서: 계약을 정했어. docs/handoff/x.md 를 읽어 줘", "✓ 전달"), f"대상 채널 한 줄(결과 ✓ 전달): {posts(ch)}")
finish()
PY

# ── 코덱스가 바쁠 때: 대기열로 들어간다 ──
touch "$TMPROOT/codex-ctl/busy"
out="$(DISCORD_STATE_DIR="$A_SD" msess room-send proj/feat/cx '바쁠 때 보내는 글' 2>&1)" || fail "바쁜 코덱스 전달 실패: $out"
echo "$out" | grep -q "대기열" || fail "대기열 안내: $out"
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
screen = ms._tmux("capture-pane", "-p", "-t", rec("proj/feat/cx")["tmux"]).stdout
check("Messages to be submitted" in screen, "화면 대기 목록에 들어감")
finish()
PY
rm -f "$TMPROOT/codex-ctl/busy"

# ── 터미널에서 부르면(DISCORD_STATE_DIR 없음) 보낸 방은 '터미널', 답할 곳이 없으니 답하는 법은 안 붙인다 ──
out="$(env -u DISCORD_STATE_DIR bash -c "cd '$TMPROOT' && bash '$MARINA_SH' session room-send proj/feat/cx '터미널에서 보낸 글'" 2>&1)" || fail "터미널 전달 실패: $out"
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
m = [x for x in user_msgs() if "터미널에서 보낸 글" in x]
check(len(m) == 1 and m[0].startswith("[마리나 · 터미널 방에서] 터미널에서 보낸 글"), f"터미널 머리말: {m}")
check(m and "답은" not in m[0], f"터미널엔 답하는 법 없음: {m}")
check(any(p.startswith("📨 터미널 방에서: ") for p in posts(rec("proj/feat/cx")["channelId"])), "채널 한 줄(터미널)")
finish()
PY

# ── 코덱스가 글을 삼키면: 실패(exit 1) · 채널에 한 줄 안 남김 ──
touch "$TMPROOT/codex-ctl/swallow"
before="$(run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
print(len(posts(rec("proj/feat/cx")["channelId"])))
PY
)"
out="$(DISCORD_STATE_DIR="$A_SD" msess room-send proj/feat/cx '삼켜질 글' 2>&1)" && fail "삼킨 글이 성공함: $out"
echo "$out" | grep -q "확인하지 못했어" || fail "삼킴 안내: $out"
after="$(run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
print(len(posts(rec("proj/feat/cx")["channelId"])))
PY
)"
[ "$before" = "$after" ] || fail "실패했는데 채널에 글이 남음($before → $after)"
rm -f "$TMPROOT/codex-ctl/swallow"

# ── 잠든 코덱스 방: 그 글을 첫 지시로 깨운다 ──
msess stop proj/feat/cx >/dev/null 2>&1 || fail "stop cx"
out="$(DISCORD_STATE_DIR="$A_SD" msess room-send proj/feat/cx '깨워서 줄 글' 2>&1)" || fail "잠든 코덱스 깨우기 실패: $out"
echo "$out" | grep -q "깨웠" || fail "깨움 안내: $out"
has_first() { python3 - "$@" <<'PY'
import glob, sys
need = sys.argv[2:]
for f in glob.glob(sys.argv[1] + "/*/argv"):
    args = [x.decode("utf-8", "replace") for x in open(f, "rb").read().split(b"\0")]
    if any(all(n in x for n in need) for x in args): sys.exit(0)
sys.exit(1)
PY
}
for _ in $(seq 100); do has_first "$FAKE_CODEX_OUT" "깨워서 줄 글" && break; sleep 0.1; done
has_first "$FAKE_CODEX_OUT" "[마리나 · proj/feat/a 방에서] 깨워서 줄 글" || fail "코덱스 첫 지시에 글이 안 들어감"

# ── 잠든 클로드 방: 첫 지시로 깨운다(보낸 방 = 코덱스 방) ──
msess stop proj/feat/b >/dev/null 2>&1 || fail "stop b"
out="$(DISCORD_STATE_DIR="$CX_SD" msess room-send proj/feat/b '코덱스가 보내는 글' 2>&1)" || fail "잠든 클로드 깨우기 실패: $out"
echo "$out" | grep -q "깨웠" || fail "클로드 깨움 안내: $out"
for _ in $(seq 100); do has_first "$FAKE_OUT" "코덱스가 보내는 글" && break; sleep 0.1; done
has_first "$FAKE_OUT" "[마리나 · proj/feat/cx 방에서] 코덱스가 보내는 글" "marina session room-send proj/feat/cx" || fail "클로드 첫 지시에 글·답하는 법이 안 들어감"
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
check(has_line(rec("proj/feat/b")["channelId"], "📨 proj/feat/cx 방에서: 코덱스가 보내는 글", "✓ 전달"), "클로드 방 채널 한 줄")
finish()
PY

# ── 떠 있는 클로드 방: 쉬는 순간 입력창에 친다(run_slash, 쳐 넣은 직후 반환) · 바쁘면 대기열 ──
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
mw.SAY_CHECK_GAP = 0
check(ms.tmux_alive(rec("proj/feat/a")["tmux"]), "준비: 클로드 방 a 가 떠 있어야 함")
calls, spawned = [], []
mb.run_slash = lambda tmux, cmd, ch, mid, **kw: (calls.append((tmux, cmd, ch, mid, kw)), True)[1]
mb._spawn_type = lambda *a, **k: spawned.append(a)
mw._left_in_input = lambda tmux, text: False
how = mw.room_send("proj/feat/a", "아래 줄\n바꿈 있는 글", sender_ref="proj/feat/cx")
check(how == "delivered", f"떠 있으면 전달: {how}")
t, cmd, ch, mid, kw = calls[0]
check(t == rec("proj/feat/a")["tmux"] and ch == rec("proj/feat/a")["channelId"] and "\n" not in cmd, f"한 줄로 친다: {calls}")
check(cmd.startswith("[마리나 · proj/feat/cx 방에서] 아래 줄 바꿈 있는 글") and 'marina session room-send proj/feat/cx "…"' in cmd, f"입력 글: {cmd!r}")
check(kw.get("return_after_type") is True, f"치고 바로 돌아오지 않으면 보낸 쪽이 상대 턴이 끝날 때까지 묶인다: {kw}")
check(has_line(rec("proj/feat/a")["channelId"], "📨 proj/feat/cx 방에서: 아래 줄 바꿈 있는 글", "✓ 전달"), "채널 한 줄")
check(not spawned, "바로 쳤으면 대기열 없음")
# 바쁨 — 제한 시간 안에 못 치면 쉬는 순간에 넣는 대기열(뒤에서 따로 친다)로 넘긴다
calls.clear()
mb.run_slash = lambda *a, **k: False
how = mw.room_send("proj/feat/a", "바쁜 방에 보낸 글", sender_ref="proj/feat/cx")
check(how == "queued" and len(spawned) == 1 and "바쁜 방에 보낸 글" in spawned[0][1], f"바쁘면 대기열: {how} {spawned}")
check(mb.typeable(spawned[0][1], spawned[0][2]), "대기열로 넘긴 글을 type 하위명령이 못 친다(허용 목록)")
check(not mb.typeable("[마리나] 아무 글", spawned[0][2]), "허용 머리말이 아닌 글까지 열렸다")
# 쳤지만 입력창에 남아 있으면 확인 못 한 것 — 갔다고 지어내지 않는다
mb.run_slash = lambda *a, **k: True
mw._left_in_input = lambda tmux, text: True
check(mw.room_send("proj/feat/a", "남는 글", sender_ref="proj/feat/cx") == "typed", "입력창에 남았는데 delivered")
chA = rec("proj/feat/a")["channelId"]
check(has_line(chA, "📨 proj/feat/cx 방에서: 바쁜 방에 보낸 글", "⏳ 대기열"), f"M6 대기열 표시: {posts(chA)}")
check(has_line(chA, "📨 proj/feat/cx 방에서: 남는 글", "❔ 확인 못 함"), f"M6 확인 못 함 표시: {posts(chA)}")
finish()
PY

# ── 리뷰 반영 회귀 ──
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
mw.SAY_CHECK_GAP = 0
mw._left_in_input = lambda tmux, text: False
recA = rec("proj/feat/a"); chA = recA["channelId"]; tmA = recA["tmux"]

# I1: 기다리는 동안 방이 꺼졌으면 떼어 낸 프로세스를 띄우지 않고 실패로 보고
spawned = []
mb._spawn_type = lambda *a, **k: spawned.append(a)
real_alive = ms.tmux_alive
def run_slash_dies(*a, **k):
    ms.tmux_alive = lambda t: False
    return False
mb.run_slash = run_slash_dies
try:
    mw.room_send("proj/feat/a", "꺼질 방", sender_ref="proj/feat/b")
    check(False, "I1 방이 꺼졌는데 성공함")
except ms.SessionError as exc:
    check("꺼" in str(exc), f"I1 안내: {exc}")
ms.tmux_alive = real_alive
check(not spawned, f"I1 꺼진 방에 type 을 띄움: {spawned}")
check(not any("꺼질 방" in p for p in posts(chA)), "I1 실패했는데 📨 가 남음")

# I1: 떼어 낸 type 이 끝내 못 치면 대상 채널에 ⚠️
mb.run_slash = lambda *a, **k: False
n0 = len(posts(chA))
text = mw.ROOM_SEND_PREFIX + "proj/feat/b 방에서] 못 친 글"
mb.main(["type", tmA, text, chA, ""])
new = posts(chA)[n0:]
check(any("⚠️" in p and "못 친 글" in p for p in new), f"I1 type 실패 알림: {new}")
# 성공하면 알림 없음
mb.run_slash = lambda *a, **k: True
n0 = len(posts(chA)); mb.main(["type", tmA, text, chA, ""])
check(not any("⚠️" in p for p in posts(chA)[n0:]), "I1 성공했는데 ⚠️")

# I2: 잠든 방을 깨우면 기동 중 온 글을 놓치지 않게 settle
settles = []
mw._spawn_settle = lambda ch, t: settles.append((ch, t))
mw._start_with_launch_env = lambda name, sd, text: (["x"], [])
ms.tmux_alive = lambda t: False
how = mw.room_send("proj/feat/a", "깨우는 글", sender_ref="proj/feat/b")
ms.tmux_alive = real_alive
check(how == "started" and len(settles) == 1 and settles[0][0] == chA, f"I2 settle: {how} {settles}")

# M5: 기동 중 예외도 SessionError 로
def boom(*a): raise RuntimeError("터짐")
mw._start_with_launch_env = boom
ms.tmux_alive = lambda t: False
try:
    mw.room_send("proj/feat/a", "터지는 글", sender_ref="proj/feat/b")
    check(False, "M5 예외가 안 감싸짐")
except ms.SessionError as exc:
    check("터짐" in str(exc), f"M5 안내: {exc}")
except Exception as exc:
    check(False, f"M5 SessionError 가 아님: {type(exc)}")
ms.tmux_alive = real_alive

# M1: 허용 목록 — kind 없음(클로드 개발) 또는 codex 만
orig = ms.find_session
for kind in ("dev-lobby", "mystery"):
    ms.find_session = lambda ref, k=kind: dict(orig(ref), kind=k)
    try:
        mw.room_send("proj/feat/a", "안녕", sender_ref="proj/feat/b")
        check(False, f"M1 {kind} 가 받음")
    except ms.SessionError as exc:
        check("개발 방이 아니야" in str(exc), f"M1 {kind}: {exc}")
ms.find_session = orig

# M2: 봇 type 이 채팅방·로비에는 room-send 머리말도 못 친다
chat = rec("chat/shopping")
check(not mb.typeable(mw.ROOM_SEND_PREFIX + "x 방에서] 글", chat["channelId"]), "M2 채팅방에 type 허용")
check(not mb.typeable(mw.ROOM_SEND_PREFIX + "x 방에서] 글", "0000"), "M2 모르는 채널에 type 허용")
check(mb.typeable(mw.ROOM_SEND_PREFIX + "x 방에서] 글", chA), "M2 개발 방은 허용")

# I3: 규칙 문구 + 같은 (보낸→받는) 쌍 상한
check("답하지 않는다" in ms.ROOM_SEND_RULE and "알림" in ms.ROOM_SEND_RULE, "I3 규칙에 알림·확인엔 답하지 않는다")
mb.run_slash = lambda *a, **k: True
for i in range(mw.ROOM_SEND_LIMIT):
    mw.room_send("proj/feat/b", f"핑 {i}", sender_ref="proj/feat/a")
try:
    mw.room_send("proj/feat/b", "핑 넘침", sender_ref="proj/feat/a")
    check(False, "I3 상한 넘었는데 성공")
except ms.SessionError as exc:
    check("핑퐁" in str(exc) and str(mw.ROOM_SEND_LIMIT) in str(exc), f"I3 안내: {exc}")
check(not any("핑 넘침" in p for p in posts(rec("proj/feat/b")["channelId"])), "I3 거부됐는데 📨 가 남음")
mw.room_send("proj/feat/a", "반대 방향은 별개", sender_ref="proj/feat/b")      # 쌍은 방향별
mw.room_send("proj/feat/b", "터미널은 제한 없음", sender_ref="터미널")
finish()
PY

# ── run_slash(return_after_type): 친 뒤 상대 턴이 끝나길 기다리지 않는다(기본은 기다림) ──
run <<'PY'
import os; exec(open(os.environ["TMPROOT"] + "/prelude.py").read())
import types
class Pane:
    def __init__(self): self.enters = 0
    def __call__(self, *a, **k):
        if a[0] == "send-keys" and a[-1] == "Enter": self.enters += 1
        if a[0] == "capture-pane":
            return types.SimpleNamespace(stdout="● 답\n" + "─" * 20 + "\n❯ \n" + "─" * 20 + "\n  ⏵⏵", returncode=0)
        return types.SimpleNamespace(stdout="", returncode=0)
pane = Pane()
ms._tmux = pane
ms.tmux_alive = lambda t: True
ms.tmux_leave_mode = lambda t: None
os.environ["MARINA_ENTER_DELAY"] = "0"
mb._input_empty = lambda t: True
mb._pane_busy = lambda t: (True, bool(pane.enters))      # 친 뒤엔 계속 바쁨 — 기다리는 구현이면 timeout 까지 돈다
t0 = time.time()
r = mb.run_slash("t", "[마리나] 글", "1003", "", poll=0.05, settle=0, timeout=4, return_after_type=True)
check(r is True and pane.enters >= 1, f"쳤으면 True: {r} enters={pane.enters}")
check(time.time() - t0 < 3.5, f"친 직후 돌아와야 함: {time.time() - t0:.1f}s")
finish()
PY
echo "PASS test-session-room-send"
