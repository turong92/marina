#!/usr/bin/env bash
# 답장 못 보낸 턴 다시 깨우기(2026-10-16): #daeun 에서 MCP(캘린더·Discord)가 붙는 중이라 reply 도구가 없어
# "붙는 대로 할게요" 하고 턴이 끝났고, 아무도 다시 깨우지 않아 23분 뒤 사용자가 재촉할 때까지 멈춰 있었다.
# 턴 끝 훅이 그 지시를 다시 깨워야 한다. 깨우는 글은 입력창 허용 목록(typeable)을 통과해야 실제로 들어간다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" <<'PY'
import json, sys, time
from pathlib import Path
import marina_session as ms, marina_discord_bot as mb

fail = []
def check(ok, msg):
    if not ok:
        fail.append(msg)

typed = []
mb._spawn_type = lambda tmux, text, ch, mid, button="": typed.append(text)
tmp = Path(sys.argv[1])
sd = tmp / "sd"; sd.mkdir()
rec = {"project": "secretary", "task": "daeun", "kind": "chat", "tmux": "room-tmux",
       "stateDir": str(sd), "channelId": "7"}
tr = tmp / "tr.jsonl"

def tag(ch, mid):
    return {"type": "user", "message": {"content": [{"type": "text", "text":
            f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="{mid}" user="u">'}]}}
def plain(text):
    return {"type": "user", "message": {"content": [{"type": "text", "text": text}]}}
REPLY = {"type": "assistant", "message": {"content": [
    {"type": "tool_use", "name": ms._REPLY_TOOL, "input": {}}]}}
def wrote(*rows):
    tr.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")

# ── 답장 없이 남은 지시 찾기: 태그 없는 글(깨우기·브리핑)이 끼어도 그 지시는 아직 미답이다
wrote(tag("7", "100"))
check(ms.unanswered_mid(tr, "7") == "100", "미답 지시를 못 찾는다")
wrote(tag("7", "100"), plain(ms.NUDGE_TEXT))
check(ms.unanswered_mid(tr, "7") == "100", "깨우는 글이 끼면 미답이 아닌 줄로 본다")
wrote(tag("7", "100"), REPLY)
check(ms.unanswered_mid(tr, "7") == "", "답장을 보냈는데 미답으로 본다")
wrote(tag("9", "200"))
check(ms.unanswered_mid(tr, "7") == "", "다른 방 지시를 자기 것으로 본다")

# ── 깨우기: 같은 지시에 세 번까지, 깨운 뒤에도(태그 없는 글이 끼어도) 이어서 센다
wrote(tag("7", "100"))
check(ms.nudge_unanswered(rec, tr) is True, "답장 없이 끝난 턴을 안 깨웠다")
check(len(typed) == 1 and mb.typeable(typed[0]), f"깨우는 글이 입력창 허용 목록을 못 통과한다: {typed}")
for n in (2, 3):
    wrote(tag("7", "100"), *[plain(ms.NUDGE_TEXT)] * (n - 1))
    check(ms.nudge_unanswered(rec, tr) is True, f"{n}번째를 안 깨웠다")
wrote(tag("7", "100"), *[plain(ms.NUDGE_TEXT)] * 3)
check(ms.nudge_unanswered(rec, tr) is False, "세 번을 넘겨 계속 깨운다")
check(len(typed) == 3, f"깨운 횟수: {len(typed)}")

# ── 답장이 나간 뒤 온 다음 지시는 다시 세 번
wrote(tag("7", "100"), REPLY, tag("7", "101"))
check(ms.nudge_unanswered(rec, tr) is True, "다음 지시를 못 깨운다")

# ── 재시작 이어받기가 막 글을 넣었으면 비켜 준다(두 글이 겹쳐 들어가지 않게)
(sd / "resume-at").write_text(f"{time.time()}\n")
wrote(tag("7", "102"))
check(ms.nudge_unanswered(rec, tr) is False, "이어받기 글과 겹쳐 넣는다")
(sd / "resume-at").write_text("0\n")
check(ms.nudge_unanswered(rec, tr) is True, "오래된 이어받기 때문에 안 깨운다")

# ── 개발 세션·기록 없음·답장 끝난 턴은 건드리지 않는다
check(ms.nudge_unanswered(dict(rec, kind="dev"), tr) is False, "개발 세션까지 깨웠다")
check(ms.nudge_unanswered(rec, None) is False, "기록이 없는데 깨웠다")
wrote(tag("7", "103"), REPLY)
check(ms.nudge_unanswered(rec, tr) is False, "답장을 보낸 턴을 깨웠다")

print("\n".join("FAIL: " + m for m in fail))
sys.exit(1 if fail else 0)
PY
echo "PASS test-session-nudge-unanswered"
