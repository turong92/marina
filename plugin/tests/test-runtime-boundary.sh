#!/usr/bin/env bash
# runtime 경계(스펙 R1): runtime 모듈은 runtime 모듈만 import 한다 — 대시보드·discord 를 지워도 runtime 이 돈다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
python3 - "$SCRIPTS" <<'PY'
import ast, sys
from pathlib import Path
S = Path(sys.argv[1])
RAW = [l.strip() for l in (S / "RUNTIME_MODULES").read_text().splitlines() if l.strip() and not l.startswith("#")]
PENDING = {l[1:] for l in RAW if l.startswith("?")}
RUNTIME = {l.lstrip("?") for l in RAW}
names = {n[:-3] if n.endswith(".py") else n for n in RUNTIME}
bad = []
warn = []
for name in sorted(RUNTIME):
    f = S / (name if name.endswith(".py") else name + ".py")
    tree = ast.parse(f.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        mods = []
        if isinstance(node, ast.Import):
            mods = [a.name for a in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module:
            mods = [node.module]
        for m in mods:
            if m.startswith("marina_") and m not in names:
                (warn if name in PENDING else bad).append(f"{f.name}:{node.lineno} → {m}")
if warn:
    print("WARN(푸는 중):\n  " + "\n  ".join(warn))
if bad:
    print("FAIL: runtime 이 runtime 밖 모듈을 import:\n  " + "\n  ".join(bad)); sys.exit(1)
PY
echo "PASS test-runtime-boundary"
