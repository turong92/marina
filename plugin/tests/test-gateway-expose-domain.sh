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
assert ml._expose_cors_targets(gw)=={"user-api":["web"]}, ml._expose_cors_targets(gw)   # gateway 모드만, be→consumer 목록(코덱스 P2)
assert ml._expose_cors_targets({"expose":{"web":{"A":"gateway:api"},"admin":{"B":"gateway:api"}}})=={"api":["admin","web"]}
assert ml._expose_cors_targets({})=={}
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

# ── 코덱스 리뷰 반영 회귀 ──────────────────────────────────────────────
python3 - "$HERE/../scripts/marina-gateway.py" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("gw", sys.argv[1]); gw=importlib.util.module_from_spec(spec); spec.loader.exec_module(gw)

# [P2] 비대표 consumer(admin) → ACAO 가 admin origin
snap=[{"id":"a","projectId":"p","services":[
  {"service":"web","port":"3100","running":True},
  {"service":"admin","port":"3300","running":True},
  {"service":"api","port":"3200","running":True,"cors":True,"corsConsumers":["admin"]}]}]
out=gw.build_caddyfile(snap, 8088)
assert 'header_down Access-Control-Allow-Origin "http://a-admin.p.localhost:8088"' in out, out
print("non-primary consumer OK")

# [P2] 다중 consumer → origin 별 exact 분기 + 무매치 폴백
snap2=[{"id":"a","projectId":"p","services":[
  {"service":"web","port":"3100","running":True},
  {"service":"admin","port":"3300","running":True},
  {"service":"api","port":"3200","running":True,"cors":True,"corsConsumers":["admin","web"]}]}]
out2=gw.build_caddyfile(snap2, 8088)
blk=out2.split("a-api.p.localhost:8088 {",1)[1].split("\nhttp://",1)[0]
assert '@cors_from0 header Origin "http://a-admin.p.localhost:8088"' in blk, blk
assert '@cors_from1 header Origin "http://a.p.localhost:8088"' in blk, blk
assert blk.count("reverse_proxy 127.0.0.1:3200")==3, blk        # origin 2 + 폴백 1
print("multi consumer OK")

# [P2] :80 → origin 에서 생략 (브라우저 Origin 문자열 일치)
snap3=[{"id":"a","projectId":"p","services":[
  {"service":"web","port":"3100","running":True},
  {"service":"api","port":"3200","running":True,"cors":True,"corsConsumers":["web"]}]}]
out3=gw.build_caddyfile(snap3, 80)
assert 'header_down Access-Control-Allow-Origin "http://a.p.localhost"' in out3, out3
assert 'localhost:80"' not in out3, out3
print("port-80 origin OK")

# [P2] preflight 매처가 진짜 preflight 한정 (허용 Origin + Access-Control-Request-Method)
assert "header Access-Control-Request-Method *" in out3, out3
assert 'header Origin "http://a.p.localhost"' in out3, out3
print("preflight-only matcher OK")

# [P2 2R] 단일 consumer 도 Origin 매처 게이트 + 무매치 폴백(원형 통과) — 비허용 Origin strip 우회 방지
blk1=out3.split("a-api.p.localhost:80 {",1)[1].split("\nhttp://",1)[0]
assert '@cors_from0 header Origin "http://a.p.localhost"' in blk1, blk1
assert blk1.count("reverse_proxy 127.0.0.1:3200")==2, blk1     # 허용 origin 1 + 폴백 1
assert blk1.rindex("handle {") > blk1.rindex("@cors_from0"), blk1
print("single-consumer origin-gate OK")

# [P2 2R] 대표 최후 폴백 결정적(이름 정렬) — 합성/라이브 순서 달라도 동일 대표
assert gw._effective_primary([{"service":"zfront","port":"1","running":True},{"service":"api","port":"2","running":True}])=="api"
assert gw._effective_primary([{"service":"api","port":"2","running":True},{"service":"zfront","port":"1","running":True}])=="api"
print("deterministic primary OK")

# 레거시 스냅샷(cors:true, corsConsumers 없음) → 대표 origin 폴백(하위호환)
snap4=[{"id":"a","projectId":"p","services":[
  {"service":"web","port":"3100","running":True},
  {"service":"api","port":"3200","running":True,"cors":True}]}]
out4=gw.build_caddyfile(snap4, 8088)
assert 'header_down Access-Control-Allow-Origin "http://a.p.localhost:8088"' in out4, out4
print("legacy bool fallback OK")
PY
echo "PASS test-gateway-expose-domain (codex round2: consumer-origin/:80/preflight)"

# [P2] _gateway_port_for_up 선기록 — up 이 고른 포트를 파일에 남겨 ensure 와 일치
python3 - "$HERE/../scripts/marina-compose.py" <<'PY'
import importlib.util, sys, os, tempfile
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
with tempfile.TemporaryDirectory() as td:
    os.environ.pop("MARINA_GATEWAY_PORT", None)
    os.environ["MARINA_HOME"]=td
    p1=mc._gateway_port_for_up()
    on_disk=int(open(os.path.join(td,"gateway","port")).read())
    assert p1==on_disk, (p1,on_disk)                       # 선기록
    assert p1==mc._gateway_port_for_up()                   # 재호출 동일(파일 재사용)
    os.environ["MARINA_GATEWAY_PORT"]="4444"
    assert mc._gateway_port_for_up()==4444                 # env 우선
    os.environ.pop("MARINA_GATEWAY_PORT", None)
os.environ.pop("MARINA_HOME", None)
print("port pre-claim OK")
PY
echo "PASS test-gateway-expose-domain (port pre-claim)"
