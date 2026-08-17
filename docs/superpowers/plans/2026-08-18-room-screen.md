# 방 화면(모바일) 구현 계획 — 2차

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 폰을 열면 **방 목록**이 첫 화면으로 뜨고, 방을 눌러 그 안의 대화(탭)로 들어가며, 방 이름을 고치고 끝난 방을 접을 수 있게 한다.

**Architecture:** 서버는 이미 방을 내려준다(1차, `mobile_state().rooms`). 이번엔 **화면만** 만든다 — 새 API 는 이름 바꾸기 하나뿐이다. 방 목록은 지금의 세션 목록을 **대체**하고(형 결정), 방을 열면 탭 줄이 뜨고 탭을 고르면 기존 대화 화면을 그대로 쓴다. 대화 화면·전송·질문 카드는 손대지 않는다 — 그게 매일 쓰는 부분이라 건드리면 위험만 크다.

**Tech Stack:** 서버 Python 3.9 표준 라이브러리, 화면은 `marina_mobile.py` 안에 박힌 HTML/JS(빌드 없음), 공유 렌더러 `marina-web/chat-render.js`.

**Spec:** `docs/superpowers/specs/2026-08-11-nondev-room-redesign-design.md`
**선행 계획:** `docs/superpowers/plans/2026-08-17-room-api.md` (완료·배포됨)

## Global Constraints

- **표준 라이브러리만.** 새 의존성 금지.
- **대화 화면은 안 건드린다.** 목록 → 방 → 탭까지만. 대화 내부(전송·질문·생각중)는 그대로 둔다.
- 형 결정(2026-08-18): **방 목록이 첫 화면**(세션 목록 대체), **이름은 자동으로 줄이고 ✎ 로 바꾸기**.
- 폰에서 부를 수 있는 표면은 `/mobile/api/*` 뿐이다 — `/api/*` 는 호스트 가드에 막혀 펀넬에서 못 부른다.
- JS 블록엔 테스트가 잡을 수 있는 표식(`// ROOM_LIST_START` …)을 남긴다. 기존 테스트들이 그 방식으로 JS 를 검사한다.
- 테스트는 `. lib/harness.sh` 로 실 `~/.marina` 격리.
- 주석·커밋은 한국어, 사용자는 "형", **왜**를 적는다.

## File Structure

| 파일 | 책임 |
|---|---|
| `plugin/scripts/marina_rooms.py` | `short_name()` 추가 — 긴 첫 프롬프트를 목록용 한 줄로 |
| `plugin/scripts/marina_mobile.py` | `mobile_rename_room()` + 방 목록/방 상세 HTML·CSS·JS |
| `plugin/scripts/marina_handler.py` | `/mobile/api/rename` 라우트 |
| `plugin/tests/test-room-name.sh` (신규) | 이름 줄이기 계약 |
| `plugin/tests/test-room-rename.sh` (신규) | 이름 바꾸기 저장·가드 |
| `plugin/tests/test-room-screen.sh` (신규) | 방 목록·방 열기·접기 JS 계약 |

---

### Task 1: 목록에 쓸 짧은 이름

**Files:**
- Modify: `plugin/scripts/marina_rooms.py`
- Test: `plugin/tests/test-room-name.sh`

**Interfaces:**
- Produces: `short_name(name: str, limit: int = 22) -> str`. `build_room` 결과에 `shortName` 키 추가.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`plugin/tests/test-room-name.sh`:

