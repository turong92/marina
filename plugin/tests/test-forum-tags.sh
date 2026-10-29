#!/usr/bin/env bash
# 포럼 글 태그 전환(F2) — 진행중 → 답 필요(질문 카드) → 진행중(질문 끝) → 끊김(방이 꺼졌다 켜짐) → 진행중(이어짐) → 완료(답이 나감, 본문 복사·닫기)
#  - Claude 방: PostToolUse(reply) 훅 · 코덱스 방: marina_codex._reply
#  - 완료된 글에 같은 지시로 progress 가 오면 다시 열고 진행중
#  - 옛 스레드(폴백)면 태그 단계는 조용히 건너뛴다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
export CODEX_HOME="$TMPROOT/real-codex-home-must-not-be-used"
export MARINA_CODEX_SESSIONS="$TMPROOT/codex-sessions"
mkdir -p "$MARINA_HOME/accounts/codex-b" "$MARINA_CODEX_SESSIONS"
echo '{"tokens":{"x":1}}' > "$MARINA_HOME/accounts/codex-b/auth.json"
msess new proj feat/p --no-start >/dev/null 2>&1 || fail "new"
msess new proj feat/cx --codex --no-start >/dev/null 2>&1 || fail "new codex"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
import marina_discord_ask as ask
import marina_discord_bot as mb
import marina_discord_wake as mw
import marina_codex as mc
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
def patches(tid):
    return [x["b"] for x in log() if x["m"] == "PATCH" and x["p"] == f"/channels/{tid}"]
def dc():
    return ms.Discord(ms.read_token(ms.load_config()))
def cfg():
    return json.loads((Path(os.environ["MARINA_HOME"]) / "discord.json").read_text())

rec = ms.find_session("proj/feat/p")
sd, room = Path(rec["stateDir"]), rec["channelId"]
os.environ["DISCORD_STATE_DIR"] = str(sd)
ms._progress(rec, {"message_id": "9001", "text": "시작"})
tid = json.loads((sd / "threads.json").read_text())["9001"]
T = cfg()["projects"]["proj"]["forumTags"]
ms._write_json(sd / "activity.json", {"mid": "9001", "marked": {}, "ever": {}, "chans": {}})
check(ms.current_post(sd) == tid, "지금 지시의 글")

# 답 필요 → 진행중
ask.post_question(str(sd), room, {"questions": [{"question": "어느 쪽?", "header": "고르기", "options": [{"label": "A"}, {"label": "B"}]}]})
check(patches(tid)[-1:] == [{"applied_tags": [T["답 필요"]]}], f"질문 카드가 뜨면 답 필요: {patches(tid)}")
ask.done(sd, room)
check(patches(tid)[-1:] == [{"applied_tags": [T["진행중"]]}], f"질문이 끝나면 진행중: {patches(tid)}")
n = len(patches(tid)); ask.done(sd, room)
check(len(patches(tid)) == n, "질문이 없으면 done 은 태그를 안 건드린다")

# 끊김 → progress 가 이어지면 진행중
mw._resume_interrupted = lambda r, now, text="": True
ms.tmux_alive = lambda name: False
mb._crash_resume(rec, "proj/feat/p", room, 1.0)
check(patches(tid)[-1:] == [{"applied_tags": [T["끊김"]]}], f"방이 꺼졌다 켜지면 끊김: {patches(tid)}")
ms._progress(rec, {"message_id": "9001", "text": "이어서"})
check(patches(tid)[-1:] == [{"applied_tags": [T["진행중"]], "archived": False}], f"이어지면 진행중: {patches(tid)}")
n = len(patches(tid)); ms._progress(rec, {"message_id": "9001", "text": "계속"})
check(len(patches(tid)) == n, "진행중인 글은 progress 마다 건드리지 않는다")

