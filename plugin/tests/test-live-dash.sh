#!/usr/bin/env bash
# 대시보드 live 영역 — 워크트리 카드와 분리, 단일 초록불 금지, 자동 기동 미등록이 눈에 보인다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"
WEB="$SCRIPTS/marina-web"
fail() { echo "FAIL: $*"; exit 1; }

# 1) 모듈이 로드된다
grep -qE 'app-6g-live\.js' "$WEB/index.html" || fail "app-6g-live.js 미로드"

# 2) live 영역이 워크트리 카드 목록(#sessions) **밖에** 있다 — 섞으면 '지울 수 있는 것' 으로 보인다
python3 - "$WEB/index.html" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
i_live = html.index('id="liveArea"')
i_sess = html.index('id="sessions"')
assert i_live < i_sess, "liveArea 가 sessions 뒤에 있다"
seg = html[i_live:i_sess]
assert "</div>" in seg, seg[:200]
# sessions div 안에 중첩돼 있지 않은지 — liveArea 가 자기 div 로 닫힌다
assert re.search(r'id="liveArea"[^>]*>\s*</div>', seg), "liveArea 가 스스로 닫히지 않는다(중첩 의심)"
print("ok")
PY

JS="$WEB/app-6g-live.js"
# 3) 세 신호를 각각 보여준다
grep -q '재시작' "$JS" || fail "재시작 횟수 신호 없음"
grep -q 'HTTP \${esc(h.code)}' "$JS" || fail "HTTP 상태코드를 그대로 보여주지 않는다"
grep -q '자동 기동: 안 됨' "$JS" || fail "자동 기동 미등록 표시 없음"
# 4) 단일 초록불을 만들지 않는다 — healthy 라는 **필드·식별자**를 쓰지 않는다
#    (주석에서 '401 을 healthy 로 처리하면' 처럼 언급하는 것은 괜찮다)
grep -qE '\.healthy|healthy\s*:|isHealthy|healthy\s*=' "$JS" && fail "healthy 단일 신호가 생겼다"
# 5) 데이터 '없음' 과 0 을 구분한다
grep -q '없음 (아직 기동하지 않았거나' "$JS" || fail "데이터 없음/0 구분 표시 없음"

# 5b) 오류를 **보여준다** — 영역을 조용히 숨기면 "자동 기동: 안 됨" 신호까지 같이 사라진다
grep -q 'data.error' "$JS" || fail "API 오류를 무시한다"
grep -q 'res.ok' "$JS" || fail "HTTP 실패를 무시한다"
python3 - "$JS" <<'PY'
import sys
js = open(sys.argv[1], encoding="utf-8").read()
# 오류 표시는 영역을 **숨기지 않고** 그 자리에 보여야 한다
i = js.index("function showError")
seg = js[i:js.index("async function refresh")]
assert "hidden = false" in seg, seg
assert "live-error" in seg, seg
# 세 실패 경로가 모두 showError 를 탄다: HTTP 실패 · 예외 · API 가 돌려준 error
assert js.count("showError(") >= 4, js.count("showError(")
assert "if (data && data.error) { showError" in js, "API error 를 무시한다"
assert "if (!res.ok) { showError" in js, "HTTP 실패를 무시한다"
print("ok")
PY

# 6) 스타일이 live 영역을 분리한다
grep -q '\.live-area' "$WEB/styles.css" || fail "live-area 스타일 없음"

echo "--- API"
PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS" <<'PY'
import json, os, pathlib, re, sys
sys.path.insert(0, sys.argv[1])

# 7) /api/live 가 읽기 전용 GET 목록에 등록됐다
src = open(pathlib.Path(sys.argv[1]) / "marina_handler.py", encoding="utf-8").read()
assert '"/api/live"' in src, "/api/live 라우트 미등록"
assert 'parsed.path == "/api/live"' in src, "/api/live 핸들러 없음"
assert '_require_admin_access' in src.split('parsed.path == "/api/live"')[1][:400], \
    "/api/live 가 관리자 가드를 안 탄다"

# 8) 보고에 healthy 같은 단일 불린이 없다 — UI 가 그걸로 초록불을 만들면 401 이 장애를 가린다
import marina_live as L
import marina_live_ops as O
HOME = pathlib.Path(os.environ["MARINA_HOME"])
(HOME / "projects.json").write_text(json.dumps({"projects": [
    {"id": "dashproj", "root": "/x", "composeFile": "docker-compose.yml",
     "live": {"ref": "v7", "services": ["a"]}},
    {"id": "nolive", "root": "/y"}]}), encoding="utf-8")
reports = O.live_reports()
assert [r["project"] for r in reports] == ["dashproj"], reports
r = reports[0]
assert "healthy" not in json.dumps(r), r
# 세 신호가 각각 있다
assert "containers" in r and "restartsTotal" in r and "health" in r, r
assert r["health"]["declared"] is False, r        # 선언 없으면 '선언 없음'
assert r["autostart"]["registered"] is False, r   # 유닛 없으면 '안 됨'
assert r["data"]["human"] == "없음", r
assert r["ref"] == "v7", r
print("ok")
PY
echo "PASS test-live-dash"
