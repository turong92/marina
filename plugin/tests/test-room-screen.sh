#!/usr/bin/env bash
# 방 목록 화면 — 폰을 열면 이게 첫 화면이다(형 결정 2026-08-18).
#
# 무엇을 지키나: 급한 것이 위로, 이름은 한 줄, 상태는 사람 말, 대화 수가 보인다.
# 개발 용어(worktree·session·blocked)는 화면에 안 나온다 — 스펙 §3 "비개발자가 쓰는 화면".
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
src = (scripts / "marina_mobile.py").read_text(encoding="utf-8")
start, end = src.find("// ROOM_LIST_START"), src.find("// ROOM_LIST_END")
if start < 0 or end < 0:
    raise SystemExit("ROOM_LIST_START/END 경계가 없다")
# esc 는 공유 렌더러에서 온다 — 방 블록만 떼어 실으면 없으므로 같이 싣는다(질문 카드 테스트와 같은 방식).
helpers = (scripts / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
esc = helpers[helpers.find("// ESC_HELPERS_START"):helpers.find("// ESC_HELPERS_END")]
print("const src = " + json.dumps(esc + src[start:end]) + ";")
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

// ① **급한 것이 위로.** 최근 순이 아니다 — 답을 기다리는 방이 아래 있으면 형은 그걸 놓치고,
// 그동안 일은 멈춰 있다(스펙 §2).
assert.ok(html.indexOf("배포 파이프라인") < html.indexOf("슬랙 분석"),
  "답을 기다리는 방이 최근 방보다 아래에 있다");

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
// 하나뿐이면 굳이 말하지 않는다 — 정보가 없는 글자는 목록을 흐리게만 한다.
assert.doesNotMatch(html, /대화 1개/);

// ⑤ 방을 누를 수 있어야 한다 — 그게 유일한 진입로다.
assert.match(html, /data-room="\/b"/);

// ⑥ 상태 라벨 자체
assert.equal(roomStatusLabel("응답필요"), "답을 기다려요");
assert.equal(roomStatusLabel("완료"), "끝났어요");
assert.equal(roomStatusLabel("작업중"), "일하는 중");
assert.equal(roomStatusLabel("문제"), "막혔어요");
assert.equal(roomStatusLabel("대기"), "쉬는 중");
assert.equal(roomStatusLabel("모르는값"), "쉬는 중", "모르는 상태에 빈 칸이 뜨면 고장으로 보인다");

// ⑦ 접힌 방은 기본 목록에 없다 — 안 그러면 접는 의미가 없다.
const 접힌것 = renderRooms([{root: "/c", shortName: "접은방", status: "대기", tabs: [],
                             lastAt: 10, archived: true}], 1000);
assert.doesNotMatch(접힌것, /접은방/, "접은 방이 그대로 목록에 있다");

// ⑧ 방이 하나도 없으면 **빈 화면이 아니라 말을 한다**(고장으로 보이면 안 된다).
assert.match(renderRooms([], 1000), /아직/);

// ⑨ 이름에 태그가 들어 있어도 화면을 깨뜨리지 못한다 — 이름은 형이 친 프롬프트라 무엇이든 온다.
const 위험 = renderRooms([{root: "/x", shortName: "<img src=x onerror=alert(1)>", status: "대기",
                           tabs: [], lastAt: 1, archived: false}], 1000);
assert.doesNotMatch(위험, /<img/, "이름의 태그가 그대로 화면에 들어갔다");
console.log("ok 방 목록: 급한 순·한 줄 이름·사람 말·접힘 제외·이스케이프");
''')
PY

# 방을 열면 그 안의 대화가 탭으로 뜬다(스펙 §2 "세션은 탭").
python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
src = (scripts / "marina_mobile.py").read_text(encoding="utf-8")
chunk = src[src.find("// ROOM_TABS_START"):src.find("// ROOM_TABS_END")]
if not chunk:
    raise SystemExit("ROOM_TABS_START/END 경계가 없다")
helpers = (scripts / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
esc = helpers[helpers.find("// ESC_HELPERS_START"):helpers.find("// ESC_HELPERS_END")]
print("const src = " + json.dumps(esc + chunk) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.renderRoomTabs = renderRoomTabs;`, context, {filename: "marina_mobile::roomtabs"});
const {renderRoomTabs} = context;

const room = {root: "/b", shortName: "배포", name: "배포 파이프라인 통합 대시보드", status: "응답필요",
  tabs: [
    {source: "claude", sid: "s1", title: "배포 파이프라인 통합", status: "응답필요", primary: true},
    {source: "claude", sid: "s2", title: "환불 정합성", status: "완료", primary: false},
  ]};
const html = renderRoomTabs(room);

// ① 탭이 **전부** 보인다 — 3개에서 자르면 4번째 대화에 갈 방법이 없다(1차에서 서버는 이미 안 자른다).
assert.match(html, /data-tab="claude:s1"/);
assert.match(html, /data-tab="claude:s2"/);

// ② 어느 대화가 먼저 열리는지 표시된다.
assert.match(html, /class="[^"]*roomTab[^"]*current/);

// ③ 이름을 고칠 수 있다 — 자동으로 줄인 이름이 거슬릴 때의 출구다(형 결정).
assert.match(html, /data-rename="\/b"/);

// ④ 접을 수 있다 — 끝난 방을 치우는 유일한 길이다.
assert.match(html, /data-archive="\/b"/);

// ⑤ 방 안에서는 **원래 이름**을 보여준다(줄이는 건 목록에서만).
assert.ok(html.includes("배포 파이프라인 통합 대시보드"), "방 안에서도 이름이 잘려 있다");

// ⑥ 대화가 없는 방이면 말을 건다 — 빈 화면은 고장으로 보인다.
assert.match(renderRoomTabs({root: "/z", name: "새방", tabs: []}), /대화를 시작/);

// ⑦ 숨긴 대화는 표시가 남는다(전체보기에서 꺼내 정리하라고).
const 숨김낀 = renderRoomTabs({root: "/h", name: "h", tabs: [
  {source: "claude", sid: "a", title: "A", status: "대기", primary: true},
  {source: "claude", sid: "b", title: "B", status: "대기", hidden: true},
]});
assert.match(숨김낀, /roomTab[^"]*hidden/);
console.log("ok 방 열기: 탭 전부·현재 표시·이름 바꾸기·접기");
''')
PY