# Claude 방 reply 훅 → 완료: 본문 복사 + 태그 + 닫기, 접은 목록
payload = {"tool_name": ms._REPLY_TOOL, "tool_input": {"chat_id": room, "text": "끝 보고입니다", "reply_to": "9001"}}
ms.hook_reply_done(payload)
copy = [x["b"] for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{tid}/messages"][-1]
check(copy["content"] == "✅ 끝 보고입니다" and copy.get("flags") == 4096, f"답 본문 복사: {copy}")
check(patches(tid)[-1:] == [{"applied_tags": [T["완료"]], "archived": True}], f"완료·닫기: {patches(tid)}")
check("9001" in json.loads((sd / "threads-archived.json").read_text()), "접은 목록에 적는다(턴 끝이 다시 안 접게)")
# 다른 도구·reply_to 없는 답·글이 없는 지시는 아무것도 안 한다
n = len(log())
ms.hook_reply_done({"tool_name": "Bash", "tool_input": {"reply_to": "9001"}})
ms.hook_reply_done({"tool_name": ms._REPLY_TOOL, "tool_input": {"chat_id": room, "text": "x"}})
ms.hook_reply_done({"tool_name": ms._REPLY_TOOL, "tool_input": {"chat_id": room, "text": "x", "reply_to": "7777"}})
check(len(log()) == n, "해당 없으면 Discord 를 안 부른다")
# 완료된 글에 같은 지시로 progress → 다시 열고 진행중
ms._progress(rec, {"message_id": "9001", "text": "추가 질문이 왔어"})
check(patches(tid)[-1:] == [{"applied_tags": [T["진행중"]], "archived": False}], f"완료된 글 재개: {patches(tid)}")
check("9001" not in json.loads((sd / "threads-archived.json").read_text()), "접은 목록에서 뺀다")

# 완료된 글에 늦게 간 에이전트 줄(봇이 progress 로 올리고 _rearchive 로 다시 닫는다)이 완료 태그를 풀지 않는다
ms.hook_reply_done(payload)
ms._progress(rec, {"message_id": "9001", "text": "늦게 끝난 서브에이전트"})
mb._rearchive(rec, "9001", "완료")
check(patches(tid)[-1:] == [{"applied_tags": [T["완료"]], "archived": True}], f"다시 닫을 때 한 번에 완료 태그까지(닫은 뒤 태그만은 거절된다): {patches(tid)[-2:]}")

# 이미 닫힌 글에 태그만 바꾸면 Discord 가 거절한다(50083) — 잠깐 열어 태그를 달고 도로 닫는다
def state(t):
    return next(c for c in dc().list_channels(ms.load_config()["guildId"]) if c["id"] == t)
ms.set_post_state(dc(), tid, "", archived=True)
n = len(patches(tid))
check(ms.set_post_state(dc(), tid, "답 필요"), "닫힌 글도 태그는 바뀐다")
check(state(tid).get("applied_tags") == [T["답 필요"]] and state(tid).get("archived") is True, f"태그 바뀌고 닫힌 채: {state(tid)}")
check(patches(tid)[n:] == [{"applied_tags": [T["답 필요"]]}, {"applied_tags": [T["답 필요"]], "archived": False}, {"archived": True}], f"거절되면 열고 달고 닫기: {patches(tid)[n:]}")
ms.set_post_state(dc(), tid, "완료", archived=True)

# PostToolUse 의 tool_input 에 reply_to 가 안 실려도(PreToolUse 가 채운 값은 안 올 수 있다) 같은 규칙으로 보완 —
# 방 채널로 간 reply 는 그 채널에서 Claude 가 읽은 마지막 지시에 대한 답. 다른 채널·읽은 지시 없음이면 완료로 오인하지 않는다
ms._progress(rec, {"message_id": "9001", "text": "또 이어서"})
def tagline(m, c): return f'<channel source="plugin:discord:discord" chat_id="{c}" message_id="{m}" user="u" user_id="U1">\nx\n</channel>'
trn = sd / "t.jsonl"
trn.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": tagline("9001", room)}}) + "\n")
n = len(patches(tid))
ms.hook_reply_done({"tool_name": ms._REPLY_TOOL, "transcript_path": str(trn), "tool_input": {"chat_id": "555", "text": "딴 채널"}})
check(len(patches(tid)) == n, "방 밖 채널로 간 reply 는 완료가 아니다")
ms.hook_reply_done({"tool_name": ms._REPLY_TOOL, "transcript_path": str(sd / "none.jsonl"), "tool_input": {"chat_id": room, "text": "읽은 지시 없음"}})
check(len(patches(tid)) == n, "읽은 지시가 없으면 완료가 아니다")
ms.hook_reply_done({"tool_name": ms._REPLY_TOOL, "transcript_path": str(trn), "tool_input": {"chat_id": room, "text": "reply_to 없이 온 끝 보고"}})
check(patches(tid)[-1:] == [{"applied_tags": [T["완료"]], "archived": True}], f"reply_to 가 없어도 방 채널 reply 는 마지막 지시의 완료: {patches(tid)[-2:]}")

# 코덱스 방: _reply → 완료
rc = ms.find_session("proj/feat/cx")
csd = Path(rc["stateDir"])
ms._progress(rc, {"message_id": "9201", "text": "코덱스 시작"})
ctid = json.loads((csd / "threads.json").read_text())["9201"]
CT = cfg()["codex"]["forumTags"]
dc = ms.Discord(ms.read_token(ms.load_config()))
mc._reply(rc, dc, "x", {"chat_id": rc["channelId"], "text": "코덱스 답", "reply_to": "9201"})
check(patches(ctid)[-1:] == [{"applied_tags": [CT["완료"]], "archived": True}], f"코덱스 완료: {patches(ctid)}")
check([x["b"]["content"] for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{ctid}/messages"][-1] == "✅ 코덱스 답", "코덱스 답 복사")
check(len([b for b in patches(ctid) if b.get("archived") is True]) == 1, "닫기는 한 번만(close_instruction 이 또 안 접는다)")

# 옛 스레드(폴백): 태그 단계 없음
(fd / "no_forum").write_text("1")
rec2 = dict(rec)
c2 = cfg(); c2["projects"]["proj"].pop("forumChannelId", None); (Path(os.environ["MARINA_HOME"]) / "discord.json").write_text(json.dumps(c2))
ms._progress(rec, {"message_id": "9301", "text": "폴백"})
old = json.loads((sd / "threads.json").read_text())["9301"]
ms._write_json(sd / "activity.json", {"mid": "9301", "marked": {}, "ever": {}, "chans": {}})
check(ms.current_post(sd) == "", "옛 스레드는 글이 아니다")
ms.hook_reply_done({"tool_name": ms._REPLY_TOOL, "tool_input": {"chat_id": room, "text": "끝", "reply_to": "9301"}})
check(patches(old) == [], f"옛 스레드엔 아무것도 안 한다: {patches(old)}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
PY
echo "PASS test-forum-tags"
