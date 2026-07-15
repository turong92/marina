#!/usr/bin/env bash
# 실측 e2e: 생성된 Caddyfile 을 진짜 caddy 로 띄워 도메인모드 be 서브도메인 CORS 검증
# (preflight 204·credentialed·헤더 echo + GET 시 be 의 ACAO 를 header_down 으로 replace). caddy 없으면 SKIP.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"
CADDY="$(command -v caddy 2>/dev/null || true)"
for c in "$HOME/.local/bin/caddy" /opt/homebrew/bin/caddy /usr/local/bin/caddy; do [ -z "$CADDY" ] && [ -x "$c" ] && CADDY="$c"; done
[ -n "$CADDY" ] || { echo "SKIP test-gateway-expose-cors-e2e (caddy 미설치)"; exit 0; }

TMP="$(mktemp -d)"
freeport() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
PG="$(freeport)"; ADMIN_PORT="$(freeport)"; PB="$(freeport)"
export MARINA_GATEWAY_ADMIN="127.0.0.1:$ADMIN_PORT"
cleanup(){ [ -n "${CADDY_PID:-}" ] && kill "$CADDY_PID" 2>/dev/null; [ -n "${BE_PID:-}" ] && kill "$BE_PID" 2>/dev/null
           pkill -f "$TMP/Caddyfile" 2>/dev/null; rm -rf "$TMP"; }   # 테스트 것만(유니크 tmp 경로) — 실 게이트웨이 불침해
trap cleanup EXIT

# 백엔드: Origin 헤더 보이면 403(Spring Security CORS 재현) — caddy 가 header_up -Origin 으로 벗겨야 200.
# Origin 없을 때만 200 + 자기 ACAO(bogus) → caddy 가 응답 ACAO 를 replace 하는지도 증명.
cat > "$TMP/be.py" <<PY
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _r(self):
        if self.headers.get("Origin"):                       # be(Spring)처럼 cross-origin 거부
            self.send_response(403); self.end_headers(); self.wfile.write(b"Invalid CORS request"); return
        self.send_response(200); self.send_header("Access-Control-Allow-Origin","http://evil.example")
        self.send_header("Content-Type","text/plain"); self.end_headers(); self.wfile.write(b"be-ok")
    def do_GET(self): self._r()
    def do_OPTIONS(self): self._r()
    def log_message(self,*a): pass
HTTPServer(("127.0.0.1",$PB),H).serve_forever()
PY
python3 "$TMP/be.py" & BE_PID=$!; sleep 1

printf '%s' "[{\"id\":\"alpha\",\"projectId\":\"mdc\",\"services\":[
  {\"service\":\"web\",\"port\":\"3999\",\"running\":true},
  {\"service\":\"user-api\",\"port\":\"$PB\",\"running\":true,\"cors\":true}]}]" \
  | python3 "$GW" gen --port "$PG" > "$TMP/Caddyfile"

"$CADDY" run --config "$TMP/Caddyfile" --adapter caddyfile >"$TMP/caddy.log" 2>&1 & CADDY_PID=$!
up=""; for i in $(seq 1 25); do curl -s -o /dev/null "http://$MARINA_GATEWAY_ADMIN/config/" && { up=1; break; }; sleep 0.3; done
[ -n "$up" ] || { echo "FAIL: caddy 안 뜸"; cat "$TMP/caddy.log"; exit 1; }

BE_HOST="alpha-user-api.mdc.localhost"; FE_ORIGIN="http://alpha.mdc.localhost:$PG"

pf=$(curl -s -i --resolve "$BE_HOST:$PG:127.0.0.1" -X OPTIONS -H "Origin: $FE_ORIGIN" \
  -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers: authorization,content-type" \
  "http://$BE_HOST:$PG/v1.0/x")
echo "$pf" | grep -qiE "HTTP/1.1 204" || { echo "FAIL: preflight 204"; echo "$pf"; exit 1; }
echo "$pf" | grep -qi "access-control-allow-origin: $FE_ORIGIN" || { echo "FAIL: preflight ACAO"; exit 1; }
echo "$pf" | grep -qi "access-control-allow-credentials: true" || { echo "FAIL: credentials"; exit 1; }
echo "$pf" | grep -qi "access-control-allow-headers: authorization,content-type" || { echo "FAIL: 헤더 echo"; exit 1; }

gt=$(curl -s -i --resolve "$BE_HOST:$PG:127.0.0.1" -H "Origin: $FE_ORIGIN" "http://$BE_HOST:$PG/v1.0/x")
echo "$gt" | grep -qi "access-control-allow-origin: $FE_ORIGIN" || { echo "FAIL: GET ACAO replace 안 됨"; echo "$gt"; exit 1; }
echo "$gt" | grep -qi "access-control-allow-origin: http://evil.example" && { echo "FAIL: be 의 evil ACAO 누출"; exit 1; }
echo "$gt" | grep -q "be-ok" || { echo "FAIL: be 미도달"; exit 1; }

echo "PASS test-gateway-expose-cors-e2e"
