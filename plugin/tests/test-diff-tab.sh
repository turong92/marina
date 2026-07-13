#!/usr/bin/env bash
# 깃 탭 diff 오버레이 계약 — 변경 탭 철거(2026-07-13): diff·커밋 폼 전부 깃 탭 안에서.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"

# 변경 탭 잔재 0 — 탭 버튼·pane·스크립트·파일
! grep -q 'data-ws-tab="diff"' "$WEB/index.html" || { echo "FAIL: 변경 탭 버튼 잔재"; exit 1; }
! grep -q 'id="tab-diff"' "$WEB/index.html" || { echo "FAIL: 변경 pane 잔재"; exit 1; }
! grep -q 'app-8c' "$WEB/index.html" || { echo "FAIL: app-8c 스크립트 태그 잔재"; exit 1; }
[[ ! -f "$WEB/app-8c-diff-tab.js" ]] || { echo "FAIL: app-8c 파일 미삭제"; exit 1; }
! grep -rq "openDiffTab" "$WEB"/app-*.js || { echo "FAIL: openDiffTab 호출 잔재(철거된 진입점)"; exit 1; }
! grep -q "diff: {}" "$WEB/app-6-modals.js" || { echo "FAIL: WS_VIEWS.diff 잔재"; exit 1; }

# 오버레이 계약 — 그래프 자리 덮기 + ✕/Esc + 파일/전체 드릴인 + WIP wipMode(커밋 폼)
grep -q "gitShowDiffOverlay" "$WEB/app-8-git.js" || { echo "FAIL: diff 오버레이 없음"; exit 1; }
grep -q "git-diff-overlay" "$WEB/app-8-git.js" || { echo "FAIL: 오버레이 마크업 없음"; exit 1; }
grep -q "e.key === 'Escape'" "$WEB/app-8-git.js" || { echo "FAIL: Esc 닫기 없음"; exit 1; }
grep -q "gitShowCommitDetail" "$WEB/app-8-git.js" || { echo "FAIL: 커밋 행 → 상세 패널 라우팅 없음"; exit 1; }
grep -q "/api/git-commit-info" "$WEB/app-8-git.js" || { echo "FAIL: 커밋 상세 API 호출 없음"; exit 1; }
grep -q "data-diff-flash" "$WEB/app-8-git.js" || { echo "FAIL: 오버레이 커밋 flash 슬롯 없음(app-8b 계약)"; exit 1; }
# untracked 클릭 = 패치 영역만 교체(목록·커밋 폼 유지, 형 통일 지시) — 전체 재렌더 드릴인 금지
grep -q "el.__origPatch" "$WEB/app-8-git.js" || { echo "FAIL: untracked 패치 교체/원복 로직 없음"; exit 1; }
! grep -q "function diffLoadFile" "$WEB/app-8-git.js" || { echo "FAIL: 구 전체-재렌더 드릴인(diffLoadFile) 잔재"; exit 1; }
grep -q "data-git-commit-slot" "$WEB/app-8-git.js" || { echo "FAIL: wipMode 커밋 폼 슬롯 소실"; exit 1; }

# 문법 — 전 웹 JS
if command -v node >/dev/null 2>&1; then
  for f in "$WEB"/app-*.js; do node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }; done
fi
echo "PASS test-diff-tab"
