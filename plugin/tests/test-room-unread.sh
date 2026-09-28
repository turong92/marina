#!/usr/bin/env bash
# 새 메시지 빨간 점 — 형: "슬랙 보니까 메시지 새로 오면 레드닷 찍어주던데 우리도".
# 잠그는 계약:
#   ① 처음 켤 땐 전부 본 걸로 시작한다(안 그러면 방마다 점이 뜬다).
#   ② 본 뒤에 그 대화가 움직이면(tab.ts 가 더 새로우면) 대화 줄과 방 카드에 점.
#   ③ 열어 보면(markTabSeen) 점이 사라진다. 숨긴·지운·접은 것엔 점이 없다.
#   ④ 처음 켠 뒤에 생긴 대화는 "새 대화"라 점.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json, sys
from pathlib import Path
src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
a, b = src.find("    // ROOM_LIST_START"), src.find("    // ROOM_LIST_END")
assert a >= 0 and b > a, "ROOM_LIST 경계가 없다"
c, d = src.find("    // ROOM_TABS_START"), src.find("    // ROOM_TABS_END")
assert c >= 0 and d > c, "ROOM_TABS 경계가 없다"
print("const src = " + json.dumps(src[a:b] + "\n" + src[c:d]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const store = {};
const context = {esc: s => String(s), statusReasonText: () => "", shortAgo: () => "", roomStatusIcon: () => "",
  localStorage: {getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); }}};
vm.createContext(context);
vm.runInContext(`${src}
this.api = {renderRooms, seedSeen, markTabSeen, tabUnread, roomUnread};`, context, {filename: "rooms"});
const {renderRooms, seedSeen, markTabSeen, tabUnread, roomUnread} = context.api;
const dots = html => (html.match(/unreadDot/g) || []).length;

const room = {root: "/r/a", name: "방", shortName: "방", tabs: [{source: "claude", sid: "s1", title: "대화", ts: 100}]};
// ① 처음: 전부 본 걸로.
seedSeen([room]);
assert.equal(roomUnread(room), false, "처음 켰는데 점이 떴다");
assert.equal(dots(renderRooms([room], 200, false, "", "", "", [])), 0);
// ② 그 대화가 움직였다.
room.tabs[0].ts = 150;
assert.equal(roomUnread(room), true, "새 메시지인데 점이 없다");
assert.ok(dots(renderRooms([room], 200, false, "", "", "", [])) >= 1, "방 카드에 점이 안 그려졌다");
assert.ok(dots(renderRooms([room], 200, false, "", "", "/r/a", [])) >= 2, "펼친 대화 줄에도 점이 있어야 한다");
// ③ 열어 봤다.
markTabSeen("/r/a", "claude", "s1", 150);
assert.equal(roomUnread(room), false, "봤는데 점이 남았다");
assert.ok(JSON.parse(store.marinaSeenTabs)["/r/a|claude:s1"] === 150, "본 시각이 저장되지 않았다");
// ④ 켠 뒤에 새로 생긴 대화.
room.tabs.push({source: "codex", sid: "s2", title: "새 대화", ts: 160});
assert.equal(tabUnread(room, room.tabs[1]), true, "새로 생긴 대화에 점이 없다");
// 숨김·지움·접은 방엔 점 없음.
assert.equal(tabUnread(room, {...room.tabs[1], hidden: true}), false);
assert.equal(tabUnread(room, {...room.tabs[1], deleted: true}), false);
assert.equal(roomUnread({...room, archived: true}), false, "접어 둔 방에 점이 떴다");
console.log("PASS test-room-unread");
''')
PY
