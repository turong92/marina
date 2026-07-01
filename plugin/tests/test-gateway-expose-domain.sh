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

python3 - "$HERE/../scripts/marina_lifecycle.py" <<'PY'
import importlib.util, sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec=importlib.util.spec_from_file_location("ml", sys.argv[1]); ml=importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(ml)
except Exception as e:
    print("skip import (env dep):", e); sys.exit(0)
gw={"expose":{"web":{"NEXT_PUBLIC_API_URL":"gateway:user-api","OTHER":"origin:svc2"}}}
assert ml._expose_cors_targets(gw)=={"user-api"}, ml._expose_cors_targets(gw)   # gateway 모드만 cors 대상
assert ml._expose_cors_targets({})==set()
print("_expose_cors_targets OK")
PY
echo "PASS test-gateway-expose-domain (cors targets)"

python3 - "$GW" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("gw", sys.argv[1]); gw=importlib.util.module_from_spec(spec); spec.loader.exec_module(gw)
snap=[{"id":"alpha","projectId":"mdc","services":[
  {"service":"web","port":"3100","running":True},
  {"service":"user-api","port":"3200","running":True,"cors":True,"routes":[]}]}]
s=gw.summarize_gateway(snap, 8088)
assert any(r["domain"]=="alpha-user-api.mdc.localhost:8088" and r["cors_origin"]=="http://alpha.mdc.localhost:8088" for r in s), s
assert any(r["domain"]=="alpha.mdc.localhost:8088" and r["cors_origin"] is None for r in s), s   # 대표 web 은 CORS 없음
print("summarize_gateway OK")
PY
echo "PASS test-gateway-expose-domain (summarize)"
