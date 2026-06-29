#!/usr/bin/env bash
# 게이트웨이 env 빈 문자열 방어 — supervised 기동이 MARINA_GATEWAY_PORT='' 를 export 해도
# 데몬 import 가 int('') 로 크래시하면 안 된다(코덱스 P1: 빈 env → 기본값).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
MARINA_GATEWAY="" MARINA_GATEWAY_PORT="" MARINA_GATEWAY_POLL="" MARINA_HOME="$(mktemp -d)" python3 - "$CTRL" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mctrl", sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m._GATEWAY_PORT == 3902, ("빈 MARINA_GATEWAY_PORT → 3902 기본(비특권, int('') 크래시 없이)", m._GATEWAY_PORT)
assert m._GATEWAY_ON is True, "빈 MARINA_GATEWAY → 기본 on(서비스 start 시 자동 기동)"
print("ok gateway-env-empty")
PY
echo "PASS test-gateway-env"
