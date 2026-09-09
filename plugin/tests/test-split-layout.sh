#!/usr/bin/env bash
# 분할 레이아웃 공통 규칙 — 터미널과 대화가 **같은 표**를 쓴다(스펙 §3.2).
#
# 왜 뽑았나: 값이 갈리면 버튼 개수와 칸 개수가 어긋난다. 터미널은 이미
# `if (termFocus >= termSlotCount()) termFocus = 0` 으로 그 사고를 막고 있고, 대화 쪽에 표를
# 복사해 두면 같은 사고를 두 번 겪는다.
#
# 계약: ① 칸이 최소치보다 좁거나 낮으면 그 레이아웃은 못 쓴다 ② **고른 것과 그리는 것은
# 다르다** — 창이 좁아지면 접어 그리되 고른 값은 보존한다(창을 줄였다 늘리면 되돌아온다)
# ③ 배치는 "이미 떠 있으면 그 칸 / 빈 칸 있으면 거기 / 없으면 focus" ④ 드래그로도 최소치를
# 못 깬다 ⑤ 저장값이 깨져도 없는 칸을 가리키지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json, sys
from pathlib import Path
src = (Path(sys.argv[1]) / "marina-web" / "app-9b-split.js").read_text(encoding="utf-8")
print("const src = " + json.dumps(src) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const ctx = {};
vm.createContext(ctx);
vm.runInContext(`${src}
this.splitFits = splitFits; this.splitEffective = splitEffective;
this.splitPlace = splitPlace; this.splitFrac = splitFrac;
this.splitNormalize = splitNormalize; this.splitSlotCount = splitSlotCount;
this.SPLIT_LAYOUTS = SPLIT_LAYOUTS;`, ctx, {filename: "app-9b-split"});
const {splitFits, splitEffective, splitPlace, splitFrac, splitNormalize, splitSlotCount, SPLIT_LAYOUTS} = ctx;

// ① 칸 크기로 가능 여부가 갈린다. 좌우 2분할은 폭이 720 은 돼야 한다(360×2).
assert.equal(splitFits("lr", 800, 900), true);
assert.equal(splitFits("lr", 700, 900), false, "칸이 350px 인데 통과시켰다");
assert.equal(splitFits("tb", 400, 700), true);
assert.equal(splitFits("tb", 400, 600), false, "칸 높이가 300px 인데 통과시켰다");
assert.equal(splitFits("4", 800, 700), true, "400×350 이면 4분할이 들어간다");
assert.equal(splitFits("4", 800, 600), false, "칸 높이가 300px 인데 통과시켰다");
assert.equal(splitFits("1", 200, 200), false, "최소치는 1분할에도 적용된다");

// ② **고른 것과 그리는 것은 다르다.** 넓으면 그대로, 좁으면 접어 그린다.
assert.equal(splitEffective("4", 1400, 900), "4");
assert.equal(splitEffective("4", 800, 900), "4", "400×450 이면 4분할이 그대로 들어간다");
// 높이가 모자라면 **행**을 줄인다 → 좌우 2분할(칸마다 전체 높이). 상하로 접으면 더 낮아진다.
assert.equal(splitEffective("4", 1400, 600), "lr", "높이가 모자란데 행을 안 줄였다");
// 폭이 모자라면 **열**을 줄인다 → 상하 2분할(칸마다 전체 폭).
assert.equal(splitEffective("4", 700, 900), "tb", "폭이 모자란데 열을 안 줄였다");
assert.equal(splitEffective("4", 500, 1200), "tb");
assert.equal(splitEffective("4", 500, 500), "1");
assert.equal(splitEffective("lr", 500, 900), "1");
// 좁혔다 넓히면 **고른 값 그대로** 돌아온다 — 폴드를 펴면 아무것도 안 눌러도 원래대로.
const 고른것 = "lr";
assert.equal(splitEffective(고른것, 500, 900), "1");
assert.equal(splitEffective(고른것, 900, 900), "lr", "넓혔는데 설정이 뭉개졌다");

// ③ 배치 규칙 — 터미널과 같다.
assert.equal(splitPlace(["a", null, null, null], 4, "a", 3), 0, "이미 떠 있으면 그 칸");
assert.equal(splitPlace(["a", null, null, null], 4, "b", 3), 1, "빈 칸이 있으면 거기");
assert.equal(splitPlace(["a", "b", "c", "d"], 4, "e", 2), 2, "꽉 찼으면 보고 있는 칸");
// 칸 수 밖에 있던 것은 '이미 떠 있는' 것으로 치지 않는다 — 안 보이는 칸에 포커스를 준다.
assert.equal(splitPlace([null, null, "z", null], 2, "z", 0), 0, "안 보이는 칸을 그대로 썼다");

// ④ 드래그로도 최소치를 못 깬다.
const [a1] = splitFrac(50, 1000, 360);
assert.ok(Math.abs(a1 - 0.36) < 1e-9, `왼쪽이 최소치 아래로 갔다: ${a1}`);
const [a2] = splitFrac(990, 1000, 360);
assert.ok(Math.abs(a2 - 0.64) < 1e-9, `오른쪽이 최소치 아래로 갔다: ${a2}`);
// 컨테이너가 최소치의 두 배도 안 되면 반반이 최선 — 클램프가 서로 싸우면 안 된다.
const [a3, b3] = splitFrac(10, 600, 360);
assert.ok(Math.abs(a3 - 0.5) < 1e-9 && Math.abs(b3 - 0.5) < 1e-9, `${a3},${b3}`);

// ⑤ 저장값이 깨져도 없는 칸을 가리키지 않는다 — 터미널이 실제로 겪은 버그다.
const 복원 = splitNormalize({layout: "1", focus: 3, slots: ["a", "b", "c", "d"]});
assert.equal(복원.focus, 0, "1분할인데 4번째 칸을 가리킨다");
assert.equal(splitNormalize({layout: "없는것"}).layout, "1");
assert.equal(splitNormalize(null).slots.length, 4);
// vm 안에서 만든 배열은 프로토타입이 달라 deepStrictEqual 이 값이 같아도 거부한다 — JSON 으로 잰다.
assert.equal(JSON.stringify(splitNormalize({frac: {col: [9, -1]}}).frac.col), "[0.5,0.5]",
  "말도 안 되는 비율을 그대로 썼다");
assert.equal(splitSlotCount("4"), 4);
assert.equal(splitSlotCount("없는것"), 1, "모르는 레이아웃은 1칸으로 떨어져야 한다");

console.log("ok");
''')
PY
echo "PASS: 분할 규칙 — 최소칸·접힘/복귀·배치·드래그 클램프·복원 보정"
