#!/usr/bin/env bash
# L2 공개 노출 — Funnel 포트 배정·경로 경고·Cloudflare 자격증명 완전성·멱등 해제.
# 가짜 tailscale 로 돌려 실제 tailnet 을 건드리지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS" <<'PY'
import json, os, pathlib, stat, sys, textwrap
sys.path.insert(0, sys.argv[1])
import marina_live as L
import marina_live_expose as X
from marina_remote import RemoteController, RemoteControlError

HOME = pathlib.Path(os.environ["MARINA_HOME"])

# ── 순수 판정 ────────────────────────────────────────────────────────────────
# 1) Funnel 은 443 을 쓰지 않는다. AllowFunnel 이 경로가 아니라 host:port 단위라,
#    443 의 /app 을 공개하면 같은 443 의 "/" 에 있는 대시보드까지 공개된다.
assert 443 not in X.FUNNEL_PORTS, X.FUNNEL_PORTS
assert X.FUNNEL_PORTS == (8443, 10000), X.FUNNEL_PORTS

# 2) 쓸 수 있는 포트가 2개뿐이라는 한도를 숨기지 않는다 — 세 번째는 거부하고 대안을 말한다
assert X.pick_funnel_port([]) == 8443
assert X.pick_funnel_port([8443]) == 10000
try:
    X.pick_funnel_port([8443, 10000])
    raise AssertionError("세 번째인데 통과했다")
except L.LiveConfigError as e:
    assert "Cloudflare" in str(e), e
    assert "8443" in str(e) and "10000" in str(e), e

# 3) 경로 기본값은 /<프로젝트>, 경로 공개가 앱을 깨뜨릴 수 있다는 경고가 반드시 있다
assert X.funnel_path("ovation") == "/ovation"
assert X.funnel_path("ovation", "/x/") == "/x"
assert "절대경로" in X.PATH_WARNING and "쿠키" in X.PATH_WARNING, X.PATH_WARNING

# 4) Cloudflare 자격증명은 **넷 다** 필요하고, 하나라도 비면 아무것도 만들기 전에 거부한다
assert X.CLOUDFLARE_REQUIRED == ("token", "zone", "account", "tunnel"), X.CLOUDFLARE_REQUIRED
for missing in X.CLOUDFLARE_REQUIRED:
    creds = {k: "v" for k in X.CLOUDFLARE_REQUIRED if k != missing}
    try:
        X.validate_cloudflare(creds)
        raise AssertionError(f"{missing} 가 없는데 통과했다")
    except L.LiveConfigError as e:
        assert missing in str(e), e
X.validate_cloudflare({k: "v" for k in X.CLOUDFLARE_REQUIRED})

# 5) cloudflared 는 live overlay 에만 들어간다 — 터널 하나에 커넥터가 여럿이면 Cloudflare 가
#    공개 요청을 무작위 커넥터로 보낸다(홈서버 구현에서 실측).
ov = "\n".join(X.cloudflared_service_lines("ovation", "app.example.com", "server", 8080))
assert "cloudflared" in ov, ov
assert "secrets.env" in ov, "비밀 파일을 참조하지 않는다"
# 토큰 **값**은 생성 파일에 안 들어간다 — overlay 는 평문으로 ~/.marina 에 남는다
assert "TUNNEL_TOKEN=" not in ov, ov
assert str(L.LIVE_LABEL) in ov, ov          # GC 면제 라벨이 cloudflared 에도 붙는다
# 백엔드는 **컨테이너 DNS** 다. 127.0.0.1 은 cloudflared 컨테이너 자신이라 아무것도 없다.
assert "http://server:8080" in ov, ov
assert "127.0.0.1" not in ov, ov
assert X.cloudflared_service_lines("ovation", "", "", 0) == [], "도메인 없으면 아무것도 넣지 않는다"

