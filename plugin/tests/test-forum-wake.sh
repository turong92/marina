#!/usr/bin/env bash
# 포럼 글(F3·F4) — 방끼리(📨) 줄의 고정 글, 그리고 형이 포럼 글에 쓴 글이 그 방 세션으로 가는 길
#  - F3: 받는 방마다 '[task] 📨 방끼리' 글 하나(태그 없음), id 재사용, 닫혔으면 다시 열고 쓴다, 포럼 못 쓰면 옛 스레드
#  - F4: wake_forum_post — forum-posts.json 으로 방을 찾고(없으면 무시), 방의 allowFrom 으로 거르고,
#    꺼진 방은 첫 지시로 깨우고 켜진 방은 입력창에 '[마리나 · 포럼 글에서] 제목 에 형이 덧붙임: 본문 (답은 …reply_to=…)'
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new a"
msess new proj feat/b --no-start >/dev/null 2>&1 || fail "new b"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
import marina_discord_wake as mw
import marina_discord_bot as mb
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
def dc():
    return ms.Discord(ms.read_token(ms.load_config()))
def room_posts(ch):
    return [k for k, v in ms._forum_posts().items() if v.get("kind") == "room" and str(v.get("channelId")) == str(ch)]
def patches(tid):
    return [x["b"] for x in log() if x["m"] == "PATCH" and x["p"] == f"/channels/{tid}"]
def lines(tid):
    return [x["b"]["content"] for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{tid}/messages"]

a, b = ms.find_session("proj/feat/a"), ms.find_session("proj/feat/b")

# ── F3: 방끼리 고정 글 ──
mw.post_room_line(b, dc(), "📨 a 방에서: 첫 줄")
ids = room_posts(b["channelId"])
check(len(ids) == 1, f"받는 방마다 고정 글 하나: {ids}")
made = [x for x in log() if x["m"] == "POST" and x["p"].endswith("/threads") and "message" in x["b"]][-1]["b"]
check(made["name"] == "[feat/b] 📨 방끼리" and not made.get("applied_tags"), f"제목·태그 없음: {made}")
tid = ids[0]
check(lines(tid)[-1] == "📨 a 방에서: 첫 줄", f"줄이 글로: {lines(tid)}")
check(not ms.room_threads(b["stateDir"]), "옛 방끼리 스레드는 안 만든다")
mw.post_room_line(b, dc(), "📨 a 방에서: 둘째")
check(room_posts(b["channelId"]) == [tid] and lines(tid)[-1] == "📨 a 방에서: 둘째", "글 id 재사용")
check(room_posts(a["channelId"]) == [], "다른 방 글은 따로")
# 닫혔으면 다시 열고 쓴다(쓰기 전에 archived False)
ms.set_post_state(dc(), tid, archived=True)
n = len(log())
mw.post_room_line(b, dc(), "📨 a 방에서: 닫힌 뒤")
after = log()[n:]
kinds = [(x["m"], x["p"]) for x in after if x["p"].startswith(f"/channels/{tid}")]
check(kinds[:2] == [("PATCH", f"/channels/{tid}"), ("POST", f"/channels/{tid}/messages")] and after[0]["b"] == {"archived": False}, f"닫힌 글은 먼저 연다: {kinds}")
# 사람이 글을 지웠으면(404) 새로 만들어 쓴다
class Gone(ms.Discord):
    def send_message(self, ch, text, *a, **k):
        if ch == tid: raise ms.DiscordError(404, "Unknown Channel")
        return super().send_message(ch, text, *a, **k)
g = Gone(ms.read_token(ms.load_config()))
mw.post_room_line(b, g, "📨 a 방에서: 지운 뒤")
new = room_posts(b["channelId"])
check(len(new) == 1 and new[0] != tid and lines(new[0])[-1] == "📨 a 방에서: 지운 뒤", f"지워졌으면 새 글: {new}")
# 포럼을 못 쓰면 옛 스레드로 폴백
(fd / "no_forum").write_text("1")
mw.post_room_line(a, dc(), "📨 b 방에서: 폴백")
check(room_posts(a["channelId"]) == [] and [v for v in ms.room_threads(a["stateDir"]).values() if v.get("name") == mw.ROOM_SEND_THREAD], "포럼 못 쓰면 옛 스레드")
(fd / "no_forum").unlink()

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
PY
echo "PASS test-forum-wake"
