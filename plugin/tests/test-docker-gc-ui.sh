#!/usr/bin/env bash
# 대시보드 헤더 Docker 디스크 배지 + GC 팝오버 — 요소·함수·엔드포인트 배선(기존 UI 테스트 관례) + 실 도커가 있으면
# dry-run 이 정말 아무것도 안 지우는지(컨테이너·이미지 수 전후 동일).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
fail() { echo "FAIL: $1"; exit 1; }

grep -qE 'id="dgc"' "$WEB/index.html" || fail "헤더에 #dgc 배지가 없다"
grep -qE 'id="dgcBtn"' "$WEB/index.html" || fail "#dgcBtn 없음"
grep -qE 'id="dgcMenu"' "$WEB/index.html" || fail "#dgcMenu 팝오버 없음"
grep -qE 'app-6f-docker-gc.js' "$WEB/index.html" || fail "app-6f-docker-gc.js 미로드"
# 배지는 메모리 게이지(#mem) 바로 다음 — 헤더 서버현황 묶음
python3 - "$WEB/index.html" <<'PY' || fail "배지 위치가 #mem 옆이 아니다"
import re, sys
html = open(sys.argv[1]).read()
assert html.index('id="mem"') < html.index('id="dgc"') < html.index('id="agentInboxWrap"')
PY
JS="$WEB/app-6f-docker-gc.js"
grep -qE 'function loadDockerGc' "$JS" || fail "loadDockerGc 없음"
grep -qE 'function renderDockerGc' "$JS" || fail "renderDockerGc 없음"
grep -qF "/api/docker-gc'" "$JS" || fail "GET /api/docker-gc 배선 없음"
grep -qF '/api/docker-gc/run' "$JS" || fail "run 배선 없음"
grep -qF '/api/docker-gc/policy' "$JS" || fail "policy 배선 없음"
grep -qE 'dryRun: true' "$JS" || fail "미리보기(dry-run) 없음"
grep -qE 'withBusy\(' "$JS" || fail "지금 정리 버튼이 withBusy 를 안 쓴다"
grep -qE "classList.toggle\('off'" "$JS" || fail "자동 정리 꺼짐 상태(.off) 표시 없음"
grep -qE "classList.toggle\('warn'" "$JS" || fail "실패 상태(.warn) 표시 없음"
grep -qE "document.hidden" "$JS" || fail "탭 숨김이면 폴링 안 함"
grep -qE 'role !== .admin.' "$JS" || fail "admin 아니면 배지 숨김"
grep -qE '\.dgc-btn' "$WEB/styles.css" || fail ".dgc-btn css 없음"
grep -qE '\.dgc\.off' "$WEB/styles.css" || fail ".dgc.off css 없음"
grep -qE '\.dgc\.warn' "$WEB/styles.css" || fail ".dgc.warn css 없음"
grep -qE '\.dgc-menu' "$WEB/styles.css" || fail ".dgc-menu css 없음"
grep -qE 'max-width: 640px' "$WEB/styles.css" || fail "모바일 규칙"

# 실 도커: dry-run 은 무삭제 — 컨테이너·이미지·볼륨·네트워크 개수 전후 동일
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # 다른 세션이 그 사이 컨테이너를 띄울 수 있으니(실측) 개수 동일이 아니라 "전에 있던 것이 하나도 안 사라졌다" 로 판정
  snapshot() { { docker ps -aq --no-trunc; docker images -q --no-trunc; docker volume ls -q; docker network ls -q --no-trunc; } | sort -u; }
  before="$(snapshot)"
  bash "$HERE/../scripts/marina-entrypoint.sh" docker gc --dry-run --json > "$MARINA_HOME/dry.json" || fail "실 도커 dry-run 실패"
  python3 -c "import json; d=json.load(open('$MARINA_HOME/dry.json')); assert d['dryRun'] is True and len(d['steps'])==5, d" || fail "실 dry-run 형태"
  after="$(snapshot)"
  gone="$(comm -23 <(echo "$before") <(echo "$after") || true)"
  [ -z "$gone" ] || fail "dry-run 이 실 도커에서 지운 것이 있다: $gone"
  [ ! -e "$MARINA_HOME/docker-gc-state.json" ] || fail "dry-run 이 상태를 썼다"
else
  echo "note: docker 미가용 — 실 dry-run 검사 생략"
fi
echo "PASS test-docker-gc-ui"
