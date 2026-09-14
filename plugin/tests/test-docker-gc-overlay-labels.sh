#!/usr/bin/env bash
# MARINA_E2E=1 이면 compose 오버레이가 라벨 marina.e2e=1 을 서비스(컨테이너)·build(이미지)·네트워크에 붙인다.
# 평소(env 없음)엔 오버레이에 라벨이 한 글자도 안 들어간다. external 네트워크는 건드리지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

python3 - "$HERE/../scripts/marina-compose.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

cfg = {"services": {"app": {"build": {"context": "/x", "dockerfile": "Dockerfile"}}, "redis": {"image": "redis:7"}}}
plain = mc.build_overlay(cfg)
assert "marina.e2e" not in plain, plain                                  # 평소엔 불변
lab = mc.build_overlay(cfg, extra_labels={"marina.e2e": "1"})
print(lab)
assert lab.count('"marina.e2e": "1"') == 4, lab                          # app 컨테이너 + app 이미지 + redis 컨테이너 + default 네트워크
app = lab.split("  app:")[1].split("  redis:")[0]
assert "    build:" in app and '      context: "/x"' in app and "      labels:" in app, app   # build 블록엔 context 보존 + labels
assert "\n    labels:\n" in app, app
red = lab.split("  redis:")[1].split("networks:")[0]
assert "build:" not in red and "    labels:" in red, red                 # image-only 는 컨테이너 라벨만
assert "networks:\n  default:\n    labels:" in lab, lab

# external 네트워크는 제외, 선언된 비-external 만
cfg2 = {"services": {"a": {"image": "x"}}, "networks": {"shared": {"external": True, "name": "shared"}, "mine": {}}}
lab2 = mc.build_overlay(cfg2, extra_labels={"marina.e2e": "1"})
assert "  mine:\n    labels:" in lab2 and "shared" not in lab2 and "default" not in lab2, lab2

# 엮기 사이드카에도 라벨
cfg3 = {"services": {"app": {"build": {"context": "/x"}, "ports": ["3000"]}, "be": {"image": "y"}}}
lab3 = mc.build_overlay(cfg3, connectivity={"forward": {"8081": "be"}}, extra_labels={"marina.e2e": "1"})
side = lab3.split("  app-bind:")[1]
assert "    labels:" in side, side

# env 배선 — 하네스가 세운 MARINA_E2E=1 을 up 이 읽는다
assert mc.e2e_extra_labels({"MARINA_E2E": "1"}) == {"marina.e2e": "1"}
assert mc.e2e_extra_labels({}) is None and mc.e2e_extra_labels({"MARINA_E2E": "0"}) is None
assert mc.e2e_extra_labels() == {"marina.e2e": "1"}, "하네스가 MARINA_E2E=1 을 export 해야 한다"
src = open(sys.argv[1], encoding="utf-8").read()
assert "extra_labels=e2e_extra_labels()" in src, "up 이 e2e_extra_labels() 를 build_overlay 에 안 넘긴다"
print("ok")
PY
echo "PASS test-docker-gc-overlay-labels"
