#!/usr/bin/env bash
# (형 2026-10-28) `marina dashboard off` 로 내린 대시보드를 자동 업데이트가 한 시간마다 restart 로 다시 띄웠다 —
#  대시보드가 워크트리마다 git 을 초당 수십 번 돌려 맥 fseventsd 가 100% 로 붙었다 → 꺼 둠 표시가 있으면 다시 띄우지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
PYTHONPATH="$DSCRIPTS/../../plugin/scripts" python3 - <<'PY'
import marina_autoupdate as au
calls = []
au._run = lambda argv, timeout=0: (calls.append(argv), (0, "ok"))[1]
(au.MARINA_HOME / "dashboard-off").parent.mkdir(parents=True, exist_ok=True)
(au.MARINA_HOME / "dashboard-off").write_text("")
rc, msg = au._default_restart()
assert rc == 0 and not calls, f"꺼 둔 대시보드를 다시 띄움: {calls} {msg}"
assert "꺼 둠" in msg, msg
(au.MARINA_HOME / "dashboard-off").unlink()
au._default_restart()
assert calls and calls[-1][-1] == "restart" or not calls, calls      # 표시 없으면 기존대로(installPath 없으면 실패 메시지)
PY
echo "PASS test-auto-update-dashboard-off"
