#!/usr/bin/env bash
# (실사용 2026-10-30 homeserver) 여러 줄 질문은 선택창에서 줄마다 '│ ' 가 붙어 그려진다.
#  첫 20자가 줄바꿈에 걸치면 '│' 가 끼어 _question_visible 이 거짓 → pane_ask 가 살아 있는 카드를
#  '지나간 질문'으로 닫고 대신 올리지도 못해 "터미널에서 골라 줘" 알림만 남았다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
PYTHONPATH="$DSCRIPTS" python3 - <<'PY'
import marina_discord_ask as ask
q = {"question": "워크스페이스 싣는 법 장단점이야.\n① 헤더: 화면 주소는 /notes 그대로고"}
screen = """────
 ☐ 워크스페이스

│ 워크스페이스 싣는 법 장단점이야.
│ ① 헤더: 화면 주소는 /notes 그대로고
│ 어떻게 갈까?

❯ 1. 절충안 (Recommended)
  2. 헤더만
  4. Type something.

Enter to select · ↑/↓ to navigate · Esc to cancel
"""
assert ask._question_visible(screen, q), "상자 테두리(│)가 끼어도 같은 질문으로 봐야 한다"
assert not ask._question_visible(screen, {"question": "전혀 다른 질문이야 이건 아니지"}), "다른 질문은 아니다"
print("PASS")
PY
