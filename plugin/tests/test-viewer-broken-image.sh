#!/usr/bin/env bash
# 사진 뷰어에서 **못 여는 그림에 닿으면 조용히 까매지면 안 된다.**
#
# 형 2026-09-10: "사진 누르면 넘기다보면 흑백되거든". 필터 같은 건 없었다. 실제로는 이랬다:
# 채팅에서 넘기는 목록(collectViewables)에 그 대화가 만든/건넨 **파일**이 섞이는데, 그중 워크트리
# 밖에 있는 것(스크래치패드 스크린샷·~/.aside·~/.marina/mobile-uploads)은 서버가 400 으로
# 거절한다(dashboard.log 실측 43건, 전부 "이 워크트리 밖의 경로예요"). 뷰어는 .png 면 img.src
# 에 넣기만 하고 **실패를 듣지 않았다** — 깨진 그림은 안 그려지고, 남는 건 거의 검은 배경과
# 흰 파일명·n/N·흰 테두리 버튼뿐이다. 그게 "흑백"이었다. 거절 자체는 맞는 보안 동작이라 그대로 두고,
# 뷰어가 실패를 말하게 한다.
#
# 계약: ① 그림 로드가 실패하면 "열 수 없어요"가 뜨고 깨진 img 는 숨는다 ② 다음 장으로 넘기면
# 그 문구는 걷히고 새 그림이 뜬다 ③ 뷰어가 닫힌 뒤나 텍스트를 보는 중에 늦게 온 error 는 무시한다
# (안 그러면 멀쩡한 화면을 덮는다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
start, end = src.find("// VIEWER_START"), src.find("// VIEWER_END")
if start < 0 or end < 0:
    raise SystemExit("VIEWER_START/END 경계가 없다")
print("const src = " + json.dumps(src[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");

function 요소(id) {
  const e = {
    id, style: {}, textContent: "", disabled: false, attrs: {}, listeners: {},
    classList: {s: new Set(), add(c) { this.s.add(c); }, remove(c) { this.s.delete(c); },
                contains(c) { return this.s.has(c); }, toggle(c, on) { on ? this.s.add(c) : this.s.delete(c); }},
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
    removeAttribute(k) { delete this.attrs[k]; },
    hasAttribute(k) { return k in this.attrs; },
    addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); },
  };
  // 진짜 img 처럼 src 속성과 프로퍼티를 한 몸으로 묶는다(removeAttribute 가 src 를 지우게).
  Object.defineProperty(e, "src", {get() { return this.attrs.src || ""; },
                                   set(v) { this.attrs.src = String(v); }});
  return e;
}
const els = {};
for (const id of ["imageViewer", "imageViewerImg", "viewerText", "viewerName", "viewerCount",
                  "viewerDead", "viewerPrev", "viewerNext"]) els[id] = 요소(id);

const context = {
  document: {getElementById: id => els[id] || 요소(id)},
  imageViewer: els.imageViewer, imageViewerImg: els.imageViewerImg,
  viewerText: els.viewerText, viewerName: els.viewerName,
  headers: () => ({}), responseError: async () => "err",
  transcriptImageUrl: ref => `/ti?ref=${ref}`, sessionFileUrl: p => `/sf?path=${encodeURIComponent(p)}`,
  IMAGE_EXT_RE: /\.(png|jpe?g|gif|webp|bmp|heic|svg)$/i,
  줌리셋: () => {},
  fetch: async () => ({ok: true, text: async () => "본문"}),
  console,
};
vm.createContext(context);
vm.runInContext(`${src}
this.openViewer = openViewer; this.stepViewer = stepViewer; this.closeImageViewer = closeImageViewer;`,
  context, {filename: "marina_mobile::viewer"});
const {openViewer, stepViewer, closeImageViewer} = context;
const img = els.imageViewerImg, dead = els.viewerDead;
const 실패 = () => (img.listeners.error || []).forEach(f => f({type: "error", target: img}));

const 목록 = [
  {type: "file", path: "/private/tmp/claude-501/x/scratchpad/harness-wide.png", name: "harness-wide.png"},
  {type: "image", ref: "12140155-0-0", name: "대화 이미지"},
  {type: "file", path: "/repo/notes.txt", name: "notes.txt"},
];

// 로드 전: 그림 자리가 준비돼 있고 문구는 없다.
openViewer(목록, 0);
assert.equal(img.style.display, "block");
assert.ok(img.src.includes("harness-wide.png"), img.src);
assert.notEqual(dead.style.display, "block", "아직 실패도 안 했는데 문구가 떴다");

// ① 서버가 거절(400) → img error. **말해야 한다.** 조용히 까매지면 형은 흑백으로 변했다고 본다.
assert.ok((img.listeners.error || []).length > 0, "그림 로드 실패를 아무도 안 듣는다 — 깨진 그림이 까만 화면으로 남는다");
실패();
assert.equal(dead.style.display, "block", "로드 실패인데 '열 수 없어요'가 안 떴다");
assert.match(dead.textContent, /열 수 없어요/);
assert.equal(img.style.display, "none", "깨진 img 가 그대로 보인다");

// ② 다음 장(멀쩡한 대화 이미지)으로 넘기면 문구는 걷히고 새 그림이 뜬다.
stepViewer(1);
assert.notEqual(dead.style.display, "block", "넘겼는데 앞 장의 실패 문구가 남았다");
assert.equal(img.style.display, "block");
assert.ok(img.src.includes("12140155-0-0"), img.src);

// ③-a 텍스트 파일을 보는 중에 늦게 온 error — img 를 안 쓰는 중이니 무시한다.
stepViewer(1);
assert.equal(img.getAttribute("src"), null, "텍스트로 넘겼는데 img src 가 남았다");
실패();
assert.notEqual(dead.style.display, "block", "텍스트 화면인데 늦은 이미지 에러가 덮었다");

// ③-b 닫은 뒤에 온 error — 다음에 열 때 실패 문구가 묻어 있으면 안 된다.
openViewer(목록, 1);
closeImageViewer();
실패();
assert.notEqual(dead.style.display, "block", "닫힌 뷰어에 늦은 에러가 문구를 켰다");

console.log("ok");
''')
PY

echo "PASS: 못 여는 그림은 까만 화면이 아니라 '열 수 없어요'로 말한다"
