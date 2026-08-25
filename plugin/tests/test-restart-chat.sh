#!/usr/bin/env bash
# 대화를 **한 번 눌러 다시 시작**할 수 있어야 한다 — 형: "대화를 끄고 다시 붙는 기능이 있나?
# 걍 우리가 못해주나? 비개발자한테 하라하면 못할거같은데".
#
# **왜.** 방을 띄울 때 정해지는 것들이 있다(모델·프로필 플래그 — 예: 채팅방의
# --disallowedTools Artifact). 이미 떠 있는 세션에는 안 붙으므로, 설정을 바꾸면 그 대화를
# 새로 시작해야 반영된다. 지금은 ⋯ 패널에서 [끄기] 누르고 → [＋Claude] 를 다시 누르는
# 두 단계인데, 이건 개발자한테나 자연스러운 순서다.
#
# 규칙: 한 번 누르면 마리나가 끄고 같은 자리에 새로 띄운다. 대화 기록은 그대로 남는다
# (프로세스만 새로 뜬다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path

import marina_mobile as mm

한일 = []
mm.safe_root = lambda text: Path("/wt")
mm._live_agent_tid = lambda root, source, sid: "tid-old"
mm.term_kill = lambda tid: 한일.append(("끔", tid))
mm.term_open = lambda root, cols, rows, **kw: (한일.append(("띄움", kw.get("agent_source"), kw.get("agent_prompt"))),
                                               {"tid": "tid-new"})[1]

결과 = mm.mobile_restart_chat({"root": "/wt", "source": "claude", "sid": "s1"})
assert 한일 == [("끔", "tid-old"), ("띄움", "claude", "")], 한일
assert 결과["ok"] and 결과["tid"] == "tid-new", 결과

# ② 이미 꺼져 있으면 그냥 새로 띄운다 — 오류로 만들면 형이 뭘 잘못한 줄 안다.
한일.clear()
mm._live_agent_tid = lambda root, source, sid: ""
결과 = mm.mobile_restart_chat({"root": "/wt", "source": "claude", "sid": "s1"})
assert 한일 == [("띄움", "claude", "")], 한일
assert 결과["ok"], 결과

# ③ 첫 메시지를 같이 주면 새 세션이 그걸 들고 시작한다.
한일.clear()
mm.mobile_restart_chat({"root": "/wt", "source": "claude", "sid": "s1", "prompt": "이어서 하자"})
assert 한일[-1] == ("띄움", "claude", "이어서 하자"), 한일
print("ok 다시 시작: 끄고 새로 띄운다 · 꺼져 있어도 된다 · 첫 메시지 전달")
PY

# ④ 표면과 화면 — 폰에서 한 번 눌러 되게.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY2'
import sys
from pathlib import Path

핸들러 = (Path(sys.argv[1]) / "marina_handler.py").read_text(encoding="utf-8")
assert '"/mobile/api/restart-chat"' in 핸들러, "다시 시작 표면이 없다"
블록 = 핸들러[핸들러.find('if parsed.path == "/mobile/api/restart-chat"'):][:1200]
assert "safe_root" in 블록 and "_require_root_access" in 블록, 블록[:300]

from marina_mobile import render_mobile_html
html = render_mobile_html()
assert "data-restart-chat" in html, "방 패널에 다시 시작 버튼이 없다"
print("ok 표면·버튼이 붙어 있다")
PY2

echo "PASS test-restart-chat"
