#!/usr/bin/env bash
# **첫 화면에서 손가락으로 닿는 동작**을 잠근다.
#
# 왜 이 테스트가 생겼나: 방 목록을 첫 화면으로 만들면서 `sessionList.hidden = true` 한 줄로
# 예전 목록을 숨겼다. 그 안에만 있던 동작들 — 새 대화 시작·검색·프로젝트 필터·핀·숨김 해제 —
# 이 통째로 도달 불가가 됐는데, 테스트 22개가 전부 초록이었다. 렌더러 함수를 따로 vm 에 싣어
# 검사할 뿐, **합쳐진 화면에 무엇이 남았는지**는 아무도 안 봤기 때문이다.
#
# 그래서 여기서는 함수가 아니라 **완성된 페이지**를 본다: 그 동작을 부르는 손잡이가 화면에
# 실제로 있고, 그것이 숨겨지지 않는 컨테이너 안에 있는가.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import re

from marina_mobile import render_mobile_html

html = render_mobile_html()

# 숨겨지는 컨테이너 — 여기 **안에만** 있는 손잡이는 방 목록 화면에서 못 누른다.
숨는곳 = "sessionList"
assert re.search(r"\b%s\.hidden\s*=" % 숨는곳, html), "이 테스트의 전제가 바뀌었다(세션 목록을 안 숨긴다)"


def 도달가능(표식: str) -> bool:
    """이 표식이 숨는 컨테이너 밖에서도 쓰이나."""
    자리 = [m.start() for m in re.finditer(re.escape(표식), html)]
    assert 자리, f"화면에 '{표식}' 자체가 없다"
    for pos in 자리:
        앞 = html[max(0, pos - 900):pos]
        # 세션 목록 위임 리스너 안에서만 걸리는 손잡이는 방 화면에서 못 누른다.
        if f"{숨는곳}.addEventListener" in 앞 or f"{숨는곳}.onclick" in 앞:
            continue
        return True
    return False


# ① **새 대화를 시작할 수 있다.** 이게 막히면 대화 없는 방(실측 28개 중 14개)이 막다른 길이다.
assert 도달가능("data-room-launch"), "방 화면에서 새 대화를 시작할 방법이 없다"
assert "launchAgent(openRoomRoot" in html, "시작 버튼이 실제 실행 경로에 안 붙었다"

# ② 검색이 방 목록에도 먹는다 — 보이는데 안 먹으면 UI 가 거짓말을 한다.
assert "renderRoomList()" in html
검색 = html[html.find("sessionSearch.oninput"):][:200]
assert "renderRoomList" in 검색, 검색

# ③ 프로젝트 칩이 방 목록을 다시 그린다(칩은 개수를 광고한다).
칩 = html[html.find("projectTabs.onclick"):][:1400]
assert "renderRoomList" in 칩, 칩[-300:]

# ④ 방 목록에 안 먹는 손잡이는 **숨긴다** — 종류 탭은 세션 개념이라 방에는 적용되지 않는다.
assert re.search(r"sourceTabs\.hidden\s*=", html), "안 먹는 탭이 화면에 그대로 남아 있다"

# ⑤ 방이 하나도 없으면 예전 목록으로 되돌아간다 — 서버가 rooms 를 못 주면 빈 화면만 남는다.
assert re.search(r"sessionList\.hidden\s*=\s*!방없음", html), "방이 없을 때의 폴백이 없다"

# ⑤-b **hidden 이 실제로 숨기나.** 여기가 이 테스트의 원래 구멍이었다 — `hidden = true` 라고
# 적힌 걸 확인해놓고 화면에서는 계속 보였다. display 를 지정한 클래스가 UA 의
# [hidden]{display:none} 을 이기기 때문이다(.session-list{display:flex}).
# 실측이었다: hidden=true 인데 display=flex, 높이 363px — 방 목록 아래에 예전 목록이 통째로
# 붙어 있었다. 전역 가드가 없으면 앞으로도 같은 착각을 한다.
assert re.search(r"\[hidden\]\s*\{[^}]*display:\s*none\s*!important", html), \
    "hidden 속성이 CSS 에 진다 — 숨겼다고 믿은 것들이 계속 보인다"

# ⑥ 방의 모든 대화를 **열 수 있다.** 탭은 안 자르는데 세션 목록이 3개로 잘려 있으면,
# 4번째 탭은 눌러도 아무 일도 안 난다(chooseSession 이 조용히 돌아간다).
import marina_mobile as mm
import inspect

조립 = inspect.getsource(mm.mobile_state)
assert "for agent in all_agents:" in 조립, \
    "세션 목록이 카드용 상한(3개)으로 만들어진다 — 방의 4번째 대화를 열 수 없다"
