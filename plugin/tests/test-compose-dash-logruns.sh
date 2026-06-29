#!/usr/bin/env bash
# _compose_services 가 세션의 run-NNN 로그를 logRuns/log 로 노출한다(네이티브 뷰어 재사용).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"
python3 - "$CTRL" "$TMP/proj" <<'PY'
import importlib.util, sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mctl", sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root=Path(sys.argv[2]); root.mkdir(parents=True, exist_ok=True)
sd=m.session_dir(root)                       # 데몬이 보는 세션 디렉토리
(sd/"logs"/"web").mkdir(parents=True, exist_ok=True)
(sd/"logs"/"web"/"run-001.log").write_text("LOGZ\n", encoding="utf-8")
import marina_compose_svc as _cs                # 분리 후 compose_ps/_mc 는 compose_svc 네임스페이스 — 거기서 monkeypatch
_cs.compose_ps=lambda r,n:[{"Service":"web","State":"running","Health":"","Publishers":[{"PublishedPort":5555}]}]
_cs._mc=lambda: type("X",(),{"compose_project_name":staticmethod(lambda i,s:"proj-main")})
web=[s for s in m._compose_services(root, {"id":"proj"}) if s["service"]=="web"][0]
assert web["log"].endswith("web.log"), web["log"]
assert isinstance(web["logRuns"], list) and len(web["logRuns"])>=1, web["logRuns"]
print("ok logruns")
PY
echo "PASS test-compose-dash-logruns"
