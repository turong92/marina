#!/usr/bin/env bash
# 방 목록은 **최근 소식 순**이다 — 형: "진짜 채팅방처럼 가장 최근 메세지 도착한거 순서로".
#
# 예전엔 상태부터 줄을 세웠다(문제 > 응답필요 > 작업중 > 완료 > 대기, 스펙 §2). 뜻은 좋았지만
# 방금 답이 온 방이 며칠 전 "문제" 방 밑에 깔린다 — 카톡·슬랙 어디도 그러지 않는다.
# 놓치면 안 되는 것은 **순서가 아니라 표시**로 말한다(카드의 상태 아이콘·라벨).
# 접어둔 방만 뒤로 보낸다 — 치워둔 것이 첫 줄이 되면 접기의 뜻과 반대다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
start = src.find("    // ROOM_LIST_START")
end = src.find("    // ROOM_LIST_END")
if start < 0 or end < 0:
    raise SystemExit("ROOM_LIST 경계가 없다")
print("const src = " + json.dumps(src[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {esc: s => String(s), statusReasonText: () => "", shortAgo: () => "", roomStatusIcon: () => ""};
vm.createContext(context);
vm.runInContext(`${src}
this.renderRooms = renderRooms;`, context, {filename: "marina_mobile::rooms"});
const {renderRooms} = context;

const 방 = (name, status, lastAt, extra) => Object.assign({
  root: "/wt/" + name, name, status, lastAt, tabs: [{source: "claude", sid: name, title: name}],
}, extra || {});

// ① 최근 소식이 맨 위 — 상태와 무관하게.
const html = renderRooms([
  방("오래된문제", "문제", 100),
  방("방금답옴", "대기", 900),
  방("어제작업", "작업중", 500),
], 1000, true, "", "");
const 순서 = [...html.matchAll(/data-room="\/wt\/([^"]+)"/g)].map(m => m[1]);
assert.deepEqual(순서.slice(0, 3), ["방금답옴", "어제작업", "오래된문제"],
  `최근 순이 아니다: ${순서}`);

// ② 접어둔 방은 최근이어도 뒤로.
const html2 = renderRooms([
  방("접어둔최신", "대기", 999, {archived: true}),
  방("보통", "대기", 10),
], 1000, true, "", "");
const 순서2 = [...html2.matchAll(/data-room="\/wt\/([^"]+)"/g)].map(m => m[1]);
assert.deepEqual(순서2, ["보통", "접어둔최신"], `접어둔 방이 위로 올라왔다: ${순서2}`);
console.log("ok 방 목록: 최근 소식 순 · 접어둔 것만 뒤로");
''')
PY

echo "PASS test-room-order"
