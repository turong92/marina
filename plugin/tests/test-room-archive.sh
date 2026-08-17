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

# ① 접으면 기록된다.
out = mm.mobile_set_archived({"root": str(root), "archived": True})
assert out["ok"] is True and out["archived"] is True, out
archive = mm.room_archive()
assert str(root) in archive and archive[str(root)] > 0, archive

# ② 접은 뒤로 활동이 없으면 접힌 상태다.
at = archive[str(root)]
assert mm.room_archived(root, at - 10, archive) is True

# ③ **새 활동이 생기면 저절로 펴진다** — 접어둔 방에서 응답필요가 떠도 놓치지 않게.
assert mm.room_archived(root, at + 10, archive) is False

# ④ 다시 펴면 기록이 사라진다(접힘이 영원히 남으면 왜 안 보이는지 알 수 없다).
mm.mobile_set_archived({"root": str(root), "archived": False})
assert str(root) not in mm.room_archive()

# ⑤ 모르는 워크트리는 접힌 적 없다.
assert mm.room_archived(Path("/없는/워크트리"), 0, mm.room_archive()) is False

# ⑥ 파일은 형 것만 읽는다 — 알림·설정 파일과 같은 규칙(0600).
mm.mobile_set_archived({"root": str(root), "archived": True})
assert oct(mm.ARCHIVE_FILE.stat().st_mode)[-3:] == "600"

# ⑦ 방 목록에 접힘이 실려 나온다 — 화면이 접힌 방을 접어둘 수 있어야 한다.
mm.discover_all_roots = lambda refresh=False: [root]
mm.worktree_labels = lambda value: {"id": "wt-1", "alias": "접은방", "projectLabel": "p"}
mm.agents_payload = lambda root_arg, refresh=False, include_all=False: []
mm.term_list = lambda: {"sessions": []}
mm._live_agent_cwds = lambda refresh=False: set()
room = mm.mobile_state()["rooms"][0]
assert room["archived"] is True, room

# ⑧ 활동이 생기면 목록에서도 펴져 있다(자동 복귀가 조립까지 이어지는지).
mm.agents_payload = lambda root_arg, refresh=False, include_all=False: [
    {"source": "claude", "sid": "s1", "title": "A", "status": "blocked", "ts": 9_999_999_999},
]
room = mm.mobile_state()["rooms"][0]
assert room["archived"] is False and room["status"] == "응답필요", room
print("ok 아카이브: 기록·자동 복귀·해제·목록 반영")
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