# 6) 비밀은 0600 파일에 쓴다 (백업 목록에 들어가야 한다 — L3)
p = X.write_secrets("ovation", {"TUNNEL_TOKEN": "t0ken"})
assert p == L.live_root("ovation") / "secrets.env", p
assert stat.S_IMODE(p.stat().st_mode) == 0o600, oct(p.stat().st_mode)
assert "t0ken" in p.read_text()

# ── 컨트롤러 경유 ────────────────────────────────────────────────────────────
# 7) Tailscale 이 없으면 거부하고 이유를 말한다 — 조용히 빈 상태를 보여주지 않는다
missing = RemoteController(marina_home=HOME, tailscale_bin=str(HOME / "nope-tailscale"))
try:
    X.expose_funnel("ovation", 8080, controller=missing)
    raise AssertionError("tailscale 없는데 통과했다")
except (L.LiveConfigError, RemoteControlError) as e:
    assert "Tailscale" in str(e) or "tailscale" in str(e), e

st = X.expose_status("ovation", controller=missing)
assert st["installed"] is False, st
assert st["reason"], "거부 이유가 없다"
print("ok")
PY

echo "--- cloudflared 를 넣은 overlay 가 compose 검증을 통과한다"
# 이걸 단정하지 않아서 'cloudflared 가 networks: 밑으로 들어가 live up 이 아예 안 되는' 버그를
# 리뷰까지 못 잡았다. 생성 함수를 단독으로만 보면 머지 결과가 안 보인다.
TMPC="$MARINA_HOME/mergecheck"; mkdir -p "$TMPC"
cat > "$TMPC/base.yml" <<'Y'
services:
  server:
    image: alpine:3.20
    command: ["sleep","60"]
    ports: ["127.0.0.1:38498:8080"]
Y
PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS" "$TMPC" <<'PY'
import importlib.util, json, pathlib, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("mc", sys.argv[1] + "/marina-compose.py")
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
import marina_live as L, marina_live_expose as X
tmp = pathlib.Path(sys.argv[2])
X.save_expose_config("mergeproj", {"cloudflare": {"domain": "app.example.com",
                                                  "service": "server", "containerPort": 8080}})
X.write_secrets("mergeproj", {"TUNNEL_TOKEN": "fake"})
# 비밀 파일이 없으면 compose 는 'env file ... not found' 로 깨진다 — marina 가 먼저,
# 알아들을 수 있는 말로 거부해야 한다(백업에서 secrets.env 가 빠진 복원 경로다)
assert X.missing_cloudflare_secrets("mergeproj") == []
X.secrets_file("mergeproj").unlink()
assert X.missing_cloudflare_secrets("mergeproj"), "비밀 파일 부재를 못 잡는다"
X.write_secrets("mergeproj", {"TUNNEL_TOKEN": "fake"})
cfg = mc.load_compose_file(str(tmp / "base.yml"))
ov = mc.build_overlay(cfg, live=True,
                      extra_labels={L.LIVE_LABEL: "1", L.PROJECT_LABEL: "mergeproj"},
                      extra_services=X.cloudflared_service_lines(
                          "mergeproj", "app.example.com", "server", 8080))
