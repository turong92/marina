#!/usr/bin/env bash
# 재료 서랍(M3) 불변식: 스캔은 버튼 클릭에서만 실행(자동 결정 0) · 재료 카드 마커(data-wb-mat) ·
# 삽입 블록 출처 주석 · 필수 ARG 빈값(???) 마커 삽입 · 기존 compose 카드(불러오기, okToReplaceYaml 재사용) ·
# 구 .compose-rail 잔재 부재(HTML) · 전 웹 JS 문법.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
J="$WEB/app-2b-workbench.js"
H="$WEB/index.html"
C="$WEB/styles.css"

[[ -f "$J" ]] || { echo "FAIL: app-2b-workbench.js 없음"; exit 1; }

# 스캔 버튼 — 자동 실행 아님: wbScan 은 wbScanBtn 의 onclick 핸들러에서만 호출되고,
# 그 외(openWorkbench/wbResetMaterials/wbOnPathChanged 등 경로 변경·진입 경로)에서는 절대 직접 호출되지 않는다.
grep -q "function wbScan()" "$J" || { echo "FAIL: wbScan 함수 정의 없음"; exit 1; }
grep -q "btn.onclick = wbScan;" "$J" || { echo "FAIL: wbScan 이 wbScanBtn 클릭 핸들러에 연결되지 않음"; exit 1; }
AUTOCALLS="$(grep -n '\bwbScan()' "$J" | grep -v 'function wbScan()' | grep -v 'btn.onclick = wbScan;' || true)"
[[ -z "$AUTOCALLS" ]] || { echo "FAIL: wbScan() 이 클릭 핸들러 밖에서도 호출됨(자동 실행 의심) — $AUTOCALLS"; exit 1; }

# 재료 카드 마커 — data-wb-mat (service/include/existing 세 유형)
grep -q "dataset.wbMat = 'service'" "$J" || { echo "FAIL: 서비스 재료 카드 마커(data-wb-mat=service) 없음"; exit 1; }
grep -q "dataset.wbMat = 'include'" "$J" || { echo "FAIL: include 재료 카드 마커(data-wb-mat=include) 없음"; exit 1; }
grep -q "dataset.wbMat = 'existing'" "$J" || { echo "FAIL: 기존 compose 카드 마커(data-wb-mat=existing) 없음"; exit 1; }

# 자체 compose 서브레포(🧩)는 조용한 누락 금지 — Dockerfile 없어도 항상 카드로 표시(스킵 없이)
grep -q "wbMatIncludeCard" "$J" || { echo "FAIL: include 카드 렌더 함수 없음"; exit 1; }

# 출처 주석 — 삽입 블록 첫 줄에 재료 출처 표기
grep -q '# ← 재료에서 추가:' "$J" || { echo "FAIL: 재료 출처 주석 문자열 없음"; exit 1; }

# 필수 ARG → environment 에 빈 값 마커(???) 삽입 로직
# ??? 마커는 이제 백엔드 스캐폴드가 build.args 에 심는다(코덱스 P2) — 프론트는 감지/안내만
grep -q '\\?\\?\\?' "$J" || { echo "FAIL: ??? 마커 감지 로직 없음"; exit 1; }
grep -q 'args:' "$HERE/../scripts/marina_dockerfile.py" || { echo "FAIL: 스캐폴드 build.args 삽입 없음"; exit 1; }
grep -q "requiredArgs" "$J" || { echo "FAIL: requiredArgs(필수 ARG) 처리 없음"; exit 1; }

# 기존 compose — compose-detect 재사용 + 불러오기 시 okToReplaceYaml(기존 위저드 로직) 재사용
grep -q "/api/compose-detect" "$J" || { echo "FAIL: compose-detect 호출 없음(기존 compose 카드)"; exit 1; }
grep -q "okToReplaceYaml()" "$J" || { echo "FAIL: 기존 compose 불러오기가 okToReplaceYaml 을 재사용하지 않음"; exit 1; }

# 스캔·스캐폴드 API 재사용(위저드와 같은 패턴)
grep -q "/api/compose-scan" "$J" || { echo "FAIL: compose-scan 호출 없음"; exit 1; }
grep -q "/api/compose-scaffold" "$J" || { echo "FAIL: compose-scaffold 호출 없음"; exit 1; }

# 삽입 헬퍼(app-1-core.js) 재사용 — 중복 구현 대신 기존 appendComposeService/appendComposeInclude 활용
grep -q "appendComposeService(" "$J" || { echo "FAIL: appendComposeService 재사용 없음"; exit 1; }
grep -q "appendComposeInclude(" "$J" || { echo "FAIL: appendComposeInclude 재사용 없음"; exit 1; }
grep -q "function appendComposeService" "$WEB/app-1-core.js" || { echo "FAIL: appendComposeService 정의(app-1-core.js) 소실"; exit 1; }
grep -q "function appendComposeInclude" "$WEB/app-1-core.js" || { echo "FAIL: appendComposeInclude 정의(app-1-core.js) 소실"; exit 1; }

# HTML: 재료 서랍 자리(스캔 버튼·상태·목록 두 종류) + 구 .compose-rail 잔재 부재
grep -q 'id="wbScanBtn"' "$H" || { echo "FAIL: 스캔 버튼(#wbScanBtn) 없음"; exit 1; }
grep -q 'id="wbMatStatus"' "$H" || { echo "FAIL: 재료 서랍 상태줄(#wbMatStatus) 없음"; exit 1; }
grep -q 'id="wbMatExisting"' "$H" || { echo "FAIL: 기존 compose 목록 자리(#wbMatExisting) 없음"; exit 1; }
grep -q 'id="wbMatScan"' "$H" || { echo "FAIL: 스캔 결과 목록 자리(#wbMatScan) 없음"; exit 1; }
grep -q 'data-wb-materials' "$H" || { echo "FAIL: data-wb-materials 마커 소실"; exit 1; }
! grep -q 'class="compose-rail"' "$H" || { echo "FAIL: 구 .compose-rail 잔재가 wbRight 에 남아있음"; exit 1; }
! grep -q 'id="composeImport"' "$H" || { echo "FAIL: 구 composeImport 버튼(레포에서 찾기) 잔재 — 재료 서랍 기존-compose 카드로 흡수되어야 함"; exit 1; }
! grep -q 'id="composeSubrepos"' "$H" || { echo "FAIL: 구 composeSubrepos 잔재 — 재료 서랍 스캔 카드로 흡수되어야 함"; exit 1; }

# CSS: 재료 카드 톤(무테두리 카드 — border 없이 배경만)
grep -q '\.wb-mat ' "$C" || { echo "FAIL: .wb-mat 카드 스타일 없음"; exit 1; }
grep -q '\.wb-mat-evi' "$C" || { echo "FAIL: .wb-mat-evi 근거줄 스타일 없음"; exit 1; }

# 문법 검사 — 전 웹 JS 파일 (node 없으면 스킵)
if command -v node >/dev/null 2>&1; then
  for f in "$WEB"/app-*.js; do
    node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
  done
fi
echo "PASS test-workbench-materials"
