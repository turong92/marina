#!/usr/bin/env bash
# 데몬 GC 틱 — due 일 때만 실행, 기록된 데몬(primary)만, 어떤 예외도 삼켜 데몬에 영향 없음.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, os
from pathlib import Path
import marina_docker_gc as gc

calls = []
def fake(args):
    calls.append(list(args)); return ""          # 모든 조회가 빈 결과 → 지울 것 없음

NOW = 1_700_000_000.0
# 기록(dashboard-bind.env)이 없으면 어느 포트든 자동 실행 안 함 — 격리 홈 프리뷰가 실 도커를 지우던 사고 방지
assert gc.recorded_daemon_port() is None
assert gc.daemon_tick(3900, now=NOW, run=fake) == "skipped:not-primary"
assert gc.daemon_tick(3901, now=NOW, run=fake) == "skipped:not-primary"
assert calls == []
# primary 아님 → 아무것도 안 함
assert gc.daemon_tick(3901, now=NOW, run=fake, primary=False) == "skipped:not-primary"
assert calls == [] and not gc.STATE_FILE.exists()
# enabled=false → not-due
gc.set_policy("enabled", "false")
assert gc.daemon_tick(3900, now=NOW, run=fake, primary=True) == "skipped:not-due"
gc.set_policy("enabled", "true")
# due → 실행, 상태 기록(source=auto)
assert gc.daemon_tick(3900, now=NOW, run=fake, primary=True) == "ran"
assert calls and json.loads(gc.STATE_FILE.read_text())["source"] == "auto"
# 방금 돌았으면 not-due
calls.clear()
assert gc.daemon_tick(3900, now=NOW + 60, run=fake, primary=True) == "skipped:not-due" and calls == []
# 24h 뒤 다시 due
assert gc.daemon_tick(3900, now=NOW + 25 * 3600, run=fake, primary=True) == "ran"
# collect 자체가 터져도 문자열로 보고(스레드가 죽지 않게)
orig = gc.collect
gc.collect = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))
try:
    out = gc.daemon_tick(3900, now=NOW + 50 * 3600, run=fake, primary=True)
finally:
    gc.collect = orig
assert out.startswith("failed:") and "boom" in out, out
# primary 기본 판정: dashboard-bind.env 가 다른 포트를 기록하면 프리뷰 인스턴스는 건너뛴다
(gc.MARINA_HOME / "dashboard-bind.env").write_text("MARINA_CONTROL_HOST=localhost\nMARINA_CONTROL_PORT=3900\n")
assert gc.daemon_tick(3901, now=NOW + 100 * 3600, run=fake) == "skipped:not-primary"
assert gc.daemon_tick(3900, now=NOW + 100 * 3600, run=fake) == "ran"
print("ok")
PY
grep -q '_gc_loop' "$HERE/../scripts/marina_handler.py" || { echo "FAIL: 데몬 main 에 _gc_loop 스레드가 없다"; exit 1; }
grep -q 'daemon_tick' "$HERE/../scripts/marina_handler.py" || { echo "FAIL: 데몬이 daemon_tick 을 안 부른다"; exit 1; }
echo "PASS test-docker-gc-daemon-loop"
