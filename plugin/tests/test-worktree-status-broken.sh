#!/usr/bin/env bash
# worktree_status: git status 실패(깨진/고아 워크트리 — gitfile dangling 등)를 '미커밋 변경분' 이 아니라
# broken 으로 구분한다. 안 그러면 삭제 시 "미커밋 변경·untracked 영구 폐기" 라고 헛겁을 준다(폐기할 것 없는데).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTL="$HERE/../scripts/marina-control.py"
python3 - "$CTL" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
P = Path("/tmp/wt")
# 깨진 git(status_lines 가 '!! git status failed ...' 한 줄 반환) → broken, dirty 아님, changeCount 0
b = mc._repo_status_entry("r", P, ["!! git status failed: fatal: not a git repository"])
assert b["broken"] is True and b["dirty"] is False and b["changeCount"] == 0, b
# 실제 변경(tracked+untracked) → dirty, broken 아님
d = mc._repo_status_entry("r", P, [" M src/a.py", "?? new.txt"])
assert d["dirty"] is True and d["broken"] is False and d["changeCount"] == 2 and d["untrackedCount"] == 1, d
# 깨끗 → 둘 다 아님
c = mc._repo_status_entry("r", P, [])
assert c["dirty"] is False and c["broken"] is False and c["changeCount"] == 0, c
print("ok worktree broken-status")
PY
echo "PASS test-worktree-status-broken"
