#!/usr/bin/env bash
# marina session lobby — CHAT 카테고리의 #새-대화 로비. 여자친구가 형 없이 Discord 안에서 새 채팅방을 연다.
#  - 로비 세션은 파일·웹 도구 없이(--tools "") 마리나 MCP 도구(open_chat·list_chats)만 쓴다
#  - open_chat = 이름 검사 → 채팅방 생성(채널 설명 = 한글 제목) → 봇이 첫 안내 메시지
#  - 채팅방은 최대 20개, 사용법은 로비 채널 설명 + 첫 안내 메시지
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"

out="$(msess lobby 2>&1)" || fail "lobby 실패: $out"
echo "$out" | grep -q "discord.com/channels/G1/" || fail "로비 링크 없음: $out"
out2="$(msess lobby 2>&1)" && fail "로비가 두 개 만들어짐"
for _ in $(seq 50); do ls "$FAKE_OUT"/*/argv >/dev/null 2>&1 && break; sleep 0.1; done

PYTHONPATH="$SCRIPTS" python3 - "$FD" "$MARINA_HOME" "$FAKE_OUT" <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
import marina_session as ms
fd, mh, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]

lob = ms.find_session("chat/lobby")
check(lob.get("kind") == "chat-lobby" and lob["root"] == str((mh / "chat").resolve()), f"로비 기록: {lob}")
chpost = next(x for x in log() if x["m"] == "POST" and x["b"].get("type") == 0 and x["b"].get("name") != "자료실")
check(chpost["b"]["name"] == "새-대화" and "새 대화방" in chpost["b"].get("topic", ""), f"로비 채널 이름·설명: {chpost}")
guide = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{lob['channelId']}/messages"]
check(guide and "방 열어줘" in guide[0]["b"]["content"], f"로비 사용법 메시지: {guide}")

calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
check(argv == ms.lobby_argv("chat", "lobby", lob["sessionId"])[1:], f"로비 인자: {argv}")
check(argv[argv.index("--tools") + 1] == "", "로비는 내장 도구 없음")
check("--restricted" in argv and argv[argv.index("--permission-mode") + 1] == "dontAsk", "제한 모드")
sd = Path(lob["stateDir"])
mcp = json.loads(Path(argv[argv.index("--mcp-config") + 1]).read_text())
srv = mcp["mcpServers"]["marina"]
st = json.loads((sd / "settings.json").read_text())
check("mcp__marina__open_chat" in st["permissions"]["allow"] and "mcp__marina__list_chats" in st["permissions"]["allow"], "로비 도구 허용")
check(st["hooks"]["PreToolUse"][0]["matcher"].startswith("mcp__plugin_discord_discord__reply"), "로비 답장 첨부도 가드")

# MCP 서버 — 한 줄 JSON-RPC
def rpc(msgs):
    p = subprocess.run([srv["command"]] + srv["args"], input="".join(json.dumps(m) + "\n" for m in msgs),
                       text=True, capture_output=True, env=dict(os.environ, **srv.get("env", {})), timeout=60)
    return [json.loads(l) for l in p.stdout.splitlines() if l.strip()], p.stderr
init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}}
res, err = rpc([init, {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
check(res[0]["result"]["protocolVersion"] == "2025-06-18" and "tools" in res[0]["result"]["capabilities"], f"initialize: {res} {err}")
check(len(res) == 2, f"알림엔 답하지 않는다: {res}")
tools = {t["name"]: t for t in res[1]["result"]["tools"]}
check(set(tools) == {"open_chat", "list_chats"}, f"도구 목록: {list(tools)}")

def call(i, name, args):
    r, e = rpc([init, {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}}])
    return r[-1]["result"], e
r, e = call(3, "open_chat", {"name": "wedding-prep", "title": "웨딩 준비"})
check(not r.get("isError") and "discord.com/channels/G1/" in r["content"][0]["text"], f"open_chat: {r} {e}")
rec = ms.find_session("chat/wedding-prep")
check(rec["kind"] == "chat" and rec.get("title") == "웨딩 준비", f"새 방 기록: {rec}")
post = [x for x in log() if x["m"] == "POST" and x["b"].get("name") == "wedding-prep"][-1]
check(post["b"].get("topic") == "웨딩 준비", f"새 방 채널 설명 = 제목: {post}")
welcome = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/messages"]
check(welcome and "웨딩 준비" in welcome[0]["b"]["content"], f"새 방 첫 안내: {welcome}")
check(all(x["b"].get("allowed_mentions") == {"parse": []} for x in log() if x["m"] == "POST" and x["p"].endswith("/messages")),
      "봇 메시지는 멘션 알림을 만들지 않는다")

for bad in ({"name": "웨딩", "title": "x"}, {"name": "../x", "title": "x"}, {"name": "lobby", "title": "x"},
            {"name": "wedding-prep", "title": "x"}, {"name": "", "title": "x"}, {"title": "x"},
            {"name": "ping-all", "title": "@everyone 모여"}, {"name": "ping-role", "title": "<@&123> 호출"},
            {"name": "two-lines", "title": "a\nb"}):
    r, e = call(4, "open_chat", bad)
    check(r.get("isError") is True, f"잘못된 요청은 오류: {bad} → {r}")
r, e = call(5, "list_chats", {})
check("wedding-prep" in r["content"][0]["text"] and "웨딩 준비" in r["content"][0]["text"], f"list_chats: {r}")
r, e = rpc([init, [{"jsonrpc": "2.0", "id": 9, "method": "ping"}], {"jsonrpc": "2.0", "id": 10, "method": "ping"}])
check(r[-1].get("id") == 10, f"dict 아닌 메시지에 서버가 죽지 않는다: {r} {e}")
r, e = call(6, "no_such_tool", {})
check(r.get("isError") is True, "없는 도구는 오류")

# 채팅방 최대 20개
items = ms.load_sessions()
ms.save_sessions(items + [dict(rec, task=f"fill{i}", tmux=f"chat-fill{i}") for i in range(19)])
r, e = call(7, "open_chat", {"name": "one-more", "title": "x"})
check(r.get("isError") is True and "20" in r["content"][0]["text"], f"20개 제한: {r}")
ms.save_sessions(items)
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-lobby"
