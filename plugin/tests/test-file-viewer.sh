#!/usr/bin/env bash
# 모바일 뷰어로 HTML·마크다운 보기 — 형: "모바일로 파일 만든거 보기 힘들잖아 … html 이랑 마크다운 먼저".
# 예전엔 이미지 외엔 전부 text/plain 원문이라 HTML 은 소스, 마크다운은 기호째로 보였다.
# 잠그는 계약:
#   ① HTML 은 view=html 일 때만 text/html, 그리고 반드시 CSP sandbox(출처 없는 문서) — 아니면 저장형 XSS.
#      그 밖(뷰 없음·다른 확장자)은 여전히 text/plain.
#   ② 모바일 뷰어: .md 는 대화창 렌더러로, .html 은 sandbox iframe 으로 view=html 을 연다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_handler import HTML_VIEW_HEADERS, session_file_as_html

assert session_file_as_html("/wt/보고서.html", "html")
assert session_file_as_html("/wt/a.HTM", "html")
assert not session_file_as_html("/wt/보고서.html", ""), "view 없이 HTML 을 실행하면 안 된다"
assert not session_file_as_html("/wt/x.js", "html"), "HTML 이 아닌 파일이 text/html 로 나가면 안 된다"
assert not session_file_as_html("/wt/x.svg", "html")
# URL 에 토큰이 실린 요청엔 스크립트가 도는 HTML 을 주지 않는다 — 문서가 location 으로 토큰을 읽어 간다.
assert not session_file_as_html("/wt/보고서.html", "html", token_in_url=True), "토큰 모드에서 HTML 보기는 토큰 유출"
h = dict(HTML_VIEW_HEADERS)
csp = h["content-security-policy"]
assert csp.startswith("sandbox "), csp
assert "allow-same-origin" not in csp, "same-origin 을 주면 sandbox 가 무의미 — marina 쿠키·API 에 닿는다"
assert "allow-top-navigation" not in csp, "부모(대시보드) 페이지를 바꿔치기 못하게"
assert "frame-ancestors 'self'" in csp and h["x-frame-options"] == "SAMEORIGIN"
print("ok ① HTML 보기 응답은 sandbox")

from marina_mobile import render_mobile_html
html = render_mobile_html()
frame = html[html.index('id="viewerFrame"') - 40: html.index('id="viewerFrame"') + 160]
assert 'sandbox="allow-scripts allow-popups"' in frame, frame
assert "allow-same-origin" not in frame, frame
assert "view=html" in html, "HTML 을 view=html 로 열지 않는다"
assert 'kind === "html" && cookieAuth' in html, "토큰 모드에서도 iframe 으로 열면 URL 의 토큰이 문서에 넘어간다"
assert "renderMarkdownBlocks(body" in html, "마크다운을 대화 렌더러로 안 그린다"
assert 'viewerFrame.removeAttribute("src")' in html, "닫아도 페이지가 뒤에서 계속 돈다"
print("ok ② 뷰어 배선")
PY
echo "PASS test-file-viewer"
