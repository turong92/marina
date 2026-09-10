#!/usr/bin/env bash
# 접어둔 방으로 가는 길은 **방 목록 안**에 있어야 한다.
#
# **왜.** 접기는 있는데 꺼내는 길이 없었다(형 2026-09-10: "접어두기한걸 다시 불러올 방법이
# 없다?"). 정확히는 있었다 — 헤더 ⋯ → "전체보기". 그런데 그 버튼엔 `listOnly` 가 붙어 있고
# CSS 가 `#mobileApp[data-view="list"] .listOnly { display: inline-flex }` 라, **채팅 화면에선
# 사라진다.** 채팅 중 좌측 드로어를 열면 방 목록은 보이는데 전체보기로 갈 문만 없다.
# 같은 함정을 프로젝트 칩이 먼저 밟았고(#listView 주석: "헤더에 두면 채팅 뷰에서 숨겨져서…
# 다른 프로젝트로 갈 방법이 없었다"), 그때 목록 안으로 옮겨서 고쳤다. 이번에도 같은 답이다.
#
# 계약: ① 접힌 방이 있으면 목록 끝에 줄이 뜨고 개수가 맞다 ② 없으면 줄도 없다 ③ 개수는
# 지금 화면(프로젝트·검색)에 걸린 것만 센다 ④ 켜면 접힌 방이 붙고 줄은 '숨기기'가 된다
# ⑤ 다 접혀서 남은 방이 없어도 줄은 남는다(유일한 출구) ⑥ 줄은 목록 마크업 안에 있고
# listOnly 를 달지 않는다 — 그래야 드로어에도 따라온다.
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
print("const src = " + json.dumps(
    esc + block("STATUS_REASON") + block("ROOM_LIST") + block("ROOM_TABS")) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.renderRooms = renderRooms;`, context, {filename: "marina_mobile::archived"});
const {renderRooms} = context;
const sources = [{id: "claude", label: "Claude"}];
const 방 = (root, extra) => Object.assign(
  {root, name: root, shortName: root, status: "대기", lastAt: 100, tabs: []}, extra || {});

// ① 접힌 방이 있으면 줄이 뜨고, 개수가 맞다.
const 기본 = renderRooms([방("/a"), 방("/b"), 방("/z1", {archived: true}),
                          방("/z2", {archived: true})], 1000, false, "", "", "", sources);
assert.match(기본, /data-archived-toggle="1"/, "접어둔 방으로 가는 줄이 없다");
assert.match(기본, />접어둔 방 2개</, "줄이 개수를 틀리게 말한다");
assert.match(기본, /aria-expanded="false"/);
// 접힌 방 자체는 아직 목록에 없다.
assert.ok(!기본.includes('data-room="/z1"'), "안 켰는데 접힌 방이 목록에 나왔다");

// ② 접힌 게 없으면 줄도 없다 — 눌러도 아무 일 없는 줄은 목록만 길게 한다.
const 없음 = renderRooms([방("/a")], 1000, false, "", "", "", sources);
assert.ok(!없음.includes("data-archived-toggle"), "접힌 게 없는데 줄이 떴다");

// ③ 개수는 **지금 화면에 걸린 것**만 센다. 다른 프로젝트의 접힌 방까지 세면 눌러도 안 나온다.
const 방들 = [방("/a", {projectId: "p1"}), 방("/z1", {projectId: "p1", archived: true}),
              방("/z2", {projectId: "p2", archived: true}),
              방("/z3", {projectId: "p2", archived: true})];
assert.match(renderRooms(방들, 1000, false, "", "p1", "", sources), />접어둔 방 1개</);
assert.match(renderRooms(방들, 1000, false, "", "p2", "", sources), />접어둔 방 2개</);
// 검색도 마찬가지다.
assert.match(renderRooms([방("/찾을것", {archived: true}), 방("/딴것", {archived: true})],
                         1000, false, "찾을것", "", "", sources), />접어둔 방 1개</);

// ④ 켜면 접힌 방이 목록에 붙고, 줄은 '숨기기'로 뒤집힌다.
const 켬 = renderRooms([방("/a"), 방("/z1", {archived: true})], 1000, true, "", "", "", sources);
assert.match(켬, /data-room="\/z1"/, "켰는데 접힌 방이 안 나온다");
assert.match(켬, /data-room-unarchive="\/z1"/, "꺼내기 손잡이가 없다");
assert.match(켬, />접어둔 방 숨기기</);
assert.match(켬, /aria-expanded="true"/);

// ⑤ 다 접혀서 보여줄 방이 하나도 없어도 **줄은 남는다** — 그게 유일한 출구다.
const 전부접힘 = renderRooms([방("/z1", {archived: true})], 1000, false, "", "", "", sources);
assert.match(전부접힘, /data-archived-toggle="1"/, "다 접었더니 출구가 사라졌다");
assert.match(전부접힘, /아직 방이 없어요/);
// 검색 결과가 비어도 마찬가지.
assert.match(renderRooms([방("/z1", {archived: true})], 1000, false, "z", "", "", sources),
             /data-archived-toggle="1"/);

// ⑥ 줄은 **목록 마크업 안**에 있고 listOnly 를 달지 않는다. 헤더에 두면 채팅 뷰에서 숨어
// 드로어에서 못 닿는다 — 고치려던 바로 그 버그다.
assert.ok(!기본.includes("listOnly"), "줄에 listOnly 가 붙었다 — 채팅 화면에서 사라진다");
assert.ok(기본.indexOf("data-archived-toggle") > 기본.indexOf('data-room="/a"'),
  "줄이 목록 맨 위에 있다 — 바닥이어야 한다");
console.log("ok");
''')
PY

# 헤더 ⋯ 는 여전히 목록 전용이다(이 테스트가 지키는 전제) — 그러니 줄이 목록 안에 있어야 한다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import re
import sys
sys.path.insert(0, sys.argv[1])
from marina_mobile import render_mobile_html          # noqa: E402
html = render_mobile_html()
m = re.search(r'<button[^>]*id="moreBtn"[^>]*>', html)
assert m and "listOnly" in m.group(0), "moreBtn 전제가 바뀌었다 — 테스트 이유를 다시 볼 것"
assert re.search(r'#mobileApp\[data-view="list"\]\s*\.listOnly', html), "listOnly 규칙이 사라졌다"
print("ok 전제 확인: 헤더 ⋯ 는 목록 화면에서만 보인다")
PY

echo "PASS: 접어둔 방으로 가는 길이 목록 안에 있다"
