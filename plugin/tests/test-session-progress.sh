#!/usr/bin/env bash
# progress(message_id, text) — 지시마다 프로젝트 📋작업 포럼에 글을 열고(못 열면 지시 메시지 밑 스레드) 진행 기록을 쌓는다(결과는 채널에 reply).
#  - 포럼 글 자체(제목·태그·링크 답·폴백)는 test-forum-posts.sh. 여기는 글/스레드에 쌓이는 줄과 접기
#  - 같은 지시면 같은 글에 이어 쓴다(상태 폴더 threads.json), 알림 없이(flags 4096), 멘션 알림 없음
#  - 스레드 권한이 없으면 실패 대신 안내(채널에 edit 방식으로 하라고)
#  - 개발·채팅 세션 모두 허용 목록에 있다
# open_thread(name) — 사람과 한 주제를 이어 가는 스레드를 이름 붙여 만든다(진행 스레드와 별개, 머리 메시지 없음)
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
    check(("mcp__marina__open_thread" in st["permissions"]["allow"]) == ref.startswith("chat/"),
          f"{ref}: open_thread 는 대화방에만 허용")
rec = ms.find_session("proj/feat/p")
os.environ["DISCORD_STATE_DIR"] = rec["stateDir"]
names = [t["name"] for t in ms._CHAT_TOOLS_MCP]
check("progress" in names, f"도구 목록: {names}")
out1 = ms.chat_tool("progress", {"message_id": "9001", "text": "원인 찾는 중…"})
out2 = ms.chat_tool("progress", {"message_id": "9001", "text": "테스트 통과 @everyone"})
ms.chat_tool("progress", {"message_id": "9002", "text": "다른 지시"})
fid = ms.load_config()["projects"]["proj"]["forumChannelId"]
mk = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{fid}/threads"]
check(len(mk) == 2, f"지시마다 포럼 글 하나: {mk}")
check(mk and 0 < len(mk[0]["b"].get("name", "")) <= 100, "글 제목")
check(mk and mk[0]["b"].get("name") == "[feat/p] 원인 찾는 중…", f"(a) 지시 본문을 모르면 progress 줄로 제목: {mk[:1]}")
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
# 뒤에서 서브에이전트가 도는 동안엔 접지 않는다 — 진행 줄이 계속 쌓이는데 턴이 끝날 때마다 닫혔다(형 2026-10-06).
# 에이전트가 다 끝난 뒤의 턴 끝(알림으로 이어진 턴이라 새 지시 메시지가 없어도)에 밀린 스레드를 접는다
ms._progress(rec, {"message_id": "9777", "text": "뒤에서 도는 일"})
tids = json.loads((Path(rec["stateDir"]) / "threads.json").read_text())
tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": tag("9777")}}) + "\n")
ms._running_agent_ids = lambda s: {"x"}
n = len([x for x in log() if x["m"] == "PATCH" and x["b"].get("archived") is True])
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
arch = [x["p"] for x in log() if x["m"] == "PATCH" and x["b"].get("archived") is True]
check(len(arch) == n, f"에이전트가 도는 동안엔 안 접는다: {arch[n:]}")
ms._running_agent_ids = lambda s: set()
tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": "<task-notification>끝</task-notification>"}}) + "\n")
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
arch = [x["p"] for x in log() if x["m"] == "PATCH" and x["b"].get("archived") is True]
check(arch[n:] == [f"/channels/{tids['9777']}"], f"다 끝난 뒤 턴 끝에 밀린 스레드를 접는다(새 지시 없어도): {arch[n:]}")
# 에이전트가 도는 중에도 지난 지시의 스레드는 접고, 진행 줄이 지금 올라가는 스레드(activity.json 의 mid) 하나만 열어 둔다
# — 개발 에이전트를 계속 붙든 세션은 턴마다 에이전트가 돌아 스레드가 5시간 동안 9개 쌓였다(형 2026-10-07)
sdir = Path(rec["stateDir"])
for m in ("9801", "9802", "9803"):
    ms._progress(rec, {"message_id": m, "text": f"지시 {m}"})
