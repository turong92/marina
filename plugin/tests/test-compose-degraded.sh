#!/usr/bin/env bash
# Dockerfile 없는 build 서비스 하나 때문에 전체를 막지 않는다 —
# 검증은 경고(부분 등록 허용), 기동은 그 서비스만 제외하고 나머지는 띄운다(startable_services).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CC="$HERE/../scripts/marina-compose.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/app1" "$TMP/app2"
: > "$TMP/app1/Dockerfile"        # app1 = Dockerfile 있음(OK), app2 = 없음(degraded)
python3 - "$CC" "$TMP" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tmp = sys.argv[2]
config = {"services": {
    "app1": {"build": {"context": tmp + "/app1"}},   # Dockerfile 있음
    "app2": {"build": {"context": tmp + "/app2"}},   # Dockerfile 없음 → degraded
    "web":  {"image": "nginx"},                      # build 없음 → 항상 기동 대상
}}
miss = m.missing_dockerfile_services(config)
assert set(miss) == {"app2"}, miss                   # app2 만 누락으로 잡힘

# 전체 기동(--service 없음): app2 만 빠지고 app1·web 은 뜬다 (하나 깨졌다고 전체 막지 않음)
startable, skipped = m.startable_services(config, [])
assert startable == ["app1", "web"], startable
assert set(skipped) == {"app2"}, skipped

# 특정 서비스 지정도 동일 필터 — degraded 는 제외, 정상은 통과
startable2, skipped2 = m.startable_services(config, ["app2", "web"])
assert startable2 == ["web"], startable2
assert set(skipped2) == {"app2"}, skipped2

# .workspace/external: 검증(skip_external=True)은 제외, 기동(skip_external=False)은 확인(코덱스 리뷰 #1)
ext = {"services": {"svc": {"build": {"context": tmp + "/.workspace/external/foo"}}}}
assert m.missing_dockerfile_services(ext, skip_external=True) == {}, "검증은 external 제외"
assert set(m.missing_dockerfile_services(ext, skip_external=False)) == {"svc"}, "기동은 external 확인"

# depends_on: 정상 app1 이 degraded app2 를 의존 → app1 도 startable 에서 빠진다(코덱스 리뷰 #3)
dep = {"services": {
    "app1": {"build": {"context": tmp + "/app1"}, "depends_on": ["app2"]},   # app1 자체는 Dockerfile 있음
    "app2": {"build": {"context": tmp + "/app2"}},                            # 없음 → degraded
    "web":  {"image": "nginx"},
}}
s3, sk3 = m.startable_services(dep, [])
assert s3 == ["web"], s3                          # app1 은 app2 의존이라 제외, web 만 기동
assert set(sk3) == {"app1", "app2"}, sk3
# depends_on dict 형식({svc:{condition}})도 closure 에 포함
dep2 = {"services": {"a": {"build": {"context": tmp + "/app2"}},
                     "b": {"image": "x", "depends_on": {"a": {"condition": "service_started"}}}}}
s4, _ = m.startable_services(dep2, [])
assert s4 == [], s4                               # a degraded, b 가 a 의존 → 둘 다 제외
print("ok degraded partial-start")
PY
echo "PASS test-compose-degraded"
