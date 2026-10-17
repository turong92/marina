#!/usr/bin/env bash
# /clear 뒤 대화 ID 따라가기(2026-10-16): /clear 를 치면 claude 는 새 대화 ID 로 갈아탄다.
# 기록이 옛 ID 를 들고 있으면 다음 wake 가 `--resume <옛 ID>` 로 /clear 전 대화를 되살린다
# (#daeun 이 아홉 시간 전 말투로 답하고, 그 사이 자기가 한 말을 '다른 대화'라고 부른 사고).
# 턴 끝 훅이 살아 있는 ID 로 기록을 맞춰야 한다. 두 방이 한 폴더를 쓰므로 상태 폴더로 가린다.
# 개발 세션은 턴마다가 아니라 띄울 때 한 번 맞춘다(폴더의 지금 대화로 — 문턱을 높게 둔다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" <<'PY'
import json, os, sys
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

# 개발 세션은 맞추지 않는다 — --continue·옮긴 대화 규칙이 따로고, 매 턴 끝에 sessions.json 을
# 다시 쓰면 다른 세션의 load_sessions 가 반쯤 쓰인 파일을 읽는다(2026-10-17 진행 표시 안 떼짐)
reset()
ms.save_sessions([dict(rec, kind=None), dict(twin)])
check(ms.sync_session_id(dict(rec, kind=None), {"transcript_path": str(live)}) == "", "개발 세션 기록을 고쳤다")
check(sid("daeun") == old, f"개발 세션인데 기록이 바뀌었다: {sid('daeun')}")

# 다른 폴더의 전사·대화 ID 가 아닌 이름은 받지 않는다
reset()
elsewhere = ms.transcript_path(tmp / "other-room", new)
elsewhere.parent.mkdir(parents=True, exist_ok=True); elsewhere.write_text("", encoding="utf-8")
check(ms.sync_session_id(dict(rec), {"transcript_path": str(elsewhere)}) == "", "다른 폴더의 전사로 덮었다")
check(ms.sync_session_id(dict(rec), {"transcript_path": str(live.parent / "notauuid.jsonl")}) == "",
      "대화 ID 가 아닌 이름을 받았다")
check(ms.sync_session_id(dict(rec), {}) == "", "transcript_path 가 없는데 뭔가 했다")
check(sid("daeun") == old, f"받지 말아야 할 것들이 기록을 바꿨다: {sid('daeun')}")

# ── 개발 세션은 띄울 때 한 번 맞춘다(워크트리 하나에 세션 하나라 폴더의 지금 대화로 가린다)
wt = tmp / "worktree"; wt.mkdir()
dev = {"project": "proj", "task": "feat", "root": str(wt),
       "stateDir": str(tmp / "sd-dev"), "sessionId": old}
def put(name, cwd, mtime):
    f = ms.transcript_path(wt, name)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps({"type": "user", "cwd": cwd}) + "\n", encoding="utf-8")
    os.utime(f, (mtime, mtime))
    return f

ms.save_sessions([dict(dev)])
put(old, str(wt), 1000)
check(ms.adopt_live_session_id(dict(dev)) == "", "폴더에 자기 기록만인데 갈아탔다")

put(new, str(wt), 2000)                       # /clear 로 생긴 새 대화
d = dict(dev)
check(ms.adopt_live_session_id(d) == new, "/clear 로 갈아탄 대화를 못 받았다")
check(next(x["sessionId"] for x in ms.load_sessions() if x["task"] == "feat") == new, "기록이 안 바뀌었다")

# 남이 그 폴더에서 띄운 대화(cwd 가 다르다)는 받지 않는다
ms.save_sessions([dict(dev)])
put(other, "/somewhere/else", 3000)
check(ms.adopt_live_session_id(dict(dev)) == "", "cwd 가 다른 대화를 집었다")

# 기록된 대화가 더 새롭거나 시각이 같으면 받지 않는다
for t, why in ((4000, "기록된 대화가 더 새로운데"), (3000, "시각이 같은데")):
    ms.save_sessions([dict(dev)]); put(old, str(wt), t)
    check(ms.adopt_live_session_id(dict(dev)) == "", f"{why} 갈아탔다")

# 기록된 전사가 아직 없으면 집지 않는다 — 포크 사본은 첫 메시지 때 생긴다.
# 집으면 폴더의 최신(= 포크 원본)을 --resume 해서 형이 열고 있을 수 있는 대화에 끼어든다(리뷰 C1)
ms.transcript_path(wt, old).unlink()
ms.save_sessions([dict(dev)])
check(ms.adopt_live_session_id(dict(dev)) == "", "기록된 전사가 없는데 폴더의 최신을 집었다")

# 원본 대화(forkedFrom)는 사본보다 최신이어도 집지 않는다
put(old, str(wt), 1000); put(other, str(wt), 5000)
ms.save_sessions([dict(dev, forkedFrom=other)])
check(ms.adopt_live_session_id(dict(dev, forkedFrom=other)) == "", "포크 원본을 집었다")

# 프로젝트 메인 체크아웃이 root 면 건너뛴다(사람이 손으로 띄운 대화가 쌓이는 폴더다)
main = tmp / "main"; main.mkdir()
ms._write_json(ms.marina_home() / "projects.json", {"projects": [{"id": "proj", "root": str(main)}]})
mdev = {"project": "proj", "task": "mainwork", "root": str(main),
        "stateDir": str(tmp / "sd-main"), "sessionId": old}
ms.save_sessions([dict(mdev)])
f = ms.transcript_path(main, old); f.parent.mkdir(parents=True, exist_ok=True)
f.write_text(json.dumps({"type": "user", "cwd": str(main)}) + "\n", encoding="utf-8")
os.utime(f, (1000, 1000))
g = ms.transcript_path(main, new)
g.write_text(json.dumps({"type": "user", "cwd": str(main)}) + "\n", encoding="utf-8")
os.utime(g, (2000, 2000))
check(ms.adopt_live_session_id(dict(mdev)) == "", "메인 체크아웃 폴더에서 남의 대화를 집었다")

# 채팅방은 이 길로 짐작하지 않는다(한 폴더를 여러 방이 쓴다) — 턴 끝 훅이 맡는다
check(ms.adopt_live_session_id(dict(rec)) == "", "채팅방을 폴더의 최신 기록으로 짐작했다")

print("\n".join("FAIL: " + m for m in fail))
sys.exit(1 if fail else 0)
PY
echo "PASS test-session-sid-sync"
