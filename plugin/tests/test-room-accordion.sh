#!/usr/bin/env bash
# 방 패널은 **누른 카드 바로 밑**에서 펼쳐진다.
#
# 예전엔 `#roomOpen` 이 목록 맨 위에 고정돼 있어, 어느 카드의 ⋯ 를 눌러도 패널이 화면 저 위에
# 그려졌다. 코드가 그걸 알고 `roomOpen.scrollIntoView()` 로 화면을 끌어올렸는데(주석: "실측:
# 목록을 1300px 내린 상태에서 열면 패널이 뷰포트 위 -1300px"), 그건 원인이 아니라 증상을 덮은
# 것이다 — 손가락은 아래에 있는데 화면이 위로 튄다.
#
# 참고한 관습(Slack·Discord·Notion·Telegram·Gmail): 하위 목록은 **부모 바로 밑**에서 펼치고,
# 작업 메뉴는 **손가락 자리 팝오버**로 띄운다. 목록 맨 위에 상자를 띄우는 서비스는 없다 —
# 그 자리는 목록 전체에 해당하는 것(검색·필터)의 자리다.
#
# 계약: ① 아코디언은 그 카드와 다음 카드 **사이**에 온다 ② 한 번에 한 방만 ③ 펼치기는 부제줄
# 배지가, 방 작업은 ⋯ 가 맡는다 — **오른쪽 모서리엔 손잡이가 하나뿐이다** ④ 방 작업(이름·접기·
# 삭제)은 아코디언이 아니라 **메뉴**에 산다 ⑤ 대화 목록과 시작줄은 아코디언 안에 있고,
# **시작줄이 언제나 맨 위**다.
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
def block(tag):
    start, end = src.find(f"// {tag}_START"), src.find(f"// {tag}_END")
    if start < 0 or end < 0:
        raise SystemExit(f"{tag}_START/END 경계가 없다")
    return src[start:end]