tids = json.loads((sdir / "threads.json").read_text())
npatch = lambda: [x["p"] for x in log() if x["m"] == "PATCH" and x["b"].get("archived") is True]
act = json.loads((sdir / "activity.json").read_text()) if (sdir / "activity.json").exists() else {}
act["mid"] = "9803"
(sdir / "activity.json").write_text(json.dumps(act))
tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": "<task-notification>x</task-notification>"}}) + "\n")
ms._running_agent_ids = lambda s: {"x"}
n = len(npatch())
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
check(sorted(npatch()[n:]) == sorted([f"/channels/{tids['9801']}", f"/channels/{tids['9802']}"]), f"에이전트 도는 중: 옛 스레드만 접는다: {npatch()[n:]}")
check("9803" not in json.loads((sdir / "threads-archived.json").read_text()), "최근 지시 스레드는 열어 둔다")
ms._running_agent_ids = lambda s: set()
n = len(npatch())
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
check(npatch()[n:] == [f"/channels/{tids['9803']}"], f"에이전트가 없으면 남은 것도 접는다: {npatch()[n:]}")
for m in ("9811", "9812"):
    ms._progress(rec, {"message_id": m, "text": f"지시 {m}"})
act = json.loads((sdir / "activity.json").read_text()); act.pop("mid", None)
(sdir / "activity.json").write_text(json.dumps(act))
ms._running_agent_ids = lambda s: {"x"}
n = len(npatch())
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
check(npatch()[n:] == [], f"최근 지시를 모르면 에이전트 도는 중엔 아무것도 안 접는다: {npatch()[n:]}")
ms._running_agent_ids = lambda s: set()
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
# open_thread — 이름 붙인 주제 스레드(머리 메시지 없음). 대화방 전용이고 progress 의 threads.json 과 섞이지 않는다
check("open_thread" in names, f"도구 목록: {names}")
try:
    ms.chat_tool("open_thread", {"name": "개발방"}); check(False, "개발 세션은 거부")
except ms.SessionError as exc:
    check("대화방" in str(exc), f"개발 세션 거부 문구: {exc}")
room = ms.find_session("chat/room")
os.environ["DISCORD_STATE_DIR"] = room["stateDir"]
rch = f"/channels/{room['channelId']}/threads"
ap = Path(room["stateDir"]) / "access.json"      # 방 사람(채널 플러그인이 쓰는 꼴) — 스레드에 넣어 줄 대상
acc = json.loads(ap.read_text())
acc["groups"][str(room["channelId"])]["allowFrom"] = ["111", "222"]
ap.write_text(json.dumps(acc, ensure_ascii=False))
out = ms.chat_tool("open_thread", {"name": "  cellabo  패키지 "})
mk = [x for x in log() if x["m"] == "POST" and x["p"] == rch]
check(len(mk) == 1, f"채널에 스레드 하나: {mk}")
check(mk and mk[0]["b"].get("name") == "cellabo 패키지", f"이름은 공백만 다듬어 그대로: {mk}")
check(mk and mk[0]["b"].get("type") == 11, f"공개 스레드: {mk}")
check(mk and mk[0]["b"].get("auto_archive_duration") == 10080, f"7일 열어 둔다(진행 스레드의 60분과 다름): {mk}")
check(str(ms.load_config()["guildId"]) in out and "chat_id" in out, f"링크·쓰는 법 안내: {out}")
tid_new = list(ms.room_threads(room["stateDir"]))[-1]      # 방금 만든 스레드
check(not (Path(room["stateDir"]) / "threads.json").exists(),
      "주제 스레드는 진행 스레드 장부(threads.json)를 만들지 않는다")
# 디스코드 스레드는 들어가 있는 사람 사이드바에만 뜬다 — 방 사람을 넣어 준다
joined = [x["p"] for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]]
check(joined and all(p.startswith(f"/channels/{tid_new}/thread-members/") for p in joined),
      f"만든 스레드에 방 사람을 넣는다: {joined}")
check([p.rsplit("/", 1)[-1] for p in joined] == ms.room_people(room["stateDir"], room["channelId"]) == ["111", "222"],
      f"넣는 사람 = 이 채널 허용 목록: {joined}")
