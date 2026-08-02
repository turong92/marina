#!/usr/bin/env bash
# 입력창 키 배정 — 엔터=전송, Shift+엔터·Shift+스페이스=줄바꿈.
# **물리 키보드에서만** 갈라 쓴다: 폰 가상 키보드에서 엔터가 전송이면 오발이 잦아 예전에
# "엔터=줄바꿈, ↑로 전송"(옵션 B)으로 정했고 그 판단은 폰에선 그대로 유효하다.
# 한글 조립 중(isComposing) 엔터는 조합 확정용이라 절대 가로채면 안 된다 — 가로채면 마지막 음절이 깨진다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY' | node
from marina_mobile import render_mobile_html
import json

html = render_mobile_html()
a, b = html.find("// KEY_SEND_START"), html.find("// KEY_SEND_END")
if a < 0 or b < 0 or b <= a:
    raise SystemExit("KEY_SEND boundaries missing")
print("const keySource = " + json.dumps(html[a:b]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");

// 입력창 · 제안목록 · matchMedia 를 최소한으로 흉내낸 무대.
function stage({pointerFine}) {
  const calls = {sent: 0, grew: 0, saved: 0, inserted: []};
  const promptInput = {
    value: "", placeholder: "", selectionStart: 0, selectionEnd: 0, attrs: {},
    setAttribute(k, v) { this.attrs[k] = v; },
    onkeydown: null,
  };
  const ctx = {
    promptInput,
    suggestionsEl: {classList: {contains: () => ctx.__suggestOpen}, querySelector: () => ctx.__suggestFirst},
    window: {matchMedia: q => ({matches: q.includes("pointer: fine") ? pointerFine : false, addEventListener() {}})},
    closeSuggestions() {},
    insertSuggestion(v) { calls.inserted.push(v); },
    autoGrowComposer() { calls.grew++; },
    saveDraft() { calls.saved++; },
    send() { calls.sent++; },
    __suggestOpen: false,
    __suggestFirst: null,
  };
  vm.createContext(ctx);
  vm.runInContext(keySource, ctx, {filename: "marina_mobile.py::KEY_SEND"});
  return {ctx, promptInput, calls};
}
function press(promptInput, key, opts = {}) {
  let prevented = false;
  promptInput.onkeydown({
    key, code: key === " " ? "Space" : key,
    shiftKey: false, altKey: false, metaKey: false, ctrlKey: false, isComposing: false,
    preventDefault() { prevented = true; }, ...opts,
  });
  return prevented;
}

// ---------- 물리 키보드(형이 쓰는 웹) ----------
{
  const {promptInput, calls} = stage({pointerFine: true});
  assert.equal(promptInput.attrs.enterkeyhint, "send", "힌트가 전송이어야 함");
  assert.ok(promptInput.placeholder.includes("엔터=전송"), promptInput.placeholder);

  // 엔터 → 전송(기본 동작 막고)
  assert.equal(press(promptInput, "Enter"), true, "엔터는 기본 줄바꿈을 막아야 함");
  assert.equal(calls.sent, 1, "엔터로 전송돼야 함");

  // Shift+엔터 → 줄바꿈(textarea 기본 동작이므로 막지 않고 통과)
  assert.equal(press(promptInput, "Enter", {shiftKey: true}), false, "Shift+엔터는 기본 통과");
  assert.equal(calls.sent, 1, "Shift+엔터로 전송되면 안 됨");

  // Shift+스페이스 → 줄바꿈을 직접 삽입(기본 공백을 막고)
  promptInput.value = "가나"; promptInput.selectionStart = promptInput.selectionEnd = 2;
  assert.equal(press(promptInput, " ", {shiftKey: true}), true, "Shift+스페이스는 공백 기본동작을 막아야 함");
  assert.equal(promptInput.value, "가나\n", `줄바꿈이 들어가야 함: ${JSON.stringify(promptInput.value)}`);
  assert.equal(promptInput.selectionStart, 3, "캐럿이 줄바꿈 뒤로");
  assert.equal(calls.sent, 1, "Shift+스페이스로 전송되면 안 됨");
  assert.ok(calls.grew > 0 && calls.saved > 0, "높이 재계산 + 임시저장이 따라와야 함");

  // 캐럿 중간 삽입 + 선택영역 대체
  promptInput.value = "abcd"; promptInput.selectionStart = 1; promptInput.selectionEnd = 3;
  press(promptInput, " ", {shiftKey: true});
  assert.equal(promptInput.value, "a\nd", `선택영역이 줄바꿈으로 대체: ${JSON.stringify(promptInput.value)}`);

  // 한글 조립 중 엔터는 손대지 않는다(조합 확정용)
  const before = calls.sent;
  assert.equal(press(promptInput, "Enter", {isComposing: true}), false, "조립 중엔 기본 통과");
  assert.equal(calls.sent, before, "조립 중 엔터로 전송되면 안 됨 — 마지막 음절이 깨진다");

  // 조합키가 섞이면 건드리지 않는다
  for (const mod of ["altKey", "metaKey", "ctrlKey"]) {
    const n = calls.sent;
    assert.equal(press(promptInput, "Enter", {[mod]: true}), false, `${mod}+엔터는 통과`);
    assert.equal(calls.sent, n, `${mod}+엔터로 전송되면 안 됨`);
  }
}

// ---------- 제안 목록이 열려 있으면 엔터는 채택이 우선 ----------
{
  const {ctx, promptInput, calls} = stage({pointerFine: true});
  ctx.__suggestOpen = true;
  ctx.__suggestFirst = {getAttribute: () => "@marina_mobile.py"};
  assert.equal(press(promptInput, "Enter"), true);
  assert.deepEqual(calls.inserted, ["@marina_mobile.py"], "첫 제안이 채택돼야 함");
  assert.equal(calls.sent, 0, "제안이 열려 있으면 전송되면 안 됨");
}

// ---------- 폰(가상 키보드) — 예전 결정 유지 ----------
{
  const {promptInput, calls} = stage({pointerFine: false});
  assert.equal(promptInput.attrs.enterkeyhint, "enter", "폰에선 힌트가 줄바꿈");
  assert.ok(promptInput.placeholder.includes("↑ 로 전송"), promptInput.placeholder);
  assert.equal(press(promptInput, "Enter"), false, "폰에선 엔터가 기본 줄바꿈으로 통과");
  assert.equal(calls.sent, 0, "폰에서 엔터로 전송되면 오발 — 안 됨");

  // 폰에서도 Shift+스페이스 줄바꿈은 동작한다(외장 키보드 붙였을 때)
  promptInput.value = "x"; promptInput.selectionStart = promptInput.selectionEnd = 1;
  assert.equal(press(promptInput, " ", {shiftKey: true}), true);
  assert.equal(promptInput.value, "x\n");
}

console.log("PASS 키 배정: 물리키보드 엔터=전송 · Shift+엔터/스페이스=줄바꿈 · 조립중 보호 · 조합키 회피 · 제안 우선 · 폰은 옵션B 유지");
''')
PY

# ---------- 클립보드 붙여넣기(Cmd/Ctrl+V) ----------
# 예전엔 paste 핸들러가 없어서 스크린샷을 붙여넣으면 조용히 버려졌다(형: "채팅에 단축키로 붙여넣기도 안되네").
PYTHONPATH="$SCR" python3 - <<'PY' | node
from marina_mobile import render_mobile_html
import json

html = render_mobile_html()
a, b = html.find("// PASTE_START"), html.find("// PASTE_END")
if a < 0 or b < 0 or b <= a:
    raise SystemExit("PASTE boundaries missing")
print("const pasteSource = " + json.dumps(html[a:b]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");

function stage() {
  const calls = {uploaded: [], prevented: 0};
  const listeners = {};
  const ctx = {
    promptInput: {addEventListener(type, fn) { listeners[type] = fn; }},
    uploadFiles(files) { calls.uploaded.push(files); },
  };
  vm.createContext(ctx);
  vm.runInContext(`${pasteSource}\nthis.clipboardFiles = clipboardFiles;`, ctx, {filename: "paste"});
  return {ctx, calls, listeners,
          paste(clipboardData) {
            let prevented = false;
            listeners.paste({clipboardData, preventDefault() { prevented = true; }});
            if (prevented) calls.prevented += 1;
            return prevented;
          }};
}

// 이미지 붙여넣기 → 업로드 경로로, 기본 동작은 막는다
{
  const s = stage();
  const file = {name: "image.png", type: "image/png"};
  assert.equal(s.paste({files: [file], items: []}), true, "파일 붙여넣기는 기본 동작을 막아야 함");
  // vm 경계를 넘으면 Array 프로토타입이 달라 deepStrictEqual 이 못 쓴다 — 참조로 비교한다.
  assert.equal(s.calls.uploaded.length, 1, "업로드가 한 번 불려야 함");
  assert.equal(s.calls.uploaded[0].length, 1);
  assert.equal(s.calls.uploaded[0][0], file, "붙여넣은 파일 그대로 넘겨야 함");
}

// files 가 비고 items 에만 실리는 브라우저(Safari 계열)
{
  const s = stage();
  const file = {name: "shot.png", type: "image/png"};
  const clipboard = {files: [], items: [{kind: "file", getAsFile: () => file}, {kind: "string", getAsFile: () => null}]};
  assert.equal(s.paste(clipboard), true);
  assert.equal(s.calls.uploaded.length, 1);
  assert.equal(s.calls.uploaded[0][0], file, "items 경로도 처리해야 함");
}

// 순수 텍스트 붙여넣기는 손대지 않는다(브라우저 기본 삽입이 캐럿/undo 를 제대로 처리)
{
  const s = stage();
  assert.equal(s.paste({files: [], items: [{kind: "string", getAsFile: () => null}]}), false,
    "텍스트 붙여넣기를 가로채면 캐럿/undo 가 깨진다");
  assert.equal(s.calls.uploaded.length, 0);
}

// clipboardData 가 없어도 죽지 않는다
{
  const s = stage();
  assert.equal(s.paste(null), false);
  assert.equal(s.calls.uploaded.length, 0);
}
console.log("PASS 붙여넣기: 이미지/파일 → 업로드 · items 폴백 · 텍스트는 기본동작 · null 안전 (4/4)");
''')
PY

echo "PASS test-mobile-enter-send"
