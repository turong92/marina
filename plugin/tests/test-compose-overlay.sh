#!/usr/bin/env bash
# build_overlay: ports[] 보유 서비스(고정+auto) 전부 !override 127.0.0.1::<target>, expose/image-only 제외, 범위 거부.
# + isolation_breakers + parse_ps_ports.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CP="$HERE/../scripts/marina-compose.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/c.json" <<'JSON'
{"services":{
  "web":{"ports":[{"target":80,"published":"3000","protocol":"tcp"}]},
  "be":{"ports":[{"target":8081,"published":"8081","protocol":"tcp"}]},
  "auto":{"ports":[{"target":9000,"protocol":"tcp"}]},
  "index":{"image":"py"},
  "dbonly":{"image":"pg","expose":["5432"]}
}}
JSON
ov="$(python3 "$CP" overlay < "$TMP/c.json")"
echo "$ov" | grep -q '!override' || { echo "FAIL: no !override"; exit 1; }
echo "$ov" | grep -q '"127.0.0.1::80"' || { echo "FAIL: web fixed→localhost"; exit 1; }
echo "$ov" | grep -q '"127.0.0.1::8081"' || { echo "FAIL: be"; exit 1; }
echo "$ov" | grep -q '"127.0.0.1::9000"' || { echo "FAIL: auto-publish(published 없음)도 override 돼야 함"; exit 1; }
echo "$ov" | grep -qE '^  index:' && { echo "FAIL: image-only service in overlay"; exit 1; } || true
echo "$ov" | grep -qE '^  dbonly:' && { echo "FAIL: expose-only service in overlay"; exit 1; } || true

# 범위 거부
echo '{"services":{"a":{"ports":[{"target":"8080-8090","published":"8080"}]}}}' \
  | python3 "$CP" overlay >/dev/null 2>&1 && { echo "FAIL: range not rejected"; exit 1; } || true

