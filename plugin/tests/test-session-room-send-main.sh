#!/usr/bin/env bash
# (형 2026-10-28) 메인 방에서 형과 얘기하고 나머지 방은 room-send 로 지휘하는데, 개발 방들이 지시를 안 따랐다.
#  ① 메인 지시가 '옆 방 잡담'으로 읽혔다('사람이 한 말이 아니다'·'확인엔 답하지 않는다') → 프로젝트의 메인 방을 정하면 그 방 글은 '메인 지시'로 간다
#  ② 받는 방이 429 등으로 튕겨도 보낸 방은 '전달했어'만 알았다 → 튕긴 턴의 room-send 글을 보낸 방에 '못 받았어'를 돌려준다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new a"
msess new proj feat/b --no-start >/dev/null 2>&1 || fail "new b"
msess new proj feat/c --no-start >/dev/null 2>&1 || fail "new c"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, time, threading
from pathlib import Path
import marina_session as ms
import marina_discord_wake as mw
import marina_discord_bot as mb
import marina_codex as mc
fails = []
def check(c, m):
    if not c: fails.append(m)
ms.tmux_alive = lambda t: True
typed = []
mb.run_slash = lambda tmux, cmd, ch, mid, **kw: (typed.append(cmd), True)[1]
mw._left_in_input = lambda tmux, text: False
mw.SAY_CHECK_GAP = 0

# ── ① 메인 방 ──
check(ms.main_room("proj") is None, "처음엔 메인 없음")
ms.set_main_room("proj/feat/b")
check(ms.main_room("proj") == "proj/feat/b", f"메인 지정: {ms.main_room('proj')}")
mw.room_send("proj/feat/a", "좋아 그대로 진행해", sender_ref="proj/feat/b")
t = typed[-1]
check(t.startswith("[마리나 · 메인 proj/feat/b 방의 지시] 좋아 그대로 진행해"), f"메인 지시 머리말: {t!r}")
check("짧아도" in t and 'marina session room-send proj/feat/b "…"' in t, f"일 지시라는 안내·보고 길: {t!r}")
check(mb.typeable(t, ms.find_session("proj/feat/a")["channelId"]), "메인 지시도 대기열 글로 칠 수 있어야")
mw.room_send("proj/feat/b", "끝났어", sender_ref="proj/feat/a")
check(typed[-1].startswith("[마리나 · proj/feat/a 방에서] 끝났어"), f"메인이 아닌 방은 그대로: {typed[-1]!r}")
check(ms.main_room("other") is None, "메인은 프로젝트마다")
ms.set_main_room("proj/feat/a")
check(ms.main_room("proj") == "proj/feat/a", "다시 정하면 바뀐다(하나만)")
ms.set_main_room("proj/feat/a", on=False)
check(ms.main_room("proj") is None, "끄기")
check("메인" in ms.ROOM_SEND_RULE, "방 규칙에도 메인 지시를 따르라는 말")
# (형 2026-10-28) 줄글 보고가 읽히지 않는다 — 결론 한 줄·형이 정할 것·3~5줄, 세부는 빼거나 끝 한 줄
import marina_codex as _mc
for name, rules in (("클로드", ms.CHANNEL_RULES), ("코덱스", _mc.CODEX_RULES)):
    check(ms.REPORT_RULE in rules and "결론" in ms.REPORT_RULE and "3~5줄" in ms.REPORT_RULE, f"{name} 방 규칙에 보고 형식")

# ── ② 튕긴 room-send 를 보낸 방에 알림 ──
ms.set_main_room("proj/feat/b")
ro = Path(ms.marina_home()) / "ro.jsonl"
def ev(t, p): return json.dumps({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t)), "type": "event_msg", "payload": p})
now = time.time()
ro.write_text("\n".join([
    ev(now - 20, {"type": "task_started", "turn_id": "t1"}),
    ev(now - 19, {"type": "user_message", "message": "[마리나 · 메인 proj/feat/b 방의 지시] 어드민 슬라이스 재개해 (끝나면 보고: marina session room-send proj/feat/b \"…\")"}),
    ev(now - 18, {"type": "user_message", "message": "[마리나 · proj/feat/a 방에서] 계약 정정 반영해 (답은: marina session room-send proj/feat/a \"…\")"}),
    ev(now - 17, {"type": "task_complete", "turn_id": "t1", "error": {"message": "exceeded retry limit, last status: 429 Too Many Requests"}}),
]) + "\n")
err = mc.last_turn_error(ro)
check(err and err.get("rooms") == ["proj/feat/b", "proj/feat/a"], f"튕긴 턴의 보낸 방들: {err}")
cx = dict(ms.find_session("proj/feat/c"), kind="codex", rollout=str(ro))
ms.load_sessions = (lambda real: lambda: [cx if r.get("tmux") == cx["tmux"] else r for r in real()])(ms.load_sessions)
sent = []
mw.room_send = lambda ref, msg, sender_ref=None, notice=False: (sent.append((ref, msg, sender_ref, notice)), "delivered")[1]
mc.rate_windows = lambda *a, **k: []
mb._dc = lambda cfg: type("D", (), {"_req": lambda self, *a, **k: {"id": "1"}, "send_message": lambda self, *a, **k: {"id": "1"}})()
mb.codex_error_tick(now)
for th in threading.enumerate():
    if th is not threading.current_thread() and th.name.startswith("room-bounce"): th.join(5)
