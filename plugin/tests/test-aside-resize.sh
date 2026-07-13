#!/usr/bin/env bash
# 좌측 패널 IDE 식 리사이즈 — 레일 드래그(--aside-w, localStorage 기억) + 클릭 접기 공존 불변식
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
J="$WEB/app-6-modals.js"
C="$WEB/styles.css"

# CSS — 폭은 --aside-w 변수 산(미설정 시 기존 minmax 폴백), 레일 커서 col-resize
grep -q 'var(--aside-w, minmax(420px, 520px))' "$C" || { echo "FAIL: main 그리드가 --aside-w 변수를 안 씀(폴백 minmax 포함)"; exit 1; }
grep -q 'cursor: col-resize' "$C" || { echo "FAIL: 레일 col-resize 커서 없음"; exit 1; }

# 접힘 상태 우선순위 — aside-collapsed 는 클래스 규칙(0 트랙)이라 인라인 --aside-w 보다 이겨야 함
grep -q 'main.aside-collapsed { grid-template-columns: 0 16px' "$C" || { echo "FAIL: 접힘 규칙(0 트랙) 소실 — 리사이즈가 접기를 덮었는지 확인"; exit 1; }

# JS — 드래그 핸들(pointerdown)·폭 기억(marinaAsideW)·클릭 접기 유지(aside-collapsed 토글)
grep -q "rail.addEventListener('pointerdown'" "$J" || { echo "FAIL: 레일 드래그(pointerdown) 없음"; exit 1; }
grep -q "localStorage.setItem('marinaAsideW'" "$J" || { echo "FAIL: 폭 기억(marinaAsideW) 없음"; exit 1; }
grep -q "localStorage.getItem('marinaAsideW')" "$J" || { echo "FAIL: 저장된 폭 복원 없음"; exit 1; }
grep -q "aside-collapsed" "$J" || { echo "FAIL: 클릭 접기 토글 소실"; exit 1; }
# 드래그 직후 접기 오발 방지 가드
grep -q "if (dragged)" "$J" || { echo "FAIL: 드래그-클릭 구분 가드 없음"; exit 1; }

if command -v node >/dev/null 2>&1; then
  node --check "$J" || { echo "FAIL: 문법 오류 $J"; exit 1; }
fi
echo "PASS test-aside-resize"
