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

# ① 접으면 기록된다 — 접을 때의 상태까지 **서버가 직접 재서** 같이 적는다.
# 폰이 보낸 값을 믿으면 규칙 전체가 클라이언트 손에 넘어간다(안 보내면 완료로 접은 방이
# 다음 폴에 바로 펴지고, "완료"를 보내면 영원히 안 펴지는 방을 만들 수 있다).
mm.current_room_mark = lambda root_arg: "q:tok-1"
out = mm.mobile_set_archived({"root": str(root), "archived": True, "status": "완료(거짓말)"})
assert out["ok"] is True and out["archived"] is True, out
archive = mm.room_archive()
assert archive[str(root)]["at"] > 0 and archive[str(root)]["mark"] == "q:tok-1", archive

# ② 부르는 내용이 그대로면 접힌 채다.
at = archive[str(root)]["at"]
assert mm.room_unarchives(root, archive, "응답필요", "q:tok-1") is False
assert mm.room_unarchives(root, archive, "작업중", "") is False
assert mm.room_unarchives(root, archive, "대기", "") is False

# ③ **새로 부르면 펴진다** — 여기가 핵심이다. 상태 문자열만 비교하면 "질문 뜬 방을 접었는데
# 더 급한 걸 새로 묻는" 경우가 통째로 사라진다(상태는 여전히 응답필요라 영영 안 펴진다).
assert mm.room_unarchives(root, archive, "응답필요", "q:tok-2") is True, \
    "같은 상태의 새 질문을 못 알아본다 — 접기가 형을 가두는 도구가 된다"
assert mm.room_unarchives(root, archive, "문제", "f:s9") is True
assert mm.room_unarchives(root, archive, "완료", "done") is True

# ③-b **활동 시각을 보지 않는다.** 답을 기다리는 질문은 트랜스크립트에 안 써져서 세션 파일
# mtime 이 안 움직인다(그래서 훅으로 따로 잡는다). 시각으로 관문을 만들면 질문이 떠도
# 통과를 못 하고, 형은 방이 안 보여 답을 못 하고, 답을 안 해서 시각이 안 움직이는 교착이 된다.
import inspect

소스 = inspect.getsource(mm.room_unarchives)
assert "last_at" not in 소스, "활동 시각 관문이 다시 생겼다 — 질문이 뜬 방이 접힌 채로 남는다"

# ③-c 완료는 **접을 때 완료였나**로 갈린다. 완료인 채로 치운 방이 다시 들이밀리면 접기가
# 무의미하다. 반대로 접어둔 뒤에 끝난 일은 보여줘야 한다.
완료로접음 = {str(root): {"at": at, "mark": "done"}}
assert mm.room_unarchives(root, 완료로접음, "완료", "done") is False

# ④ 다시 펴면 기록이 사라진다(접힘이 영원히 남으면 왜 안 보이는지 알 수 없다).
mm.mobile_set_archived({"root": str(root), "archived": False})
assert str(root) not in mm.room_archive()

# ⑤ 모르는 워크트리는 접힌 적 없다.
assert mm.room_unarchives(Path("/없는/워크트리"), mm.room_archive()) is False

# ⑥ 옛 형식(숫자만)도 읽는다 — 배포 한 번에 형이 접어둔 방이 다 펴지면 안 된다.
mm.ARCHIVE_FILE.write_text(json.dumps({str(root): 1000.0}), encoding="utf-8")
옛것 = mm.room_archive()
assert 옛것[str(root)] == {"at": 1000.0, "mark": None}, 옛것
# 무엇으로 접었는지 모르면 **부르는 것만** 편다 — 완료까지 펴면 접자마자 튀어나온다.
assert mm.room_unarchives(root, 옛것, "작업중", "") is False
assert mm.room_unarchives(root, 옛것, "완료", "done") is False
assert mm.room_unarchives(root, 옛것, "응답필요", "q:x") is True

