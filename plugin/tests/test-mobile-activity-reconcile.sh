#!/usr/bin/env bash
# 모바일 활동(접기) 목록의 증분 갱신 — 자율 진행 중 도구가 하나 늘 때마다 exchange 를 통째로
# 다시 만들면, 읽고 있던 펼친 상세가 파괴돼 스크롤이 튄다. 정체성/지문 분리가 그 방어선이다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' | node
# 렌더러는 marina-web/chat-render.js 로 옮겨졌다(웹 대시보드와 공유). 마커도 같이 따라갔다.
import json
import sys
from pathlib import Path

html = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
start = html.find("// ACTIVITY_IDENTITY_START")
end = html.find("// ACTIVITY_IDENTITY_END")
if start < 0 or end < 0 or end <= start:
    raise SystemExit("activity identity helper boundaries missing")
c, d = html.find("// RENDER_CONSTS_START"), html.find("// RENDER_CONSTS_END")
if c < 0 or d < 0:
    raise SystemExit("RENDER_CONSTS boundaries missing")
# activityTypeLabels 는 아래 vm 컨텍스트가 스텁으로 넣는다 — 요약이 라벨 맵을 실제로 읽는지
# 보려는 것이므로 그 스텁이 권위다. 실제 상수를 같이 실으면 const 가 스텁을 가린다.
consts = "\n".join(l for l in html[c:d].splitlines() if "const activityTypeLabels" not in l)
print("const helperSource = " + json.dumps(consts + "\n" + html[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {activityTypeLabels: {tool: "도구", skill: "스킬", file: "파일"}};
vm.createContext(context);
vm.runInContext(`${helperSource}
this.activityItemKey = activityItemKey;
this.activityItemFingerprint = activityItemFingerprint;
this.activityGroupSummary = activityGroupSummary;`, context, {filename: "marina_mobile.py::activity-identity"});
const {activityItemKey, activityItemFingerprint, activityGroupSummary} = context;

// 1) 정체성은 id 우선 — 순서가 밀려도 같은 항목이면 같은 키(= DOM 재사용)
const item = {id: "toolu_1", activityType: "tool", label: "Bash", status: "running", detail: "ls", result: ""};
assert.equal(activityItemKey(item, 0), "toolu_1");
assert.equal(activityItemKey(item, 7), "toolu_1", "인덱스가 정체성을 바꾸면 안 된다");

// 2) 내용이 그대로면 지문도 그대로 — 폴링마다 노드를 갈아치우지 않는다
assert.equal(activityItemFingerprint(item), activityItemFingerprint({...item}));

// 3) 실행 중 → 완료로 바뀌면 지문이 달라진다(그 항목만 다시 그린다)
const done = {...item, status: "completed", result: "a.txt"};
assert.notEqual(activityItemFingerprint(item), activityItemFingerprint(done));

// 4) id 가 없으면 label, 그것도 없으면 인덱스로 떨어진다(키 충돌 방지)
assert.equal(activityItemKey({label: "Read"}, 3), "Read");
assert.equal(activityItemKey({}, 3), "activity-3");

// 5) 요약은 개수를 따라간다 — 제자리 갱신 시 summary 만 고쳐 쓰면 된다.
//    내역은 **총계와 합이 맞아야 한다**: 예전엔 목록이 하드코딩이라 tool 종류가 총계엔 들어가고
//    내역엔 안 나와 "작업 1"만 떴다(형: "갯수가 안맞는다"). 자세한 계약은 test-activity-counts.
assert.equal(activityGroupSummary([item]), "작업 1 · 도구 1");
assert.equal(activityGroupSummary([item, {activityType: "skill"}]), "작업 2 · 스킬 1 · 도구 1");
console.log("ok activity identity survives polling, fingerprint tracks content");
''')
PY

# 제자리 갱신 경로가 실제로 배선돼 있는지 — 마커/속성이 '서빙되는 코드'에 있어야 한다.
# 렌더 마크업은 공유 렌더러(chat-render.js)에, 교환 골격 비교는 모바일에 있다. 둘 다 서빙되므로
# 합쳐서 본다 — 어느 파일에 있는지가 아니라 배선이 살아 있는지가 계약이다.
html="$(PYTHONPATH="$SCR" python3 -c 'from marina_mobile import render_mobile_html; print(render_mobile_html())')
$(cat "$SCR/marina-web/chat-render.js")"
for needle in \
  'data-activity-list' \
  'data-activity-key=' \
  'data-activity-fp=' \
  'function reconcileActivityList' \
  'function exchangeShellKey' \
  'reconcileExchangeActivities(node, exchange)'; do
  grep -qF "$needle" <<<"$html" || { echo "FAIL: 활동 증분 갱신 배선 누락 — $needle"; exit 1; }
done

# exchange 통째 교체는 골격이 바뀐 경우로 한정돼야 한다(활동만 늘면 in-place 경로).
grep -qF 'node.dataset.exchangeShell === shell' <<<"$html" || { echo "FAIL: 골격 비교 없이 통째 교체한다"; exit 1; }
echo "ok activity list reconciles in place"

echo "PASS test-mobile-activity-reconcile"
