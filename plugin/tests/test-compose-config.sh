#!/usr/bin/env bash
# 실 `docker compose config` (데몬 불요): services=map, ports 객체(published 문자열), ${VAR} 보간, bind 절대경로.
# 그 결과로 build_overlay 가 !override 127.0.0.1::<target> 를 뽑는지까지.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CP="$HERE/../scripts/marina-compose.py"
command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || { echo "SKIP test-compose-config (docker compose 미설치)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"; : > "$TMP/src/marker"
cat > "$TMP/docker-compose.yml" <<'YML'
services:
  web:
    image: "img-${APP_ENV:?APP_ENV required}"
    ports: ["3000:80"]
    volumes: ["./src:/app"]
YML
python3 - "$CP" "$TMP/docker-compose.yml" "$TMP" <<'PY'
import importlib.util, json, os, sys
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
env=dict(os.environ); env["APP_ENV"]="local"
cfg=mc.docker_config_json(sys.argv[2], sys.argv[3], "proj-test", env)   # raise 시 = P1 위반
w=cfg["services"]["web"]
assert isinstance(cfg["services"], dict)                                # map
p=w["ports"][0]; assert isinstance(p, dict) and isinstance(p["published"], str)  # 객체, published 문자열
assert w["image"]=="img-local", w["image"]                             # ${APP_ENV} 보간
vols=w.get("volumes",[])
src=lambda v: v.get("source","") if isinstance(v,dict) else str(v)
assert any(src(v).startswith(sys.argv[3]) for v in vols), vols          # bind 절대경로
ov=mc.build_overlay(cfg)
assert "!override" in ov and "127.0.0.1::80" in ov, ov                  # overlay 정확
print("ok config shape + interpolation + abspath + overlay")
PY
echo "PASS test-compose-config"
