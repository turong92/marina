#!/usr/bin/env bash
# 스레드에서 온 글도 '이 방 지시'로 본다 — Discord 스레드는 그 자체가 채널이라 들어오는 글의 chat_id 가 방 채널과 다르다.
# 그대로 두면 답은 가지만 표시·안전망이 전부 비껴간다(형 2026-10-20: "스레드에서 치면 그 스레드에서만 대답하게").
#  - 방 스레드 장부(room-threads.json): open_thread 가 만들 때·봇이 글을 넘길 때(wake) 적는다
#  - 진행 표시(👀·🛑)·'입력 중…'·턴 끝 떼기는 그 글이 있는 채널(= 스레드)에 한다
#  - 답장 못 한 지시 다시 깨우기는 채널별로 — 스레드에 답했다고 방의 미답이 지워지지 않는다
#  - 꺼진 방을 깨울 때 방 스레드도 함께 훑는다(스레드에 연달아 쓴 둘째 글이 유실되지 않게)
#  - 사람이 Discord 에서 직접 만든 스레드의 첫 글도 — 태그의 chat_id 는 믿지 않고 부모를 Discord 에 확인해서 입양
#  - 장부 수명: 이름 있는 주제 스레드는 답글 라우팅 항목에 밀려나지 않고, 지워진 스레드는 빠진다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/t --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
import marina_discord_wake as mw
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]

rec = ms.find_session("proj/feat/t"); sd = Path(rec["stateDir"]); ch = str(rec["channelId"])
os.environ["DISCORD_STATE_DIR"] = str(sd)
TID = "9900000000000001"
tr = sd / "t.jsonl"

def tag(mid, chan):
    return f'<channel source="plugin:discord:discord" chat_id="{chan}" message_id="{mid}" user="u" user_id="U1">\nx\n</channel>'
def urow(mid, chan):
    return json.dumps({"type": "user", "message": {"role": "user", "content": tag(mid, chan)}})
def areply(chan):
    return json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": ms._REPLY_TOOL, "input": {"chat_id": chan, "text": "답"}}]}})

# ① 장부
check(ms.room_chans(rec) == {ch}, f"처음엔 방 채널뿐: {ms.room_chans(rec)}")
ms.remember_room_thread(sd, TID, "cellabo")
check(ms.room_chans(rec) == {ch, TID}, f"적은 스레드는 이 방 채널로 본다: {ms.room_chans(rec)}")
check(ms.room_threads(sd)[TID].get("name") == "cellabo", f"이름도 적는다: {ms.room_threads(sd)}")
ms.remember_room_thread(sd, "스레드아님")
check(ms.room_chans(rec) == {ch, TID}, "숫자가 아닌 id 는 무시")
mt = (sd / ms.ROOM_THREADS).stat().st_mtime_ns
ms.remember_room_thread(sd, TID)
check((sd / ms.ROOM_THREADS).stat().st_mtime_ns == mt, "아는 스레드면 글마다 파일을 다시 쓰지 않는다")
check(ms.room_threads(sd)[TID].get("name") == "cellabo", "다시 적어도 이름이 지워지지 않는다")
(sd / ms.ROOM_THREADS).write_text("{깨")
check(ms.room_chans(rec) == {ch} and ms.room_threads(sd) == {}, "장부가 깨졌으면 방 채널만")
ms.remember_room_thread(sd, TID, "cellabo")

# ①-2 장부 수명 — 이름 있는 주제 스레드는 이름 없는 항목(답글 라우팅)에 밀려나지 않는다
for i in range(ms.ROOM_THREADS_KEEP + 5):
    ms.remember_room_thread(sd, str(9910000000000000 + i))
check(TID in ms.room_threads(sd), f"답글 라우팅 항목이 넘쳐도 주제 스레드는 남는다: {len(ms.room_threads(sd))}")
check(len([v for v in ms.room_threads(sd).values() if not v.get("name")]) == ms.ROOM_THREADS_KEEP,
      f"이름 없는 항목은 상한까지만: {len(ms.room_threads(sd))}")
