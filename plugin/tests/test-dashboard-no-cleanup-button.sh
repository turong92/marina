#!/usr/bin/env bash
# dashboard card actions: legacy cleanup reset is intentionally not exposed; cache clear owns that space.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
WEB="$ROOT/plugin/scripts/marina-web"
CARDS="$WEB/app-5b-actions.js"   # P4 분할로 clearCacheFlow 가 app-5-sessions.js → app-5b-actions.js 로 이동

# data-cleanup= 정확 매치 — 깃 탭의 워크트리 [정리](data-cleanup-root, P2 신기능)는 다른 의미라 제외
if grep -nE "data-cleanup=|sessionAction\\('cleanup'|Cleanup —|로그·pid·포트 ?설정|세션을 리셋" "$WEB"/app-*.js; then
  echo "FAIL: cleanup button/action copy is still exposed in dashboard scripts"
  exit 1
fi

# 캐시 정리는 카드 ⋯ 메뉴로 이동(콘솔 재설계 D7) — 메뉴 항목(clearCacheFlow)이 그 자리를 소유
if ! grep -q "clearCacheFlow" "$CARDS"; then
  echo "FAIL: cache clear action is missing from session cards (⋯ menu)"
  exit 1
fi

echo "PASS test-dashboard-no-cleanup-button"
