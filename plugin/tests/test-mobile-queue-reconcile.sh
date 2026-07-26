#!/usr/bin/env bash
# 모바일 pending 큐 reconcile 순수 로직 — tid-liveness auto-fail(문신 자동 소멸).
# marina_mobile.py 에 임베드된 JS 에서 reconcilePendingRecord 헬퍼만 뽑아 node vm 으로 검증한다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY' | node
from marina_mobile import render_mobile_html
import json

html = render_mobile_html()
start_marker = "// RECONCILE_PENDING_RECORD_START"
end_marker = "// RECONCILE_PENDING_RECORD_END"
start = html.find(start_marker)
end = html.find(end_marker)
if start < 0 or end < 0 or end <= start:
    raise SystemExit("reconcilePendingRecord source boundaries missing")
# normUserText 는 헬퍼 바로 위에서 정의됨 — 같이 뽑아온다.
norm_marker = "function normUserText(raw)"
norm_start = html.rfind(norm_marker, 0, start)
if norm_start < 0:
    raise SystemExit("normUserText source missing before helper")
snippet = html[norm_start:end]
print("const helperSource = " + json.dumps(snippet) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");

const context = {};
vm.createContext(context);
vm.runInContext(`${helperSource}\nthis.reconcilePendingRecord = reconcilePendingRecord;\nthis.liveTidsFromTerms = liveTidsFromTerms;`, context, {filename: "marina_mobile.py::reconcilePendingRecord"});
const reconcilePendingRecord = context.reconcilePendingRecord;
const liveTidsFromTerms = context.liveTidsFromTerms;
if (typeof reconcilePendingRecord !== "function") throw new Error("reconcilePendingRecord not extracted");
if (typeof liveTidsFromTerms !== "function") throw new Error("liveTidsFromTerms not extracted");

const base = {role: "user", text: "do the thing", baseline: 0, pending: true};

// 1) delivery:queue, tid 살아있음(liveTids 포함), 나이 10s → 유지(여전히 대기중).
{
  const record = {...base, delivery: "queue", tid: "tid-1", createdAt: Date.now() - 10000};
  const liveTids = new Set(["tid-1"]);
  const result = reconcilePendingRecord(record, {confirmedUsers: new Map(), latestConfirmedAt: 0, liveTids, now: Date.now()});
  assert.ok(result && !result.failed, `expected kept (live tid): ${JSON.stringify(result)}`);
}

// 2) 같은 레코드지만 tid 가 liveTids 에 없음, 나이 10s → failed(자동 실패, 문신 소멸).
{
  const record = {...base, delivery: "queue", tid: "tid-dead", createdAt: Date.now() - 10000};
  const liveTids = new Set(["tid-other"]);
  const result = reconcilePendingRecord(record, {confirmedUsers: new Map(), latestConfirmedAt: 0, liveTids, now: Date.now()});
  assert.ok(result && result.failed === true && result.delivery === "failed", `expected failed (dead tid, aged): ${JSON.stringify(result)}`);
}

// 3) 같은 레코드, tid 없음(liveTids 미포함), 나이 2s → 유지(레이스 가드, send 직후 첫 폴 전에 실패로 오판 금지).
{
  const record = {...base, delivery: "queue", tid: "tid-dead", createdAt: Date.now() - 2000};
  const liveTids = new Set(["tid-other"]);
  const result = reconcilePendingRecord(record, {confirmedUsers: new Map(), latestConfirmedAt: 0, liveTids, now: Date.now()});
  assert.ok(result && !result.failed, `expected kept (race guard, <4s): ${JSON.stringify(result)}`);
}

// 4) 텍스트가 확정됨(confirmedUsers 에 baseline 초과 카운트) → tid 유무·liveness 와 무관하게 제거(null).
{
  const record = {...base, delivery: "queue", tid: "tid-dead", createdAt: Date.now() - 10000};
  const liveTids = new Set(["tid-other"]);
  const confirmedUsers = new Map([["do the thing", 1]]);
  const result = reconcilePendingRecord(record, {confirmedUsers, latestConfirmedAt: 0, liveTids, now: Date.now()});
  assert.equal(result, null, `expected dropped (confirmed): ${JSON.stringify(result)}`);
}

// 5) delivery:queue 이지만 tid 가 비어있음(레거시 레코드, tid 저장 이전) → tid 없이는 자동 실패 불가, 유지
//    (수동 취소는 Task 2 몫).
{
  const record = {...base, delivery: "queue", tid: "", createdAt: Date.now() - 10000};
  const liveTids = new Set(["tid-other"]);
  const result = reconcilePendingRecord(record, {confirmedUsers: new Map(), latestConfirmedAt: 0, liveTids, now: Date.now()});
  assert.ok(result && !result.failed, `expected kept (no tid, legacy record): ${JSON.stringify(result)}`);
}

// 6) liveTidsFromTerms 는 detached term 을 제외한다 — 재시작 후 입력 불가(term_input 400)로 복원된 PTY 는
//    tid 는 state.terms 에 남아있어도 "입력 가능한 살아있는 tid" 취급하면 안 된다.
{
  const set = liveTidsFromTerms([{tid: "a"}, {tid: "b", detached: true}]);
  assert.ok(set.has("a"), `expected live term kept: ${JSON.stringify([...set])}`);
  assert.ok(!set.has("b"), `expected detached term excluded: ${JSON.stringify([...set])}`);
}

// 7) detached term 으로 큐된 메시지 — liveTidsFromTerms 로 뽑은 집합엔 그 tid 가 없으므로(제외됨)
//    reconcilePendingRecord 의 !tidLive 경로가 타 자동 실패돼야 한다(문신 소멸).
{
  const liveTids = liveTidsFromTerms([{tid: "a"}, {tid: "b", detached: true}]);
  const record = {...base, delivery: "queue", tid: "b", createdAt: Date.now() - 10000};
  const result = reconcilePendingRecord(record, {confirmedUsers: new Map(), latestConfirmedAt: 0, liveTids, now: Date.now()});
  assert.ok(result && result.failed === true && result.delivery === "failed", `expected failed (detached tid excluded from liveTids): ${JSON.stringify(result)}`);
}

console.log("PASS test-mobile-queue-reconcile: tid-liveness auto-fail incl. detached (7/7)");
''')
PY
