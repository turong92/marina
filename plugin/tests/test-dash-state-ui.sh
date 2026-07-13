#!/usr/bin/env bash
# 카드 재설계 구조 불변식: state 기반 헬퍼 존재·구 파생 제거·토글 문법·문법 오류 없음
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
J="$HERE/../scripts/marina-web/app-5-sessions.js"
grep -q "function svcState" "$J" || { echo "FAIL: svcState 없음"; exit 1; }
grep -q "function cardState" "$J" || { echo "FAIL: cardState 없음"; exit 1; }
grep -q "function stateCounts" "$J" || { echo "FAIL: stateCounts 없음"; exit 1; }
grep -q "function svcActions" "$J" || { echo "FAIL: svcActions 없음"; exit 1; }
grep -q "function cardActions" "$J" || { echo "FAIL: cardActions 없음"; exit 1; }
! grep -q "HEALTH_PILLS" "$J" || { echo "FAIL: 구 HEALTH_PILLS 잔존"; exit 1; }
! grep -q "serviceActHidden" "$J" || { echo "FAIL: 구 serviceActHidden 잔존"; exit 1; }
! grep -q "pillState" "$J" || { echo "FAIL: 구 pillState 잔존"; exit 1; }
! grep -q "전체 시작</button>" "$J" || { echo "FAIL: 상시 전체시작 스트립 잔존"; exit 1; }
grep -q "targetPort" "$J" || { echo "FAIL: D6 내부→호스트 표기 없음"; exit 1; }
# 일부 실행은 기동중(스핀)과 별개 상태 — 정적 ◐ (partial), 섞임 카드 액션은 ▶(나머지)+⏹ 공존
grep -q "'partial'" "$J" || { echo "FAIL: cardState 일부실행(partial) 상태 없음 — 기동중 스핀으로 뭉개짐"; exit 1; }
grep -q "partial: { dot: 'part'" "$J" || { echo "FAIL: STATE_META.partial 없음"; exit 1; }
grep -q '\.wt-dot\.part' "$HERE/../scripts/marina-web/styles.css" || { echo "FAIL: .wt-dot.part CSS 없음"; exit 1; }
grep -E '\.wt-dot\.part[^}]*animation' "$HERE/../scripts/marina-web/styles.css" >/dev/null && { echo "FAIL: partial 점이 스핀함 — 스핀은 진행중 전용 문법"; exit 1; }
grep -q "나머지 시작" "$J" || { echo "FAIL: 섞임 카드 ▶(나머지 시작) 액션 없음"; exit 1; }
# 카드 수동 순서(D&D) — 자동(최근순) 정렬 폐지, localStorage 순서 + 드래그 재배열 (형 확정 2026-07-13)
grep -q "marinaCardOrder" "$J" || { echo "FAIL: 카드 순서 저장(marinaCardOrder) 없음"; exit 1; }
grep -q "wireCardDrag" "$J" || { echo "FAIL: 카드 D&D 배선 없음"; exit 1; }
! grep -q "activityTs(b) - activityTs(a)" "$J" || { echo "FAIL: 최근순 자동 정렬 잔재 — 카드가 스스로 움직이면 안 됨"; exit 1; }
# 문법 검사 — 전 웹 JS 파일 (node 없으면 스킵)
if command -v node >/dev/null 2>&1; then
  for f in "$HERE/../scripts/marina-web/"app-*.js; do
    node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
  done
fi
echo "PASS test-dash-state-ui"