# ⑥ **모든 방을 볼 수 있다.** 프로젝트 칩은 항상 하나를 강제 선택하므로, '전체' 칩이 없으면
# 방 목록이 한 프로젝트만 보여준다 — 실측으로 방 28개 중 21개, 답을 기다리는 방 4개 중 3개가
# 사라졌다. 급한 방을 아래에 두는 것보다 안 보이게 하는 게 나쁘다.
assert 'data-project=""' in html, "'전체' 칩이 없어 다른 프로젝트의 방을 볼 수 없다"
강제 = html[html.find("function renderProjectTabs"):][:700]
assert "if (selectedProjectId && !projects.some" in 강제, \
    "'전체'(빈 값) 선택이 강제 선택에 덮인다 — 전체를 고를 수 없다"
# ⑦ **전역 동작이 첫 화면에서 닿는다.** 받은 작업·새로고침·로그아웃은 워크트리별 기능이
# 아닌데 서비스 시트(워크트리 시트로만 열린다) 안에 있었다 — 세션 목록이 진짜로 숨겨지자
# 통째로 도달 불가가 됐다. 펀넬로 공개되는 화면에 로그아웃이 없는 건 특히 곤란하다.
목록화면 = html[html.find('id="listView"'):html.find('id="chatView"')]
for 표식 in ('id="logoutBtn"', 'id="inboxMenuBtn"', 'id="refreshBtn"'):
    assert 표식 in 목록화면, f"전역 동작이 목록 화면에 없다: {표식}"

# ⑧ '전체'로 본 상태가 **대화를 한 번 열었다고 풀리면 안 된다.** 예전엔 rememberProjectForRoot 가
# 무조건 덮어써서, 전체를 골라도 다음 순간 방 21개가 다시 사라졌다.
기억 = html[html.find("function rememberProjectForRoot"):][:400]
assert "if (!selectedProjectId) return;" in 기억, f"'전체'가 대화 한 번에 풀린다: {기억}"
# ⑨ **첫 화면의 줄들이 찌그러지지 않는다.** #listView 는 세로 flex 라 자식이 기본으로 줄어든다 —
# 방 목록이 길어지자 프로젝트 칩 줄이 높이 2px 로 눌려, 화면엔 잘린 조각만 보였다(형 스크린샷).
# 채팅 뷰에는 같은 수정이 이미 있었는데 목록 뷰만 빠져 있었다.
칩규칙 = re.search(r"\.project-strip \{[^}]*\}", html)
assert 칩규칙 and "flex: none" in 칩규칙.group(0), f"칩 줄이 목록에 밀려 찌그러진다: {칩규칙}"
for 클래스 in (".listTools", ".room-list"):
    규칙 = re.search(re.escape(클래스) + r" \{[^}]*\}", html)
    assert 규칙 and "flex: none" in 규칙.group(0), f"{클래스} 가 줄어들 수 있다: {규칙}"

# ⑩ **헤더가 비어 있으면 고장처럼 보인다.** 예전엔 프로젝트 칩이 헤더에 있었는데 목록 안으로
# 내려가면서 점 하나와 종만 남았다. 목록에서도 제목을 보여준다.
assert re.search(r'data-view="list"\]\s*\.chatNavTitle', html), "목록 화면에서 헤더 제목이 숨겨진다"

# ⑪ 더보기 항목은 **글자로** 말한다 — 도형만 있으면 뭔지 모른다(전엔 ☰ 하나가 떠 있었다).
메뉴규칙 = re.search(r"\.moreMenu button \{[^}]*\}", html)
assert 메뉴규칙 and "text-align: left" in 메뉴규칙.group(0), f"메뉴 항목이 아이콘처럼 보인다: {메뉴규칙}"

print("ok 첫 화면: 닿는 동작 + 줄 안 찌그러짐 + 헤더 아이콘 + 방 말투 받은작업")
PY

# ⑦ 실제 자료로 확인 — 방의 모든 탭이 세션 목록에 있나(눌러서 열리나).
PYTHONPATH="$SCR" python3 - "$HERE" <<'PY'
import sys
from pathlib import Path

import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.discover_all_roots = lambda refresh=False: [root]
mm.worktree_labels = lambda value: {"id": "wt", "alias": "방", "projectLabel": "p"}
mm.term_list = lambda: {"sessions": []}
mm._live_agent_cwds = lambda refresh=False: set()
mm.mobile_pending_question = lambda source, sid: None
mm.room_has_changes = lambda root_arg, **kw: False
# 카드 상한(3개)보다 많은 대화를 만든다 — 여기가 예전에 깨지던 자리다.
mm.agents_payload = lambda root_arg, refresh=False, include_all=False, limit=None: [
    {"source": "claude", "sid": f"s{i}", "title": f"대화{i}", "status": "idle", "ts": 100 - i}
    for i in range(5)
]

state = mm.mobile_state()
keys = {item["key"] for item in state["sessions"]}
방 = state["rooms"][0]
못여는탭 = [tab["sid"] for tab in 방["tabs"]
            if f"agent:{tab['source']}:{tab['sid']}:{root}" not in keys]
assert not 못여는탭, f"눌러도 안 열리는 탭이 있다: {못여는탭}"
assert len(방["tabs"]) == 5, 방["tabs"]
print("ok 방의 모든 대화를 열 수 있다(카드 상한을 넘어도)")
PY

echo "PASS test-mobile-reachable"
