#!/usr/bin/env bash
# 완료 카드는 **읽고 치울 수 있어야** 한다 — 형: "문신처럼 안 사라지고 겹치네?".
#
# **왜.** 카드는 대화 위에 떠 있는데(#doneSlot: absolute) 바탕이 없어서 뒤 글자가 그대로
# 비쳤고, 닫을 길도 없어 방을 볼 때마다 마지막 줄 위에 계속 얹혀 있었다.
# 영영 숨기는 것도 답이 아니다 — 다음에 뭔가 끝나면 그건 봐야 한다. 그래서 닫힘은
# **그때의 결과**에 붙는다(파일 수·커밋 수·파일명). 결과가 바뀌면 카드가 다시 뜬다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import re

from marina_mobile import render_mobile_html

html = render_mobile_html()

# ① 떠 있는 카드는 바탕이 있어야 한다 — 없으면 뒤 글자와 겹쳐 둘 다 못 읽는다.
m = re.search(r"(?:^|\})\s*\.doneCard\s*\{([^}]*)\}", html, re.M)
assert m, ".doneCard 규칙 없음"
assert re.search(r"background:\s*[^;]+", m.group(1)), f"완료 카드가 투명하다: {m.group(1)}"
어두운곳 = html[html.find("@media (prefers-color-scheme: dark)"):]
assert ".doneCard" in 어두운곳, "어두운 화면에서 밝은 바탕 그대로다"

# ② 닫는 길이 있어야 한다.
카드 = html[html.find("// DONE_CARD_START"):html.find("// DONE_CARD_END")]
assert "data-done-dismiss" in 카드, f"닫을 길이 없다: {카드[:400]}"

# ③ 닫힘은 **그 결과**에 붙는다 — 방 경로만으로 기억하면 다음 결과까지 영영 안 보인다.
키 = html[html.find("function doneKey"):][:400]
assert "files" in 키 and "commits" in 키 and "names" in 키, f"닫힘 키가 결과를 안 본다: {키[:200]}"
assert "doneKey(room) === doneDismissed" in html, "닫힘을 렌더에서 안 본다"
print("ok 완료 카드: 바탕 있고 · 닫히고 · 새 결과엔 다시 뜬다")
PY

echo "PASS test-done-dismiss"
