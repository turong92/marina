#!/usr/bin/env bash
# /clear 뒤 대화 ID 따라가기(2026-10-16): /clear 를 치면 claude 는 새 대화 ID 로 갈아탄다.
# 기록이 옛 ID 를 들고 있으면 다음 wake 가 `--resume <옛 ID>` 로 /clear 전 대화를 되살린다
# (#daeun 이 아홉 시간 전 말투로 답하고, 그 사이 자기가 한 말을 '다른 대화'라고 부른 사고).
# 턴 끝 훅이 살아 있는 ID 로 기록을 맞춰야 한다. 두 방이 한 폴더를 쓰므로 상태 폴더로 가린다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" <<'PY'
import sys
from pathlib import Path
import marina_session as ms

fail = []
def check(ok, msg):
    if not ok:
        fail.append(msg)

tmp = Path(sys.argv[1])
root = tmp / "room"; root.mkdir()          # 두 방이 같은 root(= 전사가 한 폴더에 섞인다)
old, new = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
other = "33333333-3333-3333-3333-333333333333"
rec = {"project": "secretary", "task": "daeun", "kind": "chat", "root": str(root),
       "stateDir": str(tmp / "sd-daeun"), "sessionId": old, "channelId": "1"}
twin = {"project": "secretary", "task": "test", "kind": "chat", "root": str(root),
        "stateDir": str(tmp / "sd-test"), "sessionId": other, "channelId": "2"}
def reset():
    ms.save_sessions([dict(rec), dict(twin)])
def sid(task):
    return next(x["sessionId"] for x in ms.load_sessions() if x["task"] == task)

reset()
live = ms.transcript_path(root, new)
live.parent.mkdir(parents=True, exist_ok=True); live.write_text("", encoding="utf-8")

# 같은 ID 면 아무것도 안 쓴다
check(ms.sync_session_id(dict(rec), {"transcript_path": str(ms.transcript_path(root, old))}) == "",
      "같은 대화 ID 인데 기록을 고쳤다")

# 갈아탄 ID 는 그 방 기록만 고친다
r = dict(rec)
check(ms.sync_session_id(r, {"transcript_path": str(live)}) == new, "새 대화 ID 를 못 받았다")
check(sid("daeun") == new, f"기록이 안 바뀌었다: {sid('daeun')}")
check(sid("test") == other, "같은 폴더를 쓰는 옆 방 기록까지 건드렸다")
check(r["sessionId"] == new, "넘긴 기록(메모리)이 안 맞춰졌다")

# project/task 가 겹친 잔재가 있어도 상태 폴더로 자기 것을 고른다
reset()
ms.save_sessions([dict(rec, stateDir=str(tmp / "sd-zombie"), sessionId=other), dict(rec), dict(twin)])
check(ms.sync_session_id(dict(rec), {"transcript_path": str(live)}) == new, "잔재가 있을 때 못 고쳤다")
got = [x["sessionId"] for x in ms.load_sessions() if x["task"] == "daeun"]
check(got == [other, new], f"상태 폴더가 다른 잔재를 고쳤다: {got}")

# 다른 폴더의 전사·대화 ID 가 아닌 이름은 받지 않는다
reset()
elsewhere = ms.transcript_path(tmp / "other-room", new)
elsewhere.parent.mkdir(parents=True, exist_ok=True); elsewhere.write_text("", encoding="utf-8")
check(ms.sync_session_id(dict(rec), {"transcript_path": str(elsewhere)}) == "", "다른 폴더의 전사로 덮었다")
check(ms.sync_session_id(dict(rec), {"transcript_path": str(live.parent / "notauuid.jsonl")}) == "",
      "대화 ID 가 아닌 이름을 받았다")
check(ms.sync_session_id(dict(rec), {}) == "", "transcript_path 가 없는데 뭔가 했다")
check(sid("daeun") == old, f"받지 말아야 할 것들이 기록을 바꿨다: {sid('daeun')}")

print("\n".join("FAIL: " + m for m in fail))
sys.exit(1 if fail else 0)
PY
echo "PASS test-session-sid-sync"
