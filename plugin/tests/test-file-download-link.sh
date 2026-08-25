#!/usr/bin/env bash
# 만든 파일은 **대화에서 바로 받을 수 있어야** 한다 — 형: "다운로드 바로 받을 수 있게
# 하이퍼링크 줄 수 있지않아?".
#
# 지금도 파일 활동엔 [열기] 가 붙지만 **접힌 도구 그룹 안**이라, 폰만 쓰는 사람은 평생 못 찾는다.
# 이미지가 이미 같은 문제를 겪고 접힘 밖으로 끌어올려 그리고 있다("그림은 접지 않는다").
# 파일도 같게 한다: 그룹 위에 파일 칩을 띄우고, 누르면 바로 내려받는다.
#
# 건네주는 도구(SendUserFile)도 파일 활동으로 본다 — 임시 폴더에 만들어 건네는 경우가 있고,
# 그때 대화에 링크가 없으면 받을 길이 목록뿐이다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_sessions import _activity_type, _activity_file_path

# ① 건네주기도 파일 활동이다.
assert _activity_type("SendUserFile", "") == "file", _activity_type("SendUserFile", "")
# ② 경로는 files 목록에서 뽑는다(Write 의 file_path 와 같은 규칙 하나로).
경로 = _activity_file_path({"files": ["/tmp/보고서.html"], "status": "normal"}, "")
assert 경로 == "/tmp/보고서.html", 경로
assert _activity_file_path({"file_path": "/wt/x.md"}, "") == "/wt/x.md"
print("ok 건네준 파일도 경로가 실린다")
PY

python3 - "$SCR" <<'PY2' | node
import json
import sys
from pathlib import Path

렌더 = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
print("const src = " + json.dumps(렌더) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const ctx = {console};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(src, ctx, {filename: "chat-render"});
const M = ctx.MarinaChat;
M.configure({fileUrl: p => `/mobile/api/session-file?path=${encodeURIComponent(p)}`});

const html = M.renderActivityGroup([
  {activityType: "file", label: "결혼 플랜 저장", path: "/Users/x/.marina/chat/플랜.html", status: "completed"},
  {activityType: "command", label: "cp", status: "completed"},
], "g1");

// ③ 파일 칩이 **접힘 밖**에 있어야 한다 — <details> 앞에 나와야 폰에서 보인다.
const chipAt = html.indexOf("fileChip");
const foldAt = html.indexOf("<details class=\"activityGroup\"");
assert.ok(chipAt >= 0, `파일 칩이 없다: ${html.slice(0, 200)}`);
assert.ok(chipAt < foldAt, "파일 칩이 접힘 안에 있다 — 폰에서 못 찾는다");

// ④ 누르면 바로 받아진다(다운로드 링크).
assert.ok(/href="\/mobile\/api\/session-file\?path=[^"]+"/.test(html), html.slice(0, 300));
assert.ok(html.includes("download"), "다운로드 속성이 없다");
assert.ok(html.includes("플랜.html"), "파일 이름이 안 보인다");

// ⑤ 파일이 없는 그룹은 칩을 만들지 않는다.
const 없음 = M.renderActivityGroup([{activityType: "command", label: "ls", status: "completed"}], "g2");
assert.ok(!없음.includes("fileChip"), 없음.slice(0, 160));
console.log("ok 대화에서 바로 받는 파일 링크");
''')
PY2

echo "PASS test-file-download-link"
