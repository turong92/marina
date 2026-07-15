#!/usr/bin/env bash
# 실 caddy E2E(비권한 포트): 스냅샷→Caddyfile→caddy reload→Host 헤더 라우팅 + 동적(add/remove/restart/port-change).
# caddy 없으면 SKIP. mock 백엔드=python http.server.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"
command -v caddy >/dev/null 2>&1 || { echo "SKIP test-gateway-e2e (caddy 미설치)"; exit 0; }

TMP="$(mktemp -d)"; CFG="$TMP/Caddyfile"
freeport() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
GP="$(freeport)"; P1="$(freeport)"; P2="$(freeport)"; ADMIN_PORT="$(freeport)"
export MARINA_GATEWAY_ADMIN="127.0.0.1:$ADMIN_PORT"
mkdir -p "$TMP/a" "$TMP/b"; echo "AAA" > "$TMP/a/index.html"; echo "BBB" > "$TMP/b/index.html"
( cd "$TMP/a" && python3 -m http.server "$P1" >/dev/null 2>&1 & echo $! > "$TMP/a.pid" )
( cd "$TMP/b" && python3 -m http.server "$P2" >/dev/null 2>&1 & echo $! > "$TMP/b.pid" )
CADDY_PID=""
cleanup(){ [ -n "$CADDY_PID" ] && kill "$CADDY_PID" 2>/dev/null || true; kill "$(cat "$TMP/a.pid" 2>/dev/null)" "$(cat "$TMP/b.pid" 2>/dev/null)" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

gen() { python3 "$GW" gen --port "$GP" > "$CFG"; }   # stdin=snapshot
snap_both(){ printf '[{"id":"main","projectId":"shop","services":[{"service":"web","port":"%s","running":true}]},{"id":"feat","projectId":"shop","services":[{"service":"web","port":"%s","running":true}]}]' "$P1" "$2"; }
snap_a(){ printf '[{"id":"main","projectId":"shop","services":[{"service":"web","port":"%s","running":true}]}]' "$P1"; }

snap_both x "$P2" | gen
caddy run --config "$CFG" --adapter caddyfile >"$TMP/caddy.log" 2>&1 & CADDY_PID=$!

# 정적: Host 로 라우팅
a=""
for _ in $(seq 1 30); do
  a="$(curl -s -H 'Host: main.shop.localhost' "localhost:$GP/" 2>/dev/null || true)"
  echo "$a" | grep -q AAA && break
  sleep 0.3
done
echo "$a" | grep -q AAA || { echo "FAIL: main→A: [$a]"; cat "$TMP/caddy.log"; exit 1; }
b="$(curl -s -H 'Host: feat.shop.localhost' "localhost:$GP/")"; echo "$b" | grep -q BBB || { echo "FAIL: feat→B: [$b]"; exit 1; }

# 동적 remove: B 빼고 reload → feat 라우트 제거(이제 B 로 안 감 = BBB 없음; caddy 는 미매칭 Host 에 빈 200)
snap_a | gen; caddy reload --config "$CFG" --adapter caddyfile --address "$MARINA_GATEWAY_ADMIN" >/dev/null 2>&1; sleep 0.5
fbody="$(curl -s -H 'Host: feat.shop.localhost' "localhost:$GP/")"
echo "$fbody" | grep -q BBB && { echo "FAIL: remove 후에도 feat→B(BBB) 도달: [$fbody]"; exit 1; } || true
curl -s -H 'Host: main.shop.localhost' "localhost:$GP/" | grep -q AAA || { echo "FAIL: remove 후 main 깨짐"; exit 1; }

# 동적 add 복귀 + restart/port-change: B 를 새 포트로
kill "$(cat "$TMP/b.pid")" 2>/dev/null || true
P3="$(freeport)"
( cd "$TMP/b" && python3 -m http.server "$P3" >/dev/null 2>&1 & echo $! > "$TMP/b.pid" )
snap_both x "$P3" | gen
caddy reload --config "$CFG" --adapter caddyfile --address "$MARINA_GATEWAY_ADMIN" >/dev/null 2>&1; sleep 0.5
b2="$(curl -s -H 'Host: feat.shop.localhost' "localhost:$GP/")"; echo "$b2" | grep -q BBB || { echo "FAIL: restart/port-change 후 feat 새 포트 재지정 안 됨: [$b2]"; exit 1; }

echo "PASS test-gateway-e2e (정적 라우팅 + 동적 add/remove/port-change)"
