#!/usr/bin/env bash
# 방 이름 바꾸기 — 자동으로 줄인 이름이 거슬리면 형이 직접 고친다(형 결정 2026-08-18).
#
# 저장은 **워크트리 별칭**에 한다. 별칭은 웹 대시보드가 이미 쓰는 자리라, 새 저장소를 만들면
# 같은 것이 두 군데 살고 웹에서 고친 이름과 폰에서 고친 이름이 갈라진다.
# 다만 웹이 쓰는 /api/meta 는 호스트 가드 뒤라 폰(펀넬)에서 못 부른다 — 그래서 모바일 통로가 따로 있다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$HERE" <<'PY'
import sys
from pathlib import Path

import marina_mobile as mm
import marina_sessions as ms
from marina_paths import read_meta

root = Path(sys.argv[1]).resolve()
ms.discover_all_roots = lambda refresh=False: [root]

# ⓪ 등록 안 된 워크트리는 거부 — 임의 경로에 쓰게 두면 안 된다(핀·접기와 같은 가드).
try:
    mm.mobile_rename_room({"root": "/tmp/남의폴더", "name": "x"})
    raise SystemExit("FAIL: 등록 안 된 경로의 이름을 바꿨다")
except ValueError:
    pass

# ① 저장된다. 앞뒤·가운데 공백은 다듬는다(폰 자판에서 잘 딸려 온다).
out = mm.mobile_rename_room({"root": str(root), "name": "  슬랙   분석  "})
assert out["ok"] is True and out["name"] == "슬랙 분석", out

# ② **웹과 같은 자리**에 저장됐다 — 두 화면이 다른 이름을 보면 안 된다.
assert read_meta(root).get("alias") == "슬랙 분석", read_meta(root)

# ③ 빈 이름은 **지우기**다 — 자동 이름으로 돌아간다(형이 되돌릴 길이 있어야 한다).
out = mm.mobile_rename_room({"root": str(root), "name": "   "})
assert out["ok"] is True and out["name"] == "", out
assert not read_meta(root).get("alias")

# ④ 너무 긴 이름은 잘린다. **돌려주는 값이 실제로 저장된 값과 같아야** 한다 —
# 화면은 이 값을 그대로 그리므로, 다르면 폰에는 긴 이름이 보이고 다음 폴에 짧게 바뀐다.
out = mm.mobile_rename_room({"root": str(root), "name": "가" * 200})
assert out["name"] == read_meta(root).get("alias"), (out["name"], read_meta(root))
assert 0 < len(out["name"]) < 200, len(out["name"])

# ⑤ 이름을 바꾸면 방 목록에 **바로** 반영된다(별칭이 방 이름의 첫 순위다).
mm.worktree_labels = lambda value: {"id": "wt-1", "alias": read_meta(root).get("alias", ""),
                                    "projectLabel": "p"}
mm.discover_all_roots = lambda refresh=False: [root]
mm.agents_payload = lambda root_arg, refresh=False, include_all=False, limit=None: []
mm.term_list = lambda: {"sessions": []}
mm._live_agent_cwds = lambda refresh=False: set()
mm.mobile_rename_room({"root": str(root), "name": "결제 정리"})
방 = mm.mobile_state()["rooms"][0]
assert 방["name"] == "결제 정리" and 방["shortName"] == "결제 정리", 방
print("ok 이름 바꾸기: 저장·되돌리기·길이 제한·목록 반영·경로 가드")
PY

# ⑥ HTTP 표면이 붙어 있나 — 함수만 있고 배선이 없으면 폰에서 아무 일도 안 난다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_handler.py").read_text(encoding="utf-8")
assert '"/mobile/api/rename"' in src, "이름 바꾸기 엔드포인트가 라우팅에 없다"
block = src[src.find('if parsed.path == "/mobile/api/rename"'):][:400]
assert "safe_root" in block and "_require_root_access" in block, block
import marina_handler   # import 가 깨지면(이름 오타 등) 데몬이 통째로 안 뜬다
print("ok 이름 바꾸기 HTTP 표면이 붙어 있다")
PY

echo "PASS test-room-rename"
