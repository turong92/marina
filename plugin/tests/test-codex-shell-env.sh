#!/usr/bin/env bash
# (2026-10-28) 코덱스 방의 셸 명령은 shell_environment_policy(inherit="core")로 DISCORD_STATE_DIR 를 못 받아,
#  방에서 친 `marina session room-send` 가 보낸 방을 '터미널'로 적었다(메인 지시·답 꼬리가 빠짐)
#  → 방 변수를 shell_environment_policy.set 점 경로로 넘긴다(형 config 의 set 표는 그대로 둔다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
PYTHONPATH="$DSCRIPTS:$DSCRIPTS/../../plugin/scripts" python3 - <<'PY'
from pathlib import Path
import marina_codex as mc
argv = mc.codex_argv({"stateDir": "/sd/x", "root": "/r"})
pairs = [argv[i + 1] for i, a in enumerate(argv) if a == "-c"]
want = ['shell_environment_policy.set.DISCORD_STATE_DIR="/sd/x"', 'shell_environment_policy.set.MARINA_ROOM_KIND="codex"']
missing = [w for w in want if w not in pairs]
assert not missing, f"셸에 방 변수 없음: {missing}"
assert not any(p.startswith("shell_environment_policy.set=") for p in pairs), "set 표를 통째로 덮으면 형 설정이 사라진다"
PY
echo "PASS test-codex-shell-env"
