#!/usr/bin/env bash
# build_compose_services: ps 행 → native shape 서비스 dict; running=(health!=None); 포트 int-cast+dedup; health 매핑.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
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

# 엮기 사이드카가 네임스페이스 주인이면 **게시 포트가 사이드카 행에 잡힌다**(앱 행은 비어 있다).
# 사이드카는 UI 에서 숨기므로, 접어주지 않으면 앱 카드가 URL 을 잃는다.
rows2=[
 {"Service":"api","State":"running","Health":"","Publishers":[]},                       # 앱: network_mode 라 게시 없음
 {"Service":"api-bind","State":"running","Health":"","Publishers":[{"PublishedPort":54010}]},
 {"Service":"solo","State":"running","Health":"","Publishers":[{"PublishedPort":54011}]},   # 사이드카 없는 서비스는 그대로
]
s2={x["service"]:x for x in m.build_compose_services(rows2)}
assert s2["api"]["port"]=="54010", ("사이드카 게시 포트를 본체로 접어야 한다", s2["api"])
assert s2["solo"]["port"]=="54011", s2["solo"]
# 앱이 스스로 게시하는 경우(구 오버레이·직접 실행)는 자기 값을 유지한다 — 사이드카가 덮지 않는다
rows3=[
 {"Service":"api","State":"running","Health":"","Publishers":[{"PublishedPort":54020}]},
 {"Service":"api-bind","State":"running","Health":"","Publishers":[{"PublishedPort":54021}]},
]
s3={x["service"]:x for x in m.build_compose_services(rows3)}
assert s3["api"]["port"]=="54020", s3["api"]
print("ok bind ports fold onto the app card")
PY
echo "PASS test-compose-dash-services"
