#!/usr/bin/env bash
# 세션이 하나도 없는 워크트리의 **자리표시자** 카드.
#
# 형 신고: 워크트리를 새로 만들었더니 목록에 "docs(skill): 아바타·캐릭터 사용 가이드 …" 라는
# 카드가 TERM 배지를 달고 나타났다. 그건 그 브랜치의 마지막 **커밋 제목**이고, 돌고 있는 터미널은
# 하나도 없었다. 원인은 자리표시자의 title 이 label(= alias · 커밋제목 · 프로젝트 · id) 이었던 것.
# alias 는 이미 그룹 헤더에, 프로젝트는 이미 탭에 있어 전부 중복이기도 했다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import sys
from pathlib import Path

import marina_mobile as mm

root = (Path(sys.argv[1]) / "compliance").resolve()
root.mkdir()
mm.discover_all_roots = lambda refresh=False: [root]
# 새로 만든 워크트리 — 세션도 터미널도 없고, HEAD 커밋 제목만 있다.
# 모바일은 이제 worktree_labels 로 **이름표만** 받는다(git 배지를 계산하지 않는다). 커밋 제목은
# 세션 타이틀이 없을 때의 폴백이라 sessionTitle 자리로 들어온다.
mm.worktree_labels = lambda value: {
    "id": "wt-1", "alias": "compliance", "projectId": "p", "projectLabel": "mdc-main",
    "source": "registry", "sessionTitle": "docs(skill): 아바타·캐릭터 사용 가이드 domain",
}
mm.term_list = lambda: {"sessions": []}
mm.agents_payload = lambda *a, **k: []
mm.activate_agent_payloads = lambda agents, active: agents
mm.agent_runtime_settings = lambda *a, **k: {}
mm.mobile_pending_session_settings = lambda *a, **k: {}
mm.mobile_agent_options = lambda: {}

card = [s for s in mm.mobile_state()["sessions"] if s["kind"] == "shell"]
assert len(card) == 1, card
card = card[0]

# 제목은 이 카드가 **무엇인지**만 말한다 — 커밋 제목도, alias/프로젝트 중복도 아니다.
assert "docs(skill)" not in card["title"], f"커밋 제목이 카드 제목으로 샜다: {card['title']}"
assert "compliance" not in card["title"], f"alias 가 제목에 중복된다(그룹 헤더에 이미 있다): {card['title']}"
assert "mdc-main" not in card["title"], f"프로젝트명이 제목에 중복된다(탭에 이미 있다): {card['title']}"
assert card["title"] == "새 셸 열기", card["title"]
# 브랜치 맥락은 버리지 않고 부제로 남긴다
assert card["subtitle"] == "docs(skill): 아바타·캐릭터 사용 가이드 domain", card["subtitle"]
print("PASS 자리표시자: 제목=정체 · 커밋제목은 부제 · alias/프로젝트 중복 없음")
PY

# 프론트 — 안 도는 자리표시자를 '터미널'로 세지 않는다("터미널 3"인데 실제 0개면 거짓말)
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html

html = render_mobile_html()
assert "function sessionFilterSource" in html, "필터용 소스 술어가 없다"
assert 'session.kind === "shell"' in html and 'return "none"' in html, \
    "자리표시자가 터미널 집계에서 빠지지 않는다"
assert "counts[sessionFilterSource(s)]" in html, "소스 탭 카운트가 그 술어를 안 쓴다"
assert html.count("sessionFilterSource(s) !== sourceFilter") == 2, "목록 필터가 그 술어를 안 쓴다"
assert '{label: "새 셸", badge: "새 셸"}' in html, "자리표시자가 아직 TERM 으로 배지된다"
print("PASS 프론트: 터미널 집계·필터·배지에서 자리표시자 분리")
PY

echo "PASS test-mobile-empty-worktree"

# 승격 대기 PTY — "Claude 대화 열기" 직후엔 sid 가 아직 없어 마리나엔 터미널로 보인다.
# 그때 제목이 tid 해시고 본문이 CLI 부팅 찌꺼기면 고장인 줄 안다(형: "저 꼬라지인데 어캄?").
# 고장이 아니라 시작 중이라고 말해줘야 한다.
PYTHONPATH="$SCR" python3 - <<'PY2'
import marina_mobile as M
src = open(M.__file__, encoding="utf-8").read()
assert '"새 대화 (시작 중…)"' in src, "승격 대기 제목이 없다 — tid 해시가 그대로 보인다"
assert '"첫 메시지를 보내면 시작돼요."' in src, "승격 대기 안내가 없다 — 터미널 출력이 그대로 보인다"
assert 'pending_agent = str((term.get("agent") or {}).get("source") or "")' in src, \
    "승격 대기 판정이 없다(agent.source 있고 sid 없음)"
# 순수 터미널은 건드리면 안 된다 — 그건 진짜 터미널이라 fg/cmd 가 맞는 제목이다.
assert 'else term.get("fg") or term.get("cmd") or tid' in src, "순수 터미널 제목까지 바꿨다"
print("PASS 승격 대기 표시: 제목·안내 + 순수 터미널 불변")
PY2
