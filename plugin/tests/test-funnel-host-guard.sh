#!/usr/bin/env bash
# 펀넬(테일스케일)로 들어온 요청이 `/api/*` 에서 403 나면 **새 계정이 로그인 자체를 못 한다**
# — 형: "먼저 마리나 대시보드에서 로그인 하라는데;;" (실사용 2026-08-24, 멤버 daeun 첫 로그인).
#
# **왜.** /api/* 에는 DNS 리바인딩 가드가 있다(host_allowed). 펀넬 호스트는 예외로 통과시키는데,
# 그 예외가 "살아있는 tailscale 상태의 dnsName 과 문자열 대조"였다. 맥에서는 GUI 앱과 CLI 가
# 서로 다른 tailscaled 를 보는 일이 있어(실측: CLI 두 개 모두 BackendState=NeedsLogin, DNSName
# 빈 값인데 펀넬 접속은 멀쩡) 대조할 이름을 못 얻는다 → 예외가 통째로 죽고 403.
# 그러면 로그인 페이지가 /api/auth/status 를 못 읽어 "로컬 설정 필요"로 떨어진다.
#
# **고침.** 이름을 못 얻을 때는 **프록시 신호**로 판정한다: 요청이 로컬(펀넬은 같은 기계에서
# 프록시한다)이고 x-forwarded-proto=https 면 통과. 리바인딩 공격은 이 조합을 못 만든다 —
# 브라우저는 x-forwarded-proto 를 스스로 보내지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import marina_handler as mh


class 가짜:
    def __init__(self, host, proto="", client="127.0.0.1", dns=None):
        self.headers = {"host": host, "x-forwarded-proto": proto}
        self.client_address = (client, 12345)
        self._dns = dns

    def _remote_controller(self):
        상태 = {"dnsName": self._dns}
        return type("C", (), {"status": lambda _self: 상태})()

    _host_allowed = mh.Handler._host_allowed
    _public_hosts = mh.Handler._public_hosts
    _origin_allowed = mh.Handler._origin_allowed


# ① 로컬 이름은 그대로 통과.
assert 가짜("localhost:3900")._host_allowed() is True
assert 가짜("127.0.0.1:3900")._host_allowed() is True

# ② 펀넬: 이름을 알 때 — 그 이름만 통과.
assert 가짜("my-mac.tailnet.ts.net", "https", dns="my-mac.tailnet.ts.net")._host_allowed() is True
assert 가짜("evil.example.com", "https", dns="my-mac.tailnet.ts.net")._host_allowed() is False

# ③ 펀넬: **이름을 못 얻을 때**(맥 GUI/CLI 분리) — 프록시 신호로 통과시킨다.
#    이게 없으면 새 계정이 로그인 화면조차 못 넘는다.
assert 가짜("my-mac.tailnet.ts.net", "https", dns=None)._host_allowed() is True

# ④ 리바인딩은 여전히 막힌다 — 브라우저는 x-forwarded-proto 를 안 보낸다.
assert 가짜("evil.example.com", "", dns=None)._host_allowed() is False
assert 가짜("evil.example.com", "http", dns=None)._host_allowed() is False

# ⑤ 원격 클라이언트가 직접 때리는 것도 막힌다(펀넬은 같은 기계에서 프록시한다).
assert 가짜("my-mac.tailnet.ts.net", "https", client="203.0.113.9", dns=None)._host_allowed() is False
print("ok 펀넬 호스트 가드: 이름 없어도 프록시 신호로 통과 · 리바인딩·원격직결은 차단")

# ⑥ Cloudflare 터널 같은 다른 프록시 이름 — ~/.marina/public-hosts 에 적은 것만 더 통과한다(2026-09-28).
#    펀넬 이름과 **같이** 허용돼야 하고(둘 다 켜 둔 채 옮긴다), 적지 않은 이름은 여전히 막힌다.
import os, tempfile
from pathlib import Path
원래파일 = mh.PUBLIC_HOSTS_FILE
with tempfile.TemporaryDirectory() as d:
    mh.PUBLIC_HOSTS_FILE = Path(d) / "public-hosts"
    mh.PUBLIC_HOSTS_FILE.write_text("# 개인 도메인\nMarina.Example.Dev.\n\n", encoding="utf-8")
    터널 = "marina.example.dev"
    assert 가짜(터널, "https", dns="my-mac.tailnet.ts.net")._host_allowed() is True, "적어 둔 터널 이름이 막힌다"
    assert 가짜("my-mac.tailnet.ts.net", "https", dns="my-mac.tailnet.ts.net")._host_allowed() is True, "펀넬 이름이 같이 살아야 한다"
    assert 가짜("evil.example.dev", "https", dns="my-mac.tailnet.ts.net")._host_allowed() is False, "안 적은 이름이 통과했다"
    assert 가짜(터널, "", dns="my-mac.tailnet.ts.net")._host_allowed() is False, "프록시 신호 없이 통과했다"
    # POST 출처 — 같은 공개 이름끼리만(https, 기본 포트).
    요청 = 가짜(터널, "https", dns="my-mac.tailnet.ts.net"); 요청.headers["origin"] = "https://" + 터널
    assert 요청._origin_allowed() is True, "터널 주소에서 보낸 POST 가 막힌다"
    요청.headers["origin"] = "https://evil.example.com"
    assert 요청._origin_allowed() is False
mh.PUBLIC_HOSTS_FILE = 원래파일
print("ok 추가 공개 이름(public-hosts): 적은 것만 통과")
PY

echo "PASS test-funnel-host-guard"
