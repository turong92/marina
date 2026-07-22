#!/usr/bin/env bash
# POST /api/restart-dashboard — dry-run logs the restart command, responds fast
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
PORT=39731; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
MARINA_RESTART_DRY_RUN=1 MARINA_HOME="$MARINA_HOME" MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" -d '{}' "$base/api/restart-dashboard" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('restarting') is True, d" \
  || { echo "FAIL: restart-dashboard response"; exit 1; }
# dry-run 로그에 restart 명령 기록 확인
sleep 0.3
grep -q "marina-dashboard.sh restart" "$MARINA_HOME/restart-dry-run.log" \
  || { echo "FAIL: dry-run did not log restart command"; exit 1; }
# 데몬은 여전히 살아있어야 (dry-run 이라 실제 재시작 안 함)
curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 \
  || { echo "FAIL: daemon died on dry-run restart"; exit 1; }

PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import os
from types import SimpleNamespace

import marina_handler as mh

handler = object.__new__(mh.Handler)
os.environ.pop("MARINA_RESTART_DRY_RUN", None)

runs = []
popens = []
original_platform = mh.sys.platform
original_which = mh.shutil.which
original_run = mh.subprocess.run
original_popen = mh.subprocess.Popen
try:
    mh.sys.platform = "darwin"
    mh.shutil.which = lambda name: "/bin/launchctl" if name == "launchctl" else None
    mh.subprocess.run = lambda args, **kwargs: runs.append((args, kwargs)) or SimpleNamespace(returncode=0)
    mh.subprocess.Popen = lambda args, **kwargs: popens.append((args, kwargs))
    handler._schedule_dashboard_restart()
    assert len(runs) == 1 and not popens, (runs, popens)
    command, options = runs[0]
    assert command[:3] == ["/bin/launchctl", "submit", "-l"], command
    assert command[4:7] == ["--", "/bin/bash", "-c"], command
    assert "marina-dashboard.sh" in command[7] and " restart" in command[7], command
    assert "launchctl remove" in command[7], command
    assert options.get("timeout") == 3, options

    runs.clear()
    popens.clear()
    mh.sys.platform = "linux"
    handler._schedule_dashboard_restart()
    assert not runs and len(popens) == 1, (runs, popens)
    assert popens[0][1].get("start_new_session") is True, popens[0]
finally:
    mh.sys.platform = original_platform
    mh.shutil.which = original_which
    mh.subprocess.run = original_run
    mh.subprocess.Popen = original_popen

print("ok supervised restart dispatch")
PY

echo "PASS test-restart-dashboard"
