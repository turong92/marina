#!/usr/bin/env bash
# 게이트웨이 대표(primary) 명시 존중 — compose 의 x-marina.gateway.primary 로 대표 도메인 지정(web-name 자동 override).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"

# 대표(primary) 명시가 web-name 자동을 이긴다 — 스냅샷 primary:"be" → be 가 대표 도메인(<wt>.<proj>)
out=$(printf '%s' '[{"id":"alpha","projectId":"mdc","primary":"be","services":[
  {"service":"web","port":"3100","running":true,"routes":[]},
  {"service":"be","port":"3200","running":true,"routes":[]}
]}]' | python3 "$GW" gen --port 8088)
echo "$out" | grep -qE "http://alpha\.mdc\.localhost:8088 \{" || { echo "FAIL: 대표 도메인(alpha.mdc) 없음"; echo "$out"; exit 1; }
prim=$(echo "$out" | awk '/http:\/\/alpha.mdc.localhost:8088 \{/{f=1} f{print} f&&/^}/{exit}')
echo "$prim" | grep -qE "reverse_proxy 127.0.0.1:3200" || { echo "FAIL: primary=be 인데 대표가 be(3200) 아님"; echo "$prim"; exit 1; }
echo "$out" | grep -q "alpha-web.mdc.localhost:8088 {" || { echo "FAIL: web 은 서브도메인이어야(대표 아님)"; exit 1; }

# primary 없으면 web-name 자동(회귀)
out2=$(printf '%s' '[{"id":"beta","projectId":"mdc","services":[
  {"service":"web","port":"3300","running":true,"routes":[]},
  {"service":"be","port":"3400","running":true,"routes":[]}
]}]' | python3 "$GW" gen --port 8088)
p2=$(echo "$out2" | awk '/http:\/\/beta.mdc.localhost:8088 \{/{f=1} f{print} f&&/^}/{exit}')
echo "$p2" | grep -qE "reverse_proxy 127.0.0.1:3300" || { echo "FAIL: primary 자동이 web(3300) 아님"; echo "$p2"; exit 1; }

echo "PASS test-gateway-set"
