#!/usr/bin/env bash
# 등록 워크벤치 골격(M2) 불변식: app-2b 존재·openWorkbench 정의·index.html 로드 순서·재료/폼/린트 자리 마커·
# localStorage 초안 키·openComposeEdit→openWorkbench 연결·전 웹 JS 문법.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
J="$WEB/app-2b-workbench.js"
H="$WEB/index.html"
CORE="$WEB/app-1-core.js"

[[ -f "$J" ]] || { echo "FAIL: app-2b-workbench.js 없음"; exit 1; }
grep -q "function openWorkbench" "$J" || { echo "FAIL: openWorkbench 정의 없음"; exit 1; }

grep -q 'app-2b-workbench.js' "$H" || { echo "FAIL: index.html 에 app-2b script 태그 없음"; exit 1; }
grep -q 'app-2-register.js' "$H" || { echo "FAIL: index.html 구조 변경(app-2 기준점 소실)"; exit 1; }
python3 - "$H" <<'PY' || { echo "FAIL: app-2b 가 app-2-register.js 다음에 로드되지 않음"; exit 1; }
import sys
html = open(sys.argv[1]).read()
i2 = html.index('app-2-register.js')
i2b = html.index('app-2b-workbench.js')
assert i2b > i2, "app-2b-workbench.js 가 app-2-register.js 보다 먼저 로드됨"
PY

# 재료(M3)/marina 옵션(M4)/검증바 자리 마커 — html 또는 js 어느 쪽이든 존재하면 OK
grep -q 'data-wb-materials' "$H" || grep -q 'data-wb-materials' "$J" || { echo "FAIL: data-wb-materials 마커 없음"; exit 1; }
grep -q 'data-wb-form' "$H" || grep -q 'data-wb-form' "$J" || { echo "FAIL: data-wb-form 마커 없음"; exit 1; }
grep -q 'data-wb-lint' "$H" || grep -q 'data-wb-lint' "$J" || { echo "FAIL: data-wb-lint 마커 없음"; exit 1; }

# 워크벤치 2열 골격 DOM — 좌 자리 + 기존 compose 에디터가 재배치된 자리
grep -q 'id="wbLeft"' "$H" || { echo "FAIL: #wbLeft 없음"; exit 1; }
grep -q 'id="registerWorkbench2b"' "$H" || { echo "FAIL: #registerWorkbench2b 래퍼 없음"; exit 1; }
grep -q 'id="composeSection"' "$H" || { echo "FAIL: 기존 #composeSection DOM 소실(새로 만들면 안 됨)"; exit 1; }
grep -q 'id="composeYaml"' "$H" || { echo "FAIL: 기존 #composeYaml DOM 소실"; exit 1; }

# 초안 자동 보관 — localStorage 키 문자열
grep -q 'marinaWbDraft' "$J" || { echo "FAIL: localStorage 초안 키(marinaWbDraft) 없음"; exit 1; }

# 진입 연결 — openComposeEdit(app-1) 이 openWorkbench 를 호출(brace-matched 함수 본문 검사, 포맷에 안전)
grep -q 'openWorkbench' "$CORE" || { echo "FAIL: app-1-core.js 에 openWorkbench 참조 없음"; exit 1; }
python3 - "$CORE" <<'PY' || { echo "FAIL: openComposeEdit 함수 본문에서 openWorkbench 호출을 못 찾음"; exit 1; }
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'(?:async\s+)?function\s+openComposeEdit\s*\([^)]*\)\s*\{', src)
assert m, "openComposeEdit 정의를 못 찾음"
start = src.index('{', m.start())
depth = 0
i = start
while i < len(src):
    if src[i] == '{':
        depth += 1
    elif src[i] == '}':
        depth -= 1
        if depth == 0:
            break
    i += 1
body = src[start:i]
assert 'openWorkbench' in body, "openComposeEdit 본문에 openWorkbench 호출 없음"
PY

# 위저드 삭제(R6) — 신규 등록 진입은 레포 후보 화면(app-2e-entry.js)이 openWorkbench(mode:'new') 로 연결
grep -q "openWorkbench({ root, mode: 'new' })" "$WEB/app-2e-entry.js" || { echo "FAIL: app-2e-entry.js(레포 후보) 가 openWorkbench 로 연결되지 않음"; exit 1; }
! grep -qE '\bopenWizard\b|registerWizard|wizAdvanced' "$WEB"/app-*.js "$H" || { echo "FAIL: 위저드 잔재가 남아있음"; exit 1; }

# 문법 검사 — 전 웹 JS 파일 (node 없으면 스킵)
if command -v node >/dev/null 2>&1; then
  for f in "$WEB"/app-*.js; do
    node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
  done
fi
echo "PASS test-workbench-skeleton"
