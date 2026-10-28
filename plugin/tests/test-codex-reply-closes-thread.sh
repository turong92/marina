#!/usr/bin/env bash
# (형 2026-10-28) 코덱스 방은 일하는 중 온 지시를 같은 턴에 받아(steer) 턴이 한 시간 넘게 안 끝난다 —
#  스레드 접기·👀 떼기가 턴 끝 훅에만 있어 지시 스레드가 끝나도 안 닫혔다(gcp-postgres 13개)
#  → 그 지시에 답(reply_to)을 보내면 그 지시의 진행 스레드를 접고 그 지시에 단 진행 표시만 뗀다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
PYTHONPATH="$DSCRIPTS:$DSCRIPTS/../../plugin/scripts" python3 - <<'PY'
import json, os
from pathlib import Path
import marina_session as ms
import marina_codex as mc
fails = []
def check(c, m):
    if not c: fails.append(m)
sd = Path(os.environ["MARINA_HOME"]) / "sd"; sd.mkdir()
(sd / "threads.json").write_text(json.dumps({"M1": "T1", "M2": "T2"}))
(sd / "activity.json").write_text(json.dumps({"mid": "M2", "marked": {"M1": ["👀"], "M2": ["🔧"]}, "ever": {"M1": ["👀"], "M2": ["🔧"]}, "chans": {}}))
calls = []
class DC:
    base = "x"
    def _req(self, m, p, b=None):
        calls.append((m, p, b)); return {"id": "R1"}
    def remove_reaction(self, ch, mid, e): calls.append(("UNREACT", mid, e))
rec = {"stateDir": str(sd), "channelId": "C1"}
mc._gate = lambda *a: None
mc._check_files = lambda *a: []
ms._unmark = lambda dc, ch, st, mid, e, ever=False: (calls.append(("UNMARK", mid, e)), (st.get("marked") or {}).get(mid, []).remove(e) if e in (st.get("marked") or {}).get(mid, []) else None, (st.get("ever") or {}).get(mid, []).remove(e) if e in (st.get("ever") or {}).get(mid, []) else None)
mc._reply(rec, DC(), "tok", {"chat_id": "C1", "text": "끝났어", "reply_to": "M1"})
check(("PATCH", "/channels/T1", {"archived": True}) in calls, f"M1 스레드 접기: {calls}")
check(not any(c[0] == "PATCH" and c[1] == "/channels/T2" for c in calls), "다른 지시 스레드는 그대로")
check(("UNMARK", "M1", "👀") in calls and not any(c[0] == "UNMARK" and c[1] == "M2" for c in calls), f"그 지시 표시만 뗀다: {calls}")
st = json.loads((sd / "activity.json").read_text())
check("M1" not in (st.get("marked") or {}) and st["marked"].get("M2") == ["🔧"] and st.get("mid") == "M2", f"상태: {st}")
check("M1" in json.loads((sd / "threads-archived.json").read_text()), "접은 목록에 적는다")
calls.clear()
mc._reply(rec, DC(), "tok", {"chat_id": "C1", "text": "또", "reply_to": "M1"})
check(not any(c[0] == "PATCH" for c in calls), "이미 접은 건 다시 안 접는다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
PY
echo "PASS test-codex-reply-closes-thread"
