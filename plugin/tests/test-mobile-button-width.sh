#!/usr/bin/env bash
# 버튼이 줄 전체 너비를 차지해 옆칸을 밀어내면 안 된다 — 형: "카드 아름답게 깨진다".
#
# **왜.** 전역 규칙이 `select, textarea, input, button { width: 100% }` 였다. 입력칸엔 맞는
# 말이지만 버튼까지 묶으니, flex 줄 안에 놓인 버튼이 전부 "줄 전체 너비"를 flex-basis 로
# 들고 왔다. 줄어들지 않는 버튼(flex-shrink:0)이면 옆칸을 그대로 밀어낸다.
# 실측(Aside, 방 패널): 끄기·지우기가 각각 309px(=줄 전체) → 대화 제목은 24px 로 찌그러짐.
# 헤더 유틸 버튼이 334px 로 부풀었던 것도 같은 뿌리다.
#
# 규칙: 폭 100%는 입력칸의 것이고, 줄을 채워야 하는 버튼은 **자기 클래스에서** 말한다.
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

# ① 전역 폼 규칙에 button 이 끼어 있으면서 width:100% 를 주면 안 된다.
for m in re.finditer(r"(?:^|\})\s*([^{}]*\bbutton\b[^{}]*)\{([^}]*)\}", html, re.M):
    선택자, 본문 = m.group(1).strip(), m.group(2)
    if "." in 선택자 or "#" in 선택자:
        continue                                   # 클래스가 스스로 정한 것은 그 클래스 책임
    assert not re.search(r"(^|;)\s*width:\s*100%", 본문), (
        f"전역 button 규칙이 폭 100%를 강제한다 — flex 줄에서 옆칸을 밀어낸다: {선택자} {{{본문.strip()}}}")

# ② 줄을 채워야 하는 것들은 자기 클래스에서 말하고 있어야 한다(①로 잃어버리면 안 된다).
for cls in (".inboxItem", ".roomCard", ".moreMenu button", ".wtAction"):
    m = re.search(r"(?:^|\})\s*" + re.escape(cls) + r"\s*\{([^}]*)\}", html, re.M)
    assert m, f"CSS 규칙을 못 찾음: {cls}"
    assert re.search(r"width:\s*100%", m.group(1)), f"{cls} 가 줄을 못 채운다"

# ③ 방 패널의 꼬리 버튼(끄기·지우기)은 줄어들지 않는 칸이라 폭을 스스로 정하면 안 된다.
m = re.search(r"(?:^|\})\s*\.roomTabUnhide\s*\{([^}]*)\}", html, re.M)
assert m and not re.search(r"width:\s*100%", m.group(1)), "끄기·지우기가 줄 전체를 먹는다"
print("ok 버튼 폭: 전역 강제 없음 · 채울 것은 스스로 말한다")
PY

echo "PASS test-mobile-button-width"
