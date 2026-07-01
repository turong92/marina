#!/usr/bin/env bash
# expose 도메인 모드: cors:true be 서브도메인에 CORS(replace+preflight+credentialed+헤더 echo) 생성.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"

out=$(printf '%s' '[{"id":"alpha","projectId":"mdc","services":[
  {"service":"web","port":"3100","running":true},
  {"service":"user-api","port":"3200","running":true,"cors":true}
]}]' | python3 "$GW" gen --port 8088)

# be 서브도메인 블록 추출
be=$(echo "$out" | awk '/alpha-user-api.mdc.localhost:8088 \{/{f=1} f{print} f&&/^}/{exit}')
echo "$be" | grep -q 'header_down Access-Control-Allow-Origin "http://alpha.mdc.localhost:8088"' || { echo "FAIL: ACAO=대표origin replace 아님"; echo "$be"; exit 1; }
echo "$be" | grep -q "header_down Access-Control-Allow-Credentials true" || { echo "FAIL: credentials"; echo "$be"; exit 1; }
echo "$be" | grep -q "method OPTIONS" || { echo "FAIL: preflight 매처 없음"; echo "$be"; exit 1; }
echo "$be" | grep -q "respond 204" || { echo "FAIL: preflight 204 없음"; echo "$be"; exit 1; }
echo "$be" | grep -q "Access-Control-Request-Headers" || { echo "FAIL: 헤더 echo 없음"; echo "$be"; exit 1; }
echo "$be" | grep -q "reverse_proxy 127.0.0.1:3200" || { echo "FAIL: be 프록시 유지 안 됨"; echo "$be"; exit 1; }

# 회귀: cors 없으면 CORS 0 (기존 서비스 영향 없음)
out2=$(printf '%s' '[{"id":"b","projectId":"mdc","services":[{"service":"user-api","port":"3200","running":true}]}]' | python3 "$GW" gen --port 8088)
echo "$out2" | grep -q "Access-Control-Allow-Origin" && { echo "FAIL: cors 없는데 CORS 생성"; exit 1; } || true

echo "PASS test-gateway-expose-domain"