# ⑩ 첫 화면에 방 목록 자리가 있고, 페이지가 안 깨지나.
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html

html = render_mobile_html()
assert 'id="roomList"' in html, "방 목록이 들어갈 자리가 없다"
assert "ROOM_LIST_START" in html, "방 목록 렌더러가 화면에 안 실렸다"
# 목록에 쓰이는 CSS 가 같이 있어야 한다 — 렌더는 되는데 안 보이는 사고를 전에 겪었다.
assert ".roomCard" in html, "방 카드 스타일이 없다"
assert ".roomName" in html, "이름 줄 스타일이 없다"
print("ok 방 목록이 화면에 실려 있다")
PY

# 접기·이름 바꾸기가 **서버까지 간다** — 화면만 바뀌고 서버에 안 가면 다음 폴에 되돌아온다.
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html

html = render_mobile_html()
블록 = html[html.find("// ROOM_ACTIONS_START"):html.find("// ROOM_ACTIONS_END")]
assert 블록, "방 동작 블록이 화면에 없다"

# 접기는 1차에서 만든 표면을 쓴다(새로 만들지 않는다).
assert "/mobile/api/archive" in 블록, "접기가 서버로 안 간다"
assert "/mobile/api/rename" in 블록, "이름 바꾸기가 서버로 안 간다"

# 서버에 보낸 뒤 목록을 **다시 받는다** — 안 그러면 접었는데 그대로 있는 것처럼 보인다.
접기 = 블록[블록.find("async function archiveRoom"):]
접기 = 접기[:접기.find("async function renameRoom")]
assert "load({force: true})" in 접기, 접기

# 실패하면 말한다 — 조용히 실패하면 형은 안 먹은 줄 모르고 또 누른다.
assert "접기 실패" in 접기, 접기

# 방 카드를 누르면 **바로 대화로** 간다(대부분의 방은 대화가 하나뿐이다).
assert "chooseSession(" in 블록, "방을 눌러도 대화가 안 열린다"
# 대화가 없는 방은 방 안을 연다 — 아무 반응이 없으면 고장으로 보인다.
assert "openRoom(room.root)" in 블록, 블록[:400]
print("ok 접기·이름 바꾸기가 서버로 가고 목록이 갱신된다")
PY

echo "PASS test-room-screen"
