#!/usr/bin/env bash
# 보낸 즉시 **접수됐다**고 말하고, 답이 나올 자리에서 **생각 중**이 돈다.
#
# 형: "내 모든 답변에 대해서 바로바로 접수된거로 표현하고, 채팅창 위에 작업중 뭔가 와닿지
# 않으니까 채팅창 너 대답 부분에 작업중 돌리는 것 처럼 생각 중 같은거 넣자".
#
# 왜 안 와닿았나: ① claude 전달 방식은 언제나 "queue" 라, 놀고 있던 세션에 보내도 화면은
# "작업 끝나면 전달돼요 · 대기열" 이라 했다 ② 작업중 표시가 헤더에만 있어 대화와 떨어져 있었다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ① 서버: 한가한 세션에 넣고 도착까지 확인했으면 delivery 는 accepted(대기열이 아니다).
PYTHONPATH="$SCR" python3 - "$TMP" "$HERE" <<'PY'
import json
import sys
from pathlib import Path

import marina_mobile as mm

tmp, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
mm.safe_root = lambda value: Path(str(value)).resolve()
mm.OUTBOX_DIR = tmp / "outbox"
mm._agent_input_pause = lambda: None
mm._live_agent_tid = lambda r, s, i: "tid-1"
mm._recover_pending_settings = lambda r, s, i, t: "none"

transcript = tmp / "session.jsonl"
transcript.write_text("{}\n", encoding="utf-8")
mm.agent_transcript_path = lambda r, s, i: transcript

def echoing(tid, text):
    if text in ("\r", "\t"):
        return
    with transcript.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps({"type": "user", "message": {"content": text}}, ensure_ascii=False) + "\n")
mm.term_input = echoing

body = lambda sid: {"root": str(root), "text": "이거 확인해줘",
                    "target": {"type": "agent", "source": "claude", "sid": sid}}

mm._native_agent_active = lambda r, s, i: False        # 한가하다
out = mm.mobile_send(body("sid-idle"))
assert out["delivery"] == "accepted", out

mm._native_agent_active = lambda r, s, i: True         # 작업 중이다 → 줄을 선다
out = mm.mobile_send(body("sid-busy"))
assert out["delivery"] == "queue", out

print("ok 서버: 한가하면 접수됨, 작업 중이면 대기열")
PY

# ② 화면 문구: accepted 는 "접수됨"으로 읽힌다(대기열과 구분).
python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

js = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
start = js.find("    function pendingDeliveryLabel")
end = js.find("\n    function runtimeLabel")
print("const src = " + json.dumps(js[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.pendingDeliveryLabel = pendingDeliveryLabel;`, context, {filename: "chat-render.js::delivery"});
const {pendingDeliveryLabel} = context;

assert.match(pendingDeliveryLabel("accepted"), /접수/, "한가한 세션에 넣었는데 접수됐다고 안 한다");
assert.doesNotMatch(pendingDeliveryLabel("accepted"), /대기열/, "접수된 걸 대기열이라 하면 안 와닿는다");
assert.match(pendingDeliveryLabel("queue"), /대기열/);
// 오래돼도 접수됨은 실패로 뒤집히지 않는다(서버가 도착까지 확인한 사실이다).
assert.match(pendingDeliveryLabel("accepted", Date.now() - 600000), /접수/);
console.log("ok 문구: 접수됨과 대기열을 구분한다");
''')
PY

# ③ 생각 중: 언제 보이고 언제 사라지나.
python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

mobile = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
start, end = mobile.find("// THINKING_STATE_START"), mobile.find("// THINKING_STATE_END")
if start < 0 or end < 0:
    raise SystemExit("THINKING_STATE 경계가 없다")
js = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
esc_start, esc_end = js.find("// ESC_HELPERS_START"), js.find("// ESC_HELPERS_END")
think_start, think_end = js.find("// THINKING_BUBBLE_START"), js.find("// THINKING_BUBBLE_END")
if think_start < 0:
    raise SystemExit("THINKING_BUBBLE 경계가 없다")
print("const src = " + json.dumps(js[esc_start:esc_end] + js[think_start:think_end]
                                 + mobile[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const slot = {hidden: true, innerHTML: "", dataset: {}};
const classes = new Set();
const view = {classList: {add: c => classes.add(c), remove: c => classes.delete(c),
                          contains: c => classes.has(c)}};
const context = {thinkingSlot: slot, chatView: view};
vm.createContext(context);
vm.runInContext(`${src}
this.thinkingLabelFor = thinkingLabelFor;
this.renderThinkingSlot = renderThinkingSlot;
this.renderThinking = renderThinking;`, context, {filename: "marina_mobile::thinking"});
const {thinkingLabelFor, renderThinkingSlot, renderThinking} = context;

const agent = extra => ({kind: "agent", status: "idle", ...extra});

// 작업 중이면 보인다.
assert.equal(thinkingLabelFor(agent({status: "working"}), false, 0), "생각 중");
// 방금 보냈으면 서버가 못 따라잡아도 보인다(가만있는 느낌 방지).
assert.equal(thinkingLabelFor(agent({status: "idle"}), true, 0), "생각 중");
// 끝났으면 사라진다.
assert.equal(thinkingLabelFor(agent({status: "idle"}), false, 0), "");
assert.equal(thinkingLabelFor(agent({status: "completed"}), false, 0), "");
// **답을 기다리는 질문이 떠 있으면 안 보인다** — 그건 내 차례가 아니라 형 차례다.
assert.equal(thinkingLabelFor(agent({status: "working", pendingQuestion: {token: "q1"}}), true, 0), "");
// 에이전트 대화가 아니면 '생각'이 없다.
assert.equal(thinkingLabelFor({kind: "term", status: "working"}, true, 0), "");
assert.equal(thinkingLabelFor(null, true, 0), "");

// 슬롯 갱신: 보일 땐 채우고, 끝나면 비운다.
renderThinkingSlot(agent({status: "working"}), false);
assert.equal(slot.hidden, false);
assert.match(slot.innerHTML, /thinkingBubble/);
assert.match(slot.innerHTML, /생각 중/);
// 떠 있는 표시라 마지막 말풍선을 가린다 — 보이는 동안엔 그만큼 자리를 연다.
assert.equal(view.classList.contains("thinking"), true, "여백을 안 열어 마지막 말풍선이 가린다");
// 같은 상태로 다시 그려도 DOM 을 건드리지 않는다 — 갈아끼우면 애니메이션이 매번 처음으로 튄다.
slot.innerHTML = "SENTINEL";
renderThinkingSlot(agent({status: "working"}), false);
assert.equal(slot.innerHTML, "SENTINEL", "같은 상태인데 DOM 을 다시 썼다");
// 끝나면 비우고 감춘다(잔상 금지).
renderThinkingSlot(agent({status: "idle"}), false);
assert.equal(slot.hidden, true);
assert.equal(slot.innerHTML, "");
assert.equal(view.classList.contains("thinking"), false, "끝났는데 빈 자리가 남는다");

// 마크업은 이스케이프된다(라벨이 언젠가 서버발이 되어도 안전하게).
assert.doesNotMatch(renderThinking("<img src=x onerror=1>"), /<img/);
console.log("ok 생각 중: 작업 중에만·질문 땐 숨김·불필요한 재렌더 없음");
''')
PY

# ③-1 **보이는 자리**에 있어야 한다. 마크업에 채워 넣는 것만으론 부족하다 — #chatView 는 행
# 두 개짜리 그리드라, 평범한 자식으로 두면 암묵 행으로 밀려 overflow:hidden 에 통째로 잘린다
# (실측 2026-08-17: 형 "생각중 안뜨고 그냥 작업중이네"). 그때도 위 테스트는 전부 통과했다.
PYTHONPATH="$SCR" python3 - <<'PY2'
import re
from marina_mobile import render_mobile_html

html = render_mobile_html()
chat_view = re.search(r"#chatView \{([^}]*)\}", html)
assert chat_view, "#chatView 규칙을 못 찾았다"
rows = re.search(r"grid-template-rows:\s*([^;]+);", chat_view.group(1))
slot = re.search(r"#thinkingSlot \{([^}]*)\}", html)
assert slot, "#thinkingSlot 스타일이 없다"
declared_rows = len((rows.group(1) if rows else "").split())
floating = "position: absolute" in slot.group(1)
# 그리드 행이 부족한데 평범한 자식이면 잘린다. 떠 있거나(absolute), 제 행이 선언돼 있어야 한다.
assert floating or declared_rows >= 3, (
    f"#thinkingSlot 이 잘리는 자리에 있다 — rows={declared_rows}, style={slot.group(1).strip()}")
if floating:
    assert "#chatView" in html and "thinking .turns" in html,         "떠 있으면 마지막 말풍선을 가린다 — 그만큼 아래 여백을 열어야 한다"
    assert 'classList.add("thinking")' in html and 'classList.remove("thinking")' in html,         "여백을 여닫는 코드가 없다"
print("ok 생각 중이 잘리지 않는 자리에 있다")
PY2

# ④ 낙관적 말풍선: 누르는 즉시 서고, 응답이 오면 **같은 레코드에** 결과가 얹힌다.
python3 - "$SCR" <<'PY2' | node
import json
import sys
from pathlib import Path

mobile = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
start, end = mobile.find("// OPTIMISTIC_TURN_START"), mobile.find("// OPTIMISTIC_TURN_END")
if start < 0 or end < 0:
    raise SystemExit("OPTIMISTIC_TURN 경계가 없다")
print("const src = " + json.dumps(mobile[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
let seq = 0;
const context = {
  pendingTurns: {},
  // 실제 queuePendingTurn 의 계약만 흉내낸다: 목록 끝에 id 를 가진 레코드를 붙인다.
  queuePendingTurn(key, text, delivery, tid, target, root) {
    seq += 1;
    context.pendingTurns[key] = (context.pendingTurns[key] || []).concat([
      {id: `pend${seq}`, role: "user", text, pending: true, delivery, tid: tid || "", target, root},
    ]);
  },
};
vm.createContext(context);
vm.runInContext(`${src}
this.queueOptimisticTurn = queueOptimisticTurn;
this.settleOptimisticTurn = settleOptimisticTurn;`, context, {filename: "marina_mobile::optimistic"});
const {queueOptimisticTurn, settleOptimisticTurn} = context;

// 누르는 즉시 선다.
const id = queueOptimisticTurn("s1", "안녕", {type: "agent"}, "/wt");
assert.ok(id, "말풍선이 안 섰다 — 응답 전까지 화면이 죽은 것처럼 보인다");
assert.equal(context.pendingTurns.s1.length, 1);
assert.equal(context.pendingTurns.s1[0].delivery, "pending");

// 응답이 오면 같은 레코드에 얹힌다 — **새로 만들지 않는다**(같은 말이 두 개로 보인다).
assert.equal(settleOptimisticTurn("s1", id, "accepted", "tid-9"), true);
assert.equal(context.pendingTurns.s1.length, 1, "응답 뒤 말풍선이 늘었다");
assert.equal(context.pendingTurns.s1[0].delivery, "accepted");
assert.equal(context.pendingTurns.s1[0].tid, "tid-9");
assert.equal(context.pendingTurns.s1[0].failed, false);

// 실패하면 그 자리에서 실패로 뒤집힌다(조용히 사라지지 않는다).
const id2 = queueOptimisticTurn("s1", "두번째", {type: "agent"}, "/wt");
settleOptimisticTurn("s1", id2, "failed", "");
assert.equal(context.pendingTurns.s1[1].failed, true);

// 그새 서버 행이 대신해 사라졌으면 조용히 넘어간다(되살리지 않는다).
context.pendingTurns.s1 = [];
assert.equal(settleOptimisticTurn("s1", id, "accepted", ""), false);
assert.equal(context.pendingTurns.s1.length, 0, "확정돼 사라진 말풍선을 되살렸다");
console.log("ok 낙관 말풍선: 즉시 서고, 결과는 같은 자리에 얹힌다");
''')
PY2

echo "PASS test-mobile-thinking"