```bash
#!/usr/bin/env bash
# 방 이름 줄이기 — 목록은 한 줄이고 폰은 좁다.
#
# 실제 데이터(2026-08-18): 별칭을 안 붙인 방은 형이 처음 친 말이 통째로 이름이다.
#   "야 너 슬랙 분석 할 수 있지"  /  "너는 CRABs 결제 도메인의 시니어 엔지니어다.  목..."
# 목록에서 이게 두 줄 세 줄로 흐르면 무엇이 무엇인지 못 알아본다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_rooms import short_name

# ① 첫 줄만 쓴다 — 프롬프트는 여러 줄인 경우가 많다.
assert short_name("슬랙 분석 해줘\n조건은 아래와 같다\n- 최근 30일") == "슬랙 분석 해줘"

# ② 말 거는 군더더기는 떼어낸다("야", "너", 존댓말 호출). 이름의 정보는 그 뒤에 있다.
assert short_name("야 너 슬랙 분석 할 수 있지") == "슬랙 분석 할 수 있지"
assert short_name("야 지금 배포 파이프라인 봐줘") == "배포 파이프라인 봐줘"

# ③ 길면 자른다. 자를 때 **단어 중간에서 끊지 않는다** — 뜻이 뭉개진다.
긴것 = "너는 CRABs 결제 도메인의 시니어 엔지니어다. 목표는 환불 정합성 개선"
잘린것 = short_name(긴것)
assert len(잘린것) <= 23, (len(잘린것), 잘린것)
assert 잘린것.endswith("…"), 잘린것
assert not 잘린것.replace("…", "").endswith(" "), 잘린것

# ④ 이미 짧으면 그대로 — 형이 붙인 별칭을 건드리면 안 된다.
assert short_name("ZZe2e") == "ZZe2e"
assert short_name("결제정리") == "결제정리"

# ⑤ 빈 값은 빈 값(호출자가 id 로 떨어뜨린다).
assert short_name("") == ""
assert short_name("   \n  ") == ""

# ⑥ 군더더기만 있는 경우 원문을 지키다 — 다 떼면 이름이 사라진다.
assert short_name("야 너") == "야 너"
print("ok 이름 줄이기: 첫 줄·군더더기 제거·단어 경계·별칭 보존")
PY

echo "PASS test-room-name"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-room-name.sh`
Expected: FAIL — `ImportError: cannot import name 'short_name'`

- [ ] **Step 3: 구현**

`marina_rooms.py` 에 추가:

```python
# 말 거는 군더더기 — 목록에서 이 단어들은 방을 구별해주지 않는다. 형이 말하듯 시키기 때문에
# ("야 너 …", "야 지금 …") 첫 두어 단어가 거의 항상 같다.
_FILLER = ("야", "너", "우리", "지금", "좀", "이제")


def short_name(name: str, limit: int = 22) -> str:
    """목록 한 줄에 들어갈 이름.

    별칭을 안 붙인 방은 **형이 처음 친 말**이 통째로 이름이다. 그대로 쓰면 목록이 문장으로
    가득 차 무엇이 무엇인지 안 보인다. 첫 줄만 남기고, 말 거는 군더더기를 떼고, 길면 단어
    경계에서 자른다. 자르는 것뿐이라 원본 이름은 방 안에서 그대로 볼 수 있다."""
    text = str(name or "").strip().splitlines()
    line = text[0].strip() if text else ""
    if not line:
        return ""
    words = line.split()
    trimmed = list(words)
    while len(trimmed) > 1 and trimmed[0] in _FILLER:
        trimmed.pop(0)
    line = " ".join(trimmed) if trimmed else line
    if len(line) <= limit:
        return line
    cut = line[:limit]
    if " " in cut[1:]:
        cut = cut[:cut.rindex(" ")]
    return cut.rstrip() + "…"
```

`build_room` 의 반환에 추가(`"name": name,` 바로 아래):

```python
        # 목록은 한 줄이고 폰은 좁다 — 긴 이름은 여기서 줄인다. 원본은 name 에 그대로 있다.
        "shortName": short_name(name),
```

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-room-name.sh` → `PASS test-room-name`

- [ ] **Step 5: 실 데이터로 눈으로 본다**

Run:
```bash
PYTHONPATH=plugin/scripts python3 -c "
from marina_mobile import mobile_state
for r in mobile_state()['rooms'][:12]: print('%-24s | %s' % (r['shortName'], r['name'][:40]))"
```
Expected: 왼쪽이 한 줄로 읽히고, 오른쪽 원문과 뜻이 안 어긋난다. 어긋나면 `_FILLER` 를 고친다.

- [ ] **Step 6: 커밋**

```bash
chmod +x plugin/tests/test-room-name.sh
git add plugin/scripts/marina_rooms.py plugin/tests/test-room-name.sh
git commit -m "feat(room): 목록용 짧은 이름 — 첫 프롬프트가 통째로 이름인 방들"
```

---

### Task 2: 이름 바꾸기 (폰에서 부를 수 있는 통로)

**Files:**
- Modify: `plugin/scripts/marina_mobile.py`
- Modify: `plugin/scripts/marina_handler.py`
- Test: `plugin/tests/test-room-rename.sh`

**Interfaces:**
- Consumes: 없음
- Produces: `mobile_rename_room(body: dict) -> dict` — `{root, name}` 를 받아 워크트리 별칭으로 저장. `POST /mobile/api/rename`.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`plugin/tests/test-room-rename.sh`:

```bash
#!/usr/bin/env bash
# 방 이름 바꾸기 — 자동으로 줄인 이름이 거슬리면 형이 직접 고친다(형 결정 2026-08-18).
#
# 저장은 **워크트리 별칭**에 한다. 별칭은 웹 대시보드가 이미 쓰는 자리라, 새 저장소를 만들면
# 같은 것이 두 군데 살게 된다. 다만 웹이 쓰는 /api/meta 는 호스트 가드 뒤라 폰에서 못 부른다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$HERE" <<'PY'
import sys
from pathlib import Path

