#!/usr/bin/env bash
# mobile_state 가 **방에서 파생**된다 — 스펙 §1 "Room 이 진실, 기존은 파생".
#
# 반대로(세션 목록에서 방을 조립) 하면 두 벌이 생기고 상태 판정이 또 갈라진다. 그래서 방을
# 먼저 계산하고, 세션 목록은 같은 자료에서 평탄화한다. **응답 스키마는 그대로** 두므로
# 기존 모바일 테스트가 그대로 안전망이 된다(화면을 한꺼번에 갈아엎지 않는다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$HERE" <<'PY'
import sys
from pathlib import Path

import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.discover_all_roots = lambda refresh=False: [root]
mm.worktree_labels = lambda value: {
    "id": "wt-1", "alias": "결제정리", "projectId": "p1", "projectLabel": "mdc-main",
    "source": "registry", "sessionTitle": "결제 플로우 정리",
}
mm.agents_payload = lambda root_arg, refresh=False, include_all=False, limit=None: [
    {"source": "claude", "sid": "s1", "title": "결제 플로우 정리", "status": "working",
     "ts": 100, "preview": "고치는 중"},
]
mm.term_list = lambda: {"sessions": []}
mm.mobile_pending_question = lambda source, sid: None
mm._live_agent_cwds = lambda refresh=False: set()
mm.room_has_changes = lambda root_arg, **kw: False

state = mm.mobile_state()

# ① 방이 응답에 있다.
assert "rooms" in state, list(state)
room = state["rooms"][0]
assert room["name"] == "결제정리" and room["status"] == "작업중", room
assert [tab["sid"] for tab in room["tabs"]] == ["s1"], room["tabs"]

# ② **기존 스키마가 그대로다** — 화면을 아직 안 고쳤으므로 여기서 깨지면 모바일이 죽는다.
session = next(s for s in state["sessions"] if s["kind"] == "agent")
for key in ("key", "kind", "root", "title", "subtitle", "preview", "source", "sid",
            "target", "ts", "status", "statusTs", "tid", "controllable", "settings",
            "pendingQuestion", "externalActive"):
    assert key in session, f"기존 세션 키가 사라졌다: {key}"
assert session["key"] == f"agent:claude:s1:{root}", session["key"]
assert session["status"] == "working", "세션의 status 는 **캐논 그대로**여야 한다(화면이 아직 그걸 쓴다)"
assert state["worktrees"][0]["alias"] == "결제정리"

# ③ 방과 세션이 **같은 사실**을 말한다 — 두 벌로 갈라지지 않았는지.
assert room["tabs"][0]["title"] == session["title"]
assert room["lastAt"] == session["ts"]

# ④ 완료 판정에 쓰는 git 은 **completed 가 있을 때만** 부른다 — 완료/대기를 가르는 데만
# 쓰이는 값이라, 나머지 워크트리에서 돌리는 건 순수한 낭비다.
불렀나 = []
mm.room_has_changes = lambda root_arg, **kw: 불렀나.append(root_arg) or False
mm.mobile_state()
assert not 불렀나, "작업중인데 완료 판정하러 git 을 불렀다"

mm.agents_payload = lambda root_arg, refresh=False, include_all=False, limit=None: [
    {"source": "claude", "sid": "s1", "title": "A", "status": "completed", "ts": 100},
]
mm.mobile_state()
assert 불렀나, "completed 인데 변경 여부를 안 봤다 — 완료를 가릴 수 없다"

# ⑤ 방 계산이 터져도 화면은 살아야 한다 — 방은 부가정보지 목록의 생명줄이 아니다.
def 폭발(*args, **kwargs):
    raise RuntimeError("git 폭발")


mm.room_has_changes = 폭발
state = mm.mobile_state()
assert state["sessions"], "방 계산 실패가 세션 목록을 죽였다"
assert state["rooms"] == [], state["rooms"]
print("ok mobile_state 가 방에서 파생되고 기존 스키마가 그대로다")
PY

# **실물**을 태운다 — 손으로 쓴 스텁은 실제 agents_payload/worktree_labels 보다 착해서,
# "탭 3개 컷"과 "이름이 커밋 제목으로 떨어짐" 같은 결함을 구조적으로 못 본다.
PYTHONPATH="$SCR" python3 - <<'PY'
import inspect

import marina_rooms as rooms
from marina_sessions import AGENTS_MAX_PER_ROOT, agents_payload, worktree_labels

# ① 방은 탭을 **안 자른다**. 카드는 좁아 3개로 끊지만, 방에서 자르면 4번째 대화에 도달할
# 방법이 없고 잘린 탭의 failed/blocked 가 방 상태에서 통째로 사라진다(스펙 §2 "세션은 탭").
assert "limit" in inspect.signature(agents_payload).parameters, \
    "방이 상한을 풀 방법이 없다 — 탭이 3개에서 잘린다"
source = inspect.getsource(agents_payload)
assert "entries[:AGENTS_MAX_PER_ROOT]" not in source, "상한이 여전히 고정이다"
assert AGENTS_MAX_PER_ROOT == 3   # 카드 쪽 기본값은 그대로

import marina_mobile as mm

assert "limit=0" in inspect.getsource(mm.mobile_state), "방 조립이 상한을 안 풀었다"

# ② 방 이름이 **HEAD 커밋 제목**으로 떨어지면 안 된다. worktree_labels 의 sessionTitle 은
# 세션이 없을 때 repo_head_subject 로 폴백한다 — 그걸 그대로 쓰면 방금 만든 빈 워크트리가
# 남의 커밋 작업을 하던 방처럼 보인다(세션 카드에서 이미 한 번 잡았던 오해다).
labels = {"id": "wt-7", "alias": "", "sessionTitle": "fix(mobile): 어제 누가 남긴 커밋 제목"}
빈방 = rooms.build_room(__import__("pathlib").Path("/wt"), labels, [],
                        has_changes=False, questions=lambda source, sid: None)
assert 빈방["name"] == "wt-7", f"방 이름이 커밋 제목으로 떨어졌다: {빈방['name']}"

# 대화가 있으면 그 제목을 쓴다 — 커밋 제목이 아니라 형이 시킨 일이 이름이 돼야 한다.
있는방 = rooms.build_room(__import__("pathlib").Path("/wt"), labels,
                          [{"source": "claude", "sid": "s1", "title": "결제 정리", "status": "idle", "ts": 5}],
                          has_changes=False, questions=lambda source, sid: None)
assert 있는방["name"] == "결제 정리", 있는방["name"]
print("ok 방은 탭을 안 자르고, 이름이 커밋 제목으로 떨어지지 않는다")
PY

echo "PASS test-rooms-derived-state"
