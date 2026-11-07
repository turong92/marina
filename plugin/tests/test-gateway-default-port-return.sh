#!/usr/bin/env bash
# 게이트웨이 재기동 시 기본 포트가 비면 기본으로 복귀(port 파일 갱신 + 안내 한 줄). 점유 중이면 port 파일 값 재사용.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

env -u MARINA_GATEWAY_PORT MARINA_HOME="$TMP/home" MARINA_GATEWAY=on python3 - "$HERE/../scripts" <<'PY'
import io, socket, sys, contextlib
sys.path.insert(0, sys.argv[1])
import marina_lifecycle as ml

def free():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p
base, old = free(), free()
ml._GATEWAY_PORT = base
snapshot=[{"id":"main","projectId":"p","services":[{"service":"web","port":"51000","running":True}]}]
events=[]
class FakeGateway:
    def caddy_bin(self): return "/tmp/fake-caddy"
    def build_caddyfile(self, snap, port): return "desired"
    def write_config(self, text, path): pass
    def apply(self, snap, port, path, force=False): return True
ml._gateway_snapshot=lambda: snapshot
ml._gw=lambda: FakeGateway()
ml._gw_pid_alive=lambda: False
ml.subprocess.run=lambda cmd, **kw: events.append(kw["env"]["MARINA_GATEWAY_PORT"])

# 1) port 파일이 옛 포트, 기본 포트는 비어 있음 → 기본으로 복귀
ml._GW_DIR.mkdir(parents=True, exist_ok=True)
ml._GW_PORT_FILE.write_text(str(old))
err = io.StringIO()
with contextlib.redirect_stderr(err):
    ml.ensure_gateway()
assert events == [str(base)], events
assert ml._GW_PORT_FILE.read_text() == str(base), ml._GW_PORT_FILE.read_text()
assert f"포트 {old}→{base}, 스택 재시작 필요" in err.getvalue(), err.getvalue()

# 2) 기본 포트를 남이 쥐고 있으면 port 파일 값 재사용(안내 없음)
holder = socket.socket(); holder.bind(("127.0.0.1", base)); holder.listen(1)
ml._GW_PORT_FILE.write_text(str(old)); events.clear()
err = io.StringIO()
with contextlib.redirect_stderr(err):
    ml.ensure_gateway()
holder.close()
assert events == [str(old)], events
assert "스택 재시작" not in err.getvalue(), err.getvalue()
print("PASS python")
PY

# compose up 쪽(_gateway_port_for_up)도 같은 규칙 — 기본 3902 가 비면 옛 port 파일 값 대신 3902 선기록(주입 URL 일치)
python3 - "$HERE/../scripts/marina-compose.py" <<'PY'
import importlib.util, sys, os, tempfile, socket
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
def bindable(p):
    with socket.socket() as s:
        try: s.bind(("127.0.0.1", p)); return True
        except OSError: return False
if not bindable(3902):
    print("skip compose-up(3902 사용 중)"); sys.exit(0)
s=socket.socket(); s.bind(("127.0.0.1",0)); old=s.getsockname()[1]; s.close()
with tempfile.TemporaryDirectory() as td:
    os.environ.pop("MARINA_GATEWAY_PORT", None); os.environ["MARINA_HOME"]=td
    os.makedirs(os.path.join(td,"gateway")); pf=os.path.join(td,"gateway","port"); open(pf,"w").write(str(old))
    assert mc._gateway_port_for_up()==3902
    assert open(pf).read()=="3902"
print("PASS compose-up")
PY
echo "PASS test-gateway-default-port-return"
