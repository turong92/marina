#!/usr/bin/env bash
# L2 Cloudflare — DNS CNAME 과 터널 ingress 를 marina 가 만든다. 가짜 API 로 돌린다
# (실제 Cloudflare 를 건드리지 않는다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import marina_live as L
import marina_live_cloudflare as CF

CREDS = {"token": "t0k", "zone": "ZONE1", "account": "ACC1", "tunnel": "TUN1"}

class Fake:
    """Cloudflare API 흉내 — 호출을 기록하고 저장된 응답을 돌려준다."""
    def __init__(self, records=None, ingress=None, fail=None):
        self.calls = []
        self.records = records if records is not None else []
        self.ingress = ingress
        self.fail = fail or {}
    def __call__(self, method, path, token, body=None):
        self.calls.append((method, path, body))
        assert token == "t0k", token
        key = f"{method} {path.split('?')[0]}"
        if key in self.fail:
            raise CF.CloudflareError(self.fail[key])
        if method == "GET" and "/dns_records" in path:
            return {"result": list(self.records)}
        if method == "POST" and "/dns_records" in path:
            rec = {"id": "NEW", **(body or {})}
            self.records.append(rec)
            return {"result": rec}
        if method == "PATCH" and "/dns_records/" in path:
            return {"result": {"id": path.rsplit("/", 1)[1], **(body or {})}}
        if method == "GET" and "/configurations" in path:
            return {"result": {"config": {"ingress": list(self.ingress)}} if self.ingress is not None else {}}
        if method == "PUT" and "/configurations" in path:
            self.ingress = (body or {}).get("config", {}).get("ingress")
            return {"result": {"config": body.get("config")}}
        raise AssertionError(f"예상 밖 호출: {method} {path}")

# 1) DNS 레코드가 없으면 만든다 — 터널 CNAME 이고 proxied 다(그래야 Cloudflare 를 통과한다)
f = Fake()
out = CF.ensure_dns(CREDS, "app.example.com", call=f)
assert out["action"] == "created", out
post = [c for c in f.calls if c[0] == "POST"][0]
assert post[2]["type"] == "CNAME", post
assert post[2]["name"] == "app.example.com", post
assert post[2]["content"] == "TUN1.cfargotunnel.com", post
assert post[2]["proxied"] is True, post

# 2) 이미 같은 값이면 아무것도 안 바꾼다 (멱등)
f = Fake(records=[{"id": "R1", "name": "app.example.com", "type": "CNAME",
                   "content": "TUN1.cfargotunnel.com", "proxied": True}])
out = CF.ensure_dns(CREDS, "app.example.com", call=f)
assert out["action"] == "unchanged", out
assert not [c for c in f.calls if c[0] in ("POST", "PATCH")], f.calls

# 3) 다른 곳을 가리키고 있으면 **고친다** — 중복 레코드를 만들지 않는다
f = Fake(records=[{"id": "R1", "name": "app.example.com", "type": "CNAME",
                   "content": "OLD.cfargotunnel.com", "proxied": True}])
out = CF.ensure_dns(CREDS, "app.example.com", call=f)
assert out["action"] == "updated", out
patch = [c for c in f.calls if c[0] == "PATCH"][0]
assert "/dns_records/R1" in patch[1], patch
assert not [c for c in f.calls if c[0] == "POST"], f.calls

# 4) CNAME 이 아닌 레코드(A 등)가 같은 이름에 있으면 **거부한다** — 남의 레코드를
#    말없이 CNAME 으로 바꾸면 그 호스트가 가리키던 것이 사라진다
f = Fake(records=[{"id": "R1", "name": "app.example.com", "type": "A",
                   "content": "1.2.3.4", "proxied": True}])
try:
    CF.ensure_dns(CREDS, "app.example.com", call=f)
    raise AssertionError("A 레코드인데 통과했다")
