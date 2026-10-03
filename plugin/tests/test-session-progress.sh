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

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
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
check(mk and mk[0]["b"].get("auto_archive_duration") == 60, "1시간 지나면 Discord 가 알아서 접는다")
# 턴이 끝나 ✅ 가 붙으면 그 지시의 스레드를 접는다(채널 목록에 계속 쌓이지 않게)
tr = Path(rec["stateDir"]) / "t.jsonl"
tag = lambda mid: f'<channel source="plugin:discord:discord" chat_id="{rec["channelId"]}" message_id="{mid}" user="u">\nx\n</channel>'
tr.write_text("".join(json.dumps({"type": "user", "message": {"role": "user", "content": tag(m)}}) + "\n" for m in ("9001", "9002")))
tids = json.loads((Path(rec["stateDir"]) / "threads.json").read_text())
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
arch = [x["p"] for x in log() if x["m"] == "PATCH" and x["b"].get("archived") is True]
check(f"/channels/{tids['9001']}" in arch and f"/channels/{tids['9002']}" in arch, f"끝난 지시 스레드 접기: {arch}")
check(sorted(json.loads((Path(rec["stateDir"]) / "threads-archived.json").read_text())) == ["9001", "9002"], "접은 스레드 기록")
n = len(arch); ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
check(len([x for x in log() if x["m"] == "PATCH"]) == n, "다음 턴에 다시 접지 않는다")
# 작업 중 표시: 도구를 쓸 때마다 '입력 중…'(8초에 한 번만) — 개발·채팅 세션 모두
for ref in ("proj/feat/p", "chat/room"):
    r2 = ms.find_session(ref)
    pre = json.loads((Path(r2["stateDir"]) / "settings.json").read_text())["hooks"]["PreToolUse"]
    cmds = [h["command"] for e in pre for h in e["hooks"] if "hook-typing" in h["command"]]
    check(len(cmds) == 1 and cmds[0].endswith("|| true"), f"{ref}: typing 훅: {pre}")
import subprocess
cmd = [h["command"] for e in json.loads((Path(rec["stateDir"]) / "settings.json").read_text())["hooks"]["PreToolUse"] for h in e["hooks"] if "hook-typing" in h["command"]][0]
env = dict(os.environ, DISCORD_STATE_DIR=rec["stateDir"])
for _ in range(3):
    check(subprocess.run(["/bin/sh", "-c", cmd], input="{}", text=True, env=env, capture_output=True).returncode == 0, "typing 훅 exit 0")
import time
for _ in range(50):          # 훅은 떼어 낸 프로세스가 보낸다 — 잠깐 기다린다
    typing = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/typing"]
    if typing: break
    time.sleep(0.1)
time.sleep(0.5)
typing = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/typing"]
check(len(typing) == 1, f"연달아 불러도 한 번(8초 간격): {len(typing)}")
(fd / "no_threads").write_text("1")
msg = ms.chat_tool("progress", {"message_id": "9003", "text": "x"})
check("권한" in msg and "edit_message" in msg, f"권한 없을 때 안내: {msg}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-progress"