import marina_mobile as mm
import marina_sessions as ms

root = Path(sys.argv[1]).resolve()
ms.discover_all_roots = lambda refresh=False: [root]

# ⓪ 등록 안 된 워크트리는 거부 — 임의 경로에 쓰게 두면 안 된다(핀·접기와 같은 가드).
try:
    mm.mobile_rename_room({"root": "/tmp/남의폴더", "name": "x"})
    raise SystemExit("FAIL: 등록 안 된 경로의 이름을 바꿨다")
except ValueError:
    pass

# ① 저장된다.
out = mm.mobile_rename_room({"root": str(root), "name": "  슬랙 분석  "})
assert out["ok"] is True and out["name"] == "슬랙 분석", out   # 앞뒤 공백은 다듬는다

# ② 다시 읽으면 그 이름이 나온다 — 별칭 자리에 저장됐다는 뜻이다.
from marina_sessions import worktree_labels
assert worktree_labels(root).get("alias") == "슬랙 분석"

# ③ 빈 이름은 **지우기**다 — 자동 이름으로 돌아간다(형이 되돌릴 방법이 있어야 한다).
out = mm.mobile_rename_room({"root": str(root), "name": "   "})
assert out["ok"] is True and out["name"] == "", out
assert not worktree_labels(root).get("alias")

# ④ 너무 긴 이름은 자른다 — 목록이 깨지지 않게(저장 시점에 막는다).
긴이름 = "가" * 200
out = mm.mobile_rename_room({"root": str(root), "name": 긴이름})
assert len(out["name"]) <= 80, len(out["name"])
print("ok 이름 바꾸기: 저장·되돌리기·길이 제한·경로 가드")
PY

# ⑤ HTTP 표면이 붙어 있나 — 함수만 있고 배선이 없으면 폰에서 아무 일도 안 난다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_handler.py").read_text(encoding="utf-8")
assert '"/mobile/api/rename"' in src, "이름 바꾸기 엔드포인트가 라우팅에 없다"
block = src[src.find('if parsed.path == "/mobile/api/rename"'):][:400]
assert "safe_root" in block and "_require_root_access" in block, block
import marina_handler   # import 가 깨지면 데몬이 통째로 안 뜬다
print("ok 이름 바꾸기 HTTP 표면이 붙어 있다")
PY

echo "PASS test-room-rename"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-room-rename.sh`
Expected: FAIL — `AttributeError: module 'marina_mobile' has no attribute 'mobile_rename_room'`

- [ ] **Step 3: 구현**

`marina_mobile.py` 의 `mobile_set_archived` 아래에 추가:

```python
ROOM_NAME_MAX = 80          # 목록 한 줄을 넘어서는 이름은 저장 시점에 막는다


def mobile_rename_room(body: dict[str, Any]) -> dict[str, Any]:
    """방 이름을 바꾼다 — 저장 자리는 **워크트리 별칭**이다.

    별칭은 웹 대시보드가 이미 쓰는 자리다. 새 저장소를 만들면 같은 것이 두 군데 살고, 웹에서
    고친 이름과 폰에서 고친 이름이 달라진다. 빈 이름은 지우기 — 자동 이름으로 돌아간다."""
    root = safe_root(str(body.get("root") or ""))
    name = " ".join(str(body.get("name") or "").split())[:ROOM_NAME_MAX]
    write_worktree_meta(root, {"alias": name})
    return {"ok": True, "root": str(root), "name": name}
