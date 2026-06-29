#!/usr/bin/env bash
# compose_validate: docker compose config 로 해석 → isolation_breakers. network_mode:host=에러, container_name=warning(overlay 중화), 정상=ok.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-validate (docker 미가동)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"; P="$TMP/proj"; mkdir -p "$P"

python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: compose_validate"; exit 1; }
import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mc",sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
pd=Path(sys.argv[2])
ok_yaml="services:\n  web:\n    image: nginx\n    ports: [\"8080:80\"]\n"
r=mc.compose_validate(ok_yaml, pd, "APP_ENV", "local")
assert r["ok"] and not r["errors"], r
bad="services:\n  web:\n    image: nginx\n    network_mode: host\n"
r2=mc.compose_validate(bad, pd, "", "")
assert not r2["ok"] and any("network_mode" in e for e in r2["errors"]), r2
# container_name 은 이제 reject 안 함 — ok 유지 + warning(overlay 가 워크트리별 자동명명)
cn="services:\n  web:\n    image: nginx\n    container_name: fixed\n"
r2b=mc.compose_validate(cn, pd, "", "")
assert r2b["ok"] and any("container_name" in w for w in r2b["warnings"]), r2b
broken="services: [this is not valid"
r3=mc.compose_validate(broken, pd, "", "")
assert not r3["ok"] and r3["errors"], r3
# Dockerfile 필수: build 서비스에 Dockerfile 없으면 에러
import os
os.makedirs(str(pd/"svcweb"), exist_ok=True)            # context 존재, Dockerfile 없음
nodf="services:\n  web:\n    build: ./svcweb\n"
r4=mc.compose_validate(nodf, pd, "", "")
assert not r4["ok"] and any("Dockerfile" in e for e in r4["errors"]), r4
open(str(pd/"svcweb"/"Dockerfile"),"w").close()         # Dockerfile 추가 → 통과
r5=mc.compose_validate(nodf, pd, "", "")
assert r5["ok"], r5
PY
echo "PASS test-compose-validate"
