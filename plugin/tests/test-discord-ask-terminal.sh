#!/usr/bin/env bash
# ask_terminal(command, why) — 세션이 "형이 직접 실행해 줘" 를 Discord 링크 버튼으로 넘긴다(2026-10-05).
#  - 그 세션 root 를 cwd 로 `marina term-request` 를 실행해 받은 주소를 [터미널에서 열기] 링크 버튼(style 5)에 담는다
#  - 메시지: why + 명령 코드블록, 멘션 알림 없음. 개행 명령·빈 명령은 거부(입력만 해 두는데 개행이면 실행돼 버린다)
#  - 개발 세션 전용(채팅 세션 거부), 개발 세션 허용 목록·채널 안내문에 들어 있다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
msess new proj feat/t --no-start >/dev/null 2>&1 || fail "new"
msess new chat room --title "방" >/dev/null 2>&1 || fail "new chat"
printf '#!/bin/sh\nprintf "state=funnel\\nurl=https://box.example.ts.net\\ndashboardPort=3900\\n"\n' > "$TMPROOT/bin/fake-status"
chmod +x "$TMPROOT/bin/fake-status"
export MARINA_TERM_REQUEST_REMOTE_STATUS="$TMPROOT/bin/fake-status"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" "$MARINA_HOME" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
fd, mh = Path(sys.argv[1]), Path(sys.argv[2])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]

rec = ms.find_session("proj/feat/t")
st = json.loads((Path(rec["stateDir"]) / "settings.json").read_text())
check("mcp__marina__ask_terminal" in st["permissions"]["allow"], "개발 세션 허용 목록에 ask_terminal")
crec = ms.find_session("chat/room")
cst = json.loads((Path(crec["stateDir"]) / "settings.json").read_text())
check("mcp__marina__ask_terminal" not in cst["permissions"]["allow"], "채팅 세션 허용 목록엔 없다")
check("ask_terminal" in [t["name"] for t in ms._CHAT_TOOLS_MCP], "MCP 도구 목록")
check("ask_terminal" in ms.CHANNEL_RULES, "채널 안내문에 ask_terminal")
check("우회" in ms.CHANNEL_RULES, "안내문: 래퍼 안전장치를 우회하지 않는다")

os.environ["DISCORD_STATE_DIR"] = rec["stateDir"]
out = ms.chat_tool("ask_terminal", {"command": "cloud prod db --admin", "why": "prod DB 에서 건수 확인"})
check("버튼" in out, f"반환 문구: {out}")
posts = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/messages"]
check(len(posts) == 1, f"채널 메시지 1개: {posts}")
b = posts[0]["b"] if posts else {}
check("prod DB 에서 건수 확인" in b.get("content", "") and "```\ncloud prod db --admin\n```" in b.get("content", ""), f"본문: {b.get('content')}")
# why 의 마크다운 링크·대괄호는 렌더되지 않게 이스케이프
ms.chat_tool("ask_terminal", {"command": "ls", "why": "[눌러](http://evil.example) *굵게* _x_"})
w = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/messages"][-1]["b"]["content"]
check("](" not in w.replace("\\]\\(", "") and "\\[눌러\\]" in w and "\\*굵게\\*" in w, f"why 이스케이프: {w!r}")
check(b.get("allowed_mentions") == {"parse": []}, "멘션 알림 없음")
btn = (((b.get("components") or [{}])[0]).get("components") or [{}])[0]
check(b.get("components", [{}])[0].get("type") == 1 and btn.get("type") == 2 and btn.get("style") == 5, f"링크 버튼: {b.get('components')}")
check(btn.get("label") == "터미널에서 열기" and "custom_id" not in btn, f"라벨·custom_id 없음: {btn}")
url = btn.get("url", "")
check(url.startswith("https://box.example.ts.net/term-run?t="), f"url: {url}")
# 그 토큰이 이 세션 root 로 만들어졌다
import marina_term_requests as tr
req = tr.claim(url.split("t=")[1])
check(req and req["root"] == os.path.realpath(rec["root"]) and req["command"] == "cloud prod db --admin" and "건수" in req["why"], f"요청 내용: {req} root={rec['root']}")

# 코드블록을 깨는 명령 — 더 긴 울타리로 감싸 **보이는 명령 = 실제 명령**, 1500자까지 안 자른다
cmd = "echo ```x```" + "y" * 1400
ms.chat_tool("ask_terminal", {"command": cmd, "why": "w"})
last = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/messages"][-1]["b"]
check(len(last["content"]) <= 2000 and f"````\n{cmd}\n````" in last["content"], f"백틱 명령은 긴 울타리로 그대로: {last['content'][:60]!r}")

n = len(log())
for bad in ({"command": "a\nb", "why": "x"}, {"command": "x" * 1501, "why": "x"}, {"command": "a\u202eb", "why": "x"}, {"command": "", "why": "x"}, {"why": "x"}, {"command": "ls", "why": ""}):
    try:
        ms.chat_tool("ask_terminal", bad)
        if bad.get("command") == "ls":    # why 는 선택 — 통과해야 한다
            continue
        check(False, f"잘못된 입력 통과: {bad}")
    except ms.SessionError:
        if bad.get("command") == "ls": check(False, "why 없어도 돼야 한다")
posts_after = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/messages"]
check(len(posts_after) == 4, f"거부된 건 메시지를 안 보낸다(+ls 1개): {len(posts_after)}")

# 채팅 세션은 거부
os.environ["DISCORD_STATE_DIR"] = crec["stateDir"]
try:
    ms.chat_tool("ask_terminal", {"command": "ls", "why": "x"}); check(False, "채팅 세션이 통과")
except ms.SessionError as e:
    check("개발" in str(e), f"채팅 거부 사유: {e}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
print("ok")
PY
echo "PASS test-discord-ask-terminal"
