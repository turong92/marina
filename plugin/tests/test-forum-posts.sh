#!/usr/bin/env bash
# 지시별 포럼 글(F1) — progress 첫 호출이 방 스레드 대신 프로젝트 📋작업 포럼에 글을 만든다.
#  - 포럼은 카테고리 안에 한 번만 만들고(discord.json forumChannelId·forumTags), 있으면 다시 안 만든다
#  - 제목 [task] 지시 첫 줄(100자 안) · 첫 글 = 원래 메시지 링크 + 본문 · 태그 진행중 · 형 메시지에 알림 없는 링크 답
#  - threads.json[mid] = 글 id 라 이어 쓰기가 그대로 · forum-posts.json 에 글 → {ref, mid, channelId}
#  - 포럼을 못 만들거나(403) 글을 못 만들면 옛 동작(메시지 밑 스레드)으로 — 진행이 사라지지 않는다
#  - 코덱스 방은 chat-bot 카테고리의 포럼 하나(codex.forumChannelId)
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
msess new proj feat/q --no-start >/dev/null 2>&1 || fail "new q"
msess new proj feat/cx --codex --no-start >/dev/null 2>&1 || fail "new codex"

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
def posts(path_re):
    import re
    return [x for x in log() if x["m"] == "POST" and re.fullmatch(path_re, x["p"])]
def cfg():
    return json.loads((Path(os.environ["MARINA_HOME"]) / "discord.json").read_text())

rec = ms.find_session("proj/feat/p")
rec2 = ms.find_session("proj/feat/q")
room = rec["channelId"]
(fd / "messages.json").write_text(json.dumps({room: [
    {"id": "9001", "content": "로그인 버그 고쳐줘\n세션이 자꾸 끊겨\n재현은 크롬에서"},
    {"id": "9002", "content": "x" * 300}], rec2["channelId"]: [{"id": "9101", "content": "다른 방 지시"}]}))

# 첫 progress → 포럼 만들기 + 글
ms._progress(rec, {"message_id": "9001", "text": "원인 찾는 중…"})
forums = [x for x in posts(r"/guilds/G1/channels") if x["b"].get("type") == 15]
cat = cfg()["projects"]["proj"]["categoryId"]
check(len(forums) == 1 and forums[0]["b"]["name"] == "📋작업" and forums[0]["b"]["parent_id"] == cat, f"포럼 한 번: {forums}")
check([t["name"] for t in forums[0]["b"].get("available_tags", [])] == ["진행중", "답 필요", "완료", "끊김"], "태그 4개")
fid = cfg()["projects"]["proj"].get("forumChannelId")
tags = cfg()["projects"]["proj"].get("forumTags") or {}
check(fid and set(tags) == {"진행중", "답 필요", "완료", "끊김"}, f"설정에 포럼·태그: {cfg()['projects']['proj']}")
mk = posts(rf"/channels/{fid}/threads")
check(len(mk) == 1, f"글 하나: {mk}")
b = mk[0]["b"] if mk else {}
check(b.get("name") == "[feat/p] 로그인 버그 고쳐줘", f"제목: {b.get('name')}")
check(b.get("applied_tags") == [tags.get("진행중")], f"진행중 태그: {b.get('applied_tags')}")
first = (b.get("message") or {}).get("content", "")
check(f"https://discord.com/channels/G1/{room}/9001" in first and "세션이 자꾸 끊겨" in first, f"첫 글에 링크와 본문: {first}")
check(not any(x["p"].endswith("/threads") and "/messages/" in x["p"] for x in log() if x["m"] == "POST"), "옛 스레드는 안 만든다")
tid = json.loads((Path(rec["stateDir"]) / "threads.json").read_text())["9001"]
link = [x for x in posts(rf"/channels/{room}/messages") if "📋" in x["b"].get("content", "")]
check(len(link) == 1 and f"<#{tid}>" in link[0]["b"]["content"], f"링크 답: {link}")
check(link and link[0]["b"].get("flags") == 4096 and link[0]["b"].get("message_reference", {}).get("message_id") == "9001"
      and link[0]["b"].get("allowed_mentions", {}).get("parse") == [], f"알림 없이·그 지시에 답: {link}")
fp = json.loads((Path(os.environ["MARINA_HOME"]) / "forum-posts.json").read_text())
check(fp.get(tid) == {"ref": "proj/feat/p", "mid": "9001", "channelId": room}, f"forum-posts.json: {fp}")

