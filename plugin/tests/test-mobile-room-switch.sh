#!/usr/bin/env bash
# 방을 넘나드는 일은 **서랍**이 맡는다 — 헤더 아래 줄은 하나만 남긴다.
#
# **왜 뒤집었나.** 예전엔 전역 세션 탭 줄을 헤더에 뒀다(형: "바로바로 클릭 많이 안하고
# 옮겨다니게"). 방 화면이 생기고 방 안 대화 줄(#roomChats)까지 붙자 줄이 **두 개**가 됐고
# 같은 대화가 양쪽에 겹쳐 떴다(형: "왜 두줄이지?"). 메신저(카톡·슬랙·디스코드) 중 위에 탭
# 줄을 두는 앱은 없다 — 전부 서랍/목록으로 건너뛴다. 마리나엔 이미 엣지 스와이프 서랍이
# 있으니 그 역할을 서랍에 넘기고 줄 하나를 돌려준다.
#
# 대신 서랍이 탭 줄만큼 빨라야 한다. 그래서 두 가지를 요구한다:
#   ① 열리면 **지금 방을 강조**하고 그 자리로 스크롤 (방 28개 목록에서 헤매면 더 느리다)
#   ② 방을 고르면 **마지막에 보던 대화**로 (늘 기본 대화로 가면 보던 자리를 매번 잃는다)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html

html = render_mobile_html()

# ① 전역 탭 줄은 없다 — 흔적(마크업·CSS·렌더러)까지 남기지 않는다.
assert "sessionTab" not in html, "전역 세션 탭 줄이 아직 남아 있다"
# 방 안 대화 줄은 **상단 드롭다운으로 접혔다**(2026-09-09, 스펙 §2) — 헤더가 두 줄에서 한 줄이
# 됐다. 의도는 그대로다: 이 방의 다른 대화로 가는 길이 대화 화면에 있어야 한다.
assert 'id="navDrop"' in html, "이 방의 다른 대화로 갈 길이 사라졌다"
assert 'id="roomChats"' not in html, "옛 칩줄이 남아 있다 — 줄이 다시 두 개가 된다"
assert "roomChatsEl" not in html, "죽은 엘리먼트 참조가 남아 스크립트가 초기화에서 죽는다"

# 뒤로가기는 **위에 뜬 것부터 하나씩** 닫는다(스펙 §2.4). 드롭다운·패널을 열어둔 채 뒤로
# 가면 대화에서 튕겨나가던 것을 막는다 — 찾으려고 연 것 때문에 보던 자리를 잃으면 안 된다.
닫기 = html[html.find("function 위에뜬것닫기"):][:600]
assert 닫기, "뒤로가기가 오버레이를 닫지 않는다"
for 오버레이 in ["closeImageViewer", "closeSubagents", "closeNav", "closeDrawer"]:
    assert 오버레이 in 닫기, f"뒤로가기가 {오버레이} 를 안 부른다"
# 오버레이를 닫은 뒤에는 **채팅 상태를 다시 밀어 넣는다** — 안 그러면 다음 뒤로가기가 두 칸 간다.
팝 = html[html.find('window.addEventListener("popstate"'):][:400]
assert "위에뜬것닫기()" in 팝 and 'view: "chat"' in 팝, f"뒤로가기 스택이 안 맞물린다: {팝[:200]}"

# ② 서랍이 열리면 지금 방을 표시하고 그 자리로 간다.
열기 = html[html.find("function openDrawer"):][:700]
assert "markCurrentRoom" in 열기, f"서랍이 지금 방을 표시하지 않는다: {열기[:300]}"
표시 = html[html.find("function markCurrentRoom"):][:700]
assert "scrollIntoView" in 표시, "지금 방으로 스크롤하지 않는다"
assert 'classList.toggle("here"' in 표시, "지금 방 강조가 없다"
assert ".roomCard.here" in html or ".roomRow.here" in html, "강조 스타일이 없다"
# 강조는 **어두운 화면에도** 있어야 한다. 밝은 연파랑만 주면 어두운 배경 위에 흰 판이 떠서
# 그 카드 글씨가 통째로 사라진다(형: "그냥 허얘", 2026-08-23 실사용).
어두운곳 = html[html.find("@media (prefers-color-scheme: dark)"):]
assert ".here" in 어두운곳, "지금 방 강조가 어두운 화면에서 흰 판이 된다"

# ③ 방을 고르면 마지막에 보던 대화로.
키 = html[html.find("function roomChatKey"):][:800]
assert "marinaMobileRoomChat" in html, "마지막 대화를 기억하지 않는다"
assert "primary" in 키, "기억이 없을 땐 기본 대화로 가야 한다"
assert "!tab.deleted" in 키 or "tab.deleted" in 키, "지운 대화로 보내면 빈 화면이 뜬다"
assert "rememberRoomChat(s.root, key)" in html, "대화를 고를 때 기억하지 않는다"
print("ok 서랍으로 건너뛴다: 지금 방 강조 + 마지막 대화 복귀 · 헤더 줄은 하나")
PY

echo "PASS test-mobile-room-switch"
