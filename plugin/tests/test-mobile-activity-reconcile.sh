#!/usr/bin/env bash
# 모바일 활동(접기) 목록의 증분 갱신 — 자율 진행 중 도구가 하나 늘 때마다 exchange 를 통째로
# 다시 만들면, 읽고 있던 펼친 상세가 파괴돼 스크롤이 튄다. 정체성/지문 분리가 그 방어선이다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY' | node
from marina_mobile import render_mobile_html
import json

html = render_mobile_html()
start = html.find("// ACTIVITY_IDENTITY_START")
end = html.find("// ACTIVITY_IDENTITY_END")
if start < 0 or end < 0 or end <= start:
    raise SystemExit("activity identity helper boundaries missing")
print("const helperSource = " + json.dumps(html[start:end]) + ";")
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

// 5) 요약은 개수를 따라간다 — 제자리 갱신 시 summary 만 고쳐 쓰면 된다
assert.equal(activityGroupSummary([item]), "작업 1");
assert.equal(activityGroupSummary([item, {activityType: "skill"}]), "작업 2 · 스킬 1");
console.log("ok activity identity survives polling, fingerprint tracks content");
''')
PY

# 제자리 갱신 경로가 실제로 배선돼 있는지 — 마커/속성이 서빙되는 HTML 에 있어야 한다.
html="$(PYTHONPATH="$SCR" python3 -c 'from marina_mobile import render_mobile_html; print(render_mobile_html())')"
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
