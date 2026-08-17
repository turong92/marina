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

echo "PASS test-rooms-model"
