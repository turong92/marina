#!/usr/bin/env bash
# 등록 워크벤치 진입 개편(M6, R1/R5/R6) 불변식 — grep 전용(서버 불필요):
# 헤더 상시 [+ 등록] 버튼, entry 문구 개편, 위저드 완전 삭제(코드·DOM·CSS), 등록 경로 alert 부재(토스트 대체).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
H="$WEB/index.html"
CORE="$WEB/app-1-core.js"
REG="$WEB/app-2-register.js"
ENTRY="$WEB/app-2e-entry.js"
SESS="$WEB/app-5-sessions.js"
CSS="$WEB/styles.css"

# ── R1: 헤더 상시 [+ 등록] ────────────────────────────────────────────────────
grep -q 'id="headerRegister"' "$H" || { echo "FAIL: 헤더에 #headerRegister 버튼 없음"; exit 1; }
python3 - "$H" <<'PY' || { echo "FAIL: #headerRegister 가 #refresh 왼쪽(헤더 toolbar)에 없음"; exit 1; }
import sys
html = open(sys.argv[1]).read()
head = html[:html.index('</header>')]
assert 'class="toolbar"' in head, "toolbar 가 header 안에 없음"
assert 'headerRegister' in head, "headerRegister 가 header 안에 없음"
assert head.index('headerRegister') < head.index('id="refresh"'), "headerRegister 가 refresh 보다 뒤에 있음"
PY
grep -q "getElementById('headerRegister')" "$CORE" || { echo "FAIL: headerRegister 클릭 배선 없음"; exit 1; }

# ── R1: entry 문구 개편 — "팀원 설정 받았어요" / "처음 설정해요" ──────────────────────
grep -q '팀원 설정 받았어요' "$H" || { echo "FAIL: entry 문구(팀원 설정 받았어요) 없음"; exit 1; }
grep -q '처음 설정해요' "$H" || { echo "FAIL: entry 문구(처음 설정해요) 없음"; exit 1; }

# ── R1: 레포 후보 화면(신규 뷰) ───────────────────────────────────────────────
grep -q 'id="registerCandidates"' "$H" || { echo "FAIL: #registerCandidates 뷰 없음"; exit 1; }
grep -q 'id="candScanBtn"' "$H" || { echo "FAIL: 후보 스캔 버튼(#candScanBtn) 없음 — 버튼 트리거(자동 아님) 필수"; exit 1; }
grep -q 'id="candScanScope"' "$H" || { echo "FAIL: 스캔 범위 문구 자리(#candScanScope) 없음"; exit 1; }
grep -q "function openCandidates" "$ENTRY" || { echo "FAIL: openCandidates 정의 없음(app-2e-entry.js)"; exit 1; }
grep -q "api('/api/repo-candidates')" "$ENTRY" || { echo "FAIL: app-2e-entry.js 가 /api/repo-candidates 를 호출하지 않음"; exit 1; }
grep -q "openWorkbench({ root: c.path, mode: 'new' })" "$ENTRY" || { echo "FAIL: 후보 항목 클릭 → openWorkbench(mode:'new') 연결 없음"; exit 1; }
grep -q "openWorkbench({ root, mode: 'new' })" "$ENTRY" || { echo "FAIL: 경로 직접 입력 → openWorkbench(mode:'new') 연결 없음"; exit 1; }
# 스캔은 버튼 클릭에서만 — DOMContentLoaded/자동 즉시호출 금지(원칙: 자동 결정 0)
! grep -qE 'candScan\(\)\s*;' "$ENTRY" || { echo "FAIL: candScan() 이 버튼 클릭 없이 즉시 호출됨(자동 스캔 금지)"; exit 1; }

# ── R6: 위저드 완전 삭제 (코드·DOM·CSS) ───────────────────────────────────────
! grep -qE '\bopenWizard\b|renderWizScan|renderWizFiles|renderWizConnect|renderWizReview|wizCommitScan|wizRegister\b|WIZ_STEPS' "$WEB"/app-*.js \
  || { echo "FAIL: 위저드 함수/상태 잔재가 JS 에 남아있음"; exit 1; }
