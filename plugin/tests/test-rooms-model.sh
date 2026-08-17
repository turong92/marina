#!/usr/bin/env bash
# 방 모델 — 상태 접기·완료 판정·조립의 순수 계약.
#
# 스펙 §5: 새 어휘를 만들지 않고 지금 캐논 6개를 5개로 **접기만** 한다. 캐논을 그대로 두면
# 상태 판정이 두 벌로 갈라질 일이 없다(지금 겪는 문제가 바로 그것이다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_rooms import ROOM_STATUS_ORDER, room_status

# 그대로 대응되는 것들
assert room_status("working", False) == "작업중"
assert room_status("idle", False) == "대기"
assert room_status("failed", False) == "문제"
# blocked = 권한·질문 대기 → 사람이 답해야 진행된다
assert room_status("blocked", False) == "응답필요"
# waiting = 프로세스가 살아 입력을 기다림. 멤버 관점에선 blocked 와 요구가 같다(스펙 §5)
assert room_status("waiting", False) == "응답필요"

# **completed 는 두 갈래다**(스펙 §4): 바뀐 파일이 있으면 완료, 없으면 대기.
# completed 만으로 완료를 판정하면 질문만 하고 끝난 턴까지 "일 끝났어요"가 된다.
assert room_status("completed", True) == "완료"
assert room_status("completed", False) == "대기"

# 모르는 값은 대기로 — CLI 가 새 어휘를 내놔도 화면이 깨지지 않아야 한다.
assert room_status("", False) == "대기"
assert room_status("무슨상태", False) == "대기"

# 우선순위: 방 목록에서 놓치면 안 되는 순서(스펙 §2)
assert ROOM_STATUS_ORDER == ("문제", "응답필요", "작업중", "완료", "대기"), ROOM_STATUS_ORDER
print("ok 상태 접기: 6개 → 5개, completed 는 변경 유무로 갈린다")
PY

# 완료 판정의 재료 — "바뀐 파일이 있나". 방 목록 경로에서 git 을 부르는 **유일한** 자리라
# 캐시 뒤에 둔다. 폴마다 워크트리마다 git 을 돌리면 전에 잡은 "초당 git 40회"가 재현된다.
PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path

import marina_rooms as rooms

root = Path("/tmp/wt-a")
calls = []


def fake_git(args, cwd):
    calls.append(tuple(args))
    if args[:2] == ["status", "--porcelain"]:
        return fake_git.status
    if args[0] == "log":
        return fake_git.log
    return ""


fake_git.status, fake_git.log = "", ""

# ① 아무것도 없으면 False
rooms._changes_cache.clear()
assert rooms.room_has_changes(root, runner=fake_git, now=100.0) is False

# ② 미커밋 변경이 있으면 True
rooms._changes_cache.clear()
fake_git.status = " M plugin/scripts/marina_rooms.py\n?? new.txt"
assert rooms.room_has_changes(root, runner=fake_git, now=100.0) is True

# ③ 커밋까지 끝냈어도 True — base 보다 앞선 커밋이 있으면 "볼 만한 결과"가 있다.
rooms._changes_cache.clear()
fake_git.status, fake_git.log = "", "a1b2c3 첫 커밋"
assert rooms.room_has_changes(root, runner=fake_git, now=100.0) is True

# ④ 캐시: 같은 워크트리를 연달아 물어도 git 을 다시 부르지 않는다.
rooms._changes_cache.clear()
calls.clear()
rooms.room_has_changes(root, runner=fake_git, now=100.0)
first = len(calls)
assert first > 0
rooms.room_has_changes(root, runner=fake_git, now=100.0 + rooms._CHANGES_TTL_S / 2)
assert len(calls) == first, f"캐시 안인데 git 을 또 불렀다: {calls}"

# ⑤ 수명이 지나면 다시 본다 — 커밋하고 나면 곧 반영돼야 한다.
rooms.room_has_changes(root, runner=fake_git, now=100.0 + rooms._CHANGES_TTL_S + 1)
assert len(calls) > first

# ⑥ git 이 실패해도 예외를 던지지 않는다 — 깨진 워크트리 하나가 방 목록을 통째로 죽이면 안 된다.
def broken(args, cwd):
    raise OSError("git 없음")


