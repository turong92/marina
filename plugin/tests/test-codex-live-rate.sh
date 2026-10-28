#!/usr/bin/env bash
# (형 2026-10-28) 코덱스 주간 한도가 리셋됐는데 #사용량 판은 97% 그대로였다 — 판이 지난 턴 기록(rollout)의 rate_limits 만 읽어,
#  리셋 뒤 성공한 턴이 없으면 옛 숫자에 머문다 → 코덱스에게 지금 숫자를 직접 묻고(app-server account/rateLimits/read), 실패하면 기록으로.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
PYTHONPATH="$DSCRIPTS:$DSCRIPTS/../../plugin/scripts" python3 - <<'PY'
import json, os, time
from pathlib import Path
import marina_codex as mc
fails = []
def check(c, m):
    if not c: fails.append(m)
now = time.time()
ro = Path(os.environ["MARINA_HOME"]) / "ro.jsonl"
ro.write_text(json.dumps({"timestamp": "2026-10-27T14:42:36.642Z", "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
    "primary": {"used_percent": 97.0, "window_minutes": 10080, "resets_at": now + 5 * 86400}}}}) + "\n")
recs = [{"kind": "codex", "codexAccount": "b", "rollout": str(ro)}]
calls = []
LIVE = {"primary": {"usedPercent": 25, "windowDurationMins": 10080, "resetsAt": now + 7 * 86400}, "secondary": None}
mc._live_raw = lambda account: (calls.append(account), LIVE)[1]

check(mc.rate_windows(recs, "b")[0]["usedPercent"] == 97.0, "테스트(MARINA_E2E)에선 따로 켜지 않으면 진짜 코덱스를 부르지 않는다")
check(calls == [], f"안 불렀어야: {calls}")
os.environ["MARINA_CODEX_LIVE_RATE"] = "1"; mc._RATE_CACHE.clear()
w = mc.rate_windows(recs, "b")
check(w and w[0]["usedPercent"] == 25.0 and abs(w[0]["resetsAt"] - (now + 7 * 86400)) < 2, f"지금 숫자가 기록을 이긴다: {w}")
check(calls == ["b"], f"계정별로 묻는다: {calls}")
mc.rate_windows(recs, "b")
check(calls == ["b"], "캐시 안에서는 다시 안 묻는다")
mc._RATE_CACHE.clear(); mc._LIVE_CACHE.clear()
mc._live_raw = lambda account: None
check(mc.rate_windows(recs, "b")[0]["usedPercent"] == 97.0, "못 물으면 기록으로")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
PY
echo "PASS test-codex-live-rate"