# 훑는 순서 = 마지막 활동이 늦은 것이 뒤(발견순이면 매일 쓰는 스레드가 조회 창 밖으로 밀린다)
d = json.loads((sd / ms.ROOM_THREADS).read_text()); d[TID]["at"] = 1.0
(sd / ms.ROOM_THREADS).write_text(json.dumps(d))
check(ms.room_thread_ids(sd)[0] == TID, "오래 조용한 스레드는 맨 앞(= 훑을 때 뒤로 밀린다)")
ms.remember_room_thread(sd, TID)          # 글이 오면 갱신
check(ms.room_thread_ids(sd)[-1] == TID, f"방금 글이 온 스레드가 맨 뒤: {ms.room_thread_ids(sd)[-3:]}")
check(ms.room_threads(sd)[TID].get("name") == "cellabo", "갱신해도 이름은 남는다")
check(ms.forget_room_threads(sd, [TID]) == [], "이름 있는 주제 스레드는 404 한 번으로 버리지 않는다(멱등성 열쇠)")
plain = ms.room_thread_ids(sd)[0]
check(ms.forget_room_threads(sd, [plain, TID]) == [plain], "이름 없는 라우팅 항목만 빠진다")
check(TID in ms.room_threads(sd) and plain not in ms.room_threads(sd), "주제 스레드는 남는다")
check(ms.forget_room_threads(sd, [TID], keep_named=False) == [TID], "확인한 뒤에는 주제 스레드도 뺀다")
ms.remember_room_thread(sd, TID, "cellabo")
(sd / ms.ROOM_THREADS).write_text(json.dumps({TID: {"name": "cellabo", "at": 1.0}}))

# ② 판정 — 방 글과 스레드 글을 짝으로 읽는다
tr.write_text(urow("7001", ch) + "\n" + urow("7002", TID) + "\n")
check(ms.inbound_pairs(tr, ms.room_chans(rec)) == [("7001", ch), ("7002", TID)],
      f"글마다 그 글이 있는 채널: {ms.inbound_pairs(tr, ms.room_chans(rec))}")
check(ms.inbound_messages(tr, ch) == ["7001"], "채널 하나만 주면 그 채널만(기존 호출 그대로)")
check(ms.inbound_messages(tr, ms.room_chans(rec)) == ["7001", "7002"], "방+스레드")
check(ms._turn_from_terminal(tr, ms.room_chans(rec)) is False, "스레드 글로 열린 턴은 터미널에서 친 말이 아니다")
tr.write_text(urow("7002", TID) + "\n")
check(ms._turn_from_terminal(tr, ms.room_chans(rec)) is False, "스레드 글만 있어도 Discord 턴")
check(ms._turn_from_terminal(tr, "7777777") is True, "모르는 채널 글이면 터미널 턴")

# ③ 미답 — 답한 채널의 것만 지운다
tr.write_text(urow("7001", ch) + "\n" + urow("7002", TID) + "\n" + areply(TID) + "\n")
check(ms.unanswered_mid(tr, ms.room_chans(rec)) == "7001",
      f"스레드에 답했으니 방 지시는 아직 미답: {ms.unanswered_mid(tr, ms.room_chans(rec))}")
tr.write_text(urow("7001", ch) + "\n" + areply(ch) + "\n" + urow("7002", TID) + "\n")
check(ms.unanswered_mid(tr, ms.room_chans(rec)) == "7002", "방에 답했어도 스레드 지시는 미답")
tr.write_text(urow("7001", ch) + "\n" + urow("7002", TID) + "\n" + areply(ch) + "\n" + areply(TID) + "\n")
check(ms.unanswered_mid(tr, ms.room_chans(rec)) == "", "둘 다 답하면 깨울 것 없음")

