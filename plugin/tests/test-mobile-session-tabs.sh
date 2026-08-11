#!/usr/bin/env bash
# 모바일 세션 탭 — 형: "모바일도 위에 세션 탭 넣어줘 바로바로 클릭 많이 안하고 옮겨다니게".
#
# **왜.** 모바일은 세션을 바꾸려면 매번 드로어(목록)를 열었다 골랐다 해야 했다. 웹엔 이미
# 브라우저식 대화 멀티탭이 있는데 모바일만 없어서, 같은 일을 하는 데 클릭 수가 배로 들었다.
#
# **모델.** 웹과 같다 — **연 것만** 탭으로 남는다. 전체 세션을 늘어놓으면 워크트리 14개가 그대로
# 줄이 돼 탭의 의미가 사라진다. 순서는 연 순서 그대로다(자동 정렬하면 누르려던 탭이 움직인다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import re
import sys

sys.path.insert(0, sys.argv[1])
from marina_mobile import render_mobile_html          # noqa: E402

html = render_mobile_html()

# ① 마크업: 탭 줄은 header 안에 있어야 대화를 스크롤해도 붙어 있다(그래야 "바로바로"가 된다).
assert 'id="sessionTabs"' in html, "세션 탭 컨테이너가 없다"
header = html[html.find("<header>"):html.find("</header>")]
assert 'id="sessionTabs"' in header, "탭 줄이 header 밖에 있으면 스크롤에 딸려 올라가 무용지물"
# shellRow 는 뒤로가기·제목·액션으로 이미 꽉 찬 한 줄이다 — 탭은 **별도 줄**이어야 한다.
shell_row = header[header.find('class="shellRow"'):header.find("</div>", header.find('class="shellRow"'))]
assert 'id="sessionTabs"' not in shell_row, "탭이 shellRow 안에 있으면 제목·버튼과 끼인다"

# ② 상태: 연 것만 남고, localStorage 로 재방문에도 유지된다.
assert "marinaMobileTabs" in html, "탭 목록이 저장되지 않는다 — 재방문마다 초기화된다"
assert "function addTab(" in html and "function closeTab(" in html, "탭 추가/닫기가 없다"
assert "addTab(key);" in html, "세션을 골라도 탭에 안 남으면 탭이 늘지 않는다"

# ③ 전환은 기존 chooseSession 을 그대로 쓴다 — 별도 경로를 만들면 초안·드래프트·타겟 복원이 갈라진다.
assert "chooseSession(tab.getAttribute" in html, "탭 클릭이 chooseSession 을 쓰지 않는다"

# ④ 닫기(✕)를 전환보다 **먼저** 본다. ✕ 가 탭 안에 있어서 순서가 뒤집히면 닫으려다 전환된다.
handler = html[html.find('sessionTabsEl.addEventListener("click"'):]
handler = handler[:handler.find("});")]
assert handler.find("data-tab-close") < handler.find("data-tab-key"), \
    "닫기 판정이 탭 전환보다 뒤에 있으면 ✕ 를 눌러도 전환만 된다"

# ⑤ 탭이 하나뿐이면 줄을 띄우지 않는다 — 화면만 먹는다.
assert "alive.length < 2" in html, "탭 1개일 때 줄을 숨기지 않는다"

# ⑥ 죽은 세션 탭은 조용히 정리된다(세션이 사라져도 탭이 남으면 눌렀을 때 아무 일도 안 난다).
assert "openTabs.filter(key => sessions.some" in html, "사라진 세션의 탭을 정리하지 않는다"

# ⑦ 라벨은 잘려야 한다 — 세션 제목이 긴 URL 이면 탭 하나가 줄을 다 먹는다(헤더에서 겪은 그 문제).
css = html[html.find(".sessionTab {"):html.find(".liveQuestion")]
assert "text-overflow: ellipsis" in html[html.find(".sessionTabLabel"):html.find(".sessionTabX")], \
    "탭 라벨에 말줄임이 없다 — 긴 제목 하나가 줄을 다 먹는다"
assert "overflow-x: auto" in html[html.find(".sessionTabs {"):html.find(".sessionTab {")], \
    "탭 줄이 가로 스크롤되지 않는다"

print("PASS 세션 탭: header 배치·연 것만·저장·chooseSession 재사용·닫기 우선·1개숨김·정리·말줄임")
PY

echo "PASS test-mobile-session-tabs"
