#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import urllib.parse

import marina_handler as mh
import marina_mobile as mm

H = mh.Handler


class FakeHandler:
    """Handler 의 메서드만 빌려 쓰는 최소 스텁 — 소켓 없이 술어만 검증한다.
    is_loopback_client 는 client_address[0] 을, mobile_request_ok/_origin_allowed 는 headers 만 읽는다."""

    def __init__(self, loopback=True, token="", origin=None):
        self.headers = {}
        if token:
            self.headers["x-marina-mobile-token"] = token
        if origin is not None:
            self.headers["origin"] = origin
        self.client_address = ("127.0.0.1" if loopback else "10.0.0.5", 1234)

    _agent_api_ok = H._agent_api_ok
    _agent_api_alias = H._agent_api_alias
    _AGENT_API_ALIAS = H._AGENT_API_ALIAS
    _origin_allowed = H._origin_allowed


def parse(path):
    return urllib.parse.urlparse(path)


# 1) 경로 별칭 — /api/agent/<op> 가 /mobile/api/<op> 로 정규화되고 웹 플래그가 선다
h = FakeHandler()
p = h._agent_api_alias(parse("/api/agent/send?root=/x"))
assert p.path == "/mobile/api/send", p.path
assert p.query == "root=/x", p.query
assert h._agent_api_web is True

# 별칭은 중첩 경로도 그대로 옮긴다 (로그 라우트가 /logs/chunk 처럼 슬래시를 포함한다)
h_nested = FakeHandler()
p_nested = h_nested._agent_api_alias(parse("/api/agent/logs/chunk?root=/x"))
assert p_nested.path == "/mobile/api/logs/chunk", p_nested.path

# 2) 별칭이 아닌 경로는 건드리지 않고 웹 플래그도 안 선다
h2 = FakeHandler()
p2 = h2._agent_api_alias(parse("/mobile/api/send"))
assert p2.path == "/mobile/api/send"
assert getattr(h2, "_agent_api_web", False) is False

h2b = FakeHandler()
p2b = h2b._agent_api_alias(parse("/api/worktrees"))
assert p2b.path == "/api/worktrees"
assert getattr(h2b, "_agent_api_web", False) is False

# 3) 웹 경로 + 루프백 + auth 꺼짐(principal None) → 통과 (모바일 토큰 불필요)
h3 = FakeHandler(loopback=True)
h3._agent_api_alias(parse("/api/agent/send"))
assert h3._agent_api_ok(parse("/mobile/api/send"), None) is True

# 4) 웹 경로 + 비루프백 + principal 없음 → 거부
h4 = FakeHandler(loopback=False)
h4._agent_api_alias(parse("/api/agent/send"))
assert h4._agent_api_ok(parse("/mobile/api/send"), None) is False

# 5) 모바일 경로 — 토큰 없으면 거부, 올바른 토큰이면 통과
token = mm.ensure_mobile_token()
h5 = FakeHandler(loopback=False)
assert h5._agent_api_ok(parse("/mobile/api/send"), None) is False
h6 = FakeHandler(loopback=False, token=token)
assert h6._agent_api_ok(parse("/mobile/api/send"), None) is True
h6b = FakeHandler(loopback=False, token="wrong-token")
assert h6b._agent_api_ok(parse("/mobile/api/send"), None) is False

# 6) principal 이 있으면 경로·루프백과 무관하게 통과
h7 = FakeHandler(loopback=False)
assert h7._agent_api_ok(parse("/mobile/api/send"), object()) is True

# 6b) **CSRF** — 이 라우트들은 아래쪽 공통 origin 검사에 닿기 전에 반환하고, auth 가 꺼져 있으면
#     authorize() 도 CSRF 를 안 본다. 그래서 웹 경로는 Origin 을 스스로 봐야 한다. 안 그러면 임의
#     웹페이지가 text/plain 로 POST 해(프리플라이트 없이) cli-update·send·launch 를 실행시킨다.
h_evil = FakeHandler(loopback=True, origin="http://evil.example")
h_evil._agent_api_alias(parse("/api/agent/cli-update"))
assert h_evil._agent_api_ok(parse("/mobile/api/cli-update"), None) is False, \
    "교차 출처 POST 가 통과한다 — CSRF 구멍"

# 대시보드 자신의 오리진은 통과해야 한다(안 그러면 UI 가 통째로 죽는다)
h_self = FakeHandler(loopback=True, origin=f"http://localhost:{mh.PORT}")
h_self._agent_api_alias(parse("/api/agent/send"))
assert h_self._agent_api_ok(parse("/mobile/api/send"), None) is True

# Origin 없음(curl·같은 출처 GET)은 통과 — 기존 계약 유지
h_curl = FakeHandler(loopback=True)
h_curl._agent_api_alias(parse("/api/agent/send"))
assert h_curl._agent_api_ok(parse("/mobile/api/send"), None) is True

# 7) 옛 모바일 인증 검사가 라우트에 남아 있지 않다 — 전부 술어로 교체됐는지
src = open(mh.__file__, encoding="utf-8").read()
assert "principal is None and not mobile_request_ok" not in src, \
    "모바일 라우트에 옛 인증 검사가 남아 있다 — _agent_api_ok 로 교체해야 한다"

# 8) 별칭은 host_guarded 검사 '다음'에 적용돼야 한다 — 먼저 적용하면 /api/agent/* 가 호스트 가드를
#    우회한다. do_GET/do_POST 에서 두 줄의 순서를 확인한다.
for fn in ("def do_GET", "def do_POST"):
    start = src.index(fn)
    block = src[start:start + 1800]
    guard = block.index("forbidden host")
    alias = block.index("_agent_api_alias(parsed)")
    assert guard < alias, f"{fn}: 별칭이 host_guarded 검사보다 먼저 적용된다"

print("ok")
PY