```

`write_worktree_meta` 가 없으면 `/api/meta` 핸들러가 쓰는 함수를 그대로 재사용한다 —
구현 전에 `grep -n '"/api/meta"' -A 12 marina_handler.py` 로 그 함수 이름을 확인하고 import 한다.

`marina_handler.py`:
- 모바일 POST 경로 목록에 `"/mobile/api/rename"` 추가(`/mobile/api/archive` 옆).
- 분기 추가:

```python
                    if parsed.path == "/mobile/api/rename":
                        # 핀·숨김·접기와 같은 가드 — 남의 워크트리 이름을 바꾸면 안 된다.
                        root = safe_root(str(mobile_body.get("root", "")))
                        if not self._require_root_access(root):
                            return
                        self.send_json(mobile_rename_room(mobile_body))
                        return
```
- import 에 `mobile_rename_room` 추가.

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-room-rename.sh` → `PASS test-room-rename`

- [ ] **Step 5: 회귀 확인**

Run: `cd plugin/tests && ./run-affected.sh` → `FAIL=0`

- [ ] **Step 6: 커밋**

```bash
chmod +x plugin/tests/test-room-rename.sh
git add plugin/scripts/marina_mobile.py plugin/scripts/marina_handler.py plugin/tests/test-room-rename.sh
git commit -m "feat(room): 폰에서 방 이름 바꾸기 — 저장은 웹과 같은 별칭 자리"
```

---

### Task 3: 방 목록 화면

**Files:**
- Modify: `plugin/scripts/marina_mobile.py` (HTML `#listView`, CSS, JS)
- Test: `plugin/tests/test-room-screen.sh`

**Interfaces:**
- Consumes: Task 1 `shortName`, `mobile_state().rooms`
- Produces: JS 함수 `renderRooms(rooms, now)` (표식 `// ROOM_LIST_START` ~ `// ROOM_LIST_END`), `roomStatusLabel(status)`.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`plugin/tests/test-room-screen.sh`:

```bash
#!/usr/bin/env bash
# 방 목록 화면 — 폰을 열면 이게 첫 화면이다(형 결정 2026-08-18).
#
# 무엇을 지키나: 급한 것이 위로, 이름은 한 줄, 상태는 사람 말, 대화 수가 보인다.
# 개발 용어(worktree·session·blocked)는 화면에 안 나온다 — 스펙 §3.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
start, end = src.find("// ROOM_LIST_START"), src.find("// ROOM_LIST_END")
if start < 0 or end < 0:
    raise SystemExit("ROOM_LIST_START/END 경계가 없다")
print("const src = " + json.dumps(src[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.renderRooms = renderRooms;
this.roomStatusLabel = roomStatusLabel;`, context, {filename: "marina_mobile::rooms"});
const {renderRooms, roomStatusLabel} = context;

const rooms = [
  {root: "/a", name: "야 너 슬랙 분석 할 수 있지", shortName: "슬랙 분석 할 수 있지",
   status: "대기", tabs: [{title: "A", status: "대기"}], lastAt: 100, archived: false},
  {root: "/b", name: "배포 파이프라인", shortName: "배포 파이프라인", status: "응답필요",
   tabs: [{title: "A", status: "응답필요"}, {title: "B", status: "완료"}], lastAt: 50, archived: false},
];
const html = renderRooms(rooms, 1000);

// ① **급한 것이 위로.** 최근 순이 아니다 — 답을 기다리는 방이 아래 있으면 놓친다.
assert.ok(html.indexOf("배포 파이프라인") < html.indexOf("슬랙 분석"),
  "답을 기다리는 방이 아래에 있다");

// ② 이름은 **줄인 것**을 쓴다(목록은 한 줄이다).
assert.match(html, /슬랙 분석 할 수 있지/);
assert.doesNotMatch(html, /야 너 슬랙/, "긴 원문이 목록에 그대로 나왔다");

// ③ 상태는 **사람 말**이다 — 개발 용어가 화면에 나오면 안 된다(스펙 §3).
assert.match(html, /답을 기다려요/);
for (const word of ["blocked", "worktree", "session", "completed", "idle"]) {
  assert.ok(!html.includes(word), `개발 용어가 화면에 나왔다: ${word}`);
}