(tmp / "ov.yml").write_text(ov)
PY
out="$(docker compose -f "$TMPC/base.yml" -f "$TMPC/ov.yml" -p livemergecheck config 2>&1)" || {
  echo "FAIL: cloudflared 를 넣은 overlay 가 compose 검증을 통과하지 못한다:"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -q 'cloudflared' || { echo "FAIL: cloudflared 서비스가 없다"; exit 1; }
printf '%s' "$out" | python3 -c "
import sys
t = sys.stdin.read()
i = t.index('cloudflared:')
assert 'image: cloudflare/cloudflared' in t[i:i+400], t[i:i+400]
print('ok')
" || { echo "FAIL: cloudflared 가 서비스로 안 들어갔다"; exit 1; }

echo "--- 가짜 tailscale 로 funnel 왕복"
FAKE="$MARINA_HOME/fake"
mkdir -p "$FAKE"
cat > "$FAKE/tailscale" <<'PYS'
#!/usr/bin/env python3
"""live 라우트만 다루는 가짜 tailscale — serve/funnel 설정을 파일로 흉내낸다."""
import json, sys
from pathlib import Path
root = Path(__file__).parent
cfg_path = root / "config.json"
cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {"Web": {}, "AllowFunnel": {}}
args = sys.argv[1:]
HOST = "fake.tailnet.ts.net"
if args == ["version", "--json"]:
    print(json.dumps({"long": "1.96.0"}))
elif args == ["status", "--json"]:
    print(json.dumps({"BackendState": "Running", "Self": {"DNSName": HOST + ".", "Online": True},
                      "CertDomains": [HOST], "MagicDNSSuffix": "tailnet.ts.net",
                      "TailscaleIPs": ["100.1.2.3"]}))
elif args[:2] == ["serve", "status"]:
    print(json.dumps({k: v for k, v in cfg.items() if k != "funnel"} if cfg.get("Web") else {}))
elif args[:2] == ["funnel", "status"]:
    print(json.dumps(cfg if cfg.get("Web") else {}))
elif args and args[0] in ("serve", "funnel"):
    rest = args[1:]
    if "--bg" in rest:
        rest.remove("--bg")
    port = next((a.split("=", 1)[1] for a in rest if a.startswith("--https=")), "443")
    path = next((a.split("=", 1)[1] for a in rest if a.startswith("--set-path=")), "/")
    tail = [a for a in rest if not a.startswith("--")]
    authority = f"{HOST}:{port}"
    web = cfg.setdefault("Web", {})
    if tail and tail[-1] == "off":
        handlers = (web.get(authority) or {}).get("Handlers") or {}
        handlers.pop(path, None)
        if handlers:
            web[authority] = {"Handlers": handlers}
        else:
            web.pop(authority, None)
            cfg.setdefault("AllowFunnel", {}).pop(authority, None)
    else:
        backend = tail[-1]
        web.setdefault(authority, {}).setdefault("Handlers", {})[path] = {"Proxy": backend}
        if args[0] == "funnel":
            cfg.setdefault("AllowFunnel", {})[authority] = True
    cfg_path.write_text(json.dumps(cfg))
else:
    print("unexpected: " + json.dumps(args), file=sys.stderr); raise SystemExit(99)
PYS
chmod +x "$FAKE/tailscale"

PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS" "$FAKE/tailscale" <<'PY'
import json, os, pathlib, sys
sys.path.insert(0, sys.argv[1])
import marina_live as L
import marina_live_expose as X
from marina_remote import RemoteController

HOME = pathlib.Path(os.environ["MARINA_HOME"])
ctl = RemoteController(marina_home=HOME, tailscale_bin=sys.argv[2])

# 1) funnel 공개 — 8443 을 받고, 경고를 반드시 낸다
res = X.expose_funnel("ovation", 8080, controller=ctl)
assert res["httpsPort"] == 8443, res
assert res["path"] == "/ovation", res
assert res["url"] == "https://fake.tailnet.ts.net:8443/ovation", res
assert X.PATH_WARNING in res["warnings"], res

# 2) status 가 공개 상태를 읽는다 (RemoteController 의 route 목록에서)
st = X.expose_status("ovation", controller=ctl)
assert st["mode"] == "funnel", st
assert st["url"] == "https://fake.tailnet.ts.net:8443/ovation", st

# 3) 대시보드 원격 접근(443)이 **멀쩡하다** — live 라우트가 소유 판정을 깨지 않는다
status = ctl.status(refresh=True)
assert status["conflict"] is False, status
assert status["ownMode"] == "off", status      # marina 자신의 리스너는 아직 없다
assert status["liveRoutes"], status

# 4) 같은 경로를 두 번 공개하면 거부한다
try:
    X.expose_funnel("ovation", 8080, controller=ctl)
    raise AssertionError("같은 경로인데 통과했다")
except L.LiveConfigError as e:
    assert "이미" in str(e), e

# 5) 두 번째 앱은 10000 을 받는다
res2 = X.expose_funnel("second", 9090, controller=ctl)
assert res2["httpsPort"] == 10000, res2

# 6) 세 번째는 거부하고 Cloudflare 를 안내한다
try:
    X.expose_funnel("third", 7070, controller=ctl)
    raise AssertionError("세 번째인데 통과했다")
except L.LiveConfigError as e:
    assert "Cloudflare" in str(e), e

# 7) unexpose 는 멱등 — 두 번 호출해도 성공한다
X.unexpose("ovation", controller=ctl)
assert X.expose_status("ovation", controller=ctl)["mode"] == "off"
X.unexpose("ovation", controller=ctl)
# 해제 후에도 다른 앱의 공개는 남는다
assert X.expose_status("second", controller=ctl)["mode"] == "funnel"
# 해제가 포트를 돌려준다 — 다시 공개할 수 있다
res3 = X.expose_funnel("ovation", 8080, controller=ctl)
assert res3["httpsPort"] == 8443, res3

# 8) 대시보드가 원격을 켜도 live 라우트가 살아 있다 (443 과 8443 은 다른 authority)
ctl.activate("serve", 3900)
after = ctl.status(refresh=True)
assert after["ownMode"] == "serve", after
assert after["conflict"] is False, after
assert any(int(r["httpsPort"]) == 8443 for r in after["routes"]), after
# 그리고 대시보드가 원격을 꺼도 live 는 남는다
ctl.off()
end = ctl.status(refresh=True)
assert end["ownMode"] == "off", end
assert any(int(r["httpsPort"]) == 8443 for r in end["routes"]), end
assert end["conflict"] is False, end
print("ok")
PY

echo "--- 게이트웨이 등록 (live.<프로젝트>.localhost)"
PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS" <<'PY'
import importlib.util, sys
sys.path.insert(0, sys.argv[1])
import marina_live as L

spec = importlib.util.spec_from_file_location("gw", sys.argv[1] + "/marina-gateway.py")
gw = importlib.util.module_from_spec(spec); spec.loader.exec_module(gw)

# 1) 실행 중 live 컨테이너의 호스트 포트를 읽는다 (docker ps 주입)
class FakePs:
    def __init__(self, text): self.text = text
    def __call__(self, argv, **kw):
        class R:
            returncode = 0
            stdout = self.text
            stderr = ""
        return R()

ports = L.live_service_ports("ovation", run=FakePs(
    "server\t0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp\n"
    "web\t127.0.0.1:3000->80/tcp\n"
    "worker\t\n"))
assert ports == {"server": 8080, "web": 3000}, ports

# 2) 게이트웨이 스냅샷 항목 — 워크트리 id 자리에 'live' 가 들어간다
entry = L.live_gateway_entry("ovation", ports, primary="web")
assert entry["id"] == "live" and entry["projectId"] == "ovation", entry
assert entry["primary"] == "web", entry
assert all(s["running"] for s in entry["services"]), entry

# 3) Caddyfile 에 live.ovation.localhost 가 생긴다 (대표 서비스), 나머지는 live-<svc>
cfg = gw.build_caddyfile([entry], port=3902)
assert "http://live.ovation.localhost:3902 {" in cfg, cfg
assert "http://live-server.ovation.localhost:3902 {" in cfg, cfg
assert "reverse_proxy 127.0.0.1:3000" in cfg and "reverse_proxy 127.0.0.1:8080" in cfg, cfg

# 4) 공개와 무관하다 — unexpose 후에도 게이트웨이 블록은 그대로다
assert L.live_gateway_entry("ovation", ports, primary="web") == entry
print("ok")
PY
echo "PASS test-live-expose (게이트웨이 포함)"
