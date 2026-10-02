#!/usr/bin/env bash
# progress(message_id, text) — 지시 메시지에 스레드를 열고 진행 기록을 쌓는다(결과는 채널에 reply).
#  - 같은 지시면 같은 스레드에 이어 쓴다(상태 폴더 threads.json), 알림 없이(flags 4096), 멘션 알림 없음
#  - 스레드 권한이 없으면 실패 대신 안내(채널에 edit 방식으로 하라고)
#  - 개발·채팅 세션 모두 허용 목록에 있다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
msess new proj feat/p --no-start >/dev/null 2>&1 || fail "new"
msess new chat room --title "방" >/dev/null 2>&1 || fail "new chat"

PYTHONPATH="$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
for ref in ("proj/feat/p", "chat/room"):
    rec = ms.find_session(ref)
    st = json.loads((Path(rec["stateDir"]) / "settings.json").read_text())
    check("mcp__marina__progress" in st["permissions"]["allow"], f"{ref}: progress 허용")
rec = ms.find_session("proj/feat/p")
os.environ["DISCORD_STATE_DIR"] = rec["stateDir"]
names = [t["name"] for t in ms._CHAT_TOOLS_MCP]
check("progress" in names, f"도구 목록: {names}")
out1 = ms.chat_tool("progress", {"message_id": "9001", "text": "원인 찾는 중…"})
out2 = ms.chat_tool("progress", {"message_id": "9001", "text": "테스트 통과 @everyone"})
ms.chat_tool("progress", {"message_id": "9002", "text": "다른 지시"})
mk = [x for x in log() if x["m"] == "POST" and x["p"].endswith("/threads")]
check(len(mk) == 2 and mk[0]["p"] == f"/channels/{rec['channelId']}/messages/9001/threads", f"지시마다 스레드 하나: {mk}")
check(mk and 0 < len(mk[0]["b"].get("name", "")) <= 100, "스레드 이름")
tid = json.loads((Path(rec["stateDir"]) / "threads.json").read_text())["9001"]
posts = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{tid}/messages"]
check(len(posts) == 2 and posts[1]["b"]["content"].startswith("테스트 통과"), f"같은 스레드에 이어 쓰기: {posts}")
check(all(x["b"].get("flags") == 4096 and x["b"].get("allowed_mentions") == {"parse": []} for x in posts), "알림 없이·멘션 없이")
check("스레드" in out1, f"결과 문구: {out1}")
for bad in ({"text": "x"}, {"message_id": "9001"}, {"message_id": "9001", "text": ""}, {"message_id": "../x", "text": "x"}):
    try:
        ms.chat_tool("progress", bad); check(False, f"잘못된 입력 통과: {bad}")
    except ms.SessionError:
        pass
(fd / "no_threads").write_text("1")
msg = ms.chat_tool("progress", {"message_id": "9003", "text": "x"})
check("권한" in msg and "edit_message" in msg, f"권한 없을 때 안내: {msg}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-progress"