// ④ 대화가 여럿이면 몇 개인지 보인다(방 = 대화 묶음이라는 걸 알려줘야 한다).
assert.match(html, /대화 2개/);

// ⑤ 방을 누를 수 있어야 한다 — 그게 유일한 진입로다.
assert.match(html, /data-room="\/b"/);

// ⑥ 상태 라벨 자체
assert.equal(roomStatusLabel("응답필요"), "답을 기다려요");
assert.equal(roomStatusLabel("완료"), "끝났어요");
assert.equal(roomStatusLabel("작업중"), "일하는 중");
assert.equal(roomStatusLabel("문제"), "막혔어요");
assert.equal(roomStatusLabel("대기"), "쉬는 중");
assert.equal(roomStatusLabel("모르는값"), "쉬는 중", "모르는 상태에 빈 칸이 뜨면 안 된다");

// ⑦ 접힌 방은 기본 목록에 없다 — 접기가 안 먹으면 접는 의미가 없다.
const 접힌것 = renderRooms([{root: "/c", shortName: "접은방", status: "대기", tabs: [],
                             lastAt: 10, archived: true}], 1000);
assert.doesNotMatch(접힌것, /접은방/, "접은 방이 그대로 목록에 있다");

// ⑧ 방이 하나도 없으면 **빈 화면이 아니라 말을 한다**(고장으로 보이면 안 된다).
assert.match(renderRooms([], 1000), /아직/);
console.log("ok 방 목록: 급한 순·한 줄 이름·사람 말·접힘 제외");
''')
PY

# ⑨ 첫 화면이 방 목록인가 — HTML 에 방 목록 자리가 있고, 부팅이 안 깨지나.
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html

html = render_mobile_html()
assert 'id="roomList"' in html, "방 목록이 들어갈 자리가 없다"
assert "ROOM_LIST_START" in html, "방 목록 렌더러가 화면에 안 실렸다"
print("ok 방 목록이 화면에 실려 있다")
PY

echo "PASS test-room-screen"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-room-screen.sh`
Expected: FAIL — `ROOM_LIST_START/END 경계가 없다`

- [ ] **Step 3: 구현 — JS**

`marina_mobile.py` 의 JS 영역(다른 `*_START` 표식들 근처)에 추가:

```javascript
      // ROOM_LIST_START
      // 방 목록 — 폰을 열면 이게 첫 화면이다.
      //
      // 정렬이 **최근 순이 아니다.** 답을 기다리는 방이 목록 아래에 있으면 형은 그걸 놓치고,
      // 그 동안 일은 멈춰 있다. 그래서 급한 것부터 올린다(스펙 §2).
      const ROOM_ORDER = ["문제", "응답필요", "작업중", "완료", "대기"];
      const ROOM_LABEL = {
        "문제": "막혔어요", "응답필요": "답을 기다려요", "작업중": "일하는 중",
        "완료": "끝났어요", "대기": "쉬는 중",
      };
      const ROOM_ICON = {
        "문제": "!", "응답필요": "?", "작업중": "⏵", "완료": "✓", "대기": "·",
      };

      function roomStatusLabel(status) {
        // 모르는 값에 빈 칸이 뜨면 고장으로 보인다 — 가장 순한 쪽으로 떨어뜨린다.
        return ROOM_LABEL[status] || ROOM_LABEL["대기"];
      }

      function renderRooms(rooms, now) {
        const live = (rooms || []).filter(room => !room.archived);
        if (!live.length) {
          return '<div class="roomEmpty">아직 방이 없어요. 새 일감을 만들면 여기 나와요.</div>';
        }
        const sorted = live.slice().sort((a, b) => {
          const rank = ROOM_ORDER.indexOf(a.status) - ROOM_ORDER.indexOf(b.status);
          return rank !== 0 ? rank : (b.lastAt || 0) - (a.lastAt || 0);
        });
        return sorted.map(room => {
          const tabs = room.tabs || [];
          // 대화가 하나면 개수를 말할 이유가 없다 — 방=대화 묶음이라는 건 여럿일 때만 뜻이 있다.
          const count = tabs.length > 1 ? ` · 대화 ${tabs.length}개` : "";
          const status = String(room.status || "대기");
          return `<button class="roomCard st-${esc(status)}" data-room="${esc(room.root)}">
            <span class="roomIcon">${esc(ROOM_ICON[status] || ROOM_ICON["대기"])}</span>
            <span class="roomBody">
              <span class="roomName">${esc(room.shortName || room.name || "")}</span>
              <span class="roomMeta">${esc(roomStatusLabel(status))}${esc(count)}</span>
            </span>
          </button>`;
        }).join("");
      }
      // ROOM_LIST_END
```

- [ ] **Step 4: 구현 — HTML/CSS**

`#listView` 안, `.session-list` **위**에 자리를 만든다:

```html
        <div class="room-list" id="roomList"></div>
```

CSS 는 기존 카드 규칙 옆에:

```css
        .roomCard { display:flex; gap:10px; align-items:center; width:100%; text-align:left;
                    padding:14px 12px; border:0; border-bottom:1px solid var(--line);
                    background:transparent; color:inherit; font:inherit; }
        .roomIcon { width:22px; text-align:center; font-weight:700; }
        .roomBody { display:flex; flex-direction:column; gap:2px; min-width:0; }
        /* 이름은 한 줄 — 넘치면 말줄임. 서버가 이미 줄이지만 화면 폭은 기기마다 다르다. */
        .roomName { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .roomMeta { font-size:12px; opacity:.7; }
        .roomCard.st-문제 .roomIcon { color:#e5534b; }
        .roomCard.st-응답필요 .roomIcon { color:#d29922; }
        .roomCard.st-작업중 .roomIcon { color:#2f81f7; }
        .roomCard.st-완료 .roomIcon { color:#3fb950; }
        .roomEmpty { padding:32px 16px; text-align:center; opacity:.7; }
```

- [ ] **Step 5: 구현 — 렌더 배선**

`render()` 안에서 세션 목록을 그리던 자리 옆에:

```javascript
        // 방 목록이 첫 화면이다(형 결정). 세션 목록은 지우지 않고 **숨겨만** 둔다 —
        // 방 화면이 이상하면 한 줄로 되돌릴 수 있어야 한다.
        document.getElementById("roomList").innerHTML = renderRooms(state.rooms, Date.now() / 1000);
        document.getElementById("sessionList").hidden = true;
```

- [ ] **Step 6: 통과 확인**

Run: `bash plugin/tests/test-room-screen.sh` → `PASS test-room-screen`
Run: `cd plugin/tests && ./run-affected.sh` → `FAIL=0` (특히 `test-mobile-boot-smoke`)

- [ ] **Step 7: 커밋**

```bash
chmod +x plugin/tests/test-room-screen.sh
git add plugin/scripts/marina_mobile.py plugin/tests/test-room-screen.sh
git commit -m "feat(room): 방 목록이 폰의 첫 화면 — 급한 것부터"
```

---

### Task 4: 방 열기 — 탭 줄과 대화 진입

**Files:**
- Modify: `plugin/scripts/marina_mobile.py`
- Test: `plugin/tests/test-room-screen.sh` (블록 추가)

**Interfaces:**
- Consumes: Task 3 `renderRooms`
- Produces: JS `renderRoomTabs(room)` (표식 `// ROOM_TABS_START` ~ `// ROOM_TABS_END`), 방 카드 클릭 → 탭 줄 표시 → 탭 클릭 → 기존 `openSession()` 호출.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test-room-screen.sh` 의 `echo "PASS test-room-screen"` 앞에 넣는다:

```bash
# 방을 열면 그 안의 대화가 탭으로 뜬다(스펙 §2 "세션은 탭").
python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
chunk = src[src.find("// ROOM_TABS_START"):src.find("// ROOM_TABS_END")]
if not chunk:
    raise SystemExit("ROOM_TABS_START/END 경계가 없다")
print("const src = " + json.dumps(chunk) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.renderRoomTabs = renderRoomTabs;`, context, {filename: "marina_mobile::roomtabs"});
const {renderRoomTabs} = context;

const room = {root: "/b", shortName: "배포", name: "배포 파이프라인", status: "응답필요", tabs: [
  {source: "claude", sid: "s1", title: "배포 파이프라인 통합", status: "응답필요", primary: true},
  {source: "claude", sid: "s2", title: "환불 정합성", status: "완료", primary: false},
]};
const html = renderRoomTabs(room);

// ① 탭이 전부 보인다 — 3개에서 자르지 않는다(잘리면 4번째 대화에 갈 방법이 없다).
assert.match(html, /data-tab="claude:s1"/);
assert.match(html, /data-tab="claude:s2"/);

// ② 어느 탭이 먼저 열리는지 표시된다.
assert.match(html, /class="[^"]*roomTab[^"]*current/);

// ③ 이름을 고칠 수 있다 — 자동으로 줄인 이름이 거슬릴 때의 출구다(형 결정).
assert.match(html, /data-rename="\/b"/);

// ④ 접을 수 있다 — 끝난 방을 치우는 유일한 방법이다.
assert.match(html, /data-archive="\/b"/);

// ⑤ 방 안에서는 **원래 이름**을 보여준다(목록에서만 줄인다).
assert.match(html, /배포 파이프라인/);

// ⑥ 대화가 하나도 없는 방이면 말을 건다 — 빈 화면은 고장으로 보인다.
assert.match(renderRoomTabs({root: "/z", shortName: "새방", tabs: []}), /대화를 시작/);
console.log("ok 방 열기: 탭 전부·현재 표시·이름 바꾸기·접기");
''')
PY
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-room-screen.sh` → FAIL(`ROOM_TABS_START/END 경계가 없다`)

- [ ] **Step 3: 구현 — JS**

```javascript
      // ROOM_TABS_START
      // 방 안 — 대화들이 탭이다(스펙 §2). 탭을 고르면 기존 대화 화면이 그대로 열린다.
      function renderRoomTabs(room) {
        const tabs = room.tabs || [];
        const head = `<div class="roomHead">
          <span class="roomTitle">${esc(room.name || room.shortName || "")}</span>
          <button class="iconBtn" data-rename="${esc(room.root)}" title="이름 바꾸기">✎</button>
          <button class="iconBtn" data-archive="${esc(room.root)}" title="접어두기">↓</button>
        </div>`;
        if (!tabs.length) {
          return head + '<div class="roomEmpty">대화를 시작해 보세요.</div>';
        }
        const strip = tabs.map(tab => {
          const key = `${tab.source}:${tab.sid}`;
          const cls = "roomTab" + (tab.primary ? " current" : "") + (tab.hidden ? " hidden" : "");
          return `<button class="${cls}" data-tab="${esc(key)}">${esc(tab.title || key)}</button>`;
        }).join("");
        return head + `<div class="roomTabs">${strip}</div>`;
      }
      // ROOM_TABS_END
