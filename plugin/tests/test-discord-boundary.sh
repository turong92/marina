#!/usr/bin/env bash
# discord 경계(스펙 R0·R3, 분리 B): discord 모듈은 discord 모듈만 import — runtime 은 `marina` CLI 로만, dashboard 는 안 부른다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
python3 - "$DSCRIPTS" <<'PY'
import ast, re, sys
from pathlib import Path
S = Path(sys.argv[1])
MODS = [l.strip() for l in (S / "DISCORD_MODULES").read_text().splitlines() if l.strip() and not l.startswith("#")]
bad = []
for name in MODS:
    f = S / (name + ".py")
    src = f.read_text(encoding="utf-8")
    for node in ast.walk(ast.parse(src)):
        mods = [a.name for a in node.names] if isinstance(node, ast.Import) else \
               [node.module] if isinstance(node, ast.ImportFrom) and node.module else []
        for m in mods:
            if m.startswith("marina_") and m not in MODS:
                bad.append(f"{f.name}:{node.lineno} import {m}")
    for i, line in enumerate(src.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in re.findall(r'"(marina\.sh|marina-control\.py|marina-dashboard\.sh)"', line):
            bad.append(f"{f.name}:{i} 파일 직접 호출 {m}")
if bad:
    print("FAIL: discord 가 runtime·dashboard 코드를 직접 부름:\n  " + "\n  ".join(bad)); sys.exit(1)
PY
echo "PASS test-discord-boundary"
