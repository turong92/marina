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

# (2026-11-11) 원격 박스 docker ps 를 5초마다 새 ssh 로 — 박스 sshd 에 시간당 528번 새 접속.
#  원격이면 ssh 껍데기(ControlMaster, marina_ssh_mux)를 얹어 접속 하나를 나눠 쓴다. 로컬이면 그대로.
import importlib, subprocess, types, sys
rd = importlib.reload(rd)
import marina_ssh_mux as mux
fake_rt = types.SimpleNamespace(docker_env_for_root=lambda r: {"DOCKER_HOST": "ssh://box"} if r == "/r/remote" else {})
sys.modules["marina_runtime_target"] = fake_rt
import marina_registry
marina_registry.discover_roots = lambda: ["/r/local", "/r/remote"]
mux.mux_env = lambda env: dict(env, PATH="/SHIM:" + env.get("PATH", ""))
seen = []
subprocess.run = lambda argv, env=None, **kw: (seen.append(env), types.SimpleNamespace(returncode=0, stdout=""))[1]
rd._gateway_signature()
remote = [e for e in seen if e.get("DOCKER_HOST") == "ssh://box"]
local = [e for e in seen if not e.get("DOCKER_HOST")]
assert remote and remote[0]["PATH"].startswith("/SHIM:"), "원격 docker ps 는 ssh 껍데기로 접속을 재사용해야 한다"
assert local and not local[0].get("PATH", "").startswith("/SHIM:"), "로컬 docker 에는 껍데기를 얹지 않는다"
PY
echo "PASS test-runtimed-gateway-skip"