```

- [ ] **Step 4: 구현 — 배선**

`#listView` 안, `#roomList` 위에 방 상세 자리를 만든다:

```html
        <div class="room-open" id="roomOpen" hidden></div>
```

클릭 처리(기존 목록 클릭 위임 옆):

```javascript
        // 방 카드 → 방 열기. 방을 나가는 길은 뒤로가기 버튼과 같은 자리를 쓴다.
        roomList.addEventListener("click", event => {
          const card = event.target.closest("[data-room]");
          if (!card) return;
          openRoom(card.getAttribute("data-room"));
        });
        roomOpen.addEventListener("click", event => {
          const tab = event.target.closest("[data-tab]");
          if (tab) {
            const [source, sid] = tab.getAttribute("data-tab").split(":");
            openSession({kind: "agent", root: currentRoomRoot, source, sid});
            return;
          }
          const rename = event.target.closest("[data-rename]");
          if (rename) { promptRoomName(rename.getAttribute("data-rename")); return; }
          const archive = event.target.closest("[data-archive]");
          if (archive) { archiveRoom(archive.getAttribute("data-archive")); }
        });
```

`openSession` 의 실제 이름·인자는 구현 전에 확인한다:
`grep -n "function openSession\|function openTarget" marina_mobile.py`

- [ ] **Step 5: 통과 확인**

