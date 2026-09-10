#!/usr/bin/env bash
# 채팅에서 사진을 넘길 때 **같은 그림이 두 번 끼면 안 된다.**
#
# 형 2026-09-10: "이거 이미지 3갠데 왜 중간중간 까만게 끼냐고". 실데이터(이 대화 타임라인 160건)를
# 진짜 collectViewables 에 넣어보니 그림 6장이 12칸이었다 — image, file, image, file …
# 에이전트가 그림 파일을 Read 하면 **한 activity 가 path 와 images 를 둘 다** 가진다. 빌더는 images 로
# 한 칸, path 로 또 한 칸을 넣었다. 뒤 칸은 스크래치패드 같은 방 밖 경로라 서버가 400 을 주고,
# 뷰어엔 까만 칸으로 보였다. 그림은 이미 대화 이미지(항상 받아지는 쪽)로 들어가 있으니 파일 칸은 뺀다.
#
# 계약: ① Read 로 본 그림은 한 번만 ② 만든 파일(Write·SendUserFile)은 그대로 파일로 남는다
# ③ 그냥 대화에 붙은 그림도 그대로 ④ 같은 경로를 나중에 만들면(Write) 파일 칸은 그 자리에 생긴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

js = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
start, end = js.find("// VIEWABLES_START"), js.find("// VIEWABLES_END")
if start < 0 or end < 0:
    raise SystemExit("VIEWABLES_START/END 경계가 없다")
print("const src = " + json.dumps(js[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.collectViewables = collectViewables;`, context, {filename: "chat-render::viewables"});
const {collectViewables} = context;
const 줄 = list => JSON.parse(JSON.stringify(list)).map(x => x.type + ":" + (x.ref || x.path));

// 실데이터 모양 그대로 — Read 한 activity 가 path 와 images 를 같이 갖는다.
const 읽음 = (n) => ({kind: "activity", name: "Read", activityType: "file",
                      path: `/private/tmp/x/scratchpad/shot${n}.png`,
                      images: [{ref: `${n}00-0-0`, name: `shot${n}.png`}]});

// ① 형이 본 캡처: 그림 3장 → **3칸**. 예전엔 image,file,image,file,image,file 6칸이었다.
const 셋 = collectViewables([읽음(1), 읽음(2), 읽음(3)]);
assert.deepEqual(줄(셋), ["image:100-0-0", "image:200-0-0", "image:300-0-0"],
  `그림 3장인데 넘기기 칸이 ${셋.length}개 — 같은 그림이 파일로 또 끼어 까만 칸이 된다: ${줄(셋)}`);

// ② 만든 파일은 그림이 없으니 그대로 파일 칸이다(모아보기·결과물 흐름을 깨면 안 된다).
const 만든 = collectViewables([
  {kind: "activity", name: "Write", activityType: "file", path: "/repo/out.md"},
  {kind: "activity", name: "SendUserFile", activityType: "file", path: "/repo/report.png"},
]);
assert.deepEqual(줄(만든), ["file:/repo/out.md", "file:/repo/report.png"], 줄(만든));

// ③ 대화 메시지에 바로 붙은 그림도 그대로.
const 메시지 = collectViewables([{kind: "message", role: "user", images: [{ref: "7-0-0"}]}]);
assert.deepEqual(줄(메시지), ["image:7-0-0"], 줄(메시지));

// ④ 먼저 Read 로 본 그림을 나중에 Write 로 다시 만들면: 그림 칸은 남고, 파일 칸은 **그 뒤 자리에** 한 번.
const 섞임 = collectViewables([
  읽음(4),
  {kind: "message", role: "assistant", images: []},
  {kind: "activity", name: "Write", activityType: "file", path: "/private/tmp/x/scratchpad/shot4.png"},
]);
assert.deepEqual(줄(섞임), ["image:400-0-0", "file:/private/tmp/x/scratchpad/shot4.png"], 줄(섞임));

console.log("ok");
''')
PY

echo "PASS: 같은 그림은 넘기기 목록에 한 번만"
