#!/usr/bin/env bash
# 워크스페이스 '연결' 탭(P3) 셸: 탭 버튼·pane·WS_VIEWS.conn 등록·app-9 로드·상태색(--st-*) 재사용·JS 문법.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
H="$WEB/index.html"

grep -q 'data-ws-tab="conn"' "$H" || { echo "FAIL: 연결 탭 버튼 없음"; exit 1; }
grep -q 'id="tab-conn"' "$H" || { echo "FAIL: #tab-conn pane 없음"; exit 1; }
grep -q 'app-9-connections.js' "$H" || { echo "FAIL: app-9-connections.js 스크립트 태그 없음"; exit 1; }
# 로드 순서 — app-8b 다음, app-7-init 이전(D2 관례: 부트스트랩은 항상 마지막)
python3 - "$H" <<'PY' || { echo "FAIL: app-9 로드 순서(app-8b 다음·app-7-init 이전)"; exit 1; }
import sys
text = open(sys.argv[1], encoding="utf-8").read()
i8b = text.index("app-8b-git-commit.js")
i9 = text.index("app-9-connections.js")
i7 = text.index("app-7-init.js")
assert i8b < i9 < i7, (i8b, i9, i7)
PY

grep -q "WS_VIEWS = { logs: {}, git: {}, conn: {}, term: {} }" "$WEB/app-6-modals.js" || { echo "FAIL: WS_VIEWS.conn 플레이스홀더 없음"; exit 1; }

APP9="$WEB/app-9-connections.js"
[[ -f "$APP9" ]] || { echo "FAIL: app-9-connections.js 없음"; exit 1; }
grep -q "WS_VIEWS.conn = {" "$APP9" || { echo "FAIL: WS_VIEWS.conn 등록 없음"; exit 1; }
grep -q "activate(pane, ctx)" "$APP9" || { echo "FAIL: activate(pane, ctx) 없음"; exit 1; }
grep -q "/api/weave-map" "$APP9" || { echo "FAIL: weave-map 호출 없음"; exit 1; }
grep -q "gatewayUrlFor" "$APP9" || { echo "FAIL: 게이트웨이 URL 재사용(app-3) 없음"; exit 1; }
grep -q "appServices" "$APP9" || { echo "FAIL: 엮기 사이드카(-bind) 필터(appServices) 없음"; exit 1; }
grep -q "escapeHtml" "$APP9" || { echo "FAIL: escapeHtml 미사용(사용자 데이터 이스케이프 필요)"; exit 1; }
grep -q "alert(" "$APP9" && { echo "FAIL: alert 사용 금지"; exit 1; }
grep -q "selectLog(root" "$APP9" || { echo "FAIL: 서비스 노드 클릭→로그 탭 전환 없음"; exit 1; }
# 상태색 — --st-* 토큰 재사용(카드와 같은 상태 언어, 새 하드코딩 색 팔레트 금지)
grep -q -- "--st-" "$APP9" || { echo "FAIL: --st-* 상태 토큰 미사용"; exit 1; }

# 두 구역 노드-엣지 — 💻 내 컴퓨터(브라우저·인프라 노드) · 📦 Docker(격리, 서비스 노드) · 사이 엣지
grep -q "\.conn-zone-box\b" "$WEB/styles.css" || { echo "FAIL: .conn-zone-box(호스트/도커 존 박스) 스타일 없음"; exit 1; }
grep -q "\.conn-node\b" "$WEB/styles.css" || { echo "FAIL: .conn-node(노드) 스타일 없음"; exit 1; }
grep -q "\.conn-edge\b" "$WEB/styles.css" || { echo "FAIL: .conn-edge(엣지) 스타일 없음"; exit 1; }
grep -q "conn-zone-docker" "$APP9" || { echo "FAIL: app-9 에 Docker 격리 존 렌더 없음"; exit 1; }
grep -q "data-conn-wt" "$APP9" || { echo "FAIL: 워크트리 선택기(data-conn-wt) 없음"; exit 1; }

if command -v node >/dev/null 2>&1; then
  for f in "$WEB"/app-*.js; do
    node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
  done
fi
echo "PASS test-conn-tab"
