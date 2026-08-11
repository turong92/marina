#!/usr/bin/env bash
# 미리보기 프록시 — 폰에서 워크트리 앱 화면을 여는 유일한 문.
#
# **왜 필요한가.** 앱은 이미 맥에서 돌고(compose) 게이트웨이(Caddy)가 맥 안에서 라우팅까지 한다.
# 없는 건 밖에서 거기로 들어가는 문이다. 게이트웨이 주소는 `<wt>.<proj>.localhost:3902` 인데
# `*.localhost` 는 폰에서 이름 해석이 안 되고, Funnel 도 3902 를 안 태운다(태우는 건 3900·3910).
# 그래서 이미 공개돼 있고 로그인도 걸린 대시보드(3900)에 `/preview/<label>/…` 을 내고 넘긴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import sys
from pathlib import Path

scr = Path(sys.argv[1])
handler = (scr / "marina_handler.py").read_text(encoding="utf-8")
authhttp = (scr / "marina_auth_http.py").read_text(encoding="utf-8")

# ① 게이트웨이는 **Host 헤더로** 라우팅한다 — 127.0.0.1:3902 에 붙어 Host 만 갈아 끼운다.
assert 'headers["Host"] = f"{label}.localhost"' in handler, "Host 를 갈아 끼우지 않으면 게이트웨이가 못 고른다"
assert 'http.client.HTTPConnection("127.0.0.1", _GATEWAY_PORT' in handler, "게이트웨이로 보내지 않는다"

# ② 경로 **전체**를 넘긴다. 첫 화면만 넘기면 페이지가 뒤이어 부르는 JS·CSS·API 가 죽어 하얀 화면이 된다.
assert 'rest = parsed.path[len("/preview/"):]' in handler, "경로 뒤쪽을 그대로 넘기지 않는다"
assert 'target = "/" + tail' in handler, "하위 경로가 유실된다"
assert 'if parsed.query' in handler or 'parsed.query else' in handler, "쿼리스트링이 유실된다"

# ③ POST 도 열어야 한다 — 앱이 화면을 연 뒤 자기 API 를 부른다. GET 만 열면 반쪽이 난다.
assert '_serve_preview(parsed, "GET")' in handler, "GET 라우팅 없음"
assert '_serve_preview(parsed, "POST")' in handler, "POST 라우팅 없음 — 앱 API 가 죽는다"

# ④ **인증 뒤에** 있어야 한다. /preview 는 PUBLIC_PREFIXES 가 아니므로 로그인 없이는 닿지 못한다.
assert '"/web/"' in authhttp and "/preview/" not in authhttp.split("PUBLIC_PREFIXES")[1][:120], \
    "/preview 가 공개 경로로 새면 인터넷에 그대로 열린다"
get_body = handler[handler.find("def do_GET"):handler.find("def do_POST")]
assert get_body.find("self.auth_principal = principal") < get_body.find('_serve_preview(parsed, "GET")'), \
    "인증보다 앞에 두면 로그인 없이 앱이 열린다"

# ⑤ CSRF **토큰**은 면제하되 origin 검사는 남긴다. 프록시되는 앱의 JS 는 마리나 토큰을 모른다.
assert 'not parsed.path.startswith("/preview/") and' in authhttp, "CSRF 면제가 없으면 앱 API 가 전부 403"
# 면제는 **authorize**(일반 라우팅)에만 있어야 한다. _require_principal 은 /api/auth/* 전용이라 무관하다.
authorize = authhttp[authhttp.find("    def authorize("):]
authorize = authorize[:authorize.find("        except Exception as exc:")]
assert "/preview/" in authorize, "면제가 authorize 블록에 없다"
assert authorize.find("_origin_allowed") < authorize.find('startswith("/preview/")'), \
    "origin 검사까지 건너뛰면 교차 사이트 요청이 그대로 통과한다"
require_principal = authhttp[authhttp.find("    def _require_principal("):authhttp.find("    def authorize(")]
assert "/preview/" not in require_principal, \
    "/api/auth/* 경로에까지 면제를 퍼뜨리면 안 된다"

# ⑥ 마리나 세션 쿠키를 앱으로 넘기면 안 된다 — 앱은 남의 코드다.
assert '"host", "cookie", "authorization"' in handler, "쿠키·인증 헤더가 앱으로 샌다"

# ⑦ 홉바이홉 헤더는 옮기지 않는다(연결 수명은 이쪽 소켓의 것이다).
assert "_HOP_BY_HOP" in handler and "transfer-encoding" in handler, "홉바이홉 헤더를 거르지 않는다"

# ⑧ 라벨은 검증한다 — Host 헤더에 그대로 실리므로 임의 문자열을 넣게 두면 안 된다.
assert "_PREVIEW_LABEL_RE" in handler, "라벨 검증이 없다 — Host 헤더 주입"

# ⑨ 게이트웨이가 꺼져 있으면 사람이 읽을 수 있게 알린다(빈 화면·타임아웃 금지).
assert "gateway_off" in handler, "게이트웨이 꺼짐을 알리지 않는다"
assert "preview_unreachable" in handler, "연결 실패를 알리지 않는다"

# ⑩ **미리보기 모드** — 접두사만으로는 못 푼다. 앱이 `/assets/main.js` 처럼 절대경로로 자기 자산을
#    부르고, JS 가 실행 중에 만드는 주소는 HTML 을 고쳐도 못 잡는다(실측: uptime-kuma → 하얀 화면).
#    그래서 한 번 열면 쿠키로 기억하고 마리나 것이 아닌 요청을 앱으로 흘린다.
assert "marina_preview" in handler, "미리보기 대상을 기억하지 않는다 — 절대경로 자산이 전부 404"
assert "_preview_fallback" in handler, "fallback 이 없다"
assert "HttpOnly" in handler and "SameSite=Lax" in handler, "미리보기 쿠키가 헐겁다"

# ⑪ 루트와 마리나 경로는 **절대** 넘기지 않는다. 넘기면 대시보드가 통째로 앱에 먹힌다.
assert '_MARINA_PATHS' in handler, "마리나 소유 경로 집합이 없다"
for own in ('"/api/"', '"/web/"', '"/preview/"', '"/login"', '"/mobile"'):
    assert own in handler[handler.find("_MARINA_PATHS"):handler.find("_MARINA_PATHS") + 200], \
        f"마리나 소유 경로에 {own} 가 빠졌다"
assert 'if path == "/" or path.startswith(self._MARINA_PATHS)' in handler, \
    "루트/마리나 경로를 배제하지 않으면 대시보드가 앱에 먹힌다"

# ⑫ GET 의 fallback 은 마리나 라우팅을 **다 지나친 뒤**에 있어야 한다(앞에 두면 경로를 삼킨다).
get_body2 = handler[handler.find("def do_GET"):handler.find("def do_POST")]
assert get_body2.find('_preview_fallback(parsed, "GET")') > get_body2.find("stream_log"), \
    "fallback 이 마리나 라우팅보다 앞에 있으면 대시보드 경로를 삼킨다"

print("PASS 미리보기 프록시: Host 라우팅 · 전체 경로 · GET/POST · 인증 뒤 · CSRF 면제(origin 유지) · "
      "쿠키 차단 · 홉바이홉 · 라벨 검증 · 오류 안내 · 미리보기 모드(절대경로) · 마리나 경로 보호")
PY

echo "PASS test-preview-proxy"