rooms._changes_cache.clear()
assert rooms.room_has_changes(root, runner=broken, now=200.0) is False
# 실패는 캐시에 남기지 않는다 — 다음 기회에 다시 본다.
assert str(root) not in rooms._changes_cache
print("ok 변경 판정: 미커밋·앞선 커밋·캐시·실패 내성")
PY

# 방 조립 — 워크트리 하나 + 그 안의 세션들이 탭(스펙 §2).
PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path

from marina_rooms import build_room, fold_status

labels = {"id": "wt-1", "alias": "결제정리", "projectLabel": "mdc-main",
          "sessionTitle": "결제 플로우 정리", "projectId": "p1", "source": "registry"}


def no_questions(source, sid):
    return None


# ① 탭이 하나면 그 상태가 방 상태다.
room = build_room(Path("/wt"), labels, [
    {"source": "claude", "sid": "s1", "title": "결제 플로우 정리", "status": "working", "ts": 100},
], has_changes=False, questions=no_questions)
assert room["status"] == "작업중", room
assert len(room["tabs"]) == 1 and room["tabs"][0]["primary"] is True
assert room["lastAt"] == 100, room
assert room["canShip"] is False, "배포는 아직 자리만 잡아둔다(스펙 확장 지점)"

# ② 이름은 **하나**다 — 배경의 "이름이 세 번 반복된다"가 여기서 다시 나오면 안 된다.
assert room["name"] == "결제정리", room["name"]
assert "wt-1" not in room["name"] and "mdc-main" not in room["name"], room["name"]

# ③ 탭이 여럿이면 **사람 조치가 필요한 것**이 방 상태로 올라온다(스펙 §2 우선순위).
room = build_room(Path("/wt"), labels, [
    {"source": "claude", "sid": "s1", "title": "A", "status": "idle", "ts": 100},
    {"source": "codex", "sid": "s2", "title": "B", "status": "blocked", "ts": 50},
], has_changes=False, questions=no_questions)
assert room["status"] == "응답필요", room["status"]
assert len(room["tabs"]) == 2

# ④ primary = 마지막 활동이 가장 최근인 탭. 방을 열면 그게 먼저 열린다(스펙 §2).
assert room["tabs"][0]["sid"] == "s1" and room["tabs"][0]["primary"] is True
assert room["tabs"][1]["primary"] is False

# ⑤ 답을 기다리는 질문이 있으면 그 탭은 응답필요다 — 실행 중이 아니라 형 차례다.
def asking(source, sid):
    return {"token": "q1"} if sid == "s1" else None


room = build_room(Path("/wt"), labels, [
    {"source": "claude", "sid": "s1", "title": "A", "status": "working", "ts": 100},
], has_changes=False, questions=asking)
assert room["tabs"][0]["status"] == "응답필요", room["tabs"]
assert room["status"] == "응답필요"

# ⑥ 세션이 하나도 없는 워크트리도 방이다(아직 아무도 말 안 건 일감).
room = build_room(Path("/wt"), labels, [], has_changes=False, questions=no_questions)
assert room["tabs"] == [] and room["status"] == "대기", room

# ⑦ 완료는 변경 유무로 갈린다(스펙 §4) — 조립 단계에서도 그대로.
done = [{"source": "claude", "sid": "s1", "title": "A", "status": "completed", "ts": 10}]
assert build_room(Path("/wt"), labels, done, has_changes=True, questions=no_questions)["status"] == "완료"
assert build_room(Path("/wt"), labels, done, has_changes=False, questions=no_questions)["status"] == "대기"

# ⑧ 이름이 없으면 세션 제목 → id 순으로 떨어진다(빈 이름은 아무것도 못 고르게 만든다).
noname = build_room(Path("/wt"), {**labels, "alias": ""}, [], has_changes=False, questions=no_questions)
assert noname["name"] == "결제 플로우 정리", noname["name"]
bare = build_room(Path("/wt"), {"id": "wt-9"}, [], has_changes=False, questions=no_questions)
assert bare["name"] == "wt-9", bare["name"]

# ⑨ 접기 규칙 자체
assert fold_status(["대기", "작업중"]) == "작업중"
assert fold_status(["작업중", "문제"]) == "문제"
assert fold_status([]) == "대기"
print("ok 방 조립: 이름 하나·탭·우선순위·primary·질문·빈 방")
PY

echo "PASS test-rooms-model"
