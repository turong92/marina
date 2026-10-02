#!/usr/bin/env bash
# 도구를 쓸 때마다(5초 간격) 진행 표시를 바꾼다 — Claude 가 아니라 훅이 기계적으로(토큰 0).
#  - 형 메시지 반응: 도구 종류 이모지로 교체(👀 → 📖 → 🧪 …), 턴 끝나면 ✅ 만 남는다
#  - 스레드가 있으면 맨 위 상태 줄 하나를 고쳐 쓴다(알림 없음), '입력 중…' 도 함께
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, sys, time
from pathlib import Path
import marina_session as ms
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
os.environ["DISCORD_STATE_DIR"] = str(sd)
tr = sd / "t.jsonl"
tag = f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="7001" user="u">\nfix\n</channel>'
tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": tag}}) + "\n")

check(ms.tool_activity("Read", {"file_path": "/a/b/app.py"}) == ("📖", "파일 읽는 중", "app.py"), "Read")
check(ms.tool_activity("Bash", {"command": "bash plugin/tests/run-affected.sh", "description": "영향 테스트"})[:2] == ("🧪", "테스트 중"), "테스트 명령")
check(ms.tool_activity("Bash", {"command": "git status"})[0] == "🔧", "일반 명령")
check(ms.tool_activity("Bash", {"command": "curl -H 'Authorization: Bearer SECRET' x"})[2] == "", "설명 없는 명령 원문은 안 보낸다(리뷰 5)")
check(ms.tool_activity("Edit", {"file_path": "/x/y.ts"})[0] == "✏️", "Edit")
check(ms.tool_activity("WebFetch", {"url": "https://example.com/a"})[2] == "example.com", "웹 주소는 도메인만")
check(ms.tool_activity("mcp__whatever", {})[0] == "⚙️", "기타")

def act(tool, inp, gap=0.0):
    ms.hook_activity({"tool_name": tool, "tool_input": inp, "transcript_path": str(tr)}, min_gap=gap)
act("Read", {"file_path": "/a/app.py"})
puts = [x["p"] for x in log() if x["m"] == "PUT"]
check(any("/messages/7001/reactions/%F0%9F%93%96" in p for p in puts), f"📖 반응: {puts}")
check(any(x["m"] == "POST" and x["p"] == f"/channels/{ch}/typing" for x in log()), "입력 중")
act("Read", {"file_path": "/a/b.py"})
check(len([1 for x in log() if x["m"] == "PUT" and "%F0%9F%93%96" in x["p"]]) == 1, "같은 종류면 반응을 다시 안 단다")
act("Bash", {"command": "pytest -q"})
dels = [x["p"] for x in log() if x["m"] == "DELETE"]
check(any("%F0%9F%93%96" in p for p in dels) and any("%F0%9F%91%80" in p for p in dels), f"이전 반응(📖·👀) 뗌: {dels}")
n = len(log()); act("Edit", {"file_path": "/a/c.py"}, gap=60)
check(len(log()) == n, "간격 안에선 아무것도 안 보낸다")

# 스레드가 있으면 상태 줄 하나를 고쳐 쓴다
ms.chat_tool("progress", {"message_id": "7001", "text": "시작"})
act("Edit", {"file_path": "/a/c.py"})
tid = json.loads((sd / "threads.json").read_text())["7001"]
posts = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{tid}/messages"]
check(any(x["b"]["content"].startswith("⚙️ 상태") or "코드 고치는 중" in x["b"]["content"] for x in posts), f"상태 줄: {[x['b']['content'] for x in posts]}")
act("Bash", {"command": "pytest"})
patches = [x for x in log() if x["m"] == "PATCH" and f"/channels/{tid}/messages/" in x["p"]]
check(patches and "테스트 중" in patches[-1]["b"]["content"], f"상태 줄 고쳐 쓰기: {patches}")

# 턴 끝: 진행 반응은 떼고 ✅
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
dels = [x["p"] for x in log() if x["m"] == "DELETE"]
check(any("/messages/7001/reactions/%F0%9F%A7%AA" in p for p in dels), f"턴 끝에 진행 반응(🧪) 뗌: {dels[-3:]}")
check(any(x["m"] == "PUT" and "/messages/7001/reactions/%E2%9C%85" in x["p"] for x in log()), "✅")
# (리뷰 4) 접은 뒤에도 같은 지시로 progress 를 다시 부르면 그 스레드에 이어 쓴다(새로 만들다 400 나지 않게)
check(json.loads((sd / "threads.json").read_text()).get("7001") == tid, "접어도 스레드 기록은 남긴다")
out = ms.chat_tool("progress", {"message_id": "7001", "text": "이어서"})
check(out.startswith("스레드에 남겼어"), f"접은 스레드에 이어 쓰기: {out}")
# (리뷰 3) 턴 중 새 지시가 끼어들면 이전 지시의 진행 이모지는 바로 뗀다
tag2 = f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="7002" user="u">\nmore\n</channel>'
with open(tr, "a") as fh:
    fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": tag2}}) + "\n")
act("Read", {"file_path": "/a/x.py"})
act("Edit", {"file_path": "/a/x.py"})
act("Bash", {"command": "ls", "description": "목록"})
before = len(log())
tag3 = f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="7003" user="u">\nmore\n</channel>'
with open(tr, "a") as fh:
    fh.write(json.dumps({"type": "attachment", "attachment": {"type": "queued_command", "prompt": tag3}}) + "\n")
act("Read", {"file_path": "/a/y.py"})
dels = [x["p"] for x in log()[before:] if x["m"] == "DELETE"]
check(any("/messages/7002/reactions/%F0%9F%94%A7" in p for p in dels), f"끼어든 뒤 이전 지시(7002)의 🔧 뗌: {dels}")
# (리뷰 6) 연결 오류가 나도 훅은 끝까지 가고 표시는 앞으로 간다
os.environ["MARINA_DISCORD_API"] = "http://127.0.0.1:9"
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
check((sd / "acked").read_text().strip() == "7003", f"연결 오류에도 acked 전진: {(sd / 'acked').read_text()}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-activity"
