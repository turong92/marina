#!/usr/bin/env bash
# 터널 주소로 접속했을 때 [화면 보기] — 형: "미리보기 눌러도 바로 탭 열리다가 꺼지던데".
# 원인(2026-09-28 실측): 카드가 `<접속 호스트>:8443/__room` 을 줬는데 Cloudflare 터널은 포트를 안 가려
# 대시보드로 떨어져 404. 미리보기 문은 funnel 8443 에만 붙어 있었다.
# 잠그는 계약:
#   ① public-hosts 줄의 `preview=<이름>` 을 읽는다. 공개 이름 목록(호스트 가드)은 그대로.
#   ② 그 이름이 있으면 openUrl 은 같은 호스트의 /mobile/api/preview-go(입장권 받는 곳). 없으면 예전 :8443.
#      이 맥에서 연 거면 게이트웨이 주소 그대로.
#   ③ 입장권은 1회용·짧은 수명·그 방(label) 전용.
#   ④ 미리보기 문은 입장권으로 **그 방 전용 통행증**(정식 로그인 아님)을 심고 입장권을 떼어 / 로 보낸다.
#      남의 사이트에서 건너온 입장권은 거절(로그인 CSRF), 로그에는 입장권을 남기지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import tempfile
import urllib.parse
from pathlib import Path
import marina_handler as mh

with tempfile.TemporaryDirectory() as d:
    mh.PUBLIC_HOSTS_FILE = Path(d) / "public-hosts"
    mh.PUBLIC_HOSTS_FILE.write_text(
        "# 개인 도메인\nMarina.Example.Dev.  preview=Marina-App.Example.Dev\nother.example.dev\n", encoding="utf-8")
    # ①
    assert mh.extra_public_hosts() == frozenset({"marina.example.dev", "other.example.dev"}), mh.extra_public_hosts()
    assert mh.preview_host_for("marina.example.dev") == "marina-app.example.dev"
    assert mh.preview_host_for("other.example.dev") == ""
    print("ok ① preview= 읽기")

    # ②
    class Fake:
        _route_label = staticmethod(mh.Handler._route_label)
        def __init__(self, host): self.headers = {"host": host}
        def _preview_routes(self, root, session=None): return {"web": "wt.proj.localhost:3902"}
    open_urls = lambda host: mh.Handler._service_open_urls(Fake(host), Path("/r/wt"), {})
    url = open_urls("marina.example.dev")["web"]
    assert url.startswith("/mobile/api/preview-go?"), url
    q = urllib.parse.parse_qs(url.split("?", 1)[1])
    assert q == {"root": ["/r/wt"], "label": ["wt.proj"]}, q
    assert open_urls("other.example.dev")["web"] == f"https://other.example.dev:{mh._PREVIEW_PUBLIC_PORT}/__room?label=wt.proj"
    assert open_urls("localhost:3900")["web"] == "http://wt.proj.localhost:3902/"
    print("ok ② openUrl 갈래")

# ③
t = mh.issue_preview_ticket(7, "wt.proj", now=1000.0)
assert mh.redeem_preview_ticket(t, "other", now=1001.0) == (False, None), "다른 방 입장권이 통했다"
t = mh.issue_preview_ticket(7, "wt.proj", now=1000.0)
assert mh.redeem_preview_ticket(t, "wt.proj", now=1001.0) == (True, 7)
assert mh.redeem_preview_ticket(t, "wt.proj", now=1002.0) == (False, None), "입장권을 두 번 썼다"
t = mh.issue_preview_ticket(7, "wt.proj", now=1000.0)
assert mh.redeem_preview_ticket(t, "wt.proj", now=1000.0 + mh._PREVIEW_TICKET_TTL_S + 1) == (False, None), "만료가 안 걸린다"
assert mh.redeem_preview_ticket("", "wt.proj") == (False, None)
print("ok ③ 입장권 1회용·만료·방 전용")

# ④
class Controller:
    class store:
        @staticmethod
        def create_session(uid): raise AssertionError("정식 로그인 세션을 만들었다 — 미리보기 전용 통행증이어야 한다")
    def _is_https(self, h): return True
class Req:
    def __init__(self, site="same-site"):
        self.sent, self.status, self.denied = [], None, None
        self.headers = {"sec-fetch-site": site} if site else {}
    def send_response(self, s): self.status = s
    def send_header(self, k, v): self.sent.append((k.lower(), v))
    def end_headers(self): pass
    def _deny(self, s, m): self.denied = s
def enter(site="same-site", label="wt.proj"):
    ticket = mh.issue_preview_ticket(7, label)
    req = Req(site)
    path = urllib.parse.urlparse("/__room?" + urllib.parse.urlencode({"label": label, "ticket": ticket}))
    mh.PreviewHandler._enter_with_ticket(req, path, Controller())
    return req, path
req, path = enter()
assert req.status == 302 and ("location", "/") in req.sent, req.sent
cookies = [v for k, v in req.sent if k == "set-cookie"]
통행 = [c for c in cookies if c.startswith(mh.PREVIEW_PASS_COOKIE + "=")]
assert 통행 and "HttpOnly" in 통행[0] and "Secure" in 통행[0], cookies
assert any(c.startswith("marina_preview=wt.proj") for c in cookies), cookies
token = 통행[0].split(";", 1)[0].split("=", 1)[1]
assert mh.preview_pass_ok(token, "wt.proj"), "통행증이 안 통한다"
assert not mh.preview_pass_ok(token, "other.proj"), "통행증이 다른 방에도 통한다"
again = Req()
mh.PreviewHandler._enter_with_ticket(again, path, Controller())
assert again.denied == 401 and again.status is None, "쓴 입장권으로 다시 들어왔다"
# 남의 사이트에서 건너온 입장권은 거절 — 자기 통행증을 남의 브라우저에 심는 길(로그인 CSRF).
bad, _ = enter(site="cross-site")
assert bad.denied == 403 and bad.status is None, "cross-site 입장권을 받았다"
old, _ = enter(site="")
assert old.status == 302, "Sec-Fetch-Site 가 없는 옛 브라우저를 막았다"
# 입장권 경로는 인증 검사보다 먼저, 로그에는 입장권이 안 남는다.
src = Path(mh.__file__).read_text(encoding="utf-8")
cls = src[src.index("class PreviewHandler"):]
assert cls.index("_enter_with_ticket(parsed") < cls.index("controller._principal(self) is None"), "입장권보다 로그인 검사가 먼저다"
import io, contextlib
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    mh.PreviewHandler.log_message(object(), '"%s" %s', "GET /__room?label=a&ticket=SECRET123 HTTP/1.1", "302")
assert "SECRET123" not in buf.getvalue() and "ticket=" in buf.getvalue(), buf.getvalue()
print("ok ④ 입장권 → 그 방 전용 통행증 · cross-site 거절 · 로그에 안 남음")
PY
echo "PASS test-preview-host-ticket"
