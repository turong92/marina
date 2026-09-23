#!/usr/bin/env bash
# 상단 드롭다운 — 스펙 §2(2026-09-09-chat-nav-redesign-design.md).
#
# 왜: "다른 대화로 가는 길"이 셋으로 흩어져 있었다 — ☰ 서랍(방), 헤더 칩줄(이 방 대화),
# 입력창 위 버튼(작업자). 형식도 셋 다 달랐다. 하나로 접되, 접으면서 **잃는 것이 없어야** 한다.
#
# 계약: ① 트리거는 접힌 것들의 상태를 요약한다(가장 센 것 하나 + 개수, 안 보이는 것만 셈)
# ② 방 이름과 대화 제목이 같으면 하나로 접는다 ③ 최근 대화는 **내가 마지막으로 연 순서**
# ④ 응답필요는 상한 밖이어도 끌어올린다(자리는 가장 오래 안 본 것이 낸다) ⑤ 빈 구역은 숨긴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json, sys
from pathlib import Path
scripts = Path(sys.argv[1])
src = (scripts / "marina_mobile.py").read_text(encoding="utf-8")
def block(tag):
    a, b = src.find(f"// {tag}_START"), src.find(f"// {tag}_END")
    if a < 0 or b < 0: raise SystemExit(f"{tag} 경계가 없다")
    return src[a:b]
helpers = (scripts / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
esc = helpers[helpers.find("// ESC_HELPERS_START"):helpers.find("// ESC_HELPERS_END")]
# 상태→dot 표는 복제하지 않는다 — 정의를 같이 싣는다(단일 출처).
print("const src = " + json.dumps(esc + block("AGENT_STATUS_META") + block("NAV_DROPDOWN")) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const ctx = {};
vm.createContext(ctx);
vm.runInContext(`${src}
this.navBadge = navBadge; this.navRecent = navRecent;
this.navTriggerLabel = navTriggerLabel; this.renderNavSections = renderNavSections;
this.navVisited = navVisited;`,
  ctx, {filename: "marina_mobile::nav"});
const {navBadge, navRecent, navTriggerLabel, renderNavSections, navVisited} = ctx;

// ① 가장 센 상태 하나 + 개수. 우선순위는 문제 > 응답필요 > 작업중.
assert.equal(navBadge([{status:"working"},{status:"failed"},{status:"blocked"}]).label, "문제");
assert.equal(navBadge([{status:"working"},{status:"blocked"},{status:"waiting"}]).label, "응답필요");
assert.equal(navBadge([{status:"working"},{status:"blocked"},{status:"waiting"}]).count, 2,
  "blocked 와 waiting 은 같은 '응답필요' 로 함께 센다");
assert.equal(navBadge([{status:"idle"},{status:"completed"}]), null, "조용한 것에 배지를 달았다");
assert.equal(navBadge([]), null);

// ② 방 이름과 대화 제목이 같으면 하나로 접는다 — 카드가 이름을 두 번 반복하던 그 문제.
assert.equal(navTriggerLabel("결제 플로우", "결제 플로우"), "결제 플로우");
assert.equal(navTriggerLabel("결제 플로우", "기본"), "결제 플로우 · 기본");
assert.equal(navTriggerLabel("", "기본"), "기본");
assert.equal(navTriggerLabel("결제 플로우", ""), "결제 플로우");

// ③-0 최근의 재료는 **내가 연 것만**. 안 열어 본 대화로 빈자리를 채우면 방을 가리지 않고
// 남의 대화가 "최근"에 섞인다(형 신고 2026-09-23). 자리가 남으면 비워 둔다.
{
  const 세션들 = [{key:"a"}, {key:"b"}, {key:"안본것"}];
  assert.deepEqual(navVisited(["b","a"], 세션들).map(x => x.key), ["b","a"], "연 순서가 아니다");
  assert.deepEqual(navVisited([], 세션들), [], "안 열어 본 대화가 최근으로 올라왔다");
  assert.deepEqual(navVisited(["없어진키","a"], 세션들).map(x => x.key), ["a"], "사라진 대화를 지웠어야 한다");
}

// ③ 최근 대화 = 내가 마지막으로 **연** 순서. 서버 활동순이 아니다 —
// 활동순이면 내가 안 건드린 게 위로 튀어오른다.
const 최근 = [
  {key:"a", status:"idle"},   {key:"b", status:"idle"}, {key:"c", status:"idle"},
  {key:"d", status:"idle"},   {key:"e", status:"idle"}, {key:"f", status:"blocked"},
];
const 잘린것 = navRecent(최근, 5);
assert.equal(잘린것.length, 5);
assert.deepEqual(잘린것.slice(0, 4).map(x => x.key), ["a","b","c","d"], "방문 순서가 흐트러졌다");

// ④ 응답필요(f)는 5개 밖이었지만 들어온다. 자리는 **가장 오래 안 본 것**(e)이 낸다.
assert.ok(잘린것.some(x => x.key === "f"), "물어봐 놓고 기다리는 대화를 놓쳤다");
assert.ok(!잘린것.some(x => x.key === "e"), "가장 오래 안 본 것이 자리를 안 냈다");

// ④-1 급한 게 많아도 목록을 통째로 갈아치우지는 않는다 — 최근순이 아예 사라지면 뜻이 없다.
const 급한게많음 = [{key:"a",status:"idle"},{key:"b",status:"idle"},
  {key:"x",status:"blocked"},{key:"y",status:"blocked"},{key:"z",status:"blocked"}];
const 결과 = navRecent(급한게많음, 2);
assert.equal(결과.length, 2);
assert.ok(결과.some(x => x.key === "a"), "가장 최근에 본 것까지 밀려났다");

// ⑤ 빈 구역은 통째로 숨긴다.
const 방하나 = renderNavSections({recent: [], roomTabs: [], subagents: [], currentKey: ""});
for (const 제목 of ["최근 대화", "이 방의 대화", "이 대화의 작업자"]) {
  assert.ok(!방하나.includes(제목), `빈 구역이 그려졌다: ${제목}`);
}
const 셋다 = renderNavSections({
  recent: [{key:"a", title:"결제", room:"결제 플로우", status:"working"}],
  roomTabs: [{key:"b", title:"기본", status:"idle"}, {key:"c", title:"디자인", status:"idle"}],
  subagents: [{id:"s1", title:"Explore: 결제 API", status:"completed"}],
  currentKey: "b",
});
for (const 제목 of ["최근 대화", "이 방의 대화", "이 대화의 작업자"]) {
  assert.ok(셋다.includes(제목), `구역이 없다: ${제목}`);
}
// 대화는 전환(data-nav-chat), 작업자는 패널(data-nav-agent) — 누르기 전에 결과를 안다.
assert.match(셋다, /data-nav-chat="b"/);
// 최근 구역은 방을 넘나든다 — 방 이름이 **앞에** 붙어야 구별이 된다(대화 제목은 죄다 "기본"이다).
// 붙이는 규칙은 트리거와 같은 것을 쓴다: 방과 제목이 같으면 접는다.
assert.ok(셋다.includes("결제 플로우 · 결제"), `최근 줄에 방 이름이 없다: ${셋다.slice(0, 400)}`);
assert.match(셋다, /data-nav-agent="s1"/);
assert.ok(!/data-nav-chat="s1"/.test(셋다), "작업자를 대화처럼 눌리게 했다");

console.log("ok");
''')
PY
echo "PASS: 상단 드롭다운 — 요약 배지·이름 접기·최근순·응답필요 끌어올림·빈 구역 숨김"
