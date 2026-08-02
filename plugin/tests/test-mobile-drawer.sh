#!/usr/bin/env bash
# 모바일 좌측 패널(세션 목록 드로어) — 채팅에서 목록 화면으로 나가지 않고 세션을 바로 갈아탄다.
# 핵심 계약:
#   ① 같은 #listView 를 재사용한다(렌더 경로 하나) — 목록 뷰=전체화면, 채팅 뷰=오프캔버스 드로어
#   ② 표시는 **CSS(data-view)** 가 정한다. 인라인 display 를 쓰면 드로어 규칙을 이겨서 영영 안 열린다
#   ③ 닫힌 드로어는 화면 밖이라도 터치를 먹지 않는다(pointer-events)
#   ④ 세션을 고르면 바로 닫힌다 · 엣지 스와이프로 열고/닫는다 · 세로 스크롤과 안 싸운다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY' | node
from marina_mobile import render_mobile_html
import json

html = render_mobile_html()
a, b = html.find("// DRAWER_START"), html.find("// DRAWER_END")
if a < 0 or b < 0 or b <= a:
    raise SystemExit("DRAWER boundaries missing")
print("const drawerSource = " + json.dumps(html[a:b]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");

function el() {
  return {attrs: {},
          getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
          setAttribute(k, v) { this.attrs[k] = String(v); },
          removeAttribute(k) { delete this.attrs[k]; }};
}
function stage(view) {
  const ctx = {app: el(), listView: el(), backBtn: el()};
  ctx.app.setAttribute("data-view", view);
  vm.createContext(ctx);
  vm.runInContext(`${drawerSource}
this.openDrawer = openDrawer; this.closeDrawer = closeDrawer; this.toggleDrawer = toggleDrawer;
this.drawerOpen = drawerOpen; this.drawerSwipeIntent = drawerSwipeIntent;`, ctx, {filename: "drawer"});
  return ctx;
}

// ---------- 채팅 뷰: 열고 닫기 ----------
{
  const d = stage("chat");
  assert.equal(d.drawerOpen(), false, "기본은 닫힘");
  d.openDrawer();
  assert.equal(d.drawerOpen(), true);
  assert.equal(d.listView.getAttribute("aria-hidden"), null, "열렸으면 스크린리더에 보여야 함");
  assert.equal(d.backBtn.getAttribute("aria-expanded"), "true");
  d.closeDrawer();
  assert.equal(d.drawerOpen(), false);
  assert.equal(d.listView.getAttribute("aria-hidden"), "true", "닫혔으면 숨겨야 함");
  assert.equal(d.backBtn.getAttribute("aria-expanded"), "false");
  d.toggleDrawer(); assert.equal(d.drawerOpen(), true, "토글로 열림");
  d.toggleDrawer(); assert.equal(d.drawerOpen(), false, "토글로 닫힘");
}

// ---------- 목록 뷰에선 드로어가 아니다(이미 전체 화면) ----------
{
  const d = stage("list");
  d.openDrawer();
  assert.equal(d.drawerOpen(), false, "목록 뷰에서 드로어를 열면 안 됨");
  d.closeDrawer();
  assert.equal(d.listView.getAttribute("aria-hidden"), null, "목록 뷰에선 aria-hidden 을 걸면 안 됨(전체화면 목록)");
}

// ---------- 스와이프 판정 ----------
{
  const d = stage("chat");
  const at = (x, y) => ({x, y});
  // 왼쪽 가장자리에서 오른쪽으로 충분히 → 열기
  assert.equal(d.drawerSwipeIntent(at(10, 300), at(80, 305), false), "open");
  // 가장자리가 아니면 무시(대화 스크롤/좌우 제스처 오발 방지)
  assert.equal(d.drawerSwipeIntent(at(200, 300), at(280, 305), false), null);
  // 이동이 짧으면 무시
  assert.equal(d.drawerSwipeIntent(at(10, 300), at(40, 300), false), null);
  // 세로가 더 크면 무시(스크롤과 안 싸운다)
  assert.equal(d.drawerSwipeIntent(at(10, 300), at(70, 400), false), null);
  // 열린 상태에서 왼쪽으로 → 닫기
  assert.equal(d.drawerSwipeIntent(at(300, 300), at(200, 300), true), "close");
  // 열린 상태에서 오른쪽으로 더 끌어도 아무 일 없음
  assert.equal(d.drawerSwipeIntent(at(200, 300), at(300, 300), true), null);
  // 닫힌 상태에서 왼쪽으로 끌어도 아무 일 없음
  assert.equal(d.drawerSwipeIntent(at(300, 300), at(200, 300), false), null);
}
console.log("PASS ① 드로어 상태기계: 열기/닫기/토글 · 목록뷰 예외 · aria · 스와이프 판정 6종");
''')
PY

# ---------- 배선/CSS 계약 ----------
PYTHONPATH="$SCR" python3 - <<'PY'
import re
from marina_mobile import render_mobile_html

html = render_mobile_html()

# ② 인라인 display 로 listView 를 감추면 드로어가 CSS 로 안 열린다 — 그 코드가 되살아나면 실패.
assert 'listView.style.display' not in html, \
    "listView 를 인라인 display 로 제어하면 드로어 CSS(data-view)가 안 먹는다"

# ① 같은 #listView 를 채팅 뷰에서 오프캔버스로 쓴다
assert '#mobileApp[data-view="chat"] #listView {' in html
assert "transform: translateX(-100%)" in html, "닫힘 상태가 화면 밖이어야 함"
assert '#mobileApp[data-view="chat"][data-drawer="open"] #listView { transform: translateX(0);' in html

# ③ 닫힌 드로어는 터치를 먹지 않는다
closed = re.search(r'#mobileApp\[data-view="chat"\] #listView \{(.+?)\}', html, re.S).group(1)
assert "pointer-events: none" in closed, "닫힌 드로어가 터치를 가로채면 대화 조작이 막힌다"
assert "pointer-events: auto" in html, "열렸을 때는 다시 눌려야 함"

# 백드롭 · 토글 버튼 · 선택 시 닫힘 · Esc
assert 'id="drawerBackdrop"' in html and ".drawerBackdrop {" in html
assert "drawerBackdrop.onclick = () => closeDrawer();" in html
assert "backBtn.onclick = () => toggleDrawer();" in html
assert 'aria-expanded="false"' in html, "토글 버튼에 aria-expanded 초기값"
assert re.search(r"closeDrawer\(\);\s*//\s*좌측 패널에서 골랐으면", html), "세션 선택 시 닫힘 배선 없음"
# Esc 는 위에 있는 것부터 닫는다 — 뷰어가 열려 있으면 뷰어, 아니면 드로어.
assert 'if (event.key !== "Escape") return;' in html, "Esc 핸들러 없음"
assert "if (viewerOpen()) { closeImageViewer(); return; }" in html, "Esc 가 뷰어를 먼저 닫지 않음"
assert "if (drawerOpen()) closeDrawer();" in html, "Esc 로 드로어를 닫지 않음"
assert html.find("if (viewerOpen())") < html.find("if (drawerOpen()) closeDrawer();"), \
    "뷰어보다 드로어를 먼저 닫으면 뷰어가 안 닫힌다"

# 뒤로가기는 드로어만 닫는다 — 대화에서 튕겨나가면 안 된다. 그리고 그 분기가 list 분기보다 **먼저** 와야 한다.
popstate = html[html.find('window.addEventListener("popstate"'):]
assert "if (drawerOpen()) {" in popstate[:400], "뒤로가기가 드로어를 먼저 닫지 않음"
assert popstate.find("if (drawerOpen())") < popstate.find('history.state.view === "list"'), \
    "드로어 분기가 list 분기보다 뒤에 있으면 뒤로가기로 대화에서 튕겨난다"

# 스와이프는 passive 로 붙여 스크롤을 막지 않는다
assert html.count("{passive: true}") >= 3, "터치 리스너가 passive 여야 스크롤이 안 끊긴다"

# 겹침 순서: 드로어 백드롭 < 드로어 < 시트 < 뷰어.
# 시트가 드로어보다 아래면 드로어 뒤에서 열려 보이지도 않고, 화면을 누르면 위에 있는 드로어 백드롭이
# 먼저 먹어 드로어만 닫힌다(형: "서버 누르면 뒤에 열려서 보이지도 않고, 화면 누르면 같이 접히는데").
layers = {}
for name, pattern in [("drawerBackdrop", r"\.drawerBackdrop \{ position: fixed; inset: 0; z-index: (\d+)"),
                      ("drawer", r"position: fixed; z-index: (\d+); top: 0; bottom: 0; left: 0"),
                      ("sheet", r"\.sheetBackdrop \{ position: fixed; inset: 0; z-index: (\d+)"),
                      ("viewer", r"\.imageViewer \{ position: fixed; inset: 0; z-index: (\d+)")]:
    found = re.search(pattern, html)
    assert found, f"{name} z-index 를 못 찾음"
    layers[name] = int(found.group(1))
assert layers["drawerBackdrop"] < layers["drawer"] < layers["sheet"] < layers["viewer"], layers
# 드로어에서 시트를 열면 드로어는 접는다 — 오버레이 두 장이 겹쳐 탭이 엉키지 않게
assert "closeDrawer();   // 시트를 열면 드로어는 접는다" in html, "시트를 열 때 드로어를 안 닫는다"

# 다크 모드 대응
assert '#mobileApp[data-view="chat"] #listView { background: #11151c;' in html, "다크 모드 배경 없음"

# ---- 프로젝트/종류 탭이 패널 **안**에 있어야 한다 ----
# 헤더에 두면 채팅 뷰에서 CSS 로 숨겨져, 드로어를 열어도 현재 프로젝트 세션만 보이고 다른 프로젝트로
# 갈 방법이 없다(형: "좌측패널 마리나 프로젝트밖에 안보이잖아 다른건 어케선택할건데").
panel = html[html.find('<section id="listView"'):]
panel = panel[:panel.find("</section>")]
for needle in ('id="projectTabs"', 'id="sourceTabs"', 'id="sessionSearch"', 'id="sessionList"'):
    assert needle in panel, f"패널 안에 {needle} 가 없다"
header = html[html.find("<header>"):html.find("</header>")]
assert "projectTabs" not in header and "sourceTabs" not in header, \
    "탭이 헤더에 남아 있으면 채팅 뷰에서 숨겨져 드로어에서 프로젝트를 못 바꾼다"
assert '#mobileApp[data-view="chat"] #projectTabs' not in html, "채팅 뷰에서 프로젝트 탭을 숨기는 규칙이 남아 있다"
# 서비스는 **워크트리 소속**이라 진입점이 그룹 헤더에 있다. 전역 버튼 하나로는 드로어에 여러
# 워크트리가 섞여 있을 때 "어느 워크트리 서버인지" 알 수가 없다(형: "어디 출신인지 어케아냐").
# 헤더는 **읽는 것만**, 하는 것은 ⋯ 시트로. 340px 드로어에 버튼을 늘어놓으면 답답하고 터치 목표도 작다.
assert 'data-wt-more' in html, "워크트리 작업 진입점(⋯)이 없다"
assert 'id="servicesBtn"' not in html, "전역 서버 버튼은 어느 워크트리인지 모호하다"
assert "function openServices(root)" in html, "서비스 시트가 root 를 명시적으로 안 받는다"
assert "function openWorktreeSheet(root)" in html, "워크트리 작업 시트가 없다"
# 헤더에서 버튼이 다시 늘어나면 답답해진다 — ⋯ 하나만 남는다
head = re.search(r'<summary class="session-group-title wt-group-head">(.+?)</summary>', html, re.S).group(1)
assert head.count("<button") == 1, f"그룹 헤더에 버튼이 {head.count('<button')}개 — ⋯ 하나여야 한다"
# 어느 CLI 가 쓸 수 있는지는 알 방법이 없다. 추측해서 숨기면 **세션 없는 워크트리에서 처음 띄우기**가 막힌다.
assert "wtActionUsed" not in html, "가용성을 추측하면 첫 세션을 못 띄운다"
for label in ("Claude 대화 추가", "Codex 대화 추가"):
    assert label in html, f"{label} 가 없다"

# 드로어에서 프로젝트/종류를 바꿀 때는 대화를 떠나지 않는다(패널 열어둔 채 목록만 갈린다)
assert "if (!drawerOpen() && selectedSession() && sessionProjectId(selectedSession()) !== selectedProjectId)" in html, \
    "드로어에서 프로젝트를 바꾸면 목록 화면으로 튄다"
assert "if (!drawerOpen() && selectedSession() && sourceFilter !== \"all\"" in html, \
    "드로어에서 종류를 바꾸면 목록 화면으로 튄다"

print("PASS ② 배선/CSS: 인라인 display 금지 · 오프캔버스 · pointer-events · 백드롭/토글/선택닫힘/Esc · passive · 다크모드")
PY

echo "PASS test-mobile-drawer"
