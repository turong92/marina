#!/usr/bin/env bash
# 엮기 일반화: build_overlay 가 forward={port:target} 로 앱(build) 서비스마다 사이드카 1개(<svc>-bind)를 만든다.
# target=host → host.docker.internal(리눅스 게이트웨이 폴백), target=서비스명 → 컨테이너 DNS. target==자기 서비스는 skip.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CP="$HERE/../scripts/marina-compose.py"

python3 - "$CP" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

SV={"services":{
  "fe":{"build":{"context":"."}},
  "be":{"build":{"context":"."},"ports":[{"target":8081,"published":"8081"}]},
  "cache":{"image":"redis"},
}}

# --- 헬퍼: _forward_for_service — self(타겟==자기) 제외, 포트 오름차순, [(port,target)] ---
assert mc._forward_for_service({"8081":"be","6379":"host"}, "fe")==[("6379","host"),("8081","be")], mc._forward_for_service({"8081":"be","6379":"host"},"fe")
assert mc._forward_for_service({"8081":"be","6379":"host"}, "be")==[("6379","host")], "be 는 8081 self 제외"
assert mc._forward_for_service({}, "fe")==[], "빈 forward → 빈"

# --- 헬퍼: _bind_script — host 면 $H 셋업, 포트별 백그라운드 socat, 끝에 wait ---
s=mc._bind_script([("6379","host"),("8081","be")])
assert "H=host.docker.internal" in s and "ip route" in s, s          # host → 런타임 host.docker.internal 또는 default gateway
assert 'TCP-LISTEN:6379,fork,reuseaddr TCP:"$$H":6379 &' in s, s     # $$ = compose 변수확장 회피(런타임 리터럴 $)
assert "TCP-LISTEN:8081,fork,reuseaddr TCP:be:8081 &" in s, s        # service → DNS, 따옴표 없음
assert s.rstrip().endswith("wait"), s
s2=mc._bind_script([("8081","be")])                                  # 전부 service → $H 셋업 없음
assert "host.docker.internal" not in s2 and "TCP:be:8081" in s2, s2

# --- build_overlay: service target — fe 가 localhost:8081 → be:8081. 사이드카는 fe-bind 하나 ---
ov=mc.build_overlay(SV, connectivity={"forward":{"8081":"be"}})
assert "fe-bind:" in ov and "alpine/socat" in ov, ov
assert 'network_mode: "service:fe"' in ov, ov
assert "TCP-LISTEN:8081" in ov and "TCP:be:8081" in ov, ov           # 따옴표 없는 부분문자열(json.dumps 안전)
assert "be-bind:" not in ov, ("be 는 8081 자기서빙 → 사이드카 없어야", ov)   # self-skip
assert "cache-bind" not in ov, "image-only 서비스는 사이드카 없음"

# --- build_overlay: 혼합 — 한 사이드카가 host(redis)+service(be) 둘 다 ---
ov2=mc.build_overlay(SV, connectivity={"forward":{"6379":"host","8081":"be"}})
assert ov2.count("fe-bind:")==1, ("fe 사이드카는 하나(모든 포트)", ov2)
assert "TCP-LISTEN:6379" in ov2 and "host.docker.internal" in ov2, ov2   # host target
assert "TCP:be:8081" in ov2, ov2                                         # service target
assert "be-bind:" in ov2, ("be 도 6379(host) 는 받음", ov2)              # be 는 6379 만(8081 self)

# --- _normalize_forward: backing.json top-level forward 선언 정규화 (precedence·edge) ---
assert mc._normalize_forward({"forward":{"8081":{"target":"be"},"6379":{"target":"host"}}})=={"8081":"be","6379":"host"}   # 객체형
assert mc._normalize_forward({"forward":{"8081":"be"}})=={"8081":"be"}                                                     # 축약형
assert mc._normalize_forward({"forward":{"8081":"be"},"hostForward":["6379"]})=={"8081":"be"}                              # legacy hostForward 무시
assert mc._normalize_forward({"services":{"app":{"hostForward":["6379"]}}})=={}                                             # legacy service hostForward 무시
assert mc._normalize_forward({"forward":{"abc":"be","8081":{"target":""},"6379":"host"}})=={"6379":"host"}                 # 숫자 아닌 포트·빈 target 무시
# --- codex review #1: expose-only 서비스도 자동 서비스타겟 (marina 스캐폴드/LLM 은 expose 사용) ---
assert mc._auto_service_forward({"services":{"be":{"expose":["8081"]},"fe":{"ports":[{"target":3000}]}}})=={"8081":"be","3000":"fe"}
assert mc._auto_service_forward({"services":{"be":{"expose":["8081/tcp"]}}})=={"8081":"be"}                                # proto 접미사 허용
# --- codex review P1: 옛 services.<svc>.endpoints 는 무시(서비스타겟=auto-derive). 전역 override 위험 회피 ---
assert mc._normalize_forward({"services":{"app":{"endpoints":[{"port":"6379","mode":"host"},{"port":"8081","mode":"service","service":"be"}]}}})=={}   # endpoints 무시
assert mc._normalize_forward({"forward":{"6379":"redis"},"services":{"app":{"endpoints":[{"port":"6379","mode":"host"}]}}})=={"6379":"redis"}            # forward 만, endpoints 무시
# --- codex review P2: 같은 포트 두 서비스 — 자기 서빙 포트는 타겟이 남이어도 사이드카 안 만듦(socat↔자기 listener 충돌 회피) ---
_dup={"services":{"a":{"build":{"context":"."},"expose":["8080"]},"b":{"build":{"context":"."},"expose":["8080"]}}}
assert mc._auto_service_forward(_dup)=={"8080":"a"}, mc._auto_service_forward(_dup)   # 첫 서비스(정렬) 타겟, 경고
_ovd=mc.build_overlay(_dup, connectivity={"forward":mc._auto_service_forward(_dup)})
assert "a-bind:" not in _ovd and "b-bind:" not in _ovd, ("둘 다 8080 자기서빙 → 사이드카 없음(충돌 회피)", _ovd)
assert mc._forward_for_service({"8080":"a","6379":"host"}, "b", own_ports={"8080"})==[("6379","host")], "b 는 8080 자기서빙 제외"
# --- codex review P2: UDP 포트는 엮기(socat TCP) 대상 아님 → 자동타겟 제외 ---
assert mc._served_ports({"expose":["53/udp"]})==set(), "UDP expose 제외"
assert mc._served_ports({"expose":["8080","53/udp","9000/tcp"]})=={"8080","9000"}, "TCP·무접미사만"
assert mc._auto_service_forward({"services":{"dns":{"ports":[{"target":53,"protocol":"udp"}]},"web":{"expose":["8080"]}}})=={"8080":"web"}, "UDP 자동타겟 제외"

print("ok forward")
PY
echo "PASS test-compose-forward"