helpers = (scripts / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
esc = helpers[helpers.find("// ESC_HELPERS_START"):helpers.find("// ESC_HELPERS_END")]
사유 = block("STATUS_REASON")
print("const src = " + json.dumps(esc + 사유 + block("ROOM_LIST") + block("ROOM_TABS")) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.renderRooms = renderRooms;
this.renderRoomMenu = renderRoomMenu;
this.renderChatMenu = renderChatMenu;
this.renderRoomAccordion = renderRoomAccordion;`, context, {filename: "marina_mobile::rooms"});
const {renderRooms, renderRoomMenu, renderRoomAccordion} = context;

const rooms = [
  {root: "/top", name: "맨 위 방", shortName: "맨 위 방", status: "작업중",
   tabs: [{title: "기본", source: "claude", sid: "s1"}], lastAt: 300},
  {root: "/mid", name: "가운데 방", shortName: "가운데 방", status: "응답필요",
   tabs: [{title: "기본", source: "claude", sid: "s2"},
          {title: "디자인 손보기", source: "claude", sid: "s3"}], lastAt: 200},
  {root: "/bot", name: "아래 방", shortName: "아래 방", status: "대기",
   tabs: [{title: "기본", source: "codex", sid: "s4"}], lastAt: 100},
];
const sources = [{id: "claude", label: "Claude"}, {id: "codex", label: "Codex"}];

// ① 가운데 방을 펼치면 아코디언이 **그 카드와 아래 방 사이**에 온다.
const html = renderRooms(rooms, 1000, false, "", "", "/mid", sources);
const 가운데 = html.indexOf("가운데 방");
const 아래 = html.indexOf("아래 방");
const 아코디언 = html.indexOf('data-room-acc="/mid"');
assert.ok(아코디언 > 0, "아코디언이 안 그려졌다");
assert.ok(가운데 < 아코디언 && 아코디언 < 아래,
  `아코디언이 카드 밑이 아니다 (카드 ${가운데} · 아코디언 ${아코디언} · 다음카드 ${아래})`);
assert.ok(html.indexOf('data-room-acc') < html.indexOf("맨 위 방") === false,
  "아코디언이 목록 맨 위에 그려졌다 — 고치려던 바로 그 문제다");

// ② 한 번에 한 방만 펼친다 — 여럿이 열리면 목록이 다시 길어지고 지금 어딘지 흐려진다.
assert.equal(html.split('class="roomAcc"').length - 1, 1, "아코디언이 둘 이상 열렸다");

// ③ 펼침과 메뉴는 갈라져 있다(숨은 롱프레스 없이 둘 다 눌러서 닿는다). 다만 **자리가 다르다**:
// 펼치기는 부제줄의 "대화 N개" 배지, 방 작업은 오른쪽 ⋯. 예전엔 ⌄ 와 ⋯ 가 오른쪽 모서리에
// 나란히 붙어 있었는데(형: "2개 같이 있지않고"), 둘 다 아이콘뿐이라 눌러봐야 뭐가 뭔지 알았다.
assert.match(html, /class="countChip"[^>]*data-room-expand="\/mid"/);
assert.match(html, /data-room-menu="\/mid"/);
assert.ok(!html.includes("roomExpand"), "오른쪽 모서리에 ⌄ 버튼이 되살아났다");
// 오른쪽 모서리(roomMore)는 방마다 **하나씩만** — ⋯ 셋, 그게 전부다.
assert.equal(html.split('class="roomMore"').length - 1, rooms.length,
  "카드 오른쪽 손잡이가 방 하나에 하나가 아니다");
// 배지는 무엇이 열리는지 글자로 말한다 — 아이콘만 있으면 눌러봐야 안다.
assert.match(html, /data-room-expand="\/mid"[^>]*>대화 2개/);
// 펼친 방은 스크린리더에도 펼쳐졌다고 말해야 한다.
assert.match(html, /data-room-expand="\/mid"[^>]*aria-expanded="true"/);
assert.match(html, /data-room-expand="\/top"[^>]*aria-expanded="false"/);
// 카드는 버튼이 아니라 div 다(배지가 안에 앉아야 하므로) — 대신 **이름이 진짜 버튼**이 되어
// 키보드·스크린리더를 받는다. div 에 role="button" 을 씌우면 버튼 안에 버튼을 넣는 것과
// 같은 위반이라(배지·⋯ 가 그 안에 있다) 그 길은 쓰지 않는다.
assert.match(html, /class="roomCard" data-room="\/mid"/);
assert.match(html, /<button class="roomName" type="button">/);
// 한 방에 data-room 은 **하나**다 — 이름에도 붙이면 방 개수를 세는 쪽이 두 배로 읽는다.
assert.equal(html.split('data-room="/mid"').length - 1, 1, "한 방에 data-room 이 둘 이상이다");
assert.ok(!html.includes('role="button"'), "카드 div 에 role=button 을 씌웠다 — 안에 버튼이 있다");

// ④ 방 작업은 아코디언이 아니라 **메뉴**에 산다. 삭제가 목록 안에 늘 펼쳐져 있으면 무섭다.
const acc = html.slice(아코디언, 아래);
for (const attr of ["data-rename", "data-archive", "data-room-delete"]) {
  assert.ok(!acc.includes(attr), `방 작업이 아코디언에 남아 있다: ${attr}`);
}
const menu = renderRoomMenu(rooms[1]);
for (const attr of ["data-rename", "data-archive", "data-room-delete"]) {
  assert.ok(menu.includes(attr), `메뉴에 방 작업이 없다: ${attr}`);
}
// 지울 수 없는 방(원본 체크아웃 등)엔 삭제를 주지 않는다 — 눌러도 안 되는 버튼은 거짓말이다.
assert.ok(!renderRoomMenu({root: "/x", name: "x", removable: false}).includes("data-room-delete"));

// ⑤-0 대화 행은 **이름만** 남고 작업은 ⋯ 뒤로 간다. 예전엔 대화마다 [다시 시작][끄기][지우기]
// 셋이 늘 펼쳐져 있어서, 대화 3개짜리 방을 열면 버튼이 12개였다(형: "디자인도 구리고").
// 방 작업을 팝오버로 뺐으면 성격이 같은 대화 작업도 같은 규칙을 받아야 한다 — 한쪽만
// 고치면 같은 화면 안에서 규칙이 둘이 된다.
for (const attr of ["data-restart-chat", "data-close-chat", "data-forget"]) {
  assert.ok(!acc.includes(attr), `대화 작업이 아직 아코디언에 펼쳐져 있다: ${attr}`);
}
assert.match(acc, /data-chat-menu="claude:s2"/);
const 대화메뉴 = context.renderChatMenu("claude:s2", {});
for (const attr of ["data-restart-chat", "data-close-chat", "data-forget"]) {
  assert.ok(대화메뉴.includes(attr), `대화 메뉴에 ${attr} 가 없다`);
}

// ⑤-1 **숨긴·지운 대화의 되살리기는 인라인에 남는다.** 그건 작업이 아니라 구조선이다 —
// ⋯ 뒤에 묻으면 "방 화면에서는 숨긴 것이 영영 잠긴다"는 옛 버그로 돌아간다.
const 숨김 = renderRoomAccordion({root: "/h", name: "h", tabs: [
  {source: "claude", sid: "a", title: "A", primary: true},
  {source: "claude", sid: "b", title: "B", hidden: true},
  {source: "claude", sid: "c", title: "C", deleted: true},
]}, sources);
assert.match(숨김, /data-unhide="claude:b"/, "숨긴 대화의 되살리기가 사라졌다");
assert.match(숨김, /data-restore="claude:c"/, "지운 대화의 되살리기가 사라졌다");
assert.ok(!숨김.includes('data-chat-menu="claude:b"'), "숨긴 대화에 작업 메뉴를 주면 안 된다");

// ⑤ 대화 목록과 시작줄은 아코디언 안에 있다.
assert.ok(acc.includes("디자인 손보기"), "다른 대화가 아코디언에 없다");
assert.match(acc, /data-room-launch="claude"/);

// ⑤-2 **시작줄은 맨 위**, 곧 누른 카드 바로 밑이다. 예전엔 대화가 있는 방에서만 아래로
// 내려가서 같은 ＋ 버튼이 방마다 자리가 달랐다(빈 방은 위, 대화 있는 방은 맨 밑).
assert.ok(acc.indexOf('data-room-launch="claude"') < acc.indexOf("디자인 손보기"),
  "＋ 버튼이 대화 목록 아래로 내려갔다 — 대화가 늘수록 멀어진다");
const 빈방 = renderRoomAccordion({root: "/e", name: "빈 방", tabs: []}, sources);
assert.ok(빈방.indexOf('data-room-launch="claude"') < 빈방.indexOf("아직 대화가 없어요"),
  "빈 방에서도 ＋ 가 먼저다");

// ⑤-3 펼칠 대화가 없는 방엔 배지를 주지 않는다 — 눌러도 아무것도 안 열리는 손잡이는 거짓말이다.
// (그런 방은 카드를 누르면 openRoom 으로 바로 펼쳐진다.)
const 빈방목록 = renderRooms([{root: "/e", name: "빈 방", shortName: "빈 방", status: "대기",
                              tabs: [], lastAt: 5}], 1000, false, "", "", "", sources);
assert.ok(!빈방목록.includes("countChip"), "대화가 없는 방에 펼침 배지가 붙었다");
assert.match(빈방목록, /data-room-menu="\/e"/, "빈 방에도 방 메뉴는 있어야 한다");

// ⑥ 아무 방도 안 펼쳤으면 아코디언이 하나도 없다(기본 상태는 조용하다).
const 닫힘 = renderRooms(rooms, 1000, false, "", "", "", sources);
assert.ok(!닫힘.includes("roomAcc"), "안 펼쳤는데 아코디언이 그려졌다");
assert.match(닫힘, /aria-expanded="false"/);

// ⑦ 접어둔 방은 종전대로 '다시 꺼내기'만 — 펼칠 것이 없다.
const 접힘 = renderRooms([{root: "/z", name: "접은 방", shortName: "접은 방", status: "대기",
                          tabs: [], lastAt: 10, archived: true}], 1000, true, "", "", "", sources);
assert.match(접힘, /data-room-unarchive="\/z"/);
assert.ok(!접힘.includes('data-room-expand="/z"'), "접어둔 방에 펼침 손잡이가 붙었다");
assert.ok(!접힘.includes("countChip"), "접어둔 방에 펼침 배지가 붙었다");

console.log("ok");
''')
PY
echo "PASS: 방 패널이 누른 카드 바로 밑에서 펼쳐진다"
