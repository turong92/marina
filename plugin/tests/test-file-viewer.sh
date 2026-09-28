#!/usr/bin/env bash
# 모바일 뷰어로 HTML·마크다운 보기 — 형: "모바일로 파일 만든거 보기 힘들잖아 … html 이랑 마크다운 먼저".
# 예전엔 이미지 외엔 전부 text/plain 원문이라 HTML 은 소스, 마크다운은 기호째로 보였다.
# 잠그는 계약:
#   ① HTML 은 view=html 일 때만 text/html, 그리고 반드시 CSP sandbox(출처 없는 문서) — 아니면 저장형 XSS.
#      그 밖(뷰 없음·다른 확장자)은 여전히 text/plain.
#   ② 모바일 뷰어: .md 는 대화창 렌더러로, .html 은 sandbox iframe 으로 view=html 을 연다.
#   ③ PDF 는 application/pdf 로 주고 뷰어는 "열기"(브라우저 내장 뷰어) 카드. CSV·TSV 는 표로.
#      엑셀·zip 같은 이진 파일은 깨진 글자를 쏟지 않고 "받기" 카드.
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
assert "if (cookieAuth) viewerShowCard(\"PDF" in html, "토큰 모드에서 PDF 를 새 탭으로 열면 토큰이 주소창·기록에 남는다"
assert ".viewerDoc .tableCopyBtn { display: inline-flex; }" in html, "뷰어 표의 복사 버튼이 안 보인다"
assert 'viewerFrame.removeAttribute("src")' in html, "닫아도 페이지가 뒤에서 계속 돈다"
print("ok ② 뷰어 배선")
PY
PYTHONPATH="$SCR" python3 - <<'PY'
import tempfile
from pathlib import Path
import marina_sessions as ms
with tempfile.TemporaryDirectory() as d:
    root = Path(d).resolve()
    (root / "r.pdf").write_bytes(b"%PDF-1.4 x")
    (root / "a.csv").write_text("a,b\n1,2\n", encoding="utf-8")
    ms._TEMP_ROOTS = ()   # 픽스처가 임시 폴더라 제외 규칙을 끈다
    _, ct = ms.agent_session_file_bytes(root, str(root / "r.pdf"))
    assert ct == "application/pdf", ct
    _, ct = ms.agent_session_file_bytes(root, str(root / "a.csv"))
    assert ct.startswith("text/plain"), "CSV 는 여전히 원문으로 준다(표는 뷰어가 그린다)"
print("ok ③ PDF 는 application/pdf")
PY

python3 - "$SCR" <<'PY' | node
import json, sys
from pathlib import Path
src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
def fn(name):
    at = src.index(f"function {name}(")
    i = src.index("{", at); depth = 0
    while True:
        depth += {"{": 1, "}": -1}.get(src[i], 0)
        i += 1
        if depth == 0: return src[at:i]
consts = [l for l in src.splitlines() if l.strip().startswith(("const VIEWER_BINARY_RE", "const VIEWER_TABLE_ROWS"))]
body = "\n".join(consts + [fn(n) for n in ("viewerKind", "parseDelimited", "renderDelimitedTable")])
print("const src = " + json.dumps(body) + ";")
print(r"""
const vm = require("node:vm"), assert = require("node:assert/strict");
const ctx = {esc: s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;")};
vm.createContext(ctx);
vm.runInContext(src + "; this.api = {viewerKind, parseDelimited, renderDelimitedTable};", ctx);
const {viewerKind, parseDelimited, renderDelimitedTable} = ctx.api;
assert.equal(viewerKind({path: "/w/보고서.PDF"}), "pdf");
assert.equal(viewerKind({name: "a.csv"}), "table");
assert.equal(viewerKind({path: "/w/b.tsv"}), "table");
assert.equal(viewerKind({path: "/w/매출.xlsx"}), "binary");
assert.equal(viewerKind({path: "/w/발표.pptx"}), "binary");
assert.equal(viewerKind({path: "/w/a.md"}), "markdown");
assert.equal(viewerKind({path: "/w/a.py"}), "text");
const csv = '이름,메모\r\n"김, 철수","두 줄\n메모 ""인용""' + '"\n';   // 따옴표 셋 연속은 감싼 파이썬 문자열을 닫는다
const rows = parseDelimited(csv, ",");
assert.deepEqual(JSON.parse(JSON.stringify(rows)), [["이름", "메모"], ["김, 철수", '두 줄\n메모 "인용"']]);
const html = renderDelimitedTable("﻿a\tb\n<x>\t2\n", "t.tsv");
assert.ok(html.includes("<th>a</th><th>b</th>"), html);
assert.ok(html.includes("<td>&lt;x></td>"), "셀 글자가 이스케이프되지 않았다");
assert.ok(html.includes("data-copy-table"), "표 복사 버튼이 없다");
const big = "h\n" + Array.from({length: 1500}, (_, i) => String(i)).join("\n");
const cut = renderDelimitedTable(big, "big.csv");
assert.equal((cut.match(/<tr>/g) || []).length, 1000, "표 상한이 안 걸린다");
assert.ok(cut.includes("받기로"), "잘렸다는 안내가 없다");
console.log("ok ③ 뷰어 형식 판정·표");
""")
PY
echo "PASS test-file-viewer"
