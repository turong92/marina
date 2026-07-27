#!/usr/bin/env bash
# 엮기 일반화: build_overlay 가 forward={port:target} 로 앱(build) 서비스마다 사이드카 1개(<svc>-bind)를 만든다.
# target=host → host.docker.internal(리눅스 게이트웨이 폴백), target=서비스명 → 컨테이너 DNS. target==자기 서비스는 skip.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
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
assert 'TCP4-LISTEN:6379,fork,reuseaddr TCP:"$$H":6379 &' in s, s    # $$ = compose 변수확장 회피(런타임 리터럴 $)
assert "TCP4-LISTEN:8081,fork,reuseaddr TCP:be:8081 &" in s, s       # service → DNS, 따옴표 없음
assert s.rstrip().endswith("wait"), s
# localhost 가 ::1 로 풀리는 런타임(Node 등)도 닿아야 한다 — IPv4 만 듣던 시절엔 Connection refused 였다.
# IPv6 가 꺼진 컨테이너에서도 v4 는 살아야 하므로 소켓을 따로 연다(ipv6only=1). v6 는 best-effort.
assert "TCP6-LISTEN:6379,fork,reuseaddr,ipv6only=1" in s, s
assert "TCP6-LISTEN:8081,fork,reuseaddr,ipv6only=1" in s, s
s2=mc._bind_script([("8081","be")])                                  # 전부 service → $H 셋업 없음
assert "host.docker.internal" not in s2 and "TCP:be:8081" in s2, s2

# --- build_overlay: service target — fe 가 localhost:8081 → be:8081. 사이드카는 fe-bind 하나 ---
ov=mc.build_overlay(SV, connectivity={"forward":{"8081":"be"}})
assert "fe-bind:" in ov and "alpine/socat" in ov, ov
assert 'network_mode: "service:fe-bind"' in ov, ov
assert "TCP4-LISTEN:8081" in ov and "TCP:be:8081" in ov, ov           # 따옴표 없는 부분문자열(json.dumps 안전)
assert "be-bind:" not in ov, ("be 는 8081 자기서빙 → 사이드카 없어야", ov)   # self-skip
assert "cache-bind" not in ov, "image-only 서비스는 사이드카 없음"

# --- 기동 순서: 네임스페이스 주인은 **사이드카**다 ---
# 예전엔 사이드카가 앱의 netns 를 빌렸다(network_mode: service:<앱>). 그러면 compose 가 앱을 먼저
# 띄울 수밖에 없어서, socat 이 듣기 전에 앱이 localhost:<port> 로 붙으면 Connection refused 로
# 부팅이 통째로 실패했다(실측: user-api Redisson 이 6.2초에 도달, 사이드카는 4.5초에 기동 → 패배).
# 방향을 뒤집으면 사이드카가 먼저 뜨고 앱이 그 netns 에 합류하므로 레이스가 구조적으로 사라진다.
ovo=mc.build_overlay(SV, connectivity={"forward":{"8081":"be"}})
assert 'network_mode: "service:fe-bind"' in ovo, ("앱이 사이드카 netns 에 합류해야 한다", ovo)
assert 'network_mode: "service:fe"' not in ovo, ("사이드카가 앱을 빌리면 앱이 먼저 뜬다(레이스)", ovo)

def block(text, name):
    lines, out, on = text.split("\n"), [], False
    for l in lines:
        if l.startswith(f"  {name}:"): on = True; continue
        if on and l.startswith("  ") and not l.startswith("    "): break
        if on: out.append(l)
    return "\n".join(out)

fe, fe_bind = block(ovo, "fe"), block(ovo, "fe-bind")
# netns 주인이 바뀌면 DNS 이름·게시 포트도 따라가야 한다 — 안 그러면 다른 서비스가 앱을 못 찾는다.
assert "aliases:" in fe_bind and '"fe"' in fe_bind, ("사이드카가 앱 이름 별칭을 가져야 DNS 가 유지된다", fe_bind)
# compose 는 network_mode 와 networks/ports 동시 선언을 거부한다 — 앱 쪽은 비워야 한다.
assert "networks: !reset" in fe, ("network_mode 와 networks 는 공존 불가", fe)

SVP={"services":{
  "fe":{"build":{"context":"."},"ports":[{"target":3000,"published":"3000"}]},
  "be":{"build":{"context":"."},"ports":[{"target":8081,"published":"8081"}]},
}}
ovp=mc.build_overlay(SVP, connectivity={"forward":{"8081":"be"}})
fep, fep_bind = block(ovp, "fe"), block(ovp, "fe-bind")
assert "ports: !reset" in fep, ("사이드카가 netns 주인이면 앱은 포트를 게시할 수 없다", fep)
assert "::3000" in fep_bind, ("게시 포트가 사이드카로 옮겨가야 한다", fep_bind)
assert "::3000" not in fep.replace("!reset", ""), fep
# 사이드카가 이제 평범한 컨테이너라 extra_hosts 가 실제로 먹는다(리눅스 host 타겟 신뢰성).
# host 타겟이 있을 때만 붙인다 — 서비스 타겟뿐이면 불필요.
_ovh=mc.build_overlay(SV, connectivity={"forward":{"6379":"host"}})
assert "host-gateway" in block(_ovh, "fe-bind"), block(_ovh, "fe-bind")
assert "host-gateway" not in fe_bind, ("host 타겟이 없으면 붙이지 않는다", fe_bind)

