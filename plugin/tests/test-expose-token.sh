#!/usr/bin/env bash
# expose: 도메인 스킴 헬퍼(service_domain) + 토큰 파서(parse_expose_token) 단위테스트.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"
MC="$HERE/../scripts/marina-compose.py"

python3 - "$GW" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("gw", sys.argv[1]); gw=importlib.util.module_from_spec(spec); spec.loader.exec_module(gw)
# 대표(primary)면 bare, 아니면 <wt>-<svc>. 라벨은 sanitize.
assert gw.service_domain("main","shop","web",True,3902)=="http://main.shop.localhost:3902", gw.service_domain("main","shop","web",True,3902)
assert gw.service_domain("main","shop","user-api",False,3902)=="http://main-user-api.shop.localhost:3902", gw.service_domain("main","shop","user-api",False,3902)
assert gw.service_domain("Feat_X","MDC","User_API",False,80)=="http://feat-x-user-api.mdc.localhost:80"
print("service_domain OK")
PY
echo "PASS test-expose-token (service_domain)"

python3 - "$MC" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
assert mc.parse_expose_token("${gateway:user-api}")==("gateway","user-api")
assert mc.parse_expose_token("${origin:user-api}")==("origin","user-api")
assert mc.parse_expose_token("  ${gateway:svc-a}  ")==("gateway","svc-a")   # 공백 허용
assert mc.parse_expose_token("http://localhost:8081") is None               # 토큰 아님 → None
assert mc.parse_expose_token("${bogus:x}") is None                          # 미지원 모드 → None
assert mc.parse_expose_token("") is None
print("parse_expose_token OK")
PY
echo "PASS test-expose-token (parser)"
