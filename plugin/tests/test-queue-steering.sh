#!/usr/bin/env bash
# 스티어링(작업 중 끼어든 메시지)이 "대기 중"으로 문신되거나 "취소됨"으로 뒤집히면 안 된다.
# 형 신고: "스티어링한 대화들 너가 소화했는데 대기중으로 문신되고, 새로고침하니까 하나는 사라지고
#           하나는 취소됨 되어있는데. 둘 다 소화된거같거든?"
#
# 실측한 기록 형태 3가지 (Claude Code 2.1.220):
#   A) enqueue → 진짜 user 행            : 정상 전달. 말풍선은 user 행이 그린다(중복 금지).
#   B) enqueue → remove + attachment(queued_command, prompt=원문)
#                                        : **실행 중 턴이 삼킴**. 진짜 user 행이 없으므로 여기서 말풍선을
#                                          만들어야 하고, 대기도 취소도 아니다(steered).
#   C) enqueue → remove, 배달 흔적 없음  : 진짜 취소.
# B 와 C 는 remove 만 보면 똑같아서, 예전 코드가 B 를 전부 "취소됨"으로 찍었다(최근 25세션에 27건).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import marina_sessions as ms

def enqueue(text):
    return {"type": "queue-operation", "operation": "enqueue", "content": text}
def remove(text):
    return {"type": "queue-operation", "operation": "remove", "content": text}
def steer(text):
    return {"type": "attachment", "attachment": {"type": "queued_command", "prompt": text,
                                                 "commandMode": "prompt", "origin": {"kind": "human"}}}
def user(text):
    return {"type": "user", "message": {"role": "user", "content": text}}
def assistant(text):
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}

def timeline(rows):
    return ms._transcript_timeline(list(enumerate(rows)), "claude")

def bubbles(rows):
    return [i for i in timeline(rows) if i.get("kind") == "message" and i.get("role") == "user"]

# ---------- A) 진짜 user 행으로 전달 → 말풍선은 하나뿐(중복 금지) ----------
rows = [enqueue("좌측 패널 만들자"), assistant("작업 중"), user("좌측 패널 만들자")]
got = bubbles(rows)
assert len(got) == 1, [b["text"] for b in got]
assert not got[0].get("queued") and not got[0].get("steered"), got[0]

# ---------- B) 삼켜짐 → steered. 대기 중도 취소됨도 아니고, 말풍선은 반드시 있어야 한다 ----------
rows = [enqueue("뭐하니"), remove("뭐하니"), steer("뭐하니"), assistant("방금 끝났어")]
got = bubbles(rows)
assert len(got) == 1, [b["text"] for b in got]
b = got[0]
assert b["text"] == "뭐하니", b
assert b.get("steered") is True, f"삼켜진 메시지는 steered 여야 함: {b}"
assert not b.get("queued"), f"대기 중으로 남으면 문신이 된다: {b}"
assert not b.get("queuedCancelled"), f"소화한 말이 취소됨으로 뒤집혔다: {b}"

# attachment 가 remove 보다 먼저 와도 같은 결과여야 한다(행 순서에 의존하지 않는다)
got2 = bubbles([enqueue("뭐하니"), steer("뭐하니"), remove("뭐하니")])
assert got2[0].get("steered") is True and not got2[0].get("queuedCancelled"), got2[0]

# ---------- C) 진짜 취소 → 취소됨 ----------
rows = [enqueue("아니 취소"), remove("아니 취소"), assistant("계속")]
got = bubbles(rows)
assert len(got) == 1 and got[0].get("queuedCancelled") is True, got
assert not got[0].get("steered"), got[0]

# ---------- 아직 대기 중(enqueue 만) → 대기 중 ----------
got = bubbles([enqueue("이건 아직 대기"), assistant("작업 중")])
assert len(got) == 1 and got[0].get("queued") is True and not got[0].get("queuedCancelled"), got
assert not got[0].get("steered"), got[0]

# ---------- 하네스 주입은 여전히 말풍선을 만들지 않는다 ----------
for injected in ("<system-reminder>x</system-reminder>", "<task-notification>y</task-notification>",
                 "[SYSTEM NOTIFICATION] z"):
    assert bubbles([enqueue(injected), remove(injected), steer(injected)]) == [], injected