check(f"{len(joined)}명" in out, f"몇 명 들어갔는지 알려 준다: {out}")
threads = ms.room_threads(room["stateDir"])
check([v.get("name") for v in threads.values()] == ["cellabo 패키지"], f"방 스레드 장부에 적힌다: {threads}")
# 봇은 스레드를 지울 수 없다 — 같은 이름을 또 부르면 만들지 않고 그 id 를 돌려준다
n = len([x for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]])
again = ms.chat_tool("open_thread", {"name": "cellabo 패키지"})
check(len([x for x in log() if x["m"] == "POST" and x["p"] == rch]) == 1, "같은 이름이면 또 만들지 않는다")
check(list(threads)[0] in again and "이미 있어" in again, f"있는 스레드를 돌려준다: {again}")
# 먼저 만들어 둔 스레드도 멤버를 채운다 — 안 그러면 사이드바에 안 뜨는 걸 고칠 길이 없다(리뷰 I-1)
redo = [x["p"] for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]][n:]
check(len(redo) == 2 and all(f"/channels/{tid_new}/thread-members/" in p for p in redo),
      f"'이미 있어' 경로도 멤버를 다시 넣는다: {redo}")
check("명이 들어가 있어" in again, f"몇 명 들어가 있는지 알려 준다: {again}")
# 넣어야 할 사람이 있는데 전부 실패하면 조용히 넘기지 않는다
(fd / "no_join").write_text("1")
fail_out = ms.chat_tool("open_thread", {"name": "cellabo 패키지"})
check("넣지 못했어" in fail_out and "스레드 목록" in fail_out, f"못 넣었으면 알려 준다: {fail_out}")
(fd / "no_join").unlink()
# 허용 목록이 비면(= 채널을 보는 모두) 아무도 안 넣고, 그래도 어떻게 열지 알려 준다
acc["groups"][str(room["channelId"])]["allowFrom"] = []
ap.write_text(json.dumps(acc, ensure_ascii=False))
check(ms.room_people(room["stateDir"], room["channelId"]) == [], "빈 허용 목록이면 넣을 사람을 모른다")
check(ms.recent_room_people(ms.Discord(ms.read_token(ms.load_config())), room["channelId"]) == [], "방에 글이 없으면 관측할 사람도 없다")
none_out = ms.chat_tool("open_thread", {"name": "cellabo 패키지"})
check("스레드 목록" in none_out and "명이 들어가" not in none_out, f"그래도 여는 법을 알려 준다: {none_out}")
# 허용 목록이 비었으면 그 방에서 최근에 말한 사람(봇 제외)을 넣는다 — 역할 없는 서버 주인도 빠지지 않게
(fd / "messages.json").write_text(json.dumps({str(room["channelId"]): [
    {"id": "500", "author": {"id": "333", "username": "u", "bot": False}, "type": 0, "content": "a"},
    {"id": "501", "author": {"id": "B1", "username": "bot", "bot": True}, "type": 0, "content": "b"},
    {"id": "502", "author": {"id": "444", "username": "v", "bot": False}, "type": 0, "content": "c"}]}))
check(ms.recent_room_people(ms.Discord(ms.read_token(ms.load_config())), room["channelId"]) == ["444", "333"], "봇을 빼고 최근 순")
n = len([x for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]])
obs_out = ms.chat_tool("open_thread", {"name": "cellabo 패키지"})
obs = [x["p"].rsplit("/", 1)[-1] for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]][n:]
check(obs == ["444", "333"] and "2명이 들어가 있어" in obs_out, f"관측한 사람을 넣는다: {obs} / {obs_out}")
# 형이 실제로 밟은 조합 — 새 이름 + 빈 허용 목록(그때 멤버가 봇 1명뿐이었다)
n = len([x for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]])
fresh_out = ms.chat_tool("open_thread", {"name": "sidebar-test"})
fresh = [x["p"].rsplit("/", 1)[-1] for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]][n:]
check(fresh == ["444", "333"] and "2명이 들어가 있어" in fresh_out, f"새 스레드도 사람이 들어간다: {fresh}")
# 이미 사람이 있는 스레드를 다시 열면 명단을 다시 붓지 않는다 — Leave Thread 를 누른 사람을 끌어오지 않게
(fd / "channels.json").write_text(json.dumps({t: {"id": t, "type": 11, "parent_id": str(room["channelId"]),
                                                  "member_count": 3} for t in ms.room_threads(room["stateDir"])}))
