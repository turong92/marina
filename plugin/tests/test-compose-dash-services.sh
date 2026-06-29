#!/usr/bin/env bash
# build_compose_services: ps 행 → native shape 서비스 dict; running=(health!=None); 포트 int-cast+dedup; health 매핑.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
python3 - "$CTRL" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mctl", sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.compose_health("running","")=="ok"
assert m.compose_health("running","healthy")=="ok"
assert m.compose_health("running","starting")=="starting"
assert m.compose_health("running","unhealthy")=="bad"
assert m.compose_health("restarting","")=="starting"
assert m.compose_health("created","") is None     # 생성됐지만 미기동 → OFF(▶ 표시)
assert m.compose_health("paused","") is None
assert m.compose_health("exited","") is None
assert m.compose_health("dead","") is None
print("ok health")
rows=[
 {"Service":"web","State":"running","Health":"",
  "Publishers":[{"PublishedPort":"54001"},{"PublishedPort":54001}]},   # str+int 혼합 → dedup 54001
 {"Service":"be","State":"running","Health":"healthy","Publishers":[{"PublishedPort":54002}]},
 {"Service":"worker","State":"running","Health":"","Publishers":[]},   # 내부 전용
 {"Service":"db","State":"exited","Health":"","Publishers":[]},        # 정지
 {"Service":"boot","State":"restarting","Health":"","Publishers":[{"PublishedPort":54003}]},
]
s={x["service"]:x for x in m.build_compose_services(rows)}
assert s["web"]["port"]=="54001" and s["web"]["running"] is True and s["web"]["health"]=="ok", s["web"]
for k in ("service","port","running","health","trackedPid","listenerPids","rssMb","log","logRuns","subrepo","source","def"):
    assert k in s["web"], f"missing {k}"
assert s["web"]["subrepo"]=="" and s["web"]["def"] is None and s["web"]["source"]=="compose"
assert s["be"]["port"]=="54002" and s["be"]["health"]=="ok"
assert s["worker"]["port"] is None and s["worker"]["running"] is True   # running+publish없음 → ON, port -
assert s["db"]["running"] is False and s["db"]["health"] is None        # exited → OFF
assert s["boot"]["running"] is True and s["boot"]["health"]=="starting" # restarting → BOOT
print("ok services")
PY
echo "PASS test-compose-dash-services"
