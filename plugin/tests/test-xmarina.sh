#!/usr/bin/env bash
# x-marina 파서/직렬화 왕복: compose YAML 의 x-marina 확장(prebuild·links·forward·gateway)을
# dict 로 읽고(parse_xmarina), 다시 compose YAML 로 쓴 뒤(serialize_xmarina) 재파싱하면 동일.
# docker 비의존(PyYAML 직접) — 팀원 붙여넣기 blob 도 docker 없이 검증 가능해야 함.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CC="$HERE/../scripts/marina-compose.py"

python3 - "$CC" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

COMPOSE = """\
services:
  user-api:
    build:
      context: ./be-api/user-api
      dockerfile: DockerFile
      args:
        PROFILE: local
    expose: ["8081"]
x-marina:
  prebuild:
    be-api: ./gradlew assemble
  links:
    symlink: [node_modules, .venv]
    copy: ["**/*local.yml", ".env*.local"]
  forward:
    "6379": {target: host}
  gateway:
    routes:
      user-api: ["/v1.0"]
"""

# x-marina 키는 전부 string — docker compose config 가 확장 맵의 비-string 키 거부(forward 포트)
EXPECTED = {
    "prebuild": {"be-api": "./gradlew assemble"},
    "links": {"symlink": ["node_modules", ".venv"], "copy": ["**/*local.yml", ".env*.local"]},
    "forward": {"6379": {"target": "host"}},
    "gateway": {"routes": {"user-api": ["/v1.0"]}},
}

# 1) parse_xmarina: compose 텍스트 → x-marina dict
got = mc.parse_xmarina(COMPOSE)
assert got == EXPECTED, ("parse_xmarina 불일치", got)

# 2) x-marina 없는 compose → {}
NOXM = "services:\n  app:\n    build: .\n"
assert mc.parse_xmarina(NOXM) == {}, ("x-marina 없으면 {} 여야", mc.parse_xmarina(NOXM))

# 3) serialize_xmarina 왕복: (services, xmarina) → YAML → 재파싱 동일
import yaml
services = yaml.safe_load(COMPOSE)["services"]
out = mc.serialize_xmarina(services, EXPECTED)
assert isinstance(out, str) and out.strip(), "serialize_xmarina 는 비지 않은 str"
assert mc.parse_xmarina(out) == EXPECTED, ("왕복 x-marina 불일치", mc.parse_xmarina(out))
# services 도 보존(유효 compose)
assert yaml.safe_load(out)["services"] == services, ("왕복 services 불일치", yaml.safe_load(out).get("services"))

# 4) 빈 x-marina 직렬화 → 재파싱 {}
out0 = mc.serialize_xmarina(services, {})
assert mc.parse_xmarina(out0) == {}, ("빈 x-marina 왕복", mc.parse_xmarina(out0))

# 5) int 포트 키 → serialize 가 string 으로 강제(docker compose config 가 비-string 확장 키 거부)
out_int = mc.serialize_xmarina(services, {"forward": {6379: {"target": "host"}}})
assert '"6379"' in out_int or "'6379'" in out_int or "6379:" in out_int, out_int
assert mc.parse_xmarina(out_int) == {"forward": {"6379": {"target": "host"}}}, mc.parse_xmarina(out_int)
assert "6379" in mc.parse_xmarina(out_int)["forward"], "포트 키가 string '6379' 여야"

print("ok")
PY

echo "PASS test-xmarina"
