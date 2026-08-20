#!/usr/bin/env bash
# 진행 표시는 **한 줄, 사람말로.** 도구 이름·명령어·경로는 안 보인다(스펙 §3).
#
# 지금은 무슨 일이 돌든 "생각 중" 하나뿐이라, 형은 뭘 하고 있는지 알 수 없고 멈춘 건지도
# 구별이 안 된다. 반대로 활동 항목을 그대로 보여주면 Edit(marina_mobile.py) 같은 개발 용어가
# 그대로 나온다 — 스펙이 명시적으로 금지한 것이다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

js = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
chunk = js[js.find("// PROGRESS_LINE_START"):js.find("// PROGRESS_LINE_END")]
if not chunk:
    raise SystemExit("PROGRESS_LINE_START/END 경계가 없다")
print("const src = " + json.dumps(chunk) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.progressLine = progressLine;`, context, {filename: "chat-render::progress"});
const {progressLine} = context;

// ① 파일을 고치는 중이면 **몇 개인지** 말한다 — 스펙의 예시가 "파일 3개 고치는 중…" 이다.
assert.equal(progressLine([
  {activityType: "file", status: "running", path: "/a/x.py"},
  {activityType: "file", status: "running", path: "/a/y.py"},
  {activityType: "diff",  status: "running", path: "/a/z.py"},
]), "파일 3개 고치는 중");
// 같은 파일을 여러 번 건드려도 하나로 센다 — 숫자가 부풀면 못 믿는다.
assert.equal(progressLine([
  {activityType: "file", status: "running", path: "/a/x.py"},
  {activityType: "file", status: "running", path: "/a/x.py"},
]), "파일 1개 고치는 중");

// ② **개발 용어가 새면 안 된다.** 도구 이름·경로·명령어는 한 글자도 나오지 않는다.
const 위험 = progressLine([
  {activityType: "command", status: "running", label: "Bash(git rebase -i)", detail: "git rebase"},
  {activityType: "file", status: "running", label: "Edit(marina_mobile.py)", path: "/x/marina_mobile.py"},
]);
for (const 새면안됨 of ["Bash", "Edit", "git", "marina_mobile", "/x/", "rebase"]) {
  assert.ok(!위험.includes(새면안됨), `개발 용어가 샜다: ${새면안됨} → ${위험}`);
}

// ③ 종류마다 사람말이 다르다 — 다 "작업 중"이면 알려주는 게 없다.
assert.equal(progressLine([{activityType: "command", status: "running"}]), "실행하는 중");
assert.equal(progressLine([{activityType: "agent", status: "running"}]), "다른 일꾼에게 맡기는 중");
assert.equal(progressLine([{activityType: "skill", status: "running"}]), "방법을 찾아보는 중");
assert.equal(progressLine([{activityType: "tool", status: "running"}]), "이것저것 해보는 중");

// ④ 여럿이 동시에 돌면 **가장 뚜렷한 것** 하나만 — 한 줄이 계약이다.
const 섞임 = progressLine([
  {activityType: "tool", status: "running"},
  {activityType: "file", status: "running", path: "/a/x.py"},
]);
assert.equal(섞임, "파일 1개 고치는 중");
assert.ok(!섞임.includes("·"), "한 줄에 여러 개를 붙였다");

// ⑤ 도는 게 없으면 빈 문자열 — 호출자가 "생각 중" 으로 떨어뜨린다.
assert.equal(progressLine([]), "");
assert.equal(progressLine([{activityType: "file", status: "completed", path: "/a/x.py"}]), "");
assert.equal(progressLine(null), "");
console.log("ok 진행 표시: 한 줄·사람말·개발 용어 없음");
''')
PY

# ⑥ 실제로 그 줄이 화면에 쓰인다 — 함수만 만들고 안 걸면 여전히 "생각 중" 뿐이다.
PYTHONPATH="$SCR" python3 - <<'PY2'
from marina_mobile import render_mobile_html

html = render_mobile_html()
블록 = html[html.find("function thinkingLabelFor"):][:900]
assert "progressLine" in 블록, f"진행 표시가 화면에 안 걸렸다: {블록[:300]}"
# 도는 게 없을 때의 폴백은 남는다 — 빈 칸이 뜨면 멈춘 것처럼 보인다.
assert "생각 중" in 블록, 블록[:300]
print("ok 진행 표시가 대화 화면에 걸려 있다")
PY2

echo "PASS test-progress-line"