except L.LiveConfigError as e:
    assert "A" in str(e) and "app.example.com" in str(e), e

# 5) ingress 는 **기존 호스트명을 보존하며 합친다** — PUT 이 설정을 통째로 바꾸므로
#    읽지 않고 쓰면 다른 앱의 공개가 사라진다(홈서버 구현에서 같은 교훈)
f = Fake(ingress=[{"hostname": "other.example.com", "service": "http://other:8080"},
                  {"service": "http_status:404"}])
out = CF.ensure_ingress(CREDS, "app.example.com", "http://server:8080", call=f)
assert out["action"] == "updated", out
put = [c for c in f.calls if c[0] == "PUT"][0]
rules = put[2]["config"]["ingress"]
assert {"hostname": "other.example.com", "service": "http://other:8080"} in rules, rules
assert {"hostname": "app.example.com", "service": "http://server:8080"} in rules, rules
# catch-all 은 **마지막** 하나뿐이어야 한다 (앞에 있으면 뒤 규칙이 전부 죽는다)
assert rules[-1] == {"service": "http_status:404"}, rules
assert sum(1 for r in rules if "hostname" not in r) == 1, rules

# 6) 같은 호스트명이 이미 있으면 덮고 늘리지 않는다
f = Fake(ingress=[{"hostname": "app.example.com", "service": "http://old:1"},
                  {"service": "http_status:404"}])
CF.ensure_ingress(CREDS, "app.example.com", "http://server:8080", call=f)
rules = [c for c in f.calls if c[0] == "PUT"][0][2]["config"]["ingress"]
assert len([r for r in rules if r.get("hostname") == "app.example.com"]) == 1, rules
assert rules[0]["service"] == "http://server:8080", rules

# 7) 설정이 아예 없는 새 터널 — catch-all 을 포함해 처음부터 만든다
f = Fake(ingress=None)
CF.ensure_ingress(CREDS, "app.example.com", "http://server:8080", call=f)
rules = [c for c in f.calls if c[0] == "PUT"][0][2]["config"]["ingress"]
assert rules == [{"hostname": "app.example.com", "service": "http://server:8080"},
                 {"service": "http_status:404"}], rules

# 8) 현재 설정을 **읽지 못하면 쓰지 않는다** — 못 읽은 상태로 PUT 하면 다른 호스트명이
#    조용히 사라진다. 읽기 실패는 치명적으로 다룬다.
f = Fake(ingress=[{"service": "http_status:404"}],
         fail={"GET https://api.cloudflare.com/client/v4/accounts/ACC1/cfd_tunnel/TUN1/configurations": "500 boom"})
try:
    CF.ensure_ingress(CREDS, "app.example.com", "http://server:8080", call=f)
    raise AssertionError("읽기 실패인데 통과했다")
except L.LiveConfigError as e:
    assert "읽" in str(e), e
assert not [c for c in f.calls if c[0] == "PUT"], "읽기 실패 후에 썼다"

# 9) API 오류 메시지를 그대로 보여준다 — "실패했다" 만으로는 토큰 권한 문제를 못 찾는다
f = Fake(fail={"GET https://api.cloudflare.com/client/v4/zones/ZONE1/dns_records": "Invalid API token"})
try:
    CF.ensure_dns(CREDS, "app.example.com", call=f)
    raise AssertionError("API 오류인데 통과했다")
except L.LiveConfigError as e:
    assert "Invalid API token" in str(e), e

# 10) 토큰은 **URL·메시지에 안 들어간다**
for m, path, body in f.calls:
    assert "t0k" not in path, path
print("ok")
PY

echo "--- expose --cloudflare 가 실제로 DNS·ingress 를 만든다"
PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS" <<'PY'
import json, pathlib, stat, sys
sys.path.insert(0, sys.argv[1])
import marina_live as L
import marina_live_expose as X
import marina_live_cloudflare as CF

