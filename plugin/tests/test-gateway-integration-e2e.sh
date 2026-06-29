#!/usr/bin/env bash
# 실 통합 E2E: compose 서비스 up → marina 데몬(게이트웨이 ON)이 라이브 스냅샷→caddy reload →
# 호스트에서 <wt>.<proj>.localhost 로 그 서비스 도달. 동적: 서비스 stop → 폴링이 라우트 제거.
# docker·caddy 둘 다 있어야. 없으면 SKIP.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"; GWC="$HERE/../scripts/marina-gateway-control.sh"; CTRL="$HERE/../scripts/marina-control.py"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-gateway-integration-e2e (docker 미가용)"; exit 0; }
command -v caddy >/dev/null 2>&1 || { echo "SKIP test-gateway-integration-e2e (caddy 미설치)"; exit 0; }

TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/proj-$$"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"
GP=8896; CPORT=3959; DPID=""
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" "$@"); }
cleanup() {
  [ -n "$DPID" ] && kill "$DPID" 2>/dev/null || true
  MARINA_HOME="$MARINA_HOME" MARINA_GATEWAY_PORT="$GP" bash "$GWC" stop >/dev/null 2>&1 || true
  mrun stop --all >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$P/docker-compose.yml" <<'YML'
services:
  web:
    image: hashicorp/http-echo
    command: ["-text=GWHIT","-listen=:5678"]
    ports: ["5678:5678"]
YML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
mrun start --all >/dev/null 2>&1 || { echo "FAIL: marina start"; mrun start --all 2>&1 | tail; exit 1; }

# caddy 기동(테스트 포트) + 게이트웨이 ON 데몬(같은 MARINA_HOME) — 데몬 refresh 가 caddy 를 채움
MARINA_HOME="$MARINA_HOME" MARINA_GATEWAY_PORT="$GP" bash "$GWC" start >/dev/null
for _ in $(seq 1 20); do curl -s -o /dev/null localhost:2021/config/ && break; sleep 0.3; done
MARINA_HOME="$MARINA_HOME" MARINA_CONTROL_HOST=127.0.0.1 MARINA_CONTROL_PORT=$CPORT MARINA_GATEWAY=1 MARINA_GATEWAY_PORT=$GP MARINA_GATEWAY_POLL=2 python3 "$CTRL" >"$TMP/daemon.log" 2>&1 &
DPID=$!

# 데몬 폴링이 라우트 채울 때까지 — /api/gateway-status 의 routes 에서 도메인 추출
DOMAIN=""
for _ in $(seq 1 30); do
  routes="$(curl -s "http://127.0.0.1:$CPORT/api/gateway-status" 2>/dev/null || true)"
  DOMAIN="$(printf '%s' "$routes" | grep -oE 'http://[a-z0-9.-]+\.localhost:'"$GP" | head -1 | sed -E 's#http://(.*):'"$GP"'#\1#' || true)"
  [ -n "$DOMAIN" ] && break; sleep 1
done
[ -n "$DOMAIN" ] || { echo "FAIL: 게이트웨이 라우트 생성 안 됨"; curl -s "http://127.0.0.1:$CPORT/api/gateway-status"; echo; cat "$TMP/daemon.log" | tail; exit 1; }
echo "도메인: $DOMAIN"

# 정적: 호스트 브라우저(curl) → 도메인 → 서비스
hit=false
for _ in $(seq 1 20); do
  body="$(curl -s -H "Host: $DOMAIN" "localhost:$GP/" 2>&1 || true)"
  case "$body" in *GWHIT*) hit=true; break;; esac; sleep 1
done
$hit || { echo "FAIL: $DOMAIN → 서비스 도달 안 됨: [${body:-}]"; cat "$TMP/daemon.log" | tail; exit 1; }

# 동적 remove: 서비스 stop → 데몬 폴링(2s)이 라우트 제거 → 도메인이 서비스로 안 감
mrun stop --all >/dev/null 2>&1 || true
gone=false
for _ in $(seq 1 15); do
  b2="$(curl -s -H "Host: $DOMAIN" "localhost:$GP/" 2>&1 || true)"
  case "$b2" in *GWHIT*) ;; *) gone=true; break;; esac; sleep 1
done
$gone || { echo "FAIL: stop 후에도 $DOMAIN → GWHIT (폴링 동적반영 안 됨)"; exit 1; }

echo "PASS test-gateway-integration-e2e (도메인→서비스 GWHIT + stop 후 동적 제거)"
