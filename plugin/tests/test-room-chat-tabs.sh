#!/usr/bin/env bash
# 방 안에서 **다른 대화로 바로 넘어간다**(스펙 §3 화면 그림: `[기본] [디자인 손보기]`).
#
# 지금까지는 대화 화면의 탭 줄이 "형이 연 탭" 기준이라, 방 카드를 눌러 들어가면 탭이 하나뿐이라
# 줄이 안 떴다 — 같은 방의 다른 대화로 가려면 목록으로 나갔다 다시 들어가야 했다.
#
# 기존 멀티탭(다른 방 대화를 함께 띄우는 것)은 없애지 않는다. 방을 열 때 그 방의 대화들을
# 탭으로 **얹기만** 한다 — 없애면 형이 쓰던 게 사라진다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
chunk = src[src.find("// ROOM_SIBLING_TABS_START"):src.find("// ROOM_SIBLING_TABS_END")]
if not chunk:
    raise SystemExit("ROOM_SIBLING_TABS_START/END 경계가 없다")
print("const src = " + json.dumps(chunk) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.roomSiblingKeys = roomSiblingKeys;`, context, {filename: "marina_mobile::siblings"});
const {roomSiblingKeys} = context;

const room = {root: "/wt", tabs: [
  {source: "claude", sid: "s1", title: "기본", primary: true},
  {source: "claude", sid: "s2", title: "디자인 손보기"},
]};

// ① 방의 대화가 전부 탭 후보다 — 그래야 나갔다 들어오지 않고 넘어간다.
const 같나 = (a, b) => assert.equal(JSON.stringify(a), JSON.stringify(b));
같나(roomSiblingKeys(room), ["agent:claude:s1:/wt", "agent:claude:s2:/wt"]);

// ② 숨긴·오래된 대화는 얹지 않는다 — 목록에서 뺀 것이 탭 줄로 되살아나면 숨김이 무의미하다.
같나(roomSiblingKeys({root: "/wt", tabs: [
  {source: "claude", sid: "a", title: "A"},
  {source: "claude", sid: "b", title: "B", hidden: true},
  {source: "claude", sid: "c", title: "C", stale: true},
]}), ["agent:claude:a:/wt"]);

// ③ 대화가 하나뿐인 방은 얹을 게 없다(줄도 안 뜬다 — 화면만 먹는다).
같나(roomSiblingKeys({root: "/wt", tabs: [{source: "claude", sid: "only"}]}), ["agent:claude:only:/wt"]);
같나(roomSiblingKeys(null), []);
같나(roomSiblingKeys({root: "/wt", tabs: []}), []);
console.log("ok 방의 대화들이 탭 후보가 된다");
''')
PY

# ④ 방을 열 때 실제로 얹고, **기존 탭은 안 지운다**.
PYTHONPATH="$SCR" python3 - <<'PY2'
from marina_mobile import render_mobile_html

html = render_mobile_html()
# 방 카드로 들어갈 때와 방 안 탭으로 들어갈 때 **둘 다** 얹어야 한다.
열기 = html[html.find("    roomList.addEventListener"):html.find("    // 클로드 로그인 — 폰에서 끝낸다")]
assert 열기.count("addRoomTabs(") >= 2, \
    f"방을 열어도 그 방 대화가 탭에 안 얹힌다(호출 {열기.count('addRoomTabs(')}회)"
# 기존 멀티탭을 갈아엎으면 안 된다 — 얹기만 한다.
얹기 = html[html.find("function addRoomTabs"):][:700]
assert "addTab(" in 얹기, 얹기[:300]
assert "openTabs = [" not in 얹기, f"기존 탭을 통째로 갈아치운다: {얹기[:300]}"
print("ok 방을 열면 그 방 대화가 탭으로 얹힌다")
PY2

echo "PASS test-room-chat-tabs"
