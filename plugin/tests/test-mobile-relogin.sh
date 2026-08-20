#!/usr/bin/env bash
# 로그인이 풀렸을 때 **폰에서 다시 로그인할 수 있어야 한다.**
#
# 형 지적(2026-08-18): "로그인이 간간히 풀리는데 여기서 다시 로긴 할 방법이 없다".
# 마리나의 로그인은 두 겹이다 — 계정 세션(쿠키, /login 의 비밀번호)과 모바일 토큰(localStorage).
# 그런데 폰의 로그인 화면은 **토큰만** 물었다. 계정 세션이 만료된 경우엔 토큰을 아무리 넣어도
# 안 풀리고, 설치형(PWA)이라 주소창도 없어서 /login 으로 갈 방법이 아예 없었다.
#
# 게다가 401 을 처리하는 fetch 가 36개 중 하나(load)뿐이라, 대화를 보거나 답을 보내는 도중에
# 세션이 풀리면 "전송 실패 …401" 같은 말만 뜨고 아무 데도 못 갔다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html

html = render_mobile_html()
로그인화면 = html[html.find('id="mobileLogin"'):html.find('id="mobileApp"')]

# ① 로그인 화면에서 **계정 로그인**으로 갈 수 있다. 토큰만 물으면 계정 세션이 풀린 경우
# 아무리 넣어도 안 풀린다 — 설치형이라 주소창도 없다.
assert "/login" in 로그인화면, f"계정으로 로그인할 길이 없다: {로그인화면[:400]}"

# ② 어느 요청이든 401 이면 로그인으로 보낸다. 예전엔 load() 하나만 처리해서, 대화 중에
# 풀리면 실패 메시지만 뜨고 갇혔다.
assert "인증이 풀리면" in html or "handleUnauthorized" in html, "401 을 한곳에서 처리하지 않는다"
가로채기 = html[html.find("// AUTH_GUARD_START"):html.find("// AUTH_GUARD_END")]
assert 가로채기, "AUTH_GUARD 블록이 없다"
assert "401" in 가로채기 and "/login" in 가로채기, 가로채기
# 토큰이 틀린 것(403)과 계정 세션이 풀린 것(401)은 다르다 — 403 을 로그인으로 보내면
# "토큰 다시 넣으세요" 를 못 보여준다.
# 주석에 403 을 언급하는 건 괜찮다 — **판정에 쓰는지**를 본다.
코드만 = "\n".join(줄 for 줄 in 가로채기.splitlines() if not 줄.strip().startswith("//"))
assert "403" not in 코드만, f"403 까지 로그인으로 보낸다: {코드만}"
assert "status === 401" in 코드만, 코드만
print("ok 로그인 복구: 계정 로그인 통로 + 401 일괄 처리")
PY

echo "PASS test-mobile-relogin"