# ④ 진행 표시·'입력 중…' 은 그 글이 있는 채널에
tr.write_text(urow("7002", TID) + "\n")
ms.hook_activity({"tool_name": "Read", "tool_input": {"file_path": "/a/b.py"}, "transcript_path": str(tr)}, min_gap=0.0)
puts = [x["p"] for x in log() if x["m"] == "PUT"]
check(any(p.startswith(f"/channels/{TID}/messages/7002/reactions/") for p in puts), f"반응은 스레드에: {puts}")
check(not any(p.startswith(f"/channels/{ch}/messages/7002/") for p in puts), f"방 채널에는 달지 않는다: {puts}")
check(any(x["m"] == "POST" and x["p"] == f"/channels/{TID}/typing" for x in log()), "'입력 중…' 도 스레드에")
st = json.loads((sd / "activity.json").read_text())
check(st.get("chans", {}).get("7002") == TID, f"뗄 때 쓸 채널을 적어 둔다: {st}")

# ⑤ 턴 끝 — 달았던 채널(스레드)에서 뗀다
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
dels = [x["p"] for x in log() if x["m"] == "DELETE"]
check(any(p.startswith(f"/channels/{TID}/messages/7002/reactions/") for p in dels), f"스레드에서 뗀다: {dels}")
check(json.loads((sd / "activity.json").read_text()).get("chans") == {}, "뗀 뒤 장부를 비운다")

# ⑤-2 장부에 없는 스레드(사람이 직접 만든 것)의 첫 글 — 부모가 이 방이면 입양해서 표시한다
NEW = "9900000000000002"
NEW2 = "9900000000000004"
(fd / "channels.json").write_text(json.dumps({NEW: {"id": NEW, "type": 11, "parent_id": ch},
                                              NEW2: {"id": NEW2, "type": 11, "parent_id": ch},
                                              "9900000000000003": {"id": "9900000000000003", "type": 11, "parent_id": "9"}}))
tr.write_text(urow("7010", NEW) + "\n")
ms.hook_activity({"hook_event_name": "UserPromptSubmit", "prompt": tag("7010", NEW), "transcript_path": str(tr)}, min_gap=0.0)
check(NEW in ms.room_threads(sd), f"부모가 이 방인 스레드는 장부에 적는다: {ms.room_threads(sd)}")
puts = [x["p"] for x in log() if x["m"] == "PUT"]
check(any(p.startswith(f"/channels/{NEW}/messages/7010/reactions/") for p in puts), f"첫 글에도 👀: {puts[-3:]}")
# 부모가 다른 채널이면 입양하지 않는다 — 태그의 chat_id 를 믿으면 엉뚱한 채널에 쏘게 된다
OTHER = "9900000000000003"
tr.write_text(urow("7011", OTHER) + "\n")
ms.hook_activity({"hook_event_name": "UserPromptSubmit", "prompt": tag("7011", OTHER), "transcript_path": str(tr)}, min_gap=0.0)
check(OTHER not in ms.room_threads(sd), f"남의 채널은 입양하지 않는다: {ms.room_threads(sd)}")
check(not any(f"/channels/{OTHER}/messages/" in p for p in [x["p"] for x in log() if x["m"] == "PUT"]),
      "남의 채널에는 반응을 달지 않는다")

# ⑤-2b 입양 비용 — 아는 글이 있으면 모르는 채널을 묻지 않는다(훅 예산을 표시보다 뒤에 두지 않게)
def gets():
    return [x["p"] for x in log() if x["m"] == "GET" and x["p"].count("/") == 2 and x["p"].startswith("/channels/")]
FAR = "9900000000000009"
n = len(gets())
tr.write_text(urow("7012", TID) + "\n")
ms.hook_activity({"hook_event_name": "UserPromptSubmit",
                  "prompt": tag("7012", TID) + tag("7013", FAR), "transcript_path": str(tr)}, min_gap=0.0)
