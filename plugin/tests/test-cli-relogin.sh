#!/usr/bin/env bash
# 폰에서 클로드 로그인을 끝낸다.
#
# 형 요청(2026-08-18): 클로드 로그인이 풀리면 맥에 가야만 풀 수 있었다. 폰엔 터미널 화면이
# 아예 없어서(모바일에 term 표면이 없다) URL 을 볼 방법이 없었기 때문이다.
#
# 화면은 **실물로 잡았다**(v2.1.237, 격리된 CLAUDE_CONFIG_DIR 로 띄워서 형 자격증명 무관):
#   /login  → "Select login method:"  ❯1. Claude account with subscription …
#   Enter   → "Browser didn't open? Use the url below to sign in (c to copy)"
#             https://claude.com/cai/oauth/authorize?code=true&client_id=…   ← **80칸에서 줄이 잘린다**
#             Paste code here if prompted >
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_login import extract_login_url, login_stage

# 실제로 찍힌 화면 그대로(80칸에서 잘린 URL 포함).
화면 = """
Browser didn't open? Use the url below to sign in (c to copy)
https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88
ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.co
m%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile
Paste code here if prompted >
Esc to cancel
"""

url = extract_login_url(화면)
# ① **잘린 줄을 다시 이어붙인다.** 한 줄만 집으면 URL 이 반토막이라 눌러도 안 열린다.
assert url.startswith("https://claude.com/cai/oauth/authorize?"), url
assert "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e" in url, url
assert "scope=org%3Acreate_api_key+user%3Aprofile" in url, url
# ② 안내 문구나 다음 줄이 URL 에 딸려오면 안 된다.
assert "Paste" not in url and " " not in url, url

# ②-b **실물은 OSC 8 하이퍼링크로도 온다.** 화면 글자는 80칸에서 잘리지만 이 안에는 URL 이
# 통째로 들어 있다(실측). 잘린 글자보다 이쪽을 먼저 믿어야 온전한 링크가 나온다.
osc = ("\x1b]8;id=1enbwi9;https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz"
       "\x1b\\https://claude.com/cai/oauth/authorize?code=true&client_id=ab\nc&state=xyz")
링크 = extract_login_url(osc)
assert 링크 == "https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz", 링크

# ③ URL 이 없으면 없다고 한다(빈 문자열을 링크로 걸면 안 된다).
assert extract_login_url("아무것도 없음") == ""
assert extract_login_url("") == ""

# ④ 화면이 지금 **어느 단계**인지 알아야 다음 키를 보낸다.
assert login_stage("Select login method:\n❯ 1. Claude account with subscription") == "method"
assert login_stage(화면) == "url"
assert login_stage("Not logged in · Run /login") == "logged_out"
assert login_stage("Login successful") == "done"
assert login_stage("아무 화면") == ""

# ⑤ 공백이 뭉개진 화면에서도 단계를 알아본다 — PTY 를 훑다 보면 흔하다.
assert login_stage("Selectloginmethod:") == "method"
assert login_stage("Notloggedin·Run/login") == "logged_out"
print("ok 로그인 화면: 잘린 URL 잇기 + 단계 판정")
PY

# 6) 폰 화면에 **로그인을 끝낼 길**이 실제로 있다 — 감지만 하고 길이 없으면 맥에 가야 한다.
PYTHONPATH="$SCR" python3 - <<'PY2'
from marina_mobile import render_mobile_html

html = render_mobile_html()
탭블록 = html[html.find("// ROOM_TABS_START"):html.find("// ROOM_TABS_END")]
assert "data-room-relogin" in 탭블록, "로그인이 풀린 방에 로그인 버튼이 없다"
assert "needs_login" in 탭블록, 탭블록[:300]

동작 = html[html.find("async function reloginRoom"):html.find("async function sendReloginCode")]
assert "/mobile/api/relogin" in 동작, 동작[:300]
assert "start" in 동작, 동작[:300]
# 링크는 **새 탭**으로 — 이 화면을 떠나면 코드를 붙여넣을 자리가 사라진다.
assert 'target="_blank"' in 동작, 동작
# 코드를 되돌려 보내는 길도 있어야 한다(URL 만 주고 끝나면 반쪽이다).
코드 = html[html.find("async function sendReloginCode"):][:900]
assert "reloginCode" in 코드, 코드[:300]
print("ok 폰에서 로그인을 끝낼 수 있다")
PY2

# 7) 서버 표면이 붙어 있고 가드를 탄다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY3'
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_handler.py").read_text(encoding="utf-8")
assert '"/mobile/api/relogin"' in src, "relogin 엔드포인트가 라우팅에 없다"
block = src[src.find('if parsed.path == "/mobile/api/relogin"'):][:400]
assert "safe_root" in block and "_require_root_access" in block, block
import marina_handler
print("ok relogin HTTP 표면이 붙어 있다")
PY3

echo "PASS test-cli-relogin"