CREDS = {"token": "t0k", "zone": "ZONE1", "account": "ACC1", "tunnel": "TUN1"}
calls = []
def fake(method, path, token, body=None):
    calls.append((method, path, body))
    if method == "GET" and "/dns_records" in path:
        return {"result": []}
    if method == "GET" and "/configurations" in path:
        return {"result": {"config": {"ingress": [{"service": "http_status:404"}]}}}
    return {"result": {}}

res = X.expose_cloudflare("cfproj", "app.example.com", CREDS, "server", 8080, call=fake)
assert res["url"] == "https://app.example.com", res
assert res["dns"]["action"] == "created", res
assert res["ingress"]["hostname"] == "app.example.com", res
assert res["ingress"]["service"] == "http://server:8080", res   # 컨테이너 DNS
# 토큰은 0600 파일에만 — expose.json 과 overlay 에는 안 들어간다
sec = X.secrets_file("cfproj")
assert stat.S_IMODE(sec.stat().st_mode) == 0o600, oct(sec.stat().st_mode)
saved = json.loads(X.expose_file("cfproj").read_text())
assert "t0k" not in json.dumps(saved), saved
assert saved["cloudflare"]["service"] == "server", saved
# "ingress 를 손으로 설정해라" 는 안내가 더는 없다 — marina 가 만들었으니 거짓이 된다
assert not any("손으로" in w for w in res["warnings"]), res["warnings"]
assert any("502" in w for w in res["warnings"]), res["warnings"]   # 커넥터 기동 전 상태는 알린다
# PUT 이 실제로 갔다
assert [c for c in calls if c[0] == "PUT"], calls
print("ok")
PY

echo "--- 같은 터널을 두 프로젝트가 쓰면 거부한다"
PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import marina_live as L
import marina_live_expose as X

def fake(method, path, token, body=None):
    if method == "GET" and "/dns_records" in path:
        return {"result": []}
    if method == "GET" and "/configurations" in path:
        return {"result": {"config": {"ingress": [{"service": "http_status:404"}]}}}
    return {"result": {}}

A = {"token": "t0k", "zone": "ZONE1", "account": "ACC1", "tunnel": "SHARED"}
X.expose_cloudflare("projA", "a.example.com", A, "server", 8080, call=fake)

# 같은 터널을 다른 프로젝트가 쓰려 하면 거부한다. 허용하면 커넥터가 둘 생기고,
# Cloudflare 가 요청을 아무 커넥터로나 보내는데 서로 다른 compose 네트워크라
# 상대 서비스의 DNS 를 못 찾아 절반이 502 가 된다.
B = {"token": "t0k2", "zone": "ZONE2", "account": "ACC1", "tunnel": "SHARED"}
try:
    X.expose_cloudflare("projB", "b.example.com", B, "web", 3000, call=fake)
    raise AssertionError("같은 터널인데 통과했다")
except L.LiveConfigError as e:
    assert "SHARED" in str(e) and "projA" in str(e), e
    assert "터널" in str(e), e
# 거부했으면 **아무것도 안 만들었어야** 한다
assert not X.expose_file("projB").exists() or not (
    X.expose_config("projB").get("cloudflare")), X.expose_config("projB")
assert not X.secrets_file("projB").exists(), "거부했는데 비밀 파일을 썼다"

# 터널이 다르면 된다
C = {"token": "t0k3", "zone": "ZONE2", "account": "ACC1", "tunnel": "OTHER"}
res = X.expose_cloudflare("projB", "b.example.com", C, "web", 3000, call=fake)
assert res["url"] == "https://b.example.com", res

# 같은 프로젝트가 자기 터널을 다시 쓰는 건 된다 (도메인 변경 등)
res = X.expose_cloudflare("projA", "a2.example.com", A, "server", 8080, call=fake)
assert res["url"] == "https://a2.example.com", res
print("ok")
PY
echo "PASS test-live-cloudflare (터널 공유 거부 포함)"