Run: `bash plugin/tests/test-room-screen.sh` → `PASS`
Run: `cd plugin/tests && ./run-affected.sh` → `FAIL=0`

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina_mobile.py plugin/tests/test-room-screen.sh
git commit -m "feat(room): 방을 열면 대화가 탭으로 — 자르지 않는다"
```

---

### Task 5: 접기와 이름 바꾸기 동작 붙이기

**Files:**
- Modify: `plugin/scripts/marina_mobile.py`
- Test: `plugin/tests/test-room-screen.sh` (블록 추가)

**Interfaces:**
- Consumes: Task 2 `/mobile/api/rename`, 1차의 `/mobile/api/archive`
- Produces: JS `archiveRoom(root)`, `promptRoomName(root)`, 접힌 방 보기 토글.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test-room-screen.sh` 에 추가:

```bash
# 접기·이름 바꾸기가 **서버로 간다** — 화면만 바뀌고 서버에 안 가면 다음 폴에 되돌아온다.
PYTHONPATH="$SCR" python3 - <<'PY'
import re

from marina_mobile import render_mobile_html

html = render_mobile_html()
# 접기는 1차에서 만든 표면을 쓴다(새로 만들지 않는다).
assert "/mobile/api/archive" in html, "접기가 서버로 안 간다"
assert "/mobile/api/rename" in html, "이름 바꾸기가 서버로 안 간다"
# 접은 뒤 목록을 다시 받아야 한다 — 안 그러면 접었는데 그대로 있는 것처럼 보인다.
블록 = html[html.find("async function archiveRoom"):][:600]
assert "await" in 블록 and ("refresh" in 블록 or "load(" in 블록), 블록
# 접힌 방을 다시 볼 길이 있어야 한다 — 접어놓고 못 찾으면 잃어버린 것과 같다.
assert "접은 방" in html or "showArchived" in html, "접힌 방을 볼 방법이 없다"
print("ok 접기·이름 바꾸기가 서버로 가고 목록이 갱신된다")
PY
```

