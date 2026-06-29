#!/usr/bin/env bash
# _compose_defined_services: 보관된 compose 의 services 키를 (중지 상태여도) 파싱 → 카드에 행 노출용.
# docker 불요 — 순수 들여쓰기 파싱. 중지된 compose 도 대시보드에서 ▶ 시작할 수 있게 하는 근거.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME/proj1" "$MARINA_HOME/proj2"
cat > "$MARINA_HOME/proj1/docker-compose.yml" <<'YML'
services:
  web:
    build: ./web
    ports: ["8000:8000"]
  api:
    image: nginx
  # 주석 서비스 흉내 — 무시돼야
  worker:
    image: busybox
volumes:
  data: {}
YML
# composeFile 키가 다른 파일명을 가리키는 경우도 존중
cat > "$MARINA_HOME/proj2/compose.dev.yml" <<'YML'
services:
  only:
    image: redis
YML

python3 - "$CTRL" <<'PY' || { echo "FAIL: _compose_defined_services"; exit 1; }
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

got = mc._compose_defined_services({"id": "proj1"})
assert got == ["web", "api", "worker"], got            # volumes: 블록 전에서 멈춤, 주석 무시

got2 = mc._compose_defined_services({"id": "proj2", "composeFile": "compose.dev.yml"})
assert got2 == ["only"], got2                          # composeFile 키 존중

assert mc._compose_defined_services({"id": "nope"}) == []   # 파일 없음 → 빈 목록(예외 안 남)

# compose_service_names: ps 가 비어도(=전부 중지) 정의 서비스를 인식해야 safe_service 통과 → ▶ 시작 가능
import pathlib
import marina_compose_svc as _cs                            # 분리 후 compose_ps 는 compose_svc 네임스페이스
_cs.compose_ps = lambda root, name: []                      # 라이브 컨테이너 0 강제
names = mc.compose_service_names(pathlib.Path("/tmp/marina-test-x"), {"id": "proj1"})
assert set(["web", "api", "worker"]).issubset(set(names)), names
PY
echo "PASS test-compose-dash-defined-services"