n = len([x for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]])
back = ms.chat_tool("open_thread", {"name": "sidebar-test"})
check([x for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]][n:] == [] and "이미 사람이" in back,
      f"이미 사람이 있으면 다시 넣지 않는다: {back}")
(fd / "channels.json").unlink()
(fd / "messages.json").unlink()
# 허용 목록이 있는 방은 관측하지 않는다(= GET messages 조회가 아예 없다)
acc["groups"][str(room["channelId"])]["allowFrom"] = ["111"]
ap.write_text(json.dumps(acc, ensure_ascii=False))
g = len([x for x in log() if x["m"] == "GET" and "/messages?" in x["p"]])
ms.chat_tool("open_thread", {"name": "declared-only"})
check(len([x for x in log() if x["m"] == "GET" and "/messages?" in x["p"]]) == g,
      "허용 목록이 있으면 최근 글을 긁지 않는다")
# 열어 달라고 한 사람은 반드시 넣는다 — 상한에 밀려 빠지면 안 된다(형 2026-10-21)
(fd / "messages.json").write_text(json.dumps({str(room["channelId"]): [
    {"id": "600", "author": {"id": "999", "username": "asker", "bot": False}, "type": 0, "content": "열어줘"}]}))
ms._write_json(Path(room["stateDir"]) / "activity.json", {"mid": "600", "marked": {}, "ever": {}, "chans": {}})
check(ms.asker_id(ms.Discord(ms.read_token(ms.load_config())), room["stateDir"], room["channelId"]) == "999",
      "지금 지시한 사람을 Discord 에 물어 가린다")
acc["groups"][str(room["channelId"])]["allowFrom"] = ["111", "222", "333", "444", "555"]   # 상한(5) 꽉 찬 방
ap.write_text(json.dumps(acc, ensure_ascii=False))
n = len([x for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]])
ms.chat_tool("open_thread", {"name": "cellabo 패키지"})
got = [x["p"].rsplit("/", 1)[-1] for x in log() if x["m"] == "PUT" and "/thread-members/" in x["p"]][n:]
check(got[0] == "999" and len(got) == ms.ROOM_PEOPLE_MAX + 1,
      f"지시한 사람은 명단 상한 밖에서 따로 넣는다(상한에 밀려 빠지면 안 되니까): {got}")
ms._write_json(Path(room["stateDir"]) / "activity.json", {"mid": "", "marked": {}, "ever": {}, "chans": {}})
(fd / "messages.json").unlink()
acc["groups"][str(room["channelId"])]["allowFrom"] = ["111", "222"]
ap.write_text(json.dumps(acc, ensure_ascii=False))
acc["groups"][str(room["channelId"])]["allowFrom"] = ["111", "222"]
ap.write_text(json.dumps(acc, ensure_ascii=False))
for bad in ({}, {"name": "   "}, {"name": "a" * 91}, {"name": "@everyone"}, {"name": "a<b>c"}, {"name": "보\u200b이지\u200b않는"}):
    try:
        r = ms.chat_tool("open_thread", bad)
        check(bad.get("name", "").startswith("보"), f"잘못된 이름 통과: {bad} → {r}")
    except ms.SessionError:
        pass
posts = [x for x in log() if x["m"] == "POST" and x["p"] == rch]
check(posts[-1]["b"].get("name") == "보이지않는", f"보이지 않는 문자는 지운다: {posts[-1]}")
ms.chat_tool("open_thread", {"name": "두 줄\n이름"})
last = [x for x in log() if x["m"] == "POST" and x["p"] == rch][-1]["b"].get("name")
check(last == "두 줄 이름", f"줄바꿈은 공백으로: {last!r}")
(fd / "no_threads").write_text("1")
try:
    ms.chat_tool("open_thread", {"name": "권한없음"}); check(False, "403 이면 실패해야")
except ms.SessionError as exc:
    check("권한" in str(exc), f"403 안내: {exc}")
(fd / "no_threads").unlink()
os.environ["DISCORD_STATE_DIR"] = rec["stateDir"]
(fd / "no_threads").write_text("1")
(fd / "no_forum").write_text("1")          # 포럼도 못 쓰는 서버에서 옛 스레드마저 막힌 경우
msg = ms.chat_tool("progress", {"message_id": "9003", "text": "x"})
check("권한" in msg and "edit_message" in msg, f"권한 없을 때 안내: {msg}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-progress"