check(len(gets()) == n, f"아는 글이 있으면 모르는 채널은 묻지 않는다: {gets()[n:]}")
check(FAR not in ms.room_threads(sd), "그래서 장부에도 안 들어간다(다음 턴에 그 글만 오면 그때 묻는다)")
# 모르는 채널이 여러 개여도 한 턴에 하나만, 가장 최근 태그부터(가짜 chat_id 로 창을 못 막게)
n = len(gets())
tr.write_text(urow("7014", NEW2) + "\n")
ms.hook_activity({"hook_event_name": "UserPromptSubmit",
                  "prompt": tag("1", "1") + tag("2", "2") + tag("7014", NEW2), "transcript_path": str(tr)}, min_gap=0.0)
check(len(gets()) - n == ms.ADOPT_PER_TURN, f"한 턴에 {ms.ADOPT_PER_TURN}개만 묻는다: {gets()[n:]}")
check(NEW2 in ms.room_threads(sd), f"가짜 id 가 앞서도 진짜 새 스레드를 입양한다: {gets()[n:]}")

# ⑤-3 reply_to 채우기 — 그 스레드에서 온 마지막 지시로(방 채널 글을 스레드 답장에 달면 Discord 가 거절한다)
tr.write_text(urow("7001", ch) + "\n" + urow("7002", TID) + "\n")
r = ms.hook_reply_to({"tool_name": ms._REPLY_TOOL, "tool_input": {"chat_id": TID, "text": "x"},
                      "transcript_path": str(tr)})
check((r or {}).get("hookSpecificOutput", {}).get("updatedInput", {}).get("reply_to") == "7002",
      f"스레드 답장은 그 스레드 글에 단다: {r}")
r = ms.hook_reply_to({"tool_name": ms._REPLY_TOOL, "tool_input": {"chat_id": ch, "text": "x"},
                      "transcript_path": str(tr)})
check((r or {}).get("hookSpecificOutput", {}).get("updatedInput", {}).get("reply_to") == "7001",
      f"방 답장은 방 글에 단다: {r}")
check(ms.hook_reply_to({"tool_name": ms._REPLY_TOOL, "tool_input": {"chat_id": "7777777", "text": "x"},
                        "transcript_path": str(tr)}) is None, "모르는 채널엔 손대지 않는다")

# ⑤-4 권한 요청 — 스레드 턴을 '터미널에서 친 말' 로 보면 아무도 안 보는 창에서 조용히 선다
tr.write_text(urow("7002", TID) + "\n")
n = len([x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages"])
ms.hook_permission({"tool_name": "Bash", "tool_input": {"command": "ls"}, "transcript_path": str(tr)}, wait=0.1, poll=0.05)
posts = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages"][n:]
check(any("권한 요청" in str(x["b"].get("content") or "") for x in posts), f"채널에 버튼을 올린다: {posts}")

# ⑥ 꺼진 방을 깨울 때 방 스레드도 훑는다
(fd / "messages.json").write_text(json.dumps({
    ch: [{"id": "7005", "author": {"id": "U1", "username": "u"}, "type": 0, "content": "방 글"}],
    TID: [{"id": "7006", "author": {"id": "U1", "username": "u"}, "type": 0, "content": "스레드 글"}]}))
mw._save_woke(sd, baseId="7001")        # 마지막으로 읽은 글(전사 경로는 실제 세션 것이라 여기선 못 쓴다)
msgs, _ = mw.missed(rec, mw.mb._dc(ms.load_config()), since=0.0)
got = sorted((str(m["id"]), str(m.get("channel_id") or "")) for m in msgs)
check(got == [("7005", ch), ("7006", TID)], f"방 글과 스레드 글 둘 다, 각자 채널로: {got}")
gets = [x["p"] for x in log() if x["m"] == "GET" and "/messages" in x["p"]]
check(any(p.startswith(f"/channels/{TID}/messages") for p in gets), f"스레드도 조회한다: {gets}")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-room-threads"
