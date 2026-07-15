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
guard_calls = []
released = []
ml._marina_cli_logged = lambda root, *args, **kwargs: calls.append((root, args, kwargs))
ml.refresh_gateway = lambda: None
ml.project_for = lambda root: {"id": "demo", "composeFile": "docker-compose.yml"}
ml.compose_start_targets = lambda root, project, services: [*services, "db"]
ml.acquire_memory_reservation = lambda root, services, force=False: (
    guard_calls.append((root, services, force)) or (None, "reservation-1")
)
ml.release_memory_reservation = lambda token: released.append(token)

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
assert guard_calls == [(root, ["web", "db"], True)], guard_calls
assert released == ["reservation-1"], released
print("rebuild lifecycle OK")
PY

grep -q 'rebuild_service' "$SCRIPTS/marina_handler.py" || { echo "FAIL: handler does not import rebuild_service"; exit 1; }
grep -q 'self.path == "/api/rebuild"' "$SCRIPTS/marina_handler.py" || { echo "FAIL: /api/rebuild route missing"; exit 1; }
grep -q 'start_all(root, force=bool(body.get("force")))' "$SCRIPTS/marina_handler.py" || { echo "FAIL: /api/start-all does not pass force"; exit 1; }
grep -q "action('rebuild', session.root, svc.service)" "$SCRIPTS/marina-web/app-5b-actions.js" || { echo "FAIL: Compose service Rebuild menu missing"; exit 1; }
grep -q "svc.busy === 'rebuild' ? 'rebuilding…'" "$SCRIPTS/marina-web/app-5-sessions.js" || { echo "FAIL: rebuilding status text missing"; exit 1; }
grep -q '빌드 로그 — rebuild의 prebuild·docker build 출력' "$SCRIPTS/marina-web/app-5b-actions.js" || { echo "FAIL: build log label still describes restart as a build"; exit 1; }
grep -q 'restart --<service>.*기존 이미지로 재적용' "$SCRIPTS/marina.sh" || { echo "FAIL: CLI help still describes restart as a build"; exit 1; }

echo "PASS test-rebuild-action"
