#!/usr/bin/env bash
# 대시보드 -p 이름 = CLI -p 이름: marina-control.py session_id(root) == marina.sh session 값.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/proj"; mkdir -p "$SRC/.claude/worktrees/feat-x"; SRC="$(cd "$SRC" && pwd -P)"
WT="$SRC/.claude/worktrees/feat-x"
# marina.sh: ROOT=worktree, SOURCE_ROOT=main → session_id = basename(ROOT)=feat-x
sh_sid="$(cd "$WT" && ROOT="$WT" SOURCE_ROOT="$SRC" MARINA_HOME="$TMP/home" bash "$SH" print-session-dir 2>/dev/null | xargs basename)"
ctl_sid="$(python3 - "$CTRL" "$WT" <<'PY'
import importlib.util, sys, os
os.environ.setdefault("MARINA_HOME", "/tmp/none")
spec=importlib.util.spec_from_file_location("mctl", sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
from pathlib import Path
print(m.session_id(Path(sys.argv[2])))
PY
)"
[[ "$sh_sid" == "$ctl_sid" && -n "$ctl_sid" ]] || { echo "FAIL: sid mismatch sh='$sh_sid' ctl='$ctl_sid'"; exit 1; }
echo "ok sid=$ctl_sid"
echo "PASS test-compose-dash-sessionid"
