#!/usr/bin/env bash
# ask_terminal(command, why) — 세션이 "형이 직접 실행해 줘" 를 Discord 링크 버튼으로 넘긴다(2026-10-05, 2026-10-06 대시보드 의존 제거).
#  - 그 세션 root 에 marina_termbridge 로 tmux 터미널을 만들고 `<view.publicBase>/t/<토큰>/` 주소를 [터미널에서 열기] 링크 버튼(style 5)에 담는다
#  - runtime(`marina` CLI)은 더 부르지 않는다. view.publicBase 가 없으면 "맥 앞에서 실행해 달라고 부탁해" 안내
#  - 메시지: why + 명령 코드블록, 멘션 알림 없음. 개행 명령·빈 명령은 거부(입력만 해 두는데 개행이면 실행돼 버린다)
#  - 개발 세션 전용(채팅 세션 거부), 개발 세션 허용 목록·채널 안내문에 들어 있다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
# tmux 서버(로그인 셸)가 뜨기 전에: 실제 홈에 기록(~/.bash_history 등)을 남기지 않게 HOME 을 임시로 돌리고 HISTFILE 을 끈다
export SHELL=/bin/sh HOME="$TMPROOT/home" HISTFILE=/dev/null
mkdir -p "$HOME"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
msess new proj feat/t --no-start >/dev/null 2>&1 || fail "new"
msess new chat room --title "방" >/dev/null 2>&1 || fail "new chat"
# 가짜 marina — 불리면 흔적을 남긴다(ask_terminal 이 runtime CLI 를 더는 안 부른다는 증거)
printf '#!/bin/sh\necho called >> "%s/marina-called"\nexit 9\n' "$TMPROOT" > "$TMPROOT/bin/marina"; chmod +x "$TMPROOT/bin/marina"
python3 - "$MARINA_HOME/discord.json" <<'PYJ'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); c["view"] = {"port": 3905, "publicBase": "https://box.example.ts.net:10000"}; json.dump(c, open(p, "w"))
PYJ

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" "$MARINA_HOME" "$TMPROOT" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
fd, mh, tmproot = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
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
check(url.startswith("https://box.example.ts.net:10000/t/") and url.endswith("/") and len(url.split("/t/")[1].rstrip("/")) >= 30, f"url: {url}")
# 그 토큰이 이 세션 root 로 만들어졌고, tmux 입력창에 명령이 쳐져 있다
import marina_termbridge as tb
tokn = url.split("/t/")[1].rstrip("/")
trec = json.loads((mh / "discord-term" / f"{tokn}.json").read_text())
check(trec["root"] == os.path.realpath(rec["root"]) and trec["command"] == "cloud prod db --admin" and "건수" in trec["why"] and trec["channel"] == rec["channelId"], f"요청 내용: {trec} root={rec['root']}")
import time
check(tb.claim(tokn, "c" * 20), "claim")
shown = ""
for _ in range(50):         # 셸이 뜨고 입력이 화면에 보이기까지 기다린다(한 번만 읽으면 느린 머신에서 헛실패)
    shown = tb.screen(tokn, "c" * 20) or ""
    if "cloud prod db --admin" in shown: break
    time.sleep(0.1)
check("cloud prod db --admin" in shown, f"터미널이 떠 있고 명령이 입력만 돼 있다: {shown!r}")
check(not (tmproot / "marina-called").exists(), "runtime CLI(marina) 를 부르지 않는다")

# 코드블록을 깨는 명령 — 더 긴 울타리로 감싸 **보이는 명령 = 실제 명령**, 1500자까지 안 자른다
cmd = "echo ```x```" + "y" * 900
ms.chat_tool("ask_terminal", {"command": cmd, "why": "w"})
last = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/messages"][-1]["b"]
check(len(last["content"]) <= 2000 and f"````\n{cmd}\n````" in last["content"], f"백틱 명령은 긴 울타리로 그대로: {last['content'][:60]!r}")

n = len(log())
for bad in ({"command": "a\nb", "why": "x"}, {"command": "x" * 1001, "why": "x"}, {"command": "a\u202eb", "why": "x"}, {"command": "", "why": "x"}, {"why": "x"}, {"command": "ls", "why": ""}):
    try:
        ms.chat_tool("ask_terminal", bad)
        if bad.get("command") == "ls":    # why 는 선택 — 통과해야 한다
            continue
        check(False, f"잘못된 입력 통과: {bad}")
    except ms.SessionError:
        if bad.get("command") == "ls": check(False, "why 없어도 돼야 한다")
posts_after = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/messages"]
check(len(posts_after) == 4, f"거부된 건 메시지를 안 보낸다(+ls 1개): {len(posts_after)}")

# view.publicBase 가 없으면 버튼 없이 "맥 앞에서 실행해 달라고 부탁해" 로 안내(discord 는 runtime 없이도 돈다)
n_posts = len([x for x in log() if x["m"] == "POST"])
n_term = len(list((mh / "discord-term").glob("*.json")))
cfgp = mh / "discord.json"; saved_cfg = cfgp.read_text()
nocfg = json.loads(saved_cfg); nocfg.pop("view"); cfgp.write_text(json.dumps(nocfg))
try:
    ms.chat_tool("ask_terminal", {"command": "ls", "why": "x"}); check(False, "publicBase 없는데 통과")
except ms.SessionError as e:
    check("reply" in str(e) and "직접 실행" in str(e), f"publicBase 없음 안내 문구: {e}")
check(len(list((mh / "discord-term").glob("*.json"))) == n_term, "publicBase 없으면 터미널도 안 만든다")
cfgp.write_text(saved_cfg)
# M5: 링크는 만들었는데 Discord 버튼 POST 가 실패해도 같은 안내
api = os.environ["MARINA_DISCORD_API"]; os.environ["MARINA_DISCORD_API"] = "http://127.0.0.1:1"
try:
    ms.chat_tool("ask_terminal", {"command": "ls", "why": "x"}); check(False, "POST 실패인데 통과")
except ms.SessionError as e:
    check("reply" in str(e) and "직접 실행" in str(e), f"POST 실패 안내: {e}")
os.environ["MARINA_DISCORD_API"] = api
check(len([x for x in log() if x["m"] == "POST"]) == n_posts, "안내만 하고 버튼 메시지는 안 보낸다")
check(not (tmproot / "marina-called").exists(), "끝까지 runtime CLI 를 안 불렀다")
for f in (mh / "discord-term").glob("*.json"):
    ms._tmux("kill-session", "-t", json.loads(f.read_text())["tmux"])

# 세션을 지우면(teardown) 그 채널의 터미널도 끊긴다
tdir = mh / "discord-term"
mine = [f for f in tdir.glob("*.json") if json.loads(f.read_text())["channel"] == rec["channelId"]]
check(len(mine) >= 1, "이 채널의 터미널 기록이 있다")
names = [json.loads(f.read_text())["tmux"] for f in mine]
ms.teardown(rec)
check(not any(f.exists() for f in mine), "세션 삭제 때 그 채널의 터미널 기록이 지워진다")
alive = ms._tmux("list-sessions", "-F", "#{session_name}").stdout.split()
check(not any(n in alive for n in names), "세션 삭제 때 그 채널의 터미널 tmux 세션도 죽는다")

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
