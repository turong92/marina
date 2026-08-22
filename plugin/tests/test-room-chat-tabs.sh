#!/usr/bin/env bash
# 방 안에서 **다른 대화로 바로 넘어간다**(스펙 §3 화면 그림: `[기본] [디자인 손보기]`).
#
# 지금까지는 대화 화면의 탭 줄이 "형이 연 탭" 기준이라, 방 카드를 눌러 들어가면 탭이 하나뿐이라
# 줄이 안 떴다 — 같은 방의 다른 대화로 가려면 목록으로 나갔다 다시 들어가야 했다.
#
# 그 대화들은 **방 안 대화 줄**(#roomChats)에 있다. 전역 탭 줄에 얹는 방식은 버렸다 —
# 다른 방 탭과 섞이고 8개 상한에 밀려서, 대화 4개짜리 방에서 정작 고를 수가 없었다(형 실사용:
# "대화 4개 있다는데 그중 고를 수도 없네"). 전역 탭 줄은 형이 직접 연 것만 남는 자리다.
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
# ④ 방 안 대화 줄이 화면에 있고, 대화 화면을 그릴 때 같이 그린다.
assert 'id="roomChats"' in html, "방 안 대화 줄이 없다"
assert "renderRoomChats();" in html, "대화 화면을 그릴 때 방 대화 줄을 안 그린다"

# ⑤ 그 줄은 **지금 방의 대화만** 담는다 — 전역 탭(openTabs)이 아니라 room.tabs 를 읽어야 한다.
그리기 = html[html.find("function renderRoomChats"):][:1400]
assert "room.tabs" in 그리기 and "openTabs" not in 그리기, f"전역 탭을 읽고 있다: {그리기[:300]}"

# ⑥ 방을 여는 길들이 전역 탭 줄을 오염시키지 않는다 — 8개 상한에 밀려 그 방 대화가 사라졌다.
assert "addRoomTabs" not in html, "아직도 방 대화를 전역 탭에 얹는다"
열기 = html[html.find("    roomList.addEventListener"):html.find("    // 클로드 로그인 — 폰에서 끝낸다")]
assert "chooseSession(" in 열기, "방 카드로 대화를 못 연다"
print("ok 방 안 대화 줄이 그 방 대화만 담는다")
PY2

echo "PASS test-room-chat-tabs"
