#!/usr/bin/env bash
# expose: build_overlay 가 expose_env 를 서비스 environment 로 주입(도메인=URL, origin=빈값).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MC="$HERE/../scripts/marina-compose.py"

python3 - "$MC" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
config={"services":{"web":{"build":{"context":"./web"},"ports":["3000"]}}}
ov=mc.build_overlay(config, expose_env={"web":{"NEXT_PUBLIC_API_URL":"http://alpha-user-api.mdc.localhost:8088"}})
assert "web:" in ov and "environment:" in ov, ov
assert 'NEXT_PUBLIC_API_URL: "http://alpha-user-api.mdc.localhost:8088"' in ov, ov
# same-origin 빈값도 명시 주입(하드코딩 폴백 덮기)
ov2=mc.build_overlay(config, expose_env={"web":{"NEXT_PUBLIC_API_URL":""}})
assert 'NEXT_PUBLIC_API_URL: ""' in ov2, ov2
# expose_env 없으면 environment 안 생김(회귀)
ov3=mc.build_overlay(config)
assert "NEXT_PUBLIC_API_URL" not in ov3, ov3
print("build_overlay expose_env OK")
PY
echo "PASS test-gateway-expose-origin (build_overlay)"