# isolation breakers + build_overlay 중화 + ps parse — 함수 직접
python3 - "$CP" "$TMP" <<'PY'
import importlib.util, sys, os, json
from types import SimpleNamespace
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
T=sys.argv[2]
# container_name 은 이제 막지 않음(overlay 가 중화) → warning, network_mode:host 는 여전히 error
err,warn=mc.isolation_breakers({"services":{"x":{"container_name":"fixed"},"y":{"network_mode":"host"}},"volumes":{"v":{"external":True}}})
assert any("network_mode" in e for e in err) and not any("container_name" in e for e in err), err
assert any("container_name" in w for w in warn) and any("external" in w for w in warn), warn
# build_overlay: container_name → !reset 제거(워크트리별 자동명명)
ov2=mc.build_overlay({"services":{"w":{"container_name":"web","ports":[{"target":3000,"published":"3000"}]}}})
assert "container_name: !reset null" in ov2 and "127.0.0.1::3000" in ov2, ov2
# build_overlay: Dockerfile 케이스 보정 — context 에 DockerFile(대문자)면 dockerfile: DockerFile 주입(데몬 케이스민감)
os.makedirs(os.path.join(T,"svc"),exist_ok=True); open(os.path.join(T,"svc","DockerFile"),"w").close()
ovc=mc.build_overlay({"services":{"a":{"build":{"context":os.path.join(T,"svc")}}}})
assert "dockerfile: DockerFile" in ovc, ovc
# 정확히 Dockerfile(소문자) 있으면 손 안 댐(빈 overlay)
os.makedirs(os.path.join(T,"svc2"),exist_ok=True); open(os.path.join(T,"svc2","Dockerfile"),"w").close()
assert "dockerfile:" not in mc.build_overlay({"services":{"a":{"build":{"context":os.path.join(T,"svc2")}}}})
# build args 주입 — include 서비스에도(overlay), app compose 불변
ova=mc.build_overlay({"services":{"web":{"build":{"context":"/nope"}}}}, build_args={"web":{"BUILD_ENV":"development"}})
assert "args:" in ova and "BUILD_ENV:" in ova and "development" in ova, ova
# _parse_build_args: 'svc=K=V' → {svc:{K:V}}, 형식 안 맞으면 스킵
assert mc._parse_build_args(["web=BUILD_ENV=development","api=X=1"])=={"web":{"BUILD_ENV":"development"},"api":{"X":"1"}}, mc._parse_build_args(["web=BUILD_ENV=development"])
assert mc._parse_build_args(["bad","svc=noeq",""])=={}, "malformed skipped"
# Build handoff is captured from the already-resolved config immediately before up,
# and raw build-arg values never reach the file.
handoff=os.path.join(T,"build-inputs.json"); os.environ["MARINA_BUILD_INPUT_SNAPSHOT"]=handoff
os.environ["MARINA_HOME"]=os.path.join(T,"home")
os.makedirs(os.path.join(T,"capture"),exist_ok=True); open(os.path.join(T,"capture","Dockerfile"),"w").write("FROM scratch\n")
mc._capture_build_input_handoff(
    SimpleNamespace(project_dir=T),
    {"services":{"web":{"build":{"context":os.path.join(T,"capture"),"dockerfile":"Dockerfile"}}}},
    ["web"], {"web":{"TOKEN":"must-not-reach-handoff"}},
)
raw=open(handoff,encoding="utf-8").read(); captured=json.loads(raw)
assert "must-not-reach-handoff" not in raw, raw
assert captured["services"]["web"]["buildArgs"]["TOKEN"], captured
assert os.stat(handoff).st_mode & 0o777 == 0o600, oct(os.stat(handoff).st_mode)
ps='[{"Service":"web","Publishers":[{"URL":"127.0.0.1","TargetPort":80,"PublishedPort":55001,"Protocol":"tcp"},{"PublishedPort":0}]},{"Service":"be","Publishers":[{"PublishedPort":55002}]}]'
assert mc.parse_ps_ports(ps)=={"web":[55001],"be":[55002]}, mc.parse_ps_ports(ps)
# 엮기 — _normalize_forward/_legacy_host_forward 상세는 test-compose-forward.sh 소관(중복 유지비 제거)
# 엮기 — _auto_service_forward: compose 가 서빙하는 포트 → 그 서비스 (자동 서비스타겟)
assert mc._auto_service_forward({"services":{"be":{"ports":[{"target":8081,"published":"8081"}]},"fe":{"ports":[{"target":3000}]},"redis":{"image":"r"}}})=={"8081":"be","3000":"fe"}
assert mc._auto_service_forward({"services":{}})=={}, "포트 서빙 서비스 없으면 빈"
# 엮기 사이드카 — forward(={port:target}) → 앱(build) 서비스마다 사이드카 1개. host=host.docker.internal. image-only 제외.
_ovf=mc.build_overlay({"services":{"api":{"build":{"context":"."}}, "cache":{"image":"redis"}}}, connectivity={"forward":{"6379":"host"}})
assert "api-bind:" in _ovf and "alpine/socat" in _ovf and 'network_mode: "service:api"' in _ovf, _ovf
assert "TCP-LISTEN:6379" in _ovf and "host.docker.internal" in _ovf, _ovf   # Linux fallback sh wrapper (host.docker.internal or default gateway)
assert "cache-bind" not in _ovf, "image-only 서비스는 사이드카 없음"
# service 타겟 — localhost:8081 → be:8081 (컨테이너 DNS), be 는 8081 self-skip
_ovs=mc.build_overlay({"services":{"fe":{"build":{"context":"."}}, "be":{"build":{"context":"."},"ports":[{"target":8081,"published":"8081"}]}}}, connectivity={"forward":{"8081":"be"}})
assert "fe-bind:" in _ovs and "TCP:be:8081" in _ovs and "be-bind:" not in _ovs, _ovs
# 일원화 — build_overlay 는 forward 만 본다(옛 service-redirect extraHosts/env 주입 제거)
_ovx=mc.build_overlay({"services":{"api":{"build":{"context":"."}}}}, connectivity={"forward":{"6379":"host"},"extraHosts":["api"],"env":{"api":{"X":"y"}}})
assert "extra_hosts" not in _ovx and "environment:" not in _ovx, _ovx
# x-marina — xmarina_for_stored: stored compose 의 x-marina 블록을 docker 없이 읽음
xmf=os.path.join(T,"stored-xm.yml")
open(xmf,"w").write('services:\n  api:\n    build: .\nx-marina:\n  forward:\n    6379: {target: host}\n  prebuild:\n    be-api: ./gradlew assemble\n  gateway:\n    routes:\n      api: ["/v1.0"]\n')
xm=mc.xmarina_for_stored(xmf)
assert xm.get("prebuild")=={"be-api":"./gradlew assemble"}, xm
assert (xm.get("gateway") or {}).get("routes")=={"api":["/v1.0"]}, xm
# x-marina.forward → _normalize_forward(같은 경로) → 사이드카 (cmd_up 가 이 merge 를 함)
assert mc._normalize_forward(xm)=={"6379":"host"}, mc._normalize_forward(xm)
_ovxm=mc.build_overlay({"services":{"api":{"build":{"context":"."}}}}, connectivity={"forward":mc._normalize_forward(xm)})
assert "api-bind:" in _ovxm and "TCP-LISTEN:6379" in _ovxm, _ovxm
assert mc.xmarina_for_stored(os.path.join(T,"nope.yml"))=={}, "없는 stored → {}"
# compose 커스텀 태그(!reset/!override)는 safe_load 가 ConstructorError → best-effort {} (start 크래시 금지)
tagf=os.path.join(T,"tag.yml")
open(tagf,"w").write('services:\n  app:\n    image: alpine\n    container_name: !reset null\nx-marina:\n  forward: {6379: {target: host}}\n')
assert mc.xmarina_for_stored(tagf)=={}, "커스텀 태그 compose 는 best-effort {} 여야(크래시 금지)"
print("ok funcs")
PY
# x-marina CLI 서브커맨드 — bash(marina.sh prebuild 가 이걸로 x-marina.prebuild 를 읽음)
xmpb="$(python3 "$CP" xmarina --stored "$TMP/stored-xm.yml" --key prebuild)"
echo "$xmpb" | grep -q 'gradlew assemble' || { echo "FAIL: xmarina subcommand --key prebuild"; exit 1; }
xmall="$(python3 "$CP" xmarina --stored "$TMP/stored-xm.yml")"
echo "$xmall" | grep -q '"gateway"' || { echo "FAIL: xmarina subcommand 전체"; exit 1; }
echo "$(python3 "$CP" xmarina --stored "$TMP/nope.yml")" | grep -q '^{}$' || { echo "FAIL: 없는 stored → {}"; exit 1; }
echo "PASS test-compose-overlay"
