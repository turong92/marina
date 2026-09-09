#!/usr/bin/env bash
# `const X = document.getElementById("y")` 의 y 가 마크업에 **실제로 있어야** 한다.
#
# 왜 필요한가(실측 2026-09-09): 헤더 칩줄(#roomChats)을 드롭다운으로 접으면서 마크업만 지우고
# `const roomChatsEl = document.getElementById("roomChats")` 를 남겼다. 그러면 roomChatsEl 이
# null 이 되고 바로 아래 `roomChatsEl.addEventListener(...)` 에서 **스크립트 전체가 초기화 도중
# 죽는다** — 앱이 통째로 안 뜬다. JS 문법 검사도, 렌더러 유닛 테스트도 이걸 못 잡는다.
# 우연히 눈으로 발견했다. 다음엔 우연에 기대지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import re
from marina_mobile import render_mobile_html

html = render_mobile_html()
있는id = set(re.findall(r'\bid="([A-Za-z0-9_-]+)"', html))
# 런타임에 만들어 붙이는 것들 — 마크업에 없는 게 정상이다.
동적 = {"roomMenuPop", "reloginCode", "chatPicker"}

빠진것 = []
for name, eid in re.findall(r'const\s+([A-Za-z0-9_$]+)\s*=\s*document\.getElementById\("([^"]+)"\)', html):
    if eid in 동적 or eid in 있는id:
        continue
    빠진것.append(f"{name} → #{eid}")

assert not 빠진것, (
    "마크업에 없는 id 를 const 로 잡고 있다 — null 이 되어 첫 사용에서 스크립트가 죽는다:\n  "
    + "\n  ".join(빠진것))

# 최소한 몇 개는 실제로 검사했는지 확인한다 — 정규식이 안 맞아 0건이면 통과가 거짓말이 된다.
잡은수 = len(re.findall(r'const\s+[A-Za-z0-9_$]+\s*=\s*document\.getElementById\("[^"]+"\)', html))
assert 잡은수 >= 20, f"검사 대상을 못 찾았다({잡은수}개) — 정규식이 코드와 어긋났다"
print(f"ok 엘리먼트 참조 {잡은수}개 모두 마크업에 존재")
PY
echo "PASS: 죽은 엘리먼트 참조가 없다"