! grep -qE 'id="registerWizard"|id="wizSteps"|id="wizBody"|id="wizPrev"|id="wizNext"|id="wizAdvanced"' "$H" \
  || { echo "FAIL: #registerWizard 관련 DOM 잔재가 index.html 에 남아있음"; exit 1; }
! grep -qE '\.register-wizard\b|\.wiz-steps\b|\.wiz-body\b|\.wiz-nav\b' "$CSS" \
  || { echo "FAIL: 위저드 전용 CSS(.wiz-*) 잔재가 styles.css 에 남아있음"; exit 1; }
! grep -qE '\bentryWizard\b' "$WEB"/app-*.js "$H" || { echo "FAIL: entryWizard 잔재 있음(→ entryNew 로 교체됐어야 함)"; exit 1; }
# compose-scan/scaffold API 는 재료 서랍이 그대로 재사용 — 위저드 삭제로 백엔드/재료 서랍 경로까지 지워지면 안 됨
grep -q "compose-scan" "$WEB/app-2b-workbench.js" || { echo "FAIL: 재료 서랍의 compose-scan 재사용이 사라짐(과잉 삭제 의심)"; exit 1; }
grep -q "compose-scaffold" "$WEB/app-2b-workbench.js" || { echo "FAIL: 재료 서랍의 compose-scaffold 재사용이 사라짐(과잉 삭제 의심)"; exit 1; }

# ── R5: 등록 경로 alert 전면 제거(토스트로 대체) — app-1/2/2b/2c/2d 한정 ─────────────
for f in "$CORE" "$REG" "$WEB/app-2b-workbench.js" "$WEB/app-2c-xmarina-form.js" "$WEB/app-2d-explain.js"; do
  ! grep -qE '\balert\(' "$f" || { echo "FAIL: $f 에 alert( 잔존"; exit 1; }
done
grep -q "function showToast" "$CORE" || { echo "FAIL: showToast 토스트 유틸 없음(app-1-core.js)"; exit 1; }
grep -q "showToast(" "$REG" || { echo "FAIL: app-2-register.js 가 showToast 를 쓰지 않음"; exit 1; }

# ── R5: 완료 연결 — 하이라이트 + 자동 선택 ──────────────────────────────────────
grep -q "pendingFlashProjectId" "$SESS" || { echo "FAIL: app-5-sessions.js 에 pendingFlashProjectId 하이라이트 훅 없음"; exit 1; }
grep -q "pendingFlashProjectId = res.id" "$REG" || { echo "FAIL: 등록 성공 경로가 pendingFlashProjectId 를 세팅하지 않음"; exit 1; }
grep -q "\.session\.flash" "$CSS" || { echo "FAIL: .session.flash 하이라이트 CSS 없음"; exit 1; }

# ── R1: 빈 상태 — 모달 강제 오픈 대신 #sessions 대문 CTA ──────────────────────────
! grep -qE "showRegisterPanel\(true\);\s*setRegisterKind\('compose'\);\s*return;" "$SESS" \
  || { echo "FAIL: 빈 상태가 여전히 모달을 강제로 여는 구코드"; exit 1; }
grep -q "empty-cta" "$SESS" || { echo "FAIL: 빈 상태 대문 CTA(.empty-cta) 없음"; exit 1; }
grep -q "프로젝트를 등록하고 시작하세요" "$SESS" || { echo "FAIL: 빈 상태 CTA 문구 없음"; exit 1; }

# ── 문법 검사 — 전 웹 JS 파일 (node 없으면 스킵) ─────────────────────────────────
if command -v node >/dev/null 2>&1; then
  for f in "$WEB"/app-*.js; do
    node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
  done
fi

echo "PASS test-workbench-entry"
