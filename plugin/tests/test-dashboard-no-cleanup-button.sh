#!/usr/bin/env bash
# dashboard card actions: legacy cleanup reset is intentionally not exposed; cache clear owns that space.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
WEB="$ROOT/plugin/scripts/marina-web"
CARDS="$WEB/app-5-sessions.js"

if grep -nE "data-cleanup|sessionAction\\('cleanup'|Cleanup —|로그·pid·포트 ?설정|세션을 리셋" "$WEB"/app-*.js; then
  echo "FAIL: cleanup button/action copy is still exposed in dashboard scripts"
  exit 1
fi

if ! grep -q "data-clear-cache" "$CARDS"; then
  echo "FAIL: cache clear button is missing from session cards"
  exit 1
fi

echo "PASS test-dashboard-no-cleanup-button"
