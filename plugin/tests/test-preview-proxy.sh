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

# ⑩ 대시보드 포트에는 **쿠키 기반 fallback 을 두지 않는다.**
#    한때 "마리나 소유가 아닌 경로는 앱으로" 흘렸는데, 그 목록이 닫혀 있다는 전제가 틀렸다.
#    브라우저가 알아서 요청하는 /favicon.ico·/manifest.webmanifest·/apple-touch-icon.png 가
#    전부 앱으로 새서 마리나 탭 아이콘이 Dozzle 것으로 바뀌었다(형 발견). 소유 경로를 아무리
#    열거해도 브라우저·표준이 추가하는 경로를 다 못 쫓는다. 루트가 필요한 앱은 전용 포트가 맡는다.
assert "_preview_fallback" not in handler, \
    "쿠키 fallback 이 돌아왔다 — /favicon.ico 같은 마리나 자산이 앱으로 샌다"
assert "_MARINA_PATHS" not in handler, "소유 경로 열거 방식이 남아 있다(그 전제가 틀렸다)"
dash_preview = handler[handler.find("def _serve_preview"):handler.find("def _proxy_to_gateway")]
assert "set_cookie" not in dash_preview, "대시보드 경로에서 미리보기 쿠키를 심으면 안 된다"

# ⑬ **전용 리스너** — 경로 접두사로는 못 담는 앱이 있다. Dozzle 처럼 base:"" 로 자기가 루트에
#    있다고 믿는 SPA 는 접두사가 붙은 주소에서 라우터가 길을 잃어 "페이지 없음"을 띄운다(형 실측).
#    그래서 대시보드와 다른 포트에 문을 하나 더 내고, 거기선 **앱이 루트를 소유**한다.
assert "class PreviewHandler" in handler, "미리보기 전용 리스너가 없다"
assert "_PREVIEW_PORT" in handler, "미리보기 포트를 읽지 않는다"
preview_cls = handler[handler.find("class PreviewHandler"):handler.find("def main()")]
assert '_ROOM_PATH = "/__room"' in preview_cls, "방 선택 진입점이 없다"
# 진입점은 앱 경로와 겹치면 안 된다 — 이중 밑줄로 격리한다.
assert preview_cls.count('"/__room"') >= 1, "방 선택 경로가 앱 경로와 겹칠 수 있는 이름이다"
# 프록시는 Handler 것을 **빌려 쓴다**(중복 구현 금지). 그러려면 클래스 상수도 같이 와야 한다.
assert "Handler._proxy_to_gateway(self" in preview_cls, "프록시를 중복 구현했다"
assert "_PREVIEW_LABEL_RE = Handler._PREVIEW_LABEL_RE" in preview_cls, \
    "빌려 쓴 코드가 self 에서 찾는 상수가 없다 — 런타임 AttributeError"
assert "_HOP_BY_HOP = Handler._HOP_BY_HOP" in preview_cls, "홉바이홉 상수가 없다"
# 로그인은 대시보드에서 한다 — 쿠키는 포트를 가리지 않으므로 세션이 그대로 먹는다.
assert "auth_enabled()" in preview_cls and "401" in preview_cls, "미리보기 포트가 인증 없이 열린다"

print("PASS 미리보기: Host 라우팅 · 전체 경로 · GET/POST · 인증 뒤 · CSRF 면제(origin 유지) · "
      "쿠키 차단 · 홉바이홉 · 라벨 검증 · 오류 안내 · 대시보드엔 fallback 없음 · 전용 리스너(앱이 루트 소유)")
PY

echo "PASS test-preview-proxy"
