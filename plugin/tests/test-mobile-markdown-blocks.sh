#!/usr/bin/env bash
# 모바일 말풍선의 **블록** 렌더 — 형: "시각화 위젯도 볼 수가 없어".
# 원인은 renderRichText 가 인라인(코드·굵게·링크·개행)만 처리하고 블록 요소가 아예 없던 것.
# 형 기록 실측(assistant 텍스트 1237개): 코드펜스 안 박스 다이어그램 24% · 목록 23% · 제목 13% · 표 9%.
# 인라인만 돌리면 다이어그램은 비례폰트 + 공백 접힘 + <br> 로 뭉개지고 표는 파이프가 날것으로 나온다.
# 이 테스트가 그 계약을 잠근다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY' | node
from marina_mobile import render_mobile_html
import json

html = render_mobile_html()

def extract(start, end):
    a, b = html.find(start), html.find(end)
    if a < 0 or b < 0 or b <= a:
        raise SystemExit(f"boundaries missing for {start}")
    return html[a:b]

source = extract("// ESC_HELPERS_START", "// ESC_HELPERS_END") + "\n" + \
         extract("// MARKDOWN_BLOCKS_START", "// MARKDOWN_BLOCKS_END")
print("const helperSource = " + json.dumps(source) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${helperSource}\nthis.renderMarkdownBlocks = renderMarkdownBlocks; this.renderRichText = renderRichText;`,
  context, {filename: "marina_mobile.py::renderMarkdownBlocks"});
const render = context.renderMarkdownBlocks;
if (typeof render !== "function") throw new Error("renderMarkdownBlocks not extracted");

// ① 코드펜스 안 박스 다이어그램 — 공백/정렬이 글자 그대로 살아야 한다(1순위, 형 기록의 24%).
{
  const art = ["┌──────────┐", "│  be      │──▶ api", "└──────────┘"].join("\n");
  const out = render("설명:\n\n```\n" + art + "\n```\n");
  assert.ok(out.includes("<pre><code>"), `펜스는 pre/code 로: ${out}`);
  assert.ok(out.includes("│  be      │"), `연속 공백이 보존돼야 함: ${out}`);
  assert.ok(!/│  be      │[\s\S]*<br>/.test(out.split("</code>")[0]), "코드 안에서 <br> 로 바꾸면 안 됨");
  assert.ok(out.includes('class="mdCode"'), "가로 스크롤 컨테이너 필요");
}

// ② 펜스 안 마크다운/HTML 은 해석하지 않고 그대로 — 이스케이프 확인.
{
  const out = render("```js\nconst a = \"<b>\" + `x`;\n```");
  assert.ok(out.includes("&lt;b&gt;"), `펜스 안 HTML 은 이스케이프: ${out}`);
  assert.ok(!out.includes("<strong>"), "펜스 안에서 인라인 마크다운을 적용하면 안 됨");
  assert.ok(out.includes("mdCodeLang") && out.includes(">js<"), `언어 라벨: ${out}`);
}

// ③ 표 — 진짜 <table> 로, 정렬 지정 반영, 가로 스크롤 컨테이너.
{
  const table = ["| 항목 | 값 |", "|:-----|---:|", "| 응답 | 200 |", "| 이미지 | 9장 |"].join("\n");
  const out = render(table);
  assert.ok(out.includes("<table"), `표는 table 로: ${out}`);
  assert.ok(out.includes("<th") && out.includes("항목"), "헤더 셀");
  assert.equal((out.match(/<tr>/g) || []).length, 3, `헤더1 + 본문2: ${out}`);
  assert.ok(out.includes("text-align:right"), `정렬 지정 반영: ${out}`);
  assert.ok(out.includes("mdTableWrap"), "가로 스크롤 컨테이너 필요");
  assert.ok(!out.includes("|"), `파이프가 날것으로 남으면 안 됨: ${out}`);
}

// ④ 구분선만 있고 헤더가 없으면 표가 아니다(오탐 방지 — 본문에 파이프 쓰는 경우).
{
  const out = render("a | b 를 쓰는 문장이야");
  assert.ok(!out.includes("<table"), `표가 아님: ${out}`);
  assert.ok(out.includes("mdP"), "문단으로");
}

// ⑤ 제목 · 목록(중첩) · 인용 · 구분선
{
  const out = render(["## 결과", "- 하나", "- 둘", "  - 둘의 하위", "1. 첫째", "2. 둘째", "> 인용문", "---", "끝."].join("\n"));
  assert.ok(out.includes('class="mdH mdH2"') && out.includes("결과"), `제목: ${out}`);
  assert.ok(out.includes("<ul") && out.includes("<ol"), `불릿+번호 목록: ${out}`);
  assert.ok(/<li>둘<ul[\s\S]*둘의 하위/.test(out), `중첩 목록: ${out}`);
  assert.ok(out.includes("<blockquote"), `인용: ${out}`);
  assert.ok(out.includes("<hr"), `구분선: ${out}`);
  assert.ok(out.includes("<p") && out.includes("끝."), `문단: ${out}`);
}

// ⑥ 인라인(링크/코드/굵게)은 블록 안에서도 계속 살아 있어야 한다.
{
  const out = render("- `code` 와 **굵게** 와 https://example.com/x");
  assert.ok(out.includes("<code>code</code>"), out);
  assert.ok(out.includes("<strong>굵게</strong>"), out);
  assert.ok(out.includes('href="https://example.com/x"'), out);
}

// ⑦ XSS — 본문의 HTML 은 어떤 블록에서도 실행되면 안 된다.
{
  for (const input of ["<img src=x onerror=alert(1)>", "| <script>a</script> | b |\n|---|---|\n| c | d |",
                       "## <script>a</script>", "> <script>a</script>"]) {
    const out = render(input);
    assert.ok(!/<script>/.test(out), `script 가 살아나감: ${input} -> ${out}`);
    assert.ok(!/onerror=/.test(out) || out.includes("&lt;img"), `속성 주입: ${out}`);
  }
}

// ⑧ 닫히지 않은 펜스 · 빈 입력 — 무한루프/누락 없이 끝난다.
{
  assert.ok(render("```\n미완성 다이어그램\n").includes("미완성 다이어그램"));
  assert.equal(render(""), "");
  assert.equal(render(null), "");
  assert.ok(render("한 줄").includes("한 줄"));
}

console.log("PASS renderMarkdownBlocks: 펜스(공백보존·이스케이프) + 표(정렬·오탐방지) + 제목/목록/인용/구분선 + 인라인 보존 + XSS + 엣지 (8/8)");
''')
PY

# 말풍선이 실제로 블록 렌더러를 쓰는지 — 함수만 만들고 안 붙이면 형 화면은 그대로다.
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html
html = render_mobile_html()
assert '<div class="turnBody">${renderMarkdownBlocks(stripped)}</div>' in html, "말풍선 본문이 블록 렌더러를 안 씀"
assert 'class="subagent-turn ${turn.role === "user" ? "user" : "assistant"}">${renderMarkdownBlocks(' in html, \
    "서브에이전트 말풍선이 블록 렌더러를 안 씀"
for needle in (".mdCode pre { margin: 0; padding: 8px 10px; overflow-x: auto; }",
               ".mdTableWrap {", "white-space: pre"):
    assert needle in html, needle
print("PASS 배선: 말풍선·서브에이전트 본문 + 가로 스크롤/공백보존 CSS")
PY

echo "PASS test-mobile-markdown-blocks"