check(sorted(r for r, *_ in sent) == ["proj/feat/a", "proj/feat/b"], f"보낸 방 둘 다에 알림: {sent}")
m = dict((r, (msg, s, n)) for r, msg, s, n in sent)
check(m and "proj/feat/c" in m["proj/feat/b"][0] and "끊겼어" in m["proj/feat/b"][0] and "어드민 슬라이스" in m["proj/feat/b"][0], f"누가·무엇이 끊겼나: {m}")
check(m and "못 받았어" not in m["proj/feat/b"][0], "턴 중간 오류일 수 있어 '못 받았다'고 단정하지 않는다(리뷰 I4)")
check(m and "한도" in m["proj/feat/b"][0], "한도면 한도라고")
check(m and m["proj/feat/b"][1] == "마리나" and m["proj/feat/b"][2] is True, "마리나 이름으로, 답 꼬리 없이(핑퐁 방지)")

# 클로드 방에 끝내 못 친 글 — 대상 채널 한 줄에 더해 보낸 방에도
sent.clear()
mb._room_send_lost(ms.find_session("proj/feat/a")["channelId"], "[마리나 · 메인 proj/feat/b 방의 지시] 이거 해 (끝나면 보고: …)")
check([r for r, *_ in sent] == ["proj/feat/b"] and "proj/feat/a" in sent[0][1], f"못 친 글도 보낸 방에: {sent}")
sent.clear()
mb._room_send_lost(ms.find_session("proj/feat/a")["channelId"], "[마리나 · 마리나 방에서] ⚠️ 알림")
check(not sent, "마리나 알림이 튕긴 건 되돌려 보내지 않는다(되돌이 방지)")
check([r for r, *_ in sent] == ["proj/feat/b"] or True, "")

# (리뷰 I3) 같은 방에 가는 반송이 동시에 뜨면 방 잠금에서 부딪혀 사라진다 — 차례로
sent.clear(); active, overlap = [0], [False]
def slow(ref, msg, sender_ref=None, notice=False):
    active[0] += 1
    if active[0] > 1: overlap[0] = True
    time.sleep(0.2); active[0] -= 1; sent.append(ref); return "delivered"
mw.room_send = slow
mb._room_bounce("proj/feat/b", "proj/feat/c", "x", "글1"); mb._room_bounce("proj/feat/b", "proj/feat/a", "x", "글2")
for th in threading.enumerate():
    if th is not threading.current_thread() and th.name.startswith("room-bounce"): th.join(5)
check(len(sent) == 2 and not overlap[0], f"차례로 둘 다: {sent} overlap={overlap[0]}")
# (리뷰 I2) 보낸 방이 잠들어 있으면 알림 한 줄 때문에 깨우지 않는다 — 그 방 채널에 한 줄만
sent.clear(); posted = []
mb._dc = lambda cfg: type("D", (), {"send_message": lambda self, ch, t: posted.append((ch, t)),
                                    "_req": lambda self, m, p, b=None: {"id": "777"}})()
ms.tmux_alive = lambda t: False
mb._room_bounce("proj/feat/b", "proj/feat/c", "x", "글3", wait=True)
thb = [k for k, v in ms._forum_posts().items() if v.get("kind") == "room" and v.get("channelId") == ms.find_session("proj/feat/b")["channelId"]]
check(not sent and posted and posted[0][0] in thb and "글3" in posted[0][1], f"잠든 방은 그 방의 방끼리 글에만: {sent} {posted} {thb}")
ms.tmux_alive = lambda t: True
# (리뷰 I1) 사람이 '📨 방끼리' 스레드를 지웠으면 잠든 방 알림도 다시 열어 남긴다(사라지지 않게)
old_tid = [k for k, v in ms._forum_posts().items() if v.get("kind") == "room" and v.get("channelId") == ms.find_session("proj/feat/b")["channelId"]][-1]
class Gone404:
    def __init__(self): self.sent = []
    def _req(self, m, p, b=None): return {"id": "888"}
    def send_message(self, ch, t):
        if ch == old_tid: raise ms.DiscordError(404, "Unknown Channel")
        self.sent.append((ch, t))
g = Gone404(); mb._dc = lambda cfg: g
ms.tmux_alive = lambda t: False
mb._room_bounce("proj/feat/b", "proj/feat/c", "x", "글4", wait=True)
check(g.sent and g.sent[0][0] == "888" and "글4" in g.sent[0][1], f"지운 글이면 (포럼을 못 쓰는 환경에선 옛 스레드로) 새로 열어 남김: {g.sent}")
ms.tmux_alive = lambda t: True
# (리뷰 I2) 상태 폴더가 없으면 스레드를 만들지 않는다(장부를 못 써 매번 새로 만들게 된다)
made = []
class D2:
    def _req(self, m, p, b=None): made.append(p); return {"id": "999"}
check(mw.room_thread({"stateDir": "/nonexistent/x", "channelId": "5"}, D2()) == "" and not made, f"상태 폴더 없으면 안 만든다: {made}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
PY
echo "PASS test-session-room-send-main"
# (리뷰 I1) 방 안(DISCORD_STATE_DIR 있음)에서는 스스로 메인이 될 수 없다 — 사람(터미널)만
out=$(cd "$TMPROOT" && DISCORD_STATE_DIR=/x bash "$MARINA_SH" session main proj/feat/a 2>&1) && fail "방 안에서 메인 지정이 됨: $out"
echo "$out" | grep -q "사람" || fail "거절 안내: $out"
(cd "$TMPROOT" && env -u DISCORD_STATE_DIR bash "$MARINA_SH" session main proj/feat/a >/dev/null) || fail "터미널에서는 돼야"
echo "PASS test-session-room-send-main (CLI)"
