#!/usr/bin/env bash
# 아카이브 — 끝난 일감을 접어둔다(스펙 §7).
#
# 지금 모바일의 '숨김'을 아카이브가 흡수한다. 비슷한 개념 둘을 따로 둘 이유가 없고, 숨김은
# 세션 키 단위라 "방이 단위"와 어긋난다. **새 활동이 생기면 저절로 펴진다** — 접어둔 방에서
# 응답필요가 떴는데 목록에 없으면 그걸 놓친다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$HERE" <<'PY'
import json
import sys
from pathlib import Path

import marina_mobile as mm
import marina_sessions as ms

root = Path(sys.argv[1]).resolve()
# 등록된 워크트리만 접을 수 있다 — 가드(safe_root)는 그대로 두고 등록 목록만 이 폴더로 바꾼다.
ms.discover_all_roots = lambda refresh=False: [root]

# ⓪ 등록되지 않은 경로는 거부된다 — 임의 경로에 파일을 쓰게 두면 안 된다.
try:
    mm.mobile_set_archived({"root": "/tmp/남의폴더", "archived": True})
    raise SystemExit("FAIL: 등록 안 된 경로를 접어버렸다")
except ValueError:
    pass

# ① 접으면 기록된다 — 접을 때의 상태까지 같이.
out = mm.mobile_set_archived({"root": str(root), "archived": True, "status": "작업중"})
assert out["ok"] is True and out["archived"] is True, out
archive = mm.room_archive()
assert archive[str(root)]["at"] > 0 and archive[str(root)]["status"] == "작업중", archive

# ② 접은 뒤로 활동이 없으면 접힌 채다.
at = archive[str(root)]["at"]
assert mm.room_unarchives(root, at - 10, archive, "작업중") is False

# ③ **형을 부를 일이 생기면 펴진다** — 접어둔 방의 질문을 놓치면 목록을 못 믿게 된다.
assert mm.room_unarchives(root, at + 10, archive, "응답필요") is True
assert mm.room_unarchives(root, at + 10, archive, "문제") is True

# ③-b 그러나 **아무 활동에나 펴지지는 않는다.** 작업 중인 방은 접는 순간에도 에이전트가
# 계속 움직여 lastAt 이 갱신된다 — 활동만으로 펴면 접자마자 튀어나와 버튼이 고장 나 보인다.
assert mm.room_unarchives(root, at + 10, archive, "작업중") is False
assert mm.room_unarchives(root, at + 10, archive, "대기") is False

# ③-c 완료는 **접을 때 완료였나**로 갈린다. 완료인 채로 치운 방이 파일 mtime 한 번에 다시
# 들이밀리면 접기가 무의미하다. 반대로 접어둔 뒤에 끝난 일은 보여줘야 한다.
완료로접음 = {str(root): {"at": at, "status": "완료"}}
assert mm.room_unarchives(root, at + 10, 완료로접음, "완료") is False
assert mm.room_unarchives(root, at + 10, archive, "완료") is True     # 접을 땐 작업중이었다

# ④ 다시 펴면 기록이 사라진다(접힘이 영원히 남으면 왜 안 보이는지 알 수 없다).
mm.mobile_set_archived({"root": str(root), "archived": False})
assert str(root) not in mm.room_archive()

# ⑤ 모르는 워크트리는 접힌 적 없다.
assert mm.room_unarchives(Path("/없는/워크트리"), 0, mm.room_archive()) is False

# ⑥ 옛 형식(숫자만)도 읽는다 — 배포 한 번에 형이 접어둔 방이 다 펴지면 안 된다.
mm.ARCHIVE_FILE.write_text(json.dumps({str(root): 1000.0}), encoding="utf-8")
옛것 = mm.room_archive()
assert 옛것[str(root)] == {"at": 1000.0, "status": ""}, 옛것
assert mm.room_unarchives(root, 999, 옛것, "작업중") is False

# ⑦ 파일은 형 것만 읽는다 — 알림·설정 파일과 같은 규칙(0600).
mm.mobile_set_archived({"root": str(root), "archived": True, "status": "완료"})
assert oct(mm.ARCHIVE_FILE.stat().st_mode)[-3:] == "600"

