#!/usr/bin/env bash
# 폴백 없는 var(--토큰) 은 반드시 정의돼 있어야 한다 — 형: "카드 아름답게 깨진다".
#
# **왜.** CSS 는 정의 안 된 커스텀 속성을 만나면 그 **선언 전체를 무효**로 만든다.
# `border: 1px solid var(--line)` 에서 --line 이 없으면 테두리가 얇아지는 게 아니라 아예
# 사라진다(computed: 0px none). 방 화면이 --line·--panel 을 썼는데 이 스타일시트엔 정의가
# 없어서, 탭·버튼·패널 상자의 테두리와 배경이 통째로 빠진 채 글자만 떠 있었다(실측).
# 색 하나 틀린 게 아니라 "스타일이 안 먹은 것처럼" 보이는 종류의 고장이라 원인을 찾기 어렵다.
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
정의 = set(re.findall(r"(--[a-zA-Z0-9-]+)\s*:", html))
# `var(--x, 기본값)` 은 정의가 없어도 안전하다 — 폴백 없는 것만 본다.
쓴것 = set(re.findall(r"var\(\s*(--[a-zA-Z0-9-]+)\s*\)", html))
빠짐 = sorted(쓴것 - 정의)
assert not 빠짐, f"정의 없는 CSS 토큰 — 이 토큰을 쓴 선언은 통째로 무효가 된다: {빠짐}"

# 방 화면이 실제로 쓰는 두 토큰은 밝은 화면·어두운 화면 **양쪽**에 있어야 한다.
어두운곳 = html[html.find("@media (prefers-color-scheme: dark)"):]
for 토큰 in ("--line", "--panel"):
    assert f"{토큰}:" in html, f"{토큰} 정의 없음"
    assert f"{토큰}:" in 어두운곳, f"{토큰} 이 어두운 화면에서 밝은 값 그대로다"
print(f"ok CSS 토큰: 폴백 없는 {len(쓴것)}개 모두 정의됨 · 다크까지")
PY

echo "PASS test-mobile-css-tokens"
