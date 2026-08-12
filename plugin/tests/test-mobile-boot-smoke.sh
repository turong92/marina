#!/usr/bin/env bash
# 모바일 페이지를 **실제로 실행**해 본다 — 문자열 검사로는 못 잡는 실행 오류를 잡는 그물.
#
# 왜 필요한가: 다른 테스트들은 렌더된 HTML 문자열이나 추출한 함수만 본다. 그래서 `sessionCard` 가
# `notable` 을 선언보다 먼저 쓰는 TDZ 오류가 있었는데도 130개가 전부 통과했고, 형 화면에서는
# renderSessions 가 통째로 죽어 **세션 목록도 채팅도 안 나왔다**. 한 번이라도 굴려봤으면 잡혔다.
#
# 그래서 최소 DOM 셤 위에서 ① 스크립트 초기화 ② 실제 상태로 renderSessions ③ 실제 타임라인으로
# 대화 렌더까지 굴린다. 예외가 나면 실패.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

from marina_mobile import render_mobile_html

html = render_mobile_html()
start, end = html.find("<script>"), html.rfind("</script>")
if start < 0 or end < 0:
    raise SystemExit("script 블록을 못 찾음")
# 페이지는 /web/chat-render.js 를 먼저 로드한다(타임라인 렌더러, 웹과 공유). 브라우저와 같은
# 순서로 같은 컨텍스트에 실어야 window.MarinaChat 구조분해가 산다.
shared = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
print("const SHARED = " + json.dumps(shared) + ";")
print("const SRC = " + json.dumps(html[start + 8:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");

function mk(tag) {
  const style = {setProperty() {}, removeProperty() {}};
  const node = {
    tag, dataset: {}, style, attrs: {}, children: [], value: "", textContent: "", innerHTML: "",
    placeholder: "", disabled: false, hidden: false, open: false, tagName: String(tag).toUpperCase(),
    classList: {_s: new Set(),
      add(...a) { a.forEach(x => this._s.add(x)); },
      remove(...a) { a.forEach(x => this._s.delete(x)); },
      toggle(c, f) { if (f === undefined) { this._s.has(c) ? this._s.delete(c) : this._s.add(c); } else { f ? this._s.add(c) : this._s.delete(c); } },
      contains(c) { return this._s.has(c); }},
    setAttribute(k, v) { this.attrs[k] = v; },
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
    removeAttribute(k) { delete this.attrs[k]; },
    addEventListener() {}, appendChild(x) { this.children.push(x); return x; },
    insertBefore(x, ref) {
      const i = this.children.indexOf(x); if (i >= 0) this.children.splice(i, 1);
      const at = ref ? this.children.indexOf(ref) : this.children.length;
      this.children.splice(at < 0 ? this.children.length : at, 0, x); return x;
    },
    removeChild(x) { const i = this.children.indexOf(x); if (i >= 0) this.children.splice(i, 1); return x; },
    querySelector() { return mk("div"); }, querySelectorAll() { return []; }, closest() { return null; },
    focus() {}, blur() {}, click() {}, contains() { return false; }, matches() { return false; },
    get firstChild() { return this.children[0] || null; },
    get nextSibling() { return null; }, get parentElement() { return null; },
    get firstElementChild() { return mk("div"); },
  };
  return node;
}
const registry = new Map();
const doc = {
  getElementById: id => registry.get(id) || (registry.set(id, mk(id)), registry.get(id)),
  createElement: t => mk(t), querySelector: () => mk("div"), querySelectorAll: () => [],
  addEventListener() {}, get activeElement() { return null; }, cookie: "", get body() { return mk("body"); },
};
const ctx = {
  document: doc,
  window: {matchMedia: () => ({matches: false, addEventListener() {}}), addEventListener() {},
           visualViewport: null, innerHeight: 800, open() {},
           location: {href: "http://x/mobile", reload() {}, replace() {}}},
  localStorage: {getItem: () => null, setItem() {}, removeItem() {}},
  location: {href: "http://x/mobile", search: "", reload() {}, replace() {}},
  history: {state: null, pushState() {}, replaceState() {}, back() {}},
  fetch: () => new Promise(() => {}),
  setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
  console, JSON, Math, Date, Object, Array, String, Number, Boolean, Set, Map, URL, URLSearchParams,
  performance: {now: () => 0}, navigator: {userAgent: "node"}, requestAnimationFrame: () => 0,
  Promise, isNaN, parseInt, parseFloat, encodeURIComponent, decodeURIComponent, RegExp, Error,
  prompt: () => "",
};
ctx.self = ctx; ctx.globalThis = ctx;
vm.createContext(ctx);

// ⓪ 공유 렌더러를 먼저 — 브라우저에서도 <script src> 가 인라인 스크립트보다 앞선다
vm.runInContext(SHARED, ctx, {filename: "marina-web/chat-render.js"});
assert.ok(ctx.window.MarinaChat, "chat-render.js 가 window.MarinaChat 을 안 만들었다");

// ① 초기화가 예외 없이 끝나야 한다
vm.runInContext(SRC + `
this.__renderSessions = renderSessions;
this.__renderConversationSequence = renderConversationSequence;
this.__sessionCard = sessionCard;
this.__setState = s => { state = s; };`, ctx, {filename: "marina_mobile.py::page"});

// ② 실제와 같은 모양의 상태로 세션 목록을 그린다 — 상태값을 다양하게 섞는다
const sessions = [
  {key: "agent:claude:a1", kind: "agent", source: "claude", sid: "a1", root: "/w/one",
   title: "첫 세션", subtitle: "/w/one", preview: "작업 내용", status: "blocked", ts: 1785000000, pendingQuestion: {questions: [{question: "고를래?", options: [{label: "A"}]}]}},
  {key: "agent:codex:b2", kind: "agent", source: "codex", sid: "b2", root: "/w/one",
   title: "둘째", subtitle: "/w/one", preview: "", status: "working", ts: 1785000100},
  {key: "agent:claude:c3", kind: "agent", source: "claude", sid: "c3", root: "/w/two",
   title: "셋째", subtitle: "/w/two", preview: "", status: "idle", ts: 1785000200},
  {key: "term:t1", kind: "term", root: "/w/two", title: "터미널", subtitle: "", preview: "", tid: "t1", ts: 0},
];
ctx.__setState({worktrees: [{root: "/w/one", alias: "one", projectId: "p", agents: []},
                            {root: "/w/two", alias: "two", projectId: "p", agents: []}],
                sessions, terms: [], pins: ["/w/two"], agentOptions: {}, serverInstance: "x"});
ctx.__renderSessions();
const list = registry.get("sessionList");
assert.ok(list && list.children.length > 0, "세션 목록이 비었다 — 렌더가 죽었을 수 있다");

// 카드 하나하나도 실제로 만들어 본다(문자열 검사로는 TDZ/undefined 를 못 잡는다)
for (const session of sessions) {
  const card = ctx.__sessionCard(session);
  assert.ok(typeof card === "string" && card.includes("session-card"), `카드 렌더 실패: ${session.key}`);
}

// ③ 대화 렌더 — 설명 → 도구 → 설명 → 질문 흐름을 실제로 그린다
const exchange = {id: "u1", user: {kind: "message", role: "user", id: "u1", text: "해줘"}, items: [
  {kind: "message", role: "user", id: "u1", text: "해줘"},
  {kind: "message", role: "assistant", id: "s1", text: "먼저 이걸 봅니다"},
  {kind: "activity", activityType: "command", id: "a1", name: "Bash", label: "ls", status: "completed", detail: "ls"},
  {kind: "activity", activityType: "skill", id: "a2", name: "Skill", label: "brainstorming", status: "completed", detail: ""},
  {kind: "message", role: "assistant", id: "s2", text: "정리하면 이렇습니다"},
  {kind: "message", role: "user", id: "x1", text: "야 근데", steered: true},
  {kind: "activity", activityType: "tool", id: "q1", name: "AskUserQuestion", status: "running",
   detail: JSON.stringify({questions: [{question: "고를래?", options: [{label: "A"}, {label: "B"}], multiSelect: true}]})},
]};
const seq = ctx.__renderConversationSequence(exchange, sessions[0], true);
assert.ok(seq.includes("먼저 이걸 봅니다"), "중간 설명이 채팅으로 안 나온다");
assert.ok(seq.includes("정리하면 이렇습니다"), "두 번째 설명이 안 나온다");
assert.ok(seq.includes("brainstorming"), "읽은 스킬 이름이 안 보인다");
assert.ok(seq.includes("questionCard"), "질문 카드가 안 나온다");
assert.ok((seq.match(/data-activity-list/g) || []).length >= 2, "활동이 순서대로 여러 구간으로 접히지 않는다");

console.log("PASS 부팅+렌더 스모크: 초기화 · 세션목록 · 카드 4종 · 대화 흐름(설명/스킬/질문/구간)");
''')
PY

echo "PASS test-mobile-boot-smoke"

# 탭 아이콘 — 선언이 없으면 브라우저가 /favicon.ico 를 찾는데 마리나는 그 경로를 주지 않아
# 아이콘이 빈 채로 남는다. 웹·로그인 화면엔 있었고 모바일만 빠져 있었다(형: "내 파비콘 어디갔어").
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html
html = render_mobile_html()
assert 'rel="icon"' in html, "모바일에 아이콘 선언이 없다 — 탭 아이콘이 빈다"
assert "/web/favicon.png" in html, "아이콘이 /web/ 아래를 가리켜야 한다(로그인 전에도 받아지는 공개 경로)"
assert "favicon-dark.png" in html and "prefers-color-scheme: dark" in html, \
    "다크모드용 아이콘이 없다 — 어두운 탭에서 남색 아이콘이 묻힌다"
# 폴백은 **진한 쪽**이어야 한다. media 를 못 읽는 브라우저에서 흰 아이콘이 뜨면 밝은 탭 배경에
# 아예 묻혀 안 보인다(형: "화이트모드에서 흰거 잘 안보여서"). 남색은 어두운 배경에서도 윤곽이 남는다.
tail = html[html.rfind('rel="icon"'):]
assert "favicon.png" in tail.split(">")[0] and "favicon-dark" not in tail.split(">")[0], \
    "마지막(폴백) 아이콘 선언이 흰색 버전이다 — 밝은 배경에서 안 보인다"
# 사용량은 **우상단 게이지 한 곳**에서만 말한다. 예전엔 입력창 위에도 "컨텍스트 NN%" 한 줄이
# 있었는데, 매 턴 보는 자리를 차지하면서 아이콘과 같은 값을 두 번 말했다(형 지적).
assert "contextBtn" not in html, "입력창 위 컨텍스트 줄이 돌아왔다 — 우상단 게이지와 중복"
assert "usageRing" in html and "conic-gradient" in html, \
    "우상단이 진짜 게이지가 아니다 — 고정 문자 아이콘은 값이 안 변해 정보가 없다"
assert "--pct" in html, "게이지가 퍼센트를 반영하지 않는다"
print("PASS 사용량: 우상단 게이지 단일 표시(컨텍스트 줄 제거)")
print("PASS 탭 아이콘: 라이트/다크 분리 + 폴백은 진한 쪽")
PY
