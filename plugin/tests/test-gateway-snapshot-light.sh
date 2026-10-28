#!/usr/bin/env bash
# (형 2026-10-28) 게이트웨이 스냅샷이 워크트리마다 session_payload(메모리·git status --untracked-files=all·로그)를 통째로 만들어
#  한 번에 git 97회·38초 — 게이트웨이엔 서비스·포트만 필요하다 → git·메모리·로그를 안 읽는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
PYTHONPATH="$DSCRIPTS/../../plugin/scripts" python3 - <<'PY'
from pathlib import Path
import marina_lifecycle as ml
import marina_worktrees as mw
root = Path("/tmp/wt-x")
ml.discover_roots = lambda *a, **k: [root]
ml.project_for = lambda r: {"id": "proj", "kind": "compose"}
def boom(*a, **k): raise AssertionError("게이트웨이가 통째 payload(git status 등)를 읽음")
mw.session_payload = boom
mw.worktree_status_cached = boom
if hasattr(ml, "session_payload"): ml.session_payload = boom
ml._gateway_services = lambda r, p: [{"service": "web", "port": 32001, "running": True}]
snap = ml._gateway_snapshot()
assert snap and snap[0]["projectId"] == "proj" and snap[0]["services"][0]["port"] == 32001, snap
PY
echo "PASS test-gateway-snapshot-light"
