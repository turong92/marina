#!/usr/bin/env bash
# ensure_gateway: PID가 살아 있어도 실제 listener가 없으면 control start로 복구하고 강제 apply한다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

MARINA_HOME="$TMP/home" MARINA_GATEWAY=on MARINA_GATEWAY_PORT=3902 python3 - "$HERE/../scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import marina_lifecycle as ml

snapshot=[{"id":"main","projectId":"p","services":[{"service":"web","port":"51000","running":True}]}]
events=[]

class FakeGateway:
    def caddy_bin(self): return "/tmp/fake-caddy"
    def build_caddyfile(self, snap, port): return "desired"
    def write_config(self, text, path): events.append(("write", text, path))
    def apply(self, snap, port, path, force=False):
        events.append(("apply", port, force))
        return True

ml._gateway_snapshot=lambda: snapshot
ml._gw=lambda: FakeGateway()
ml._gw_pid_alive=lambda: True
ml._resolved_gateway_port=lambda: 3902
ml._gateway_port_ready=lambda port: False
ml.subprocess.run=lambda cmd, **kwargs: events.append(("run", cmd, kwargs))

ml.ensure_gateway()

runs=[e for e in events if e[0]=="run"]
assert runs and runs[0][1][-1]=="start", events
assert any(e[0]=="write" for e in events), events
assert ("apply", 3902, True) in events, events
print("PASS test-gateway-ensure-health")
PY
