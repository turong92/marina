#!/usr/bin/env bash
# 일이 끝나면 **주소를 띄워서 확인**할 수 있어야 한다(형 결정 · 스펙 §3 완료 카드의 [화면 보기]).
#
# 만들어는 뒀는데 실제로는 안 떴다: 버튼을 "서비스가 돌고 있을 때만" 그렸는데, 일이 끝난 방은
# 대개 서버가 꺼져 있다 — 실측으로 완료 방 4개 중 3개가 도는 서비스 0개였다.
# 그래서 정작 결과를 볼 수 있어야 할 순간에 버튼이 없다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_rooms import preview_service

# ① 볼 화면이 있는 서비스를 고른다 — 형이 확인할 건 앱이지 mysql·redis 가 아니다.
정의 = [{"service": "batch"}, {"service": "index-api"}, {"service": "web"}, {"service": "mysql"}]
assert preview_service(정의) == "web", preview_service(정의)

# ② 이름이 다를 수도 있다(app·frontend·ui). 그것도 앱으로 본다.
assert preview_service([{"service": "redis"}, {"service": "frontend"}]) == "frontend"
assert preview_service([{"service": "app"}, {"service": "db"}]) == "app"

# ③ 앱이 꺼져 있고 API 만 돌아도 **앱을 켠다** — index-api 를 열면 형은 JSON 을 본다.
assert preview_service([{"service": "web"}, {"service": "index-api", "running": True}]) == "web"
# 같은 앱이 이미 돌고 있으면 그걸 쓴다(켜고 기다릴 이유가 없다).
assert preview_service([{"service": "web", "running": True}, {"service": "app"}]) == "web"

# ④ 앱 같은 게 없으면 아무거나 켜지 않는다 — mysql 을 켜봐야 형이 볼 화면이 없다.
assert preview_service([{"service": "mysql"}, {"service": "redis"}]) == ""
assert preview_service([{"service": "mysql", "running": True}]) == ""
assert preview_service([]) == ""
# 앱은 없지만 화면 있는 게 돌고 있으면 그건 준다(로그뷰어·대시보드 류).
assert preview_service([{"service": "mysql", "running": True, "port": "3306"},
                        {"service": "dozzle", "running": True, "port": "9090"}]) == "dozzle"
# 포트가 없는 배치·워커는 열어도 볼 게 없다.
assert preview_service([{"service": "batch", "running": True}]) == ""
print("ok 볼 화면 고르기: 앱 우선·도는 것 우선·없으면 안 켠다")
PY

# ⑤ 서버 표면 — 꺼져 있으면 켜서 주소까지 준다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY2'
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_handler.py").read_text(encoding="utf-8")
assert '"/mobile/api/open-preview"' in src, "완료 카드가 주소를 받아올 표면이 없다"
블록 = src[src.find('if parsed.path == "/mobile/api/open-preview"'):][:2200]
assert "safe_root" in 블록 and "_require_root_access" in 블록, 블록
# 꺼져 있으면 켠다 — 그게 이 표면의 존재 이유다.
assert "start_service" in 블록, f"꺼져 있으면 그냥 포기한다: {블록[:400]}"
import marina_handler
print("ok 주소 표면이 붙어 있고 꺼진 서비스를 켠다")
PY2

# ⑥ 화면: 완료 카드가 **서비스가 꺼져 있어도** 버튼을 보여준다.
PYTHONPATH="$SCR" python3 - <<'PY3'
from marina_mobile import render_mobile_html

html = render_mobile_html()
카드 = html[html.find("// DONE_CARD_START"):html.find("// DONE_CARD_END")]
assert "화면 보기" in 카드, 카드[:300]
# 도는 서비스가 없다고 버튼을 숨기면 안 된다 — 그때가 바로 눌러야 할 때다.
assert "openUrl" not in 카드 or "canPreview" in 카드, f"도는 서비스에만 버튼을 단다: {카드[:400]}"
동작 = html[html.find("async function openPreview"):][:2000]
assert "/mobile/api/open-preview" in 동작, 동작[:300]
# 기다리는 동안 뭐라도 말한다. 그 상태는 **카드 밖**(previewState)에 있어야 폴 재렌더에
# 지워지지 않는다 — 예전엔 버튼 안에만 넣어서 1초 뒤 "화면 보기"로 되돌아갔다(실측).
assert "켜는 중" in 카드, f"기다리는 동안 아무 말이 없다: {카드[:400]}"
assert "previewState" in 카드 and "previewState" in 동작, "켜는 중 상태가 카드 안에만 있다"
print("ok 완료 카드가 꺼져 있어도 화면을 열어준다")
PY3

echo "PASS test-done-preview"
