#!/usr/bin/env bash
# 채팅 활동 요약의 숫자가 맞아야 한다 — 형: "작업/명령/diff/파일 갯수가 안맞는거같은데".
# 원인이 둘이었다:
#   ① 요약 항목 목록이 하드코딩(skill·command·diff·file·agent)이라, tool/progress 로 분류되는 것들
#      (Grep · mcp__* · ToolSearch · AskUserQuestion · Glob …)이 "작업 N" 총계엔 들어가고 항목엔 안 나왔다.
#      실측: 40세션 활동 1291개 중 165개(13%)가 사라졌고 17세션이 영향.
#   ② 활동이 상한(120)을 넘으면 오래된 걸 **조용히** 버려서 총계 자체가 실제보다 적었다.
# 이 테스트가 둘 다 잠근다: 항목 합 == 총계(항상), 그리고 절단은 반드시 보고된다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

# ---------- ① 요약: 항목 합 == 작업 총계 ----------
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' | node
# 렌더러는 marina-web/chat-render.js 로 옮겨졌다(웹 대시보드와 공유). 마커도 같이 따라갔다.
import json
import sys
from pathlib import Path

html = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
a, b = html.find("// ACTIVITY_IDENTITY_START"), html.find("// ACTIVITY_IDENTITY_END")
if a < 0 or b < 0 or b <= a:
    raise SystemExit("ACTIVITY_IDENTITY boundaries missing")
c, d = html.find("// RENDER_CONSTS_START"), html.find("// RENDER_CONSTS_END")
if c < 0 or d < 0:
    raise SystemExit("RENDER_CONSTS boundaries missing")
print("const helperSource = " + json.dumps(html[c:d] + "\n" + html[a:b]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const ctx = {};
vm.createContext(ctx);
vm.runInContext(`${helperSource}\nthis.activityGroupSummary = activityGroupSummary;`, ctx, {filename: "summary"});
const summary = ctx.activityGroupSummary;

function parts(text) {
  const chunks = text.split(" · ");
  const total = Number(chunks[0].replace("작업 ", ""));
  const listed = chunks.slice(1).reduce((n, c) => n + Number(c.split(" ").pop()), 0);
  return {total, listed, text};
}
const item = t => ({activityType: t});

// 예전에 통째로 사라졌던 종류들이 이제 항목에 나오고, 합이 총계와 같아야 한다.
{
  const items = [item("command"), item("command"), item("tool"), item("tool"), item("tool"),
                 item("diff"), item("file"), item("skill"), item("agent"), item("progress")];
  const p = parts(summary(items));
  assert.equal(p.total, 10, p.text);
  assert.equal(p.listed, 10, `항목 합이 총계와 달라짐: ${p.text}`);
  assert.ok(p.text.includes("도구 3"), `tool 이 항목으로 나와야 함: ${p.text}`);
  assert.ok(p.text.includes("진행 1"), `progress 가 항목으로 나와야 함: ${p.text}`);
  // 표시 순서는 고정
  assert.ok(p.text.indexOf("Skill") < p.text.indexOf("명령"), p.text);
  assert.ok(p.text.indexOf("명령") < p.text.indexOf("Diff"), p.text);
  assert.ok(p.text.indexOf("도구") > p.text.indexOf("파일"), p.text);
}

// tool 만 있어도 총계와 맞아야 한다(예전엔 "작업 5" 뒤에 아무 항목도 안 붙었다).
{
  const p = parts(summary([item("tool"), item("tool"), item("tool"), item("tool"), item("tool")]));
  assert.equal(p.listed, 5, `tool 전용 그룹에서 합이 어긋남: ${p.text}`);
}

// activityType 이 없는 항목은 tool 로 센다.
{
  const p = parts(summary([{}, {}, item("command")]));
  assert.equal(p.total, 3, p.text);
  assert.equal(p.listed, 3, `분류 없는 항목이 누락됨: ${p.text}`);
}

// 처음 보는 종류가 생겨도 절대 조용히 사라지지 않는다(하드코딩 재발 방지).
{
  const p = parts(summary([item("command"), item("brand-new-kind"), item("brand-new-kind")]));
  assert.equal(p.listed, 3, `모르는 종류가 사라짐 — 목록 하드코딩 재발: ${p.text}`);
  assert.ok(p.text.includes("brand-new-kind 2"), p.text);
}

// 무작위 조합 200회 — 합 == 총계가 항상 성립해야 한다.
{
  const kinds = ["skill", "command", "diff", "file", "agent", "progress", "tool", "", "weird"];
  for (let seed = 0; seed < 200; seed += 1) {
    const n = 1 + (seed * 7) % 25;
    const items = Array.from({length: n}, (_, i) => {
      const kind = kinds[(seed * 3 + i * 5) % kinds.length];
      return kind ? item(kind) : {};
    });
    const p = parts(summary(items));
    assert.equal(p.listed, p.total, `seed ${seed}: ${p.text}`);
  }
}
console.log("PASS ① 요약: 항목 합 == 작업 총계 (tool·progress·미지 종류 포함, 무작위 200회)");
''')
PY

# ---------- ② 절단은 반드시 보고된다 ----------
PYTHONPATH="$SCR" python3 - <<'PY'
import json
import tempfile
from pathlib import Path

import marina_sessions as ms

def rows(n_activities):
    out = []
    for i in range(n_activities):
        out.append({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": f"c{i}", "name": "Bash", "input": {"command": f"echo {i}"}}]}})
    return out

cap = ms.AGENT_TIMELINE_MAX_ACTIVITIES

# 상한 이하 → 안 자르고, 보고값 0
tmp = Path(tempfile.mkdtemp())
under = tmp / "under.jsonl"
under.write_text("".join(json.dumps(r) + "\n" for r in rows(cap - 5)), encoding="utf-8")
page = ms._transcript_page(under, "claude", None, 10_000)
acts = sum(1 for i in page["timeline"] if i.get("kind") == "activity")
assert page["trimmedActivities"] == 0, page["trimmedActivities"]
assert acts == cap - 5, acts

# 상한 초과 → 자르고, 자른 수를 정확히 보고 (표시 + 생략 == 실제)
over = tmp / "over.jsonl"
real = cap + 37
over.write_text("".join(json.dumps(r) + "\n" for r in rows(real)), encoding="utf-8")
page = ms._transcript_page(over, "claude", None, 10_000)
acts = sum(1 for i in page["timeline"] if i.get("kind") == "activity")
assert acts == cap, acts
assert page["trimmedActivities"] == 37, page["trimmedActivities"]
assert acts + page["trimmedActivities"] == real, (acts, page["trimmedActivities"], real)

# 남는 것은 **최근** 활동이어야 한다(오래된 것을 버린다)
kept = [i for i in page["timeline"] if i.get("kind") == "activity"]
assert kept[-1]["label"] == f"echo {real - 1}", kept[-1]["label"]
assert kept[0]["label"] == f"echo {37}", kept[0]["label"]

# payload 계약: 항상 존재
assert "trimmedActivities" in ms._transcript_page(under, "claude", None, 5)
print(f"PASS ② 절단 보고: 상한 {cap} 초과분 37개를 정확히 보고 · 표시+생략==실제 · 최근 것 보존 · 필드 항상 존재")
PY

# ---------- 모바일이 그 보고를 실제로 띄우나 ----------
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html
html = render_mobile_html()
for needle in ('id="trimNotice"', "history.trimmedActivities", "표시 상한", ".trimNotice {"):
    assert needle in html, needle
print("PASS ③ 배선: 생략 안내가 대화 상단에 표시됨")
PY

echo "PASS test-activity-counts"