# ⑦ 파일은 형 것만 읽는다 — 알림·설정 파일과 같은 규칙(0600).
mm.current_room_mark = lambda root_arg: "done"
mm.mobile_set_archived({"root": str(root), "archived": True})
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

# ⑬ 전체보기에서는 방에서도 꺼내진다 — 전체보기의 존재 이유가 "숨긴 걸 꺼내 정리하기"인데
# 방에서만 계속 숨기면 방으로는 영영 못 꺼낸다(한 응답 안에 두 정책이 살면 안 된다).
전체 = mm.mobile_state(include_all=True)
전체방 = 전체["rooms"][0]
assert {t["sid"] for t in 전체방["tabs"]} == {"숨김", "s2"}, 전체방["tabs"]
# 다만 **상태·지문은 숨김을 뺀 기준 그대로**다. 보는 화면에 따라 달라지면 기록은 한 벌인데
# 잣대가 두 벌이 되어, 전체보기에서 접은 방이 다음 폴에 바로 펴진다.
assert 전체방["status"] == "작업중", 전체방["status"]
assert 전체방["mark"] == mm.mobile_state()["rooms"][0]["mark"], "보는 화면에 따라 지문이 달라진다"
assert [t["hidden"] for t in 전체방["tabs"] if t["sid"] == "숨김"] == [True]

# ⑭ **전체보기에서 접었다 펴는 왕복** — 스텁이 아니라 진짜 current_room_mark 를 태운다.
# 여기가 비어 있어서 "전체보기에선 접기 버튼이 안 먹는" 결함을 테스트가 못 봤다.
mm.mobile_set_archived({"root": str(root), "archived": True})   # 서버가 직접 잰다
접힌뒤 = mm.mobile_state(include_all=True)["rooms"][0]
assert 접힌뒤["archived"] is True, "전체보기에서 접었는데 안 접힌다"
assert mm.mobile_state()["rooms"][0]["archived"] is True, "일반 화면에서도 접혀 있어야 한다"

# 새 질문이 오면 양쪽 다 펴진다.
agents([{"source": "claude", "sid": "s2", "title": "B", "status": "blocked", "ts": 95}])
assert mm.mobile_state()["rooms"][0]["archived"] is False, "새로 부르는데 접힌 채다"

# ⑮ include_all 은 숨김뿐 아니라 **세션 기간(7일)**도 바꾼다. 방 상태를 재는 두 자리가 이
# 인자를 서로 다르게 주면, 전체보기에서 접은 방이 다음 폴에 바로 펴진다 — 접기 버튼이
# 안 먹는 것으로 보인다. 그래서 스텁도 include_all 을 **실제로 흉내낸다**(안 그러면 이 결함이
# 테스트를 그냥 통과한다).
옛세션 = {"source": "claude", "sid": "오래된", "title": "옛것", "status": "failed", "ts": 10}
최근 = {"source": "claude", "sid": "s2", "title": "B", "status": "working", "ts": 95}
mm.agents_payload = (lambda root_arg, refresh=False, include_all=False, limit=None:
                     [최근, 옛세션] if include_all else [최근])
mm.mobile_hidden = lambda: []
mm.mobile_set_archived({"root": str(root), "archived": True})

기본 = mm.mobile_state()["rooms"][0]
전체 = mm.mobile_state(include_all=True)["rooms"][0]
assert 기본["status"] == 전체["status"] == "작업중", (기본["status"], 전체["status"])
assert 기본["mark"] == 전체["mark"], "보는 화면에 따라 지문이 달라진다 — 접기가 안 먹는다"
assert 기본["archived"] is True and 전체["archived"] is True, (기본["archived"], 전체["archived"])
assert {t["sid"] for t in 전체["tabs"]} == {"s2", "오래된"}, 전체["tabs"]
print("ok 아카이브: 기록·끈적한 복귀·해제·목록 반영·숨김·전체보기 왕복")
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