# ---------- 섞여 있어도 서로 오염되지 않는다 ----------
rows = [enqueue("삼켜짐"), enqueue("취소됨"), enqueue("대기중"), enqueue("정상전달"),
        remove("삼켜짐"), steer("삼켜짐"), remove("취소됨"), user("정상전달"), assistant("끝")]
got = {b["text"]: b for b in bubbles(rows)}
assert got["삼켜짐"].get("steered") and not got["삼켜짐"].get("queuedCancelled"), got["삼켜짐"]
assert got["취소됨"].get("queuedCancelled") is True, got["취소됨"]
assert got["대기중"].get("queued") is True and not got["대기중"].get("queuedCancelled"), got["대기중"]
assert not got["정상전달"].get("queued") and not got["정상전달"].get("steered"), got["정상전달"]
assert len(got) == 4, sorted(got)

# ---------- 마스킹/길이 정규화가 양쪽에 같이 걸려야 매칭이 된다 ----------
secret = "토큰은 ghp_" + "a" * 30 + " 야"
got = bubbles([enqueue(secret), remove(secret), steer(secret)])
assert len(got) == 1 and got[0].get("steered") is True, \
    f"마스킹된 키로도 배달이 매칭돼야 한다(한쪽만 원문이면 조용히 어긋난다): {got}"
assert "ghp_" not in got[0]["text"], got[0]["text"]

print("PASS ① 큐 상태 판정: 전달(중복없음) · 삼켜짐=steered · 취소=취소됨 · 대기=대기중 · 주입제외 · 혼재 · 마스킹 매칭")
PY

# ---------- 렌더 키에 큐 상태가 실려야 한다(안 실리면 배지가 새로고침 전까지 문신) ----------
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' | node
# 렌더 키 헬퍼는 marina-web/chat-render.js 로 옮겨졌다(웹과 공유). 마커도 같이 따라갔다.
import json
import sys
from pathlib import Path

html = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
a, b = html.find("// TIMELINE_KEY_START"), html.find("// TIMELINE_KEY_END")
if a < 0 or b < 0 or b <= a:
    raise SystemExit("TIMELINE_KEY boundaries missing")
