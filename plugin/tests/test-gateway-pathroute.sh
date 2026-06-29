#!/usr/bin/env bash
# 게이트웨이 path 라우팅(limit#1 해소) — 서비스가 routes(경로 prefix) 선언 시 대표 도메인이
# 그 경로를 해당 서비스로 보냄. fe 가 상대주소로 be 를 부를 때(브라우저) Host 로 워크트리 구분 + path 로 be 도달.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"

out=$(printf '%s' '[{"id":"alpha","projectId":"mdc","services":[
  {"service":"web","port":"3100","running":true,"routes":[]},
  {"service":"user-api","port":"3200","running":true,"routes":["/v1.0","/v2.0"]}
]}]' | python3 "$GW" gen --port 8088)

echo "$out" | grep -q "handle /v1.0/\* {" || { echo "FAIL: /v1.0 handle 없음"; echo "$out"; exit 1; }
echo "$out" | grep -q "handle /v2.0/\* {" || { echo "FAIL: /v2.0 handle 없음"; exit 1; }

# 대표 도메인 블록: handle 는 be(3200), catch-all 은 web(3100)
prim=$(echo "$out" | awk '/alpha.mdc.localhost:8088 \{/{f=1} f{print} f&&/^}/{exit}')
echo "$prim" | grep -A1 "handle /v1.0/\*" | grep -q "reverse_proxy 127.0.0.1:3200" || { echo "FAIL: /v1.0→be(3200) 아님"; echo "$prim"; exit 1; }
echo "$prim" | grep -qE "^    reverse_proxy 127.0.0.1:3100$" || { echo "FAIL: catch-all→web(3100) 아님"; echo "$prim"; exit 1; }
# be 자체 서브도메인도 유지(직접 접근)
echo "$out" | grep -q "alpha-user-api.mdc.localhost:8088 {" || { echo "FAIL: be 서브도메인 없음"; exit 1; }

# 회귀: routes 없으면 handle 0 (경로 가정 안 함, 범용)
out2=$(printf '%s' '[{"id":"beta","projectId":"mdc","services":[{"service":"web","port":"3300","running":true}]}]' | python3 "$GW" gen --port 8088)
echo "$out2" | grep -q "handle " && { echo "FAIL: routes 없는데 handle 생성"; exit 1; } || true

# be 미실행이면 handle 안 붙음(죽은 컨테이너로 라우팅 금지)
out3=$(printf '%s' '[{"id":"g","projectId":"mdc","services":[
  {"service":"web","port":"3400","running":true,"routes":[]},
  {"service":"user-api","port":"3500","running":false,"routes":["/v1.0"]}
]}]' | python3 "$GW" gen --port 8088)
echo "$out3" | grep -q "handle /v1.0" && { echo "FAIL: be 미실행인데 handle 붙음"; exit 1; } || true

echo "PASS test-gateway-pathroute"
