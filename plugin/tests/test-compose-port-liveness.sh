#!/usr/bin/env bash
# 포트 기반 liveness: compose 컨테이너로는 안 도는데 서비스 포트를 누가 listen 중이면
# external=true 로 점등(예: main 에서 node/gradlew 로 직접 띄운 dev 서버). 포트가 닫히면 다시 꺼짐.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"

python3 - "$CTRL" "$TMP/proj" <<'PY'
import importlib.util, socket, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mctl", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = Path(sys.argv[2]); root.mkdir(parents=True, exist_ok=True)
import marina_compose_svc as cs

# 헬퍼 단위 검증 — _service_host_ports 가 published/target 분리
hp = cs._service_host_ports({"ports": [{"published": "3000", "target": 3000}, {"target": 8080}]})
assert hp == {"pub": [3000], "tgt": [3000, 8080]}, hp
hp2 = cs._service_host_ports({"ports": ["127.0.0.1:5500:80", "9000"]})
assert hp2 == {"pub": [5500], "tgt": [80, 9000]}, hp2

# 실제 listen 소켓을 띄워 _port_listening 이 잡는지
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.bind(("127.0.0.1", 0)); srv.listen(); PORT = srv.getsockname()[1]
assert cs._port_listening(PORT) is True
free = srv.getsockname()[1]

# _compose_services: 컨테이너 0개 + web 의 publish 포트가 listen → external 점등
cs.compose_ps = lambda r, n: []                          # 라이브 컨테이너 없음
cs._compose_defined_services = lambda p: ["web"]
cs._compose_config_maps = lambda r, p: ({"web": ""}, {}, {"web": {"pub": [PORT], "tgt": []}})
cs._mc = lambda: type("X", (), {"compose_project_name": staticmethod(lambda i, s: "proj-x")})
web = [s for s in m._compose_services(root, {"id": "proj"}) if s["service"] == "web"][0]
assert web["external"] is True and web["running"] is True and web["health"] == "ok", web
assert web["port"] == str(PORT), web

# 포트가 닫히면 다시 꺼짐(external=false, running=false)
srv.close()
web2 = [s for s in m._compose_services(root, {"id": "proj"}) if s["service"] == "web"][0]
assert web2["external"] is False and web2["running"] is False, web2

# worktree(비-main)는 target 만으로는 점등 안 함(격리 host포트 pub 만) — 공유 target 포트 오탐 방지
srv2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv2.bind(("127.0.0.1", 0)); srv2.listen(); TPORT = srv2.getsockname()[1]
cs.session_id = lambda r: "feature-wt"                   # 비-main
cs._compose_config_maps = lambda r, p: ({"web": ""}, {}, {"web": {"pub": [], "tgt": [TPORT]}})
web3 = [s for s in m._compose_services(root, {"id": "proj"}) if s["service"] == "web"][0]
assert web3["external"] is False, ("worktree 는 target 포트로 점등하면 안 됨", web3)

# main 은 target fallback 으로 점등(직접 실행 dev 흔함)
cs.session_id = lambda r: "main"
web4 = [s for s in m._compose_services(root, {"id": "proj"}) if s["service"] == "web"][0]
assert web4["external"] is True and web4["port"] == str(TPORT), ("main 은 target 포트로도 점등", web4)
srv2.close()
print("PASS port-liveness")
PY
echo "PASS test-compose-port-liveness"
