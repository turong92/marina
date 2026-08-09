#!/usr/bin/env bash
# 모바일 헤더가 긴 제목에 안 늘어나는 계약 — 형: "제목 섹션 때문에 전체 늘어져서 못쓰게되거든?"
#
# **왜.** 세션 제목이 긴 URL(공백 없는 불가분 문자열, 예: Slack 퍼머링크)이면 페이지 전체가
# 가로로 늘어나 못 쓰게 됐다. `#chatNavTitle` 은 ellipsis/nowrap/min-width:0 이 다 걸려 있어
# 무죄였다. 진범은 그걸 감싼 `.shellRow` —
#   header(display:grid) > .shellRow(display:flex, min-width:auto 기본값)
# 그리드 아이템의 자동 최소 크기(min-width:auto)는 min-content 라, 안 쪼개지는 URL 폭이
# 그대로 하한이 된다. 헤더 그리드 열이 1104px 로 고정 → #mobileApp 열까지 끌려감 →
# main·작성기까지 다 늘어나 body 가 가로 오버플로.
# 실측(Aside, 앱 폭 412px 제약): 수정 전 scrollWidth 1120 / .shellRow{min-width:0} 만으로 412.
# header 에 min-width:0 을 줘도 1112 라 효과 없다 — 대상은 .shellRow 다.
#
# 이 테스트가 그 계약을 잠근다. CSS 레이아웃은 노드로 못 재므로 규칙 존재를 계약으로 고정한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import re
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from marina_mobile import render_mobile_html          # noqa: E402

html = render_mobile_html()


def rule(selector):
    """CSS 본문에서 `selector { ... }` 한 덩어리를 뽑는다."""
    m = re.search(r"(?:^|\})\s*" + re.escape(selector) + r"\s*\{([^}]*)\}", html, re.M)
    assert m, f"CSS 규칙을 못 찾음: {selector} {{ ... }}"
    return m.group(1)


# ① 진짜 수정 — .shellRow 가 그리드 아이템으로서 줄어들 수 있어야 한다.
shell_row = rule(".shellRow")
assert re.search(r"min-width:\s*0", shell_row), (
    ".shellRow 에 min-width: 0 이 없다 — 긴 제목(URL)에 헤더가 min-content 로 버텨 "
    f"페이지 전체가 가로로 늘어난다. 현재: {shell_row.strip()}"
)

# ② 제목 자체의 잘림 계약(회귀 방지) — 이게 있어야 줄어든 폭에서 ellipsis 가 나온다.
nav = rule(".chatNavTitle")
for needle in ("overflow: hidden", "text-overflow: ellipsis", "white-space: nowrap", "min-width: 0"):
    assert needle in nav, f".chatNavTitle 에 {needle} 이 없다: {nav.strip()}"

# ③ 헤더는 그리드다 — ①이 필요한 이유가 이것. 구조가 바뀌면 이 테스트의 전제를 다시 봐야 한다.
assert re.search(r"display:\s*grid", rule("header")), "header 가 grid 가 아니다 — 전제 재검토 필요"

print("PASS 계약: .shellRow min-width:0 + .chatNavTitle 잘림 + header grid 전제")
PY

echo "PASS test-mobile-header-shrink"
