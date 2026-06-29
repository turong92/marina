#!/usr/bin/env bash
# build_overlay 가 profile 후보 build arg 를 런타임 environment 로도 미러링하는지.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 - "$HERE/../scripts" <<'PY'
import importlib.util, os, sys
sd = sys.argv[1]; sys.path.insert(0, sd)
spec = importlib.util.spec_from_file_location("marina_compose", os.path.join(sd, "marina-compose.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
config = {"services": {
    "ai-index": {"build": {"context": "./ai-api", "dockerfile": "index_api/Dockerfile.local"}},
    "user-api": {"build": {"context": "./be-api/user-api", "dockerfile": "DockerFile"}},
}}
ba = {"ai-index": {"PROFILE": "dev", "EXTRA": "x"}, "user-api": {"PROFILE": "local"}}
out = m.build_overlay(config, build_args=ba)
assert "environment:" in out, out
assert 'PROFILE: "dev"' in out, ("env 미러 dev 누락", out)
assert 'PROFILE: "local"' in out, ("user-api env 미러 누락", out)
assert "EXTRA:" in out, "build args 자체는 유지(args 블록)"
# ai-index segment: EXTRA 는 args 에만, environment 엔 PROFILE 만
seg = out.split("ai-index:", 1)[1].split("user-api:", 1)[0]
assert seg.count("environment:") == 1, seg
env_part = seg.split("environment:", 1)[1]
assert "PROFILE" in env_part and "EXTRA" not in env_part, ("EXTRA 가 env 로 새면 안 됨", env_part)
print("ok profile-overlay")
PY
echo "PASS test-profile-overlay"