# 이어 쓰기 — 같은 글에, 포럼·글을 또 만들지 않는다. 이름 바꾸기는 포럼 글엔 안 쓴다
ms._progress(rec, {"message_id": "9001", "text": "테스트 통과"})
msgs = posts(rf"/channels/{tid}/messages")
check(len(msgs) == 2 and msgs[1]["b"]["content"] == "테스트 통과" and msgs[1]["b"].get("flags") == 4096, f"같은 글에 이어 쓰기: {msgs}")
check(len(posts(rf"/channels/{fid}/threads")) == 1, "글 또 안 만든다")
check(not any(x["m"] == "PATCH" and "name" in x["b"] for x in log()), "포럼 글 제목은 안 바꾼다")

# 둘째 지시: 포럼은 그대로, 제목 100자 안
ms._progress(rec, {"message_id": "9002", "text": "다음 일"})
mk = posts(rf"/channels/{fid}/threads")
check(len(mk) == 2 and len(mk[1]["b"]["name"]) <= 100, f"제목 100자 안: {mk[1:]}")
check(len([x for x in posts(r"/guilds/G1/channels") if x["b"].get("type") == 15]) == 1, "포럼은 하나")

# 지시 본문을 못 읽어도(지워진 메시지) 진행 줄로 글을 만든다
ms._progress(rec, {"message_id": "9999", "text": "본문 없는 지시"})
mk = posts(rf"/channels/{fid}/threads")
check(len(mk) == 3 and mk[2]["b"]["name"].startswith("[feat/p] "), f"본문을 모를 때: {mk[2:]}")

# 다른 방(같은 프로젝트)은 같은 포럼
ms._progress(rec2, {"message_id": "9101", "text": "q 진행"})
mk = posts(rf"/channels/{fid}/threads")
check(len(mk) == 4 and mk[3]["b"]["name"] == "[feat/q] 다른 방 지시", f"같은 포럼에 다른 방 글: {mk[3:]}")

# 코덱스 방 — chat-bot 카테고리의 포럼 하나
rc = ms.find_session("proj/feat/cx")
ms._progress(rc, {"message_id": "9201", "text": "코덱스 진행"})
cf = cfg().get("codex", {}).get("forumChannelId")
fs = [x for x in posts(r"/guilds/G1/channels") if x["b"].get("type") == 15]
check(cf and len(fs) == 2 and fs[1]["b"]["parent_id"] == cfg()["codex"]["categoryId"], f"코덱스 포럼: {fs[1:]} {cfg().get('codex')}")
check(len(posts(rf"/channels/{cf}/threads")) == 1, "코덱스 글")

# 폴백 1: 포럼을 못 만든다(403) → 옛 스레드. 설정에 포럼을 적지 않는다
(fd / "no_forum").write_text("1")
rec3 = ms.find_session("proj/feat/p")
cfg_now = cfg(); cfg_now["projects"]["proj"].pop("forumChannelId"); cfg_now["projects"]["proj"].pop("forumTags")
(Path(os.environ["MARINA_HOME"]) / "discord.json").write_text(json.dumps(cfg_now))
out = ms._progress(rec3, {"message_id": "9301", "text": "폴백 진행"})
old = posts(rf"/channels/{room}/messages/9301/threads")
check(len(old) == 1, f"포럼을 못 만들면 옛 스레드: {old}")
tid3 = json.loads((Path(rec["stateDir"]) / "threads.json").read_text()).get("9301")
check(tid3 and len(posts(rf"/channels/{tid3}/messages")) == 1, "진행 줄은 옛 스레드에 간다")
check("forumChannelId" not in cfg()["projects"]["proj"], "실패한 포럼은 설정에 안 남긴다")
check(tid3 not in json.loads((Path(os.environ["MARINA_HOME"]) / "forum-posts.json").read_text()), "옛 스레드는 forum-posts 에 안 넣는다")

# 폴백 2: 포럼은 있는데 글 만들기가 막힌다 → 옛 스레드
cfg_now = cfg(); cfg_now["projects"]["proj"]["forumChannelId"] = fid; cfg_now["projects"]["proj"]["forumTags"] = tags
(Path(os.environ["MARINA_HOME"]) / "discord.json").write_text(json.dumps(cfg_now))
# 포럼이 Discord 에 아직 있도록 fake 의 채널 목록에는 남아 있다
ms._progress(rec3, {"message_id": "9302", "text": "글만 막힘"})
check(len(posts(rf"/channels/{room}/messages/9302/threads")) == 1, "글 만들기 실패 → 옛 스레드")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
PY
echo "PASS test-forum-posts"
