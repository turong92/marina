#!/usr/bin/env bash
# 메시지·표 복사 — 형: "일일히 복사할라니까 힘들다 … 진짜 모바일에서도 되게. 표는 따로".
# 잠그는 계약:
#   ① 말풍선마다 복사 버튼, 원문(마크다운) 그대로 — 화면 HTML 이 아니다. 아직 안 간 말(pending)은 없다.
#   ② 표마다 따로 복사, 탭 구분(TSV) — 시트에 붙이면 칸이 산다.
#   ③ 보안 컨텍스트가 아니면(tailnet IP 로 http 접속) navigator.clipboard 가 없다 → execCommand 폴백.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
JS="$HERE/../scripts/marina-web/chat-render.js"

node - "$JS" <<'NODE'
const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert");
const src = fs.readFileSync(process.argv[2], "utf8");

function load({secure}) {
  let listener = null;
  const written = [];
  let execCalls = 0;
  const toasts = {};
  const body = {appendChild(el) { if (el.id) toasts[el.id] = el; }};
  const document = {
    body,
    addEventListener(type, fn, capture) { if (type === "click") { listener = fn; assert.strictEqual(capture, true, "캡처 단계여야 말풍선 클릭 핸들러보다 먼저 받는다"); } },
    createElement() { const el = {style: {}, setAttribute() {}, focus() {}, setSelectionRange() {}, remove() {}, value: ""}; return el; },
    getElementById(id) { return toasts[id] || null; },
    querySelectorAll() { return []; },
    execCommand(cmd) { execCalls += 1; return cmd === "copy"; },
  };
  const window = {isSecureContext: secure, getSelection: () => ""};
  const navigator = secure ? {clipboard: {writeText: t => { written.push(t); return Promise.resolve(); }}} : {};
  vm.runInNewContext(src, {window, document, navigator, setTimeout: () => 0, clearTimeout() {}, Promise});
  return {chat: window.MarinaChat, click: e => listener(e), written, execCalls: () => execCalls, toast: () => toasts.marinaCopyToast};
}

function btn(attrs, extra = {}) {
  return Object.assign({
    dataset: {}, textContent: "⧉", classList: {toggle() {}, remove() {}},
    getAttribute: k => (k in attrs ? attrs[k] : null),
    closest(sel) { return sel.includes("data-copy") ? this : null; },
  }, extra);
}
function ev(target) { return {target, preventDefault() {}, stopPropagation() {}}; }

(async () => {
  const {chat, click, written} = load({secure: true});
  const raw = "## 결과\n| a | b |\n|---|---|\n| 1 | <x> |\n\n`code` & \"따옴표\"";

  // ①
  const html = chat.renderTimelineMessage({role: "assistant", id: "m1", text: raw});
  const m = html.match(/data-copy-text="([^"]*)"/);
  assert.ok(m, "말풍선에 복사 버튼이 없다");
  const unesc = m[1].replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;/g, "'").replace(/&amp;/g, "&");
  assert.strictEqual(unesc, raw, "복사되는 게 원문 마크다운이 아니다");
  assert.ok(!chat.renderTimelineMessage({role: "user", id: "p", text: "보내는 중", pending: true}).includes("data-copy-text"),
    "아직 안 간 말에도 복사 버튼이 붙었다");
  assert.ok(!chat.renderTimelineMessage({role: "assistant", id: "e", text: "  "}).includes("data-copy-text"), "빈 말에 버튼");

  // ②
  assert.ok(html.includes("data-copy-table"), "표에 따로 복사 버튼이 없다");
  const cell = t => ({innerText: t});
  const table = {rows: [{cells: [cell("이름"), cell("값\n여러 줄")]}, {cells: [cell("a\tb"), cell(" 2 ")]}]};
  assert.strictEqual(chat.tableTsv(table), "이름\t값 여러 줄\na b\t2", "TSV 변환이 틀렸다");

  // 클릭 → 클립보드
  click(ev(btn({"data-copy-text": "안녕"})));
  await new Promise(r => setImmediate(r));
  assert.deepStrictEqual(written, ["안녕"]);
  const block = {querySelector: () => table};
  click(ev(btn({"data-copy-table": ""}, {closest(sel) { return sel === ".mdTableBlock" ? block : this; }})));
  await new Promise(r => setImmediate(r));
  assert.strictEqual(written[1], "이름\t값 여러 줄\na b\t2", "표 버튼이 TSV 를 안 넣었다");

  // ③
  const http = load({secure: false});
  const b = btn({"data-copy-text": "폴백"});
  http.click(ev(b));
  await new Promise(r => setImmediate(r));
  assert.strictEqual(http.execCalls(), 1, "비보안 컨텍스트에서 execCommand 폴백을 안 탔다");
  assert.strictEqual(b.textContent, "✓", "복사 후 표시가 안 바뀐다");
  // 웹은 폴링마다 대화를 통째로 다시 그려 버튼이 바뀐다 — 버튼과 무관한 토스트로도 알려야 한다.
  assert.ok(http.toast() && http.toast().textContent === "복사됨", "복사 토스트가 안 뜬다");

  // ④ 폰엔 호버가 없다 — 말풍선 본문을 탭하면 복사 버튼이 뜬다(자리를 차지하지 않게 평소엔 숨김).
  const cls = new Set();
  const turn = {classList: {toggle(c) { cls.has(c) ? cls.delete(c) : cls.add(c); }, remove(c) { cls.delete(c); }},
                querySelector: () => ({})};
  const body = {closest: sel => (sel === ".turn" ? turn : null)};
  http.click(ev(body));
  assert.ok(cls.has("showTools"), "말풍선을 탭해도 복사 버튼이 안 뜬다");
  http.click(ev(body));
  assert.ok(!cls.has("showTools"), "다시 탭하면 접혀야 한다");
  const link = {closest: sel => (sel === ".turn" ? turn : sel.startsWith("a,") ? {} : null)};
  http.click(ev(link));
  assert.ok(!cls.has("showTools"), "링크를 누른 건데 복사 버튼이 떴다");

  console.log("PASS test-chat-copy");
})().catch(e => { console.error("FAIL:", e.message); process.exit(1); });
NODE
