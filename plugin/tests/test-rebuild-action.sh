#!/usr/bin/env bash
# Compose Rebuild가 lifecycle/API/UI에서 동일한 명령과 busy 상태를 사용한다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"

python3 - "$SCRIPTS" <<'PY'
import sys
import time
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import marina_lifecycle as ml
from marina_state import LIFECYCLE_BUSY, busy_key

calls = []
ml._marina_cli_logged = lambda root, *args, **kwargs: calls.append((root, args, kwargs))
ml.refresh_gateway = lambda: None

root = Path("/tmp/marina-rebuild-test")
result = ml.rebuild_service(root, "web", force=True)
assert result == {"starting": True, "op": "rebuild"}, result
for _ in range(50):
    if calls and busy_key(root, "web") not in LIFECYCLE_BUSY:
        break
    time.sleep(0.02)
assert calls, "rebuild did not invoke marina CLI"
assert calls[0][1] == ("rebuild", "--web"), calls
assert calls[0][2].get("timeout") == ml.LIFECYCLE_TIMEOUT, calls
print("rebuild lifecycle OK")
PY

grep -q 'rebuild_service' "$SCRIPTS/marina_handler.py" || { echo "FAIL: handler does not import rebuild_service"; exit 1; }
grep -q 'self.path == "/api/rebuild"' "$SCRIPTS/marina_handler.py" || { echo "FAIL: /api/rebuild route missing"; exit 1; }
grep -q "action('rebuild', session.root, svc.service)" "$SCRIPTS/marina-web/app-5b-actions.js" || { echo "FAIL: Compose service Rebuild menu missing"; exit 1; }
grep -q "svc.busy === 'rebuild' ? 'rebuilding…'" "$SCRIPTS/marina-web/app-5-sessions.js" || { echo "FAIL: rebuilding status text missing"; exit 1; }

echo "PASS test-rebuild-action"