# ⑧ 방 목록에 접힘이 실려 나온다 — 화면이 접힌 방을 접어둘 수 있어야 한다.
mm.discover_all_roots = lambda refresh=False: [root]
mm.worktree_labels = lambda value: {"id": "wt-1", "alias": "접은방", "projectLabel": "p"}


def agents(items):
    mm.agents_payload = lambda root_arg, refresh=False, include_all=False, limit=None: list(items)


agents([])
mm.term_list = lambda: {"sessions": []}
mm._live_agent_cwds = lambda refresh=False: set()
room = mm.mobile_state()["rooms"][0]
assert room["archived"] is True, room

# ⑨ 작업 중인 방은 접어두면 접힌 채로 있다 — 활동만으로 펴면 접기가 무용지물이다.
agents([{"source": "claude", "sid": "s1", "title": "A", "status": "working", "ts": 9_999_999_999}])
room = mm.mobile_state()["rooms"][0]
assert room["archived"] is True and room["status"] == "작업중", room

# ⑩ 질문이 뜨면 목록에서도 펴진다 — 그리고 **기록이 지워진다**(끈적한 복귀).
agents([{"source": "claude", "sid": "s1", "title": "A", "status": "blocked", "ts": 9_999_999_999}])
room = mm.mobile_state()["rooms"][0]
assert room["archived"] is False and room["status"] == "응답필요", room
assert str(root) not in mm.room_archive(), "펴놓고 기록을 남겼다"

# ⑪ 질문은 15분이면 만료된다(pending 이 None 이 된다). 그때 방이 슬그머니 다시 접히면
# 형은 그 질문을 못 본 채로 잃는다 — 기록을 지웠으니 계속 펴져 있어야 한다.
agents([{"source": "claude", "sid": "s1", "title": "A", "status": "working", "ts": 9_999_999_999}])
room = mm.mobile_state()["rooms"][0]
assert room["archived"] is False, "부르고 나서 저절로 다시 접혔다 — 형이 못 본 채로 사라진다"

# ⑫ 숨긴 세션은 방 상태를 지배하지 못한다 — 목록에서 지운 세션 때문에 방이 영원히 "문제"로
# 남고, 방 화면에선 그걸 뺄 방법이 없었다.
agents([{"source": "claude", "sid": "숨김", "title": "A", "status": "failed", "ts": 100},
        {"source": "claude", "sid": "s2", "title": "B", "status": "working", "ts": 90}])
mm.mobile_hidden = lambda: ["claude:숨김"]
room = mm.mobile_state()["rooms"][0]
assert [t["sid"] for t in room["tabs"]] == ["s2"], room["tabs"]
assert room["status"] == "작업중", room["status"]
print("ok 아카이브: 기록·끈적한 복귀·해제·목록 반영·숨김")
PY

# ⑨ HTTP 표면이 실제로 붙어 있나 — 함수만 있고 배선이 없으면 폰에서는 아무 일도 안 난다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_handler.py").read_text(encoding="utf-8")
assert '"/mobile/api/archive"' in src, "아카이브 엔드포인트가 라우팅에 없다"
assert "mobile_set_archived" in src, "핸들러가 아카이브 함수를 안 부른다"
# 가드: 핀·숨김과 같은 경로 검사를 거쳐야 한다(남의 워크트리를 접으면 안 된다).
block = src[src.find('if parsed.path == "/mobile/api/archive"'):][:400]
assert "safe_root" in block and "_require_root_access" in block, block
# /api/* 가 아니라 /mobile/api/* 여야 폰(펀넬)에서 부를 수 있다 — 호스트 가드에 막히지 않게.
assert "/api/archive\"" not in src.replace("/mobile/api/archive", ""), "모바일 밖 경로에도 뚫렸다"
import marina_handler   # import 가 깨지면(이름 오타 등) 데몬이 통째로 안 뜬다
print("ok 아카이브 HTTP 표면이 붙어 있다")
PY

echo "PASS test-room-archive"