print("const keySource = " + json.dumps(html[a:b]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const ctx = {pendingKeyPart: () => 0};
vm.createContext(ctx);
vm.runInContext(`${keySource}\nthis.timelineItemKeyParts = timelineItemKeyParts;`, ctx, {filename: "key"});
const parts = it => JSON.stringify(ctx.timelineItemKeyParts(it));

const base = {id: "q1", kind: "message", role: "user", text: "뭐하니"};
// 큐 상태가 바뀌면 키도 바뀌어야 한다 — 안 바뀌면 DOM 을 안 갈아서 배지가 그대로 남는다.
assert.notEqual(parts({...base, queued: true}), parts({...base, steered: true}), "대기중 → 삼켜짐이 키에 반영 안 됨");
assert.notEqual(parts({...base, queued: true}), parts({...base, queued: true, queuedCancelled: true}), "대기중 → 취소됨이 키에 반영 안 됨");
assert.notEqual(parts(base), parts({...base, queued: true}), "대기 배지 유무가 키에 반영 안 됨");
// 이미지도 키에 실려야 한다(exchange 키에서 빠져 있었음)
assert.notEqual(parts(base), parts({...base, images: [{ref: "1-0"}]}), "images 가 키에 반영 안 됨");
// 같은 내용은 같은 키(폴링마다 DOM 을 갈아치우지 않는다)
assert.equal(parts({...base, steered: true}), parts({...base, steered: true}));
console.log("PASS ② 렌더 키: queued/queuedCancelled/steered/images 변화가 모두 키에 반영");
''')
PY

# 두 렌더 키가 같은 helper 를 쓰는지 — 따로 적어두면 또 어긋난다
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import sys
from pathlib import Path

from marina_mobile import render_mobile_html

# 전체 렌더 키는 모바일에, exchange 렌더 키는 공유 렌더러에 있다. 둘 다 서빙되니 합쳐서 본다.
html = render_mobile_html() + "\n" + (
    Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
assert "timeline.map(timelineItemKeyParts)" in html, "전체 렌더 키가 공용 helper 를 안 씀"
assert "(exchange.items || []).map(timelineItemKeyParts)" in html, "exchange 렌더 키가 공용 helper 를 안 씀"
assert 'class="queuedTag steered"' in html, "steered 배지 렌더 없음"
assert ".queuedTag.steered {" in html, "steered 배지 스타일 없음"
# 이미 끝난 말이다 — 라벨이 진행 중처럼 읽히면 안 된다(형: "이것도 끝난건데 뭘 작업중이야 완료지").
assert "작업 중 전달됨" not in html, "steered 라벨이 진행 중처럼 읽힌다"
assert "⤳ 전달됨" in html, "steered 라벨 없음"
print("PASS ③ 배선: 렌더 키 공용화 + steered 배지")
PY

# ---------- ④ 끼어든 메시지는 exchange 를 쪼개지 않는다 ----------
# 쪼개면 진행 중이던 어시스턴트 설명(지문)이 이전 exchange 에 남고 질문만 새 exchange 로 가서,
# 답하기 전엔 읽을 게 아무것도 없다(형: "질문을 받는데 답을 해야 질문 전에 지문이 보여").
# queued 는 원래 예외였는데 steered 를 새로 만들면서 예외에 안 넣어 생긴 회귀다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' > /tmp/marina-exchange-sim.js
# conversationExchanges 는 모바일에, esc 헬퍼와 exchangeSections 는 공유 렌더러에 있다.
# 각자 자기 파일에서 찾는다.
import json
import sys
from pathlib import Path

from marina_mobile import render_mobile_html

html = render_mobile_html()
shared = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
src = shared[shared.find("// ESC_HELPERS_START"):shared.find("// ESC_HELPERS_END")]
for name, blob in (("function conversationExchanges", html), ("function exchangeSections", shared)):
    start = blob.find(name)
    end = blob.find("\n    function ", start + 10)
    if start < 0 or end < 0:
        raise SystemExit(f"{name} 을 못 찾음")
    src += "\n" + blob[start:end]
print("const src = " + json.dumps(src) + ";")
print(open(__file__.replace(".py", "")) if False else "")
PY
cat >> /tmp/marina-exchange-sim.js <<'JS'
const vm = require("node:vm");
const assert = require("node:assert/strict");
const ctx = {};
vm.createContext(ctx);
vm.runInContext(src + "\nthis.conversationExchanges = conversationExchanges; this.exchangeSections = exchangeSections;",
  ctx, {filename: "exchange"});
const {conversationExchanges, exchangeSections} = ctx;

function build(extra) {
  return [
    {kind: "message", role: "user", id: "u1", text: "이거 해줘"},
    {kind: "activity", activityType: "command", id: "a1", name: "Bash", status: "completed"},
    {kind: "message", role: "assistant", id: "s1", text: "지문입니다 — 이걸 읽고 골라야 한다"},
    Object.assign({kind: "message", role: "user", id: "x1", text: "야 근데"}, extra),
    {kind: "activity", activityType: "tool", id: "q1", name: "AskUserQuestion", status: "running"},
  ];
}
for (const [label, extra] of [["steered", {steered: true}], ["queued", {queued: true}]]) {
  const exchanges = conversationExchanges(build(extra));
  assert.equal(exchanges.length, 1, label + " 가 exchange 를 쪼갰다 (" + exchanges.length + "개)");
  const sections = exchangeSections(exchanges[0]);
  assert.ok(sections.assistant && sections.assistant.text.includes("지문입니다"),
    label + " 뒤에 질문이 오면 지문이 사라진다");
}
assert.equal(conversationExchanges(build({})).length, 2, "일반 user 메시지는 새 턴을 시작해야 한다");
console.log("PASS ④ exchange 분할: steered·queued 는 안 쪼갬(지문 유지) · 일반 user 는 쪼갬");
JS
node /tmp/marina-exchange-sim.js
rm -f /tmp/marina-exchange-sim.js

echo "PASS test-queue-steering"