- [ ] **Step 2: 실패 확인** → FAIL(`접기가 서버로 안 간다`)

- [ ] **Step 3: 구현**

```javascript
      // 접기 — 끝난 방을 목록에서 치운다. 서버가 판단 근거(무엇으로 부르고 있었는지)를
      // 같이 적어두므로, 새로 부를 일이 생기면 저절로 다시 올라온다(1차에서 만든 규칙).
      async function archiveRoom(root) {
        await api("/mobile/api/archive", {
          method: "POST", headers: {"content-type": "application/json"},
          body: JSON.stringify({root, archived: true}),
        });
        closeRoom();
        await load({force: true});   // 접었는데 그대로 있으면 안 먹은 걸로 보인다
      }

      async function promptRoomName(root) {
        const room = (lastState.rooms || []).find(item => item.root === root);
        const next = window.prompt("방 이름", (room && room.name) || "");
        if (next === null) return;                 // 취소
        await api("/mobile/api/rename", {
          method: "POST", headers: {"content-type": "application/json"},
          body: JSON.stringify({root, name: next}),
        });
        await load({force: true});
      }
```

접힌 방 보기: 기존 `#showAllBtn`(전체보기) 옆에 토글 하나를 두고, 켜면
`renderRooms` 에 `archived` 포함분을 넘긴다. 라벨은 "접은 방".

- [ ] **Step 4: 통과 확인 + 회귀**

Run: `bash plugin/tests/test-room-screen.sh` → `PASS`
Run: `cd plugin/tests && ./run-affected.sh --deep` → `FAIL=0`

- [ ] **Step 5: 실제 브라우저로 확인**

Aside 로 `http://127.0.0.1:3903/mobile` 를 열어 다음을 눈으로 본다(스텁이 아니라 실물):
1. 첫 화면에 방 목록이 뜨고 급한 것이 위에 있다
2. 방을 누르면 탭이 뜬다 / 탭을 누르면 대화가 열린다
3. ✎ 로 이름을 바꾸면 목록에 반영된다
4. ↓ 로 접으면 목록에서 사라지고, "접은 방"에서 보인다

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina_mobile.py plugin/tests/test-room-screen.sh
git commit -m "feat(room): 접기·이름 바꾸기 동작 — 서버까지 간다"
```

---

## 이번 범위 밖 (다음)

- **삭제**(대화 탭·방) + 미커밋 자동 보관 — 되돌릴 수 없는 동작이라 방 화면이 자리 잡은 뒤에 따로 계획을 끊는다.
- **어드민 웹 서랍** — 웹 대시보드는 지금 화면을 그대로 둔다. 방이 폰에서 검증된 뒤에 옮긴다.
- **배포 버튼**(`canShip`) — 자리만 잡혀 있고 동작은 없다.
