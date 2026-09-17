#!/usr/bin/env bash
# 데몬이 실제로 쓰는 인터프리터(macOS CommandLineTools python3.9)에서 모든 스크립트가 import 된다.
#
# 사고(2026-09-17): PyYAML 제거 커밋의 `def load_compose(..., project_dir: str | None = None)` 한 줄 때문에
# marina-compose.py 가 3.9 에서 import 자체가 실패했다(TypeError: unsupported operand type(s) for |).
# 테스트는 셸 python3(homebrew 3.14)로 돌아 전부 초록이었고, launchd 데몬은 CLT 3.9 로 떠서 배포 직후 깨졌다.
# 규칙: `from __future__ import annotations` 가 없는 모듈에선 PEP 604(X | None)·PEP 585 런타임 평가를 쓰지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

# 1) 정적 가드 — 어느 인터프리터로 돌든 잡는다
bad=""
for f in "$SCRIPTS"/*.py; do
  grep -q '^from __future__ import annotations' "$f" && continue
  hits="$(grep -nE '^\s*def .*(:|->)\s*[A-Za-z_][A-Za-z0-9_.]*(\[[^]]*\])?\s*\|\s*[A-Za-z_]' "$f" || true)"
  [ -n "$hits" ] && bad="$bad\n$(basename "$f"): $hits"
done
if [ -n "$bad" ]; then
  printf 'FAIL: __future__ annotations 없는 모듈의 PEP 604 시그니처(3.9 에서 import 실패):%b\n' "$bad"; exit 1
fi

# 2) 실제 3.9 로 import — 데몬 인터프리터가 이 머신에 있을 때만
PY39=""
for c in /Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3 /usr/bin/python3; do
  if [ -x "$c" ] && "$c" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 9) else 1)' 2>/dev/null; then PY39="$c"; break; fi
done
if [ -z "$PY39" ]; then
  echo "SKIP(3.9 없음) — 정적 가드만 통과"; echo "PASS test-py39-compat"; exit 0
fi
fail=0
for f in "$SCRIPTS"/*.py; do
  out="$(cd "$SCRIPTS" && PYTHONPATH="$SCRIPTS" "$PY39" - "$f" 2>&1 <<'PY' || true
import importlib.util, os, re, sys
path = sys.argv[1]
name = "m_" + re.sub(r"\W", "_", os.path.basename(path)[:-3])
spec = importlib.util.spec_from_file_location(name, path)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except SystemExit:
    pass
except (TypeError, SyntaxError, NameError) as exc:
    print(f"IMPORT-FAIL {type(exc).__name__}: {exc}")
PY
)"
  if printf '%s' "$out" | grep -q 'IMPORT-FAIL'; then
    echo "FAIL(3.9) $(basename "$f"): $(printf '%s' "$out" | grep IMPORT-FAIL | head -1)"; fail=1
  fi
done
[ "$fail" = 0 ] || exit 1
echo "PASS test-py39-compat ($("$PY39" --version 2>&1))"
