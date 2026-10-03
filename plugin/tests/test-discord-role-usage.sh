#!/usr/bin/env bash
# 역할 에이전트(2026-10-04): #상태에 '이번 주 역할별' 사용량 — 어느 역할이 한도를 먹는지 보고 역할표를 고칠 근거
#  - 이번 주 = 주간 한도 resetsAt − 7일(없으면 최근 7일) · 토큰 많은 순 6줄 · 비역할은 '기타' · 이벤트 없으면 블록 없음
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
export ROLE_EVENTS="$TMPROOT/role-events.jsonl"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, sys, time
from pathlib import Path
import marina_discord_bot as mb
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
ev = Path(os.environ["ROLE_EVENTS"])
now = time.time()
def stop(role, tin, out, ts, model="claude-sonnet-5-5"):
    return {"ev": "stop", "ts": ts, "session": "S", "agent": "a", "role": role, "model": "sonnet", "effort": "", "skills": [],
            "desc": "", "secs": 10.0, "tokens": {"in": tin, "out": out, "cache_read": 999999, "cache_write": 0}, "models": [model]}
check(mb.role_usage(now - 7 * 86400) == [], "이벤트 파일 없음 → 빈 목록")
rows = [stop("developer", 500_000, 700_000, now - 100), stop("developer", 100, 100, now - 50),
        stop("planner", 200_000, 100_000, now - 60, "claude-opus-5-5"), stop("-", 1000, 1000, now - 10),
        stop("-", 1, 1, now - 10), stop("qa", 5, 5, now - 8 * 86400)]
ev.write_text("\n".join(json.dumps(r) for r in rows) + "\n{깨진\n" +
              json.dumps({"ev": "start", "ts": now, "session": "S", "role": "qa"}) + "\n")
u = mb.role_usage(now - 7 * 86400)
check([(r["role"], r["calls"], r["tokens"]) for r in u] == [("developer", 2, 1_200_200), ("planner", 1, 300_000), ("기타", 2, 2002)],
      f"역할별 합(캐시 읽기 제외)·많은 순·비역할=기타·기간 밖 제외: {u}")
check(u[1]["models"] == ["opus-5-5"], f"모델 이름 짧게: {u[1]}")
snap = {"usage": [{"key": "weekly", "label": "주간", "usedPercent": 40, "resetsAt": int(now + 86400)}], "sessions": [], "roleUsage": u}
def txt(cs):
    return "\n".join([c.get("content", "") for c in cs if c.get("content")] + [txt(c.get("components") or []) for c in cs])
t = txt(mb.render(snap))
check("### 🤖 이번 주 역할별" in t and "`developer     2회   1.2M` sonnet-5-5" in t and "`기타            2회     2k`" in t,
      f"#상태 블록: {t}")
check("이번 주 역할별" not in txt(mb.render(dict(snap, roleUsage=[]))), "없으면 블록 없음")
many = [{"ref": f"p/s{i}", "channelId": str(100 + i), "alive": True, "busy": True, "emoji": "🔧", "ctx": 10.0,
         "tasks": [{"id": f"b{i}", "kind": "shell", "desc": "x"}]} for i in range(30)]
def count(cs): return sum(1 + count(c.get("components") or []) + (1 if c.get("accessory") else 0) for c in cs)
check(count(mb.render(dict(snap, sessions=many))) + 1 <= 40, "역할 블록이 있어도 구성요소 40개 이하")
check(abs(mb._week_start([{"key": "weekly", "resetsAt": int(now + 86400)}]) - (now + 86400 - 7 * 86400)) < 2, "주 시작 = reset − 7일")
check(abs(mb._week_start([]) - (time.time() - 7 * 86400)) < 5, "모르면 최근 7일")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-role-usage"
