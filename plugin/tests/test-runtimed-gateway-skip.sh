#!/usr/bin/env bash
# (형 2026-10-28) 런타임 데몬이 5초마다 게이트웨이 스냅샷을 통째로 다시 만들었다 — 한 번에 git 97회·docker 72회·38초라
#  사실상 쉬지 않고 돌아 맥 fseventsd 100% → 싼 서명(워크트리 목록 + 도커 호스트별 docker ps 1번)이 같으면 건너뛰고, 5분에 한 번은 통째로.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
PYTHONPATH="$DSCRIPTS/../../plugin/scripts" python3 - <<'PY'
import marina_runtimed as rd
sig = ["A"]; full = []
rd._gateway_signature = lambda: sig[0]
rd._refresh_full = lambda: full.append(1)
rd._refresh_gateway(now=1000.0)
assert full == [1], "처음엔 통째로"
rd._refresh_gateway(now=1005.0)
assert full == [1], f"서명이 같으면 건너뛴다: {full}"
sig[0] = "B"; rd._refresh_gateway(now=1010.0)
assert full == [1, 1], "바뀌면 다시"
rd._refresh_gateway(now=1010.0 + rd.GW_FULL_EVERY_S + 1)
assert full == [1, 1, 1], "오래되면 같아도 한 번"
rd._gateway_signature = lambda: (_ for _ in ()).throw(RuntimeError("x"))
rd._refresh_gateway(now=5000.0)
assert len(full) == 4, "서명을 못 구하면 통째로(안전한 쪽)"
PY
echo "PASS test-runtimed-gateway-skip"