# --- 순서를 넘어 **준비**까지 기다린다 ---
# 컨테이너가 "시작됨"인 것과 socat 이 "듣는 중"인 건 다르다. 사이드카가 안 떠 있으면 앱은 어차피
# 못 도니, 조용히 깨진 채 뜨느니 healthcheck 로 실제 리스닝을 확인하고 그 뒤에 앱을 띄운다.
_ovm = mc.build_overlay(SV, connectivity={"forward":{"6379":"host","8081":"be"}})   # host + service 둘 다
hc = block(_ovm, "fe-bind")
assert "healthcheck:" in hc, ("사이드카는 리스닝을 스스로 증명해야 한다", hc)
assert ":6379 " in hc and ":8081 " in hc, ("엮는 포트 전부를 확인해야 한다", hc)
fe2 = block(_ovm, "fe")
assert "depends_on:" in fe2 and "service_healthy" in fe2, ("앱은 사이드카가 준비된 뒤에 뜬다", fe2)
assert "fe-bind:" in fe2, fe2

# 사이드카 없는 서비스는 예전 그대로 자기 포트를 게시한다(회귀 방지)
SVN={"services":{"solo":{"build":{"context":"."},"ports":[{"target":9000,"published":"9000"}]}}}
ovn=mc.build_overlay(SVN, connectivity={"forward":{}})
assert "::9000" in ovn and "!reset" not in ovn and "network_mode" not in ovn, ovn

# --- build_overlay: 혼합 — 한 사이드카가 host(redis)+service(be) 둘 다 ---
ov2=mc.build_overlay(SV, connectivity={"forward":{"6379":"host","8081":"be"}})
assert ov2.count("\n  fe-bind:")==1, ("fe 사이드카는 하나(모든 포트)", ov2)   # depends_on 안의 이름과 구분해 서비스 정의만 센다
assert "TCP4-LISTEN:6379" in ov2 and "host.docker.internal" in ov2, ov2   # host target
assert "TCP:be:8081" in ov2, ov2                                         # service target
assert "be-bind:" in ov2, ("be 도 6379(host) 는 받음", ov2)              # be 는 6379 만(8081 self)

# --- _normalize_forward: backing.json top-level forward 선언 정규화 (precedence·edge) ---
assert mc._normalize_forward({"forward":{"8081":{"target":"be"},"6379":{"target":"host"}}})=={"8081":"be","6379":"host"}   # 객체형
assert mc._normalize_forward({"forward":{"8081":"be"}})=={"8081":"be"}                                                     # 축약형
assert mc._normalize_forward({"forward":{"8081":"be"},"hostForward":["6379"]})=={"8081":"be"}                              # hostForward 는 _legacy_host_forward 소관
# --- _legacy_host_forward: README 안내 포맷(hostForward) 반영 — 단 auto 서비스타겟보다 약함 ---
assert mc._legacy_host_forward({"hostForward":["6379","abc","3306"]})=={"6379":"host","3306":"host"}                        # 숫자 아닌 항목 무시
assert mc._legacy_host_forward({"hostForward":"6379"})=={}                                                                  # 리스트 아니면 무시(방어)
assert mc._legacy_host_forward({"services":{"app":{"hostForward":["6379"]}}})=={}                                           # 서비스별 hostForward 는 미지원(경고는 cmd_up)
# 우선순위: legacy hostForward < 자동 서비스타겟 < 명시 forward — 스테일 hostForward 가 compose 서비스 라우트를 못 덮는다
_c={"hostForward":["6379"]}; _cfg={"services":{"redis":{"image":"r","ports":[{"target":6379,"published":"6379"}]}}}
assert {**mc._legacy_host_forward(_c), **mc._auto_service_forward(_cfg), **mc._normalize_forward(_c)}=={"6379":"redis"}     # redis 를 compose 로 옮긴 뒤 스테일 선언 → auto 승
assert {**mc._legacy_host_forward(_c), **mc._auto_service_forward({"services":{}}), **mc._normalize_forward(_c)}=={"6379":"host"}   # 아무도 안 서빙 → hostForward 적용
_c2={"forward":{"6379":"redis"},"hostForward":["6379"]}
assert {**mc._legacy_host_forward(_c2), **mc._normalize_forward(_c2)}=={"6379":"redis"}                                     # 같은 포트 → 명시 forward 우선
# --- _forward_summary + _applied_forward: start 성공 시 실제 적용분만 1줄 요약 ---
assert mc._forward_summary({"8081":"be","6379":"host"})=="엮기: localhost:6379→host · localhost:8081→be"
assert mc._forward_summary({})==""
assert mc._applied_forward({"cache":{"image":"redis"}}, ["cache"], {"6379":"host"})=={}                                     # build 서비스 없음 → 사이드카 0 → 요약 없음
assert mc._applied_forward(SV["services"], ["fe","be","cache"], {"6379":"host","8081":"be"})=={"6379":"host","8081":"be"}
assert mc._applied_forward(SV["services"], ["be"], {"8081":"be"})=={}                                                       # be 자기서빙 제외 → 받는 컨테이너 없음
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
