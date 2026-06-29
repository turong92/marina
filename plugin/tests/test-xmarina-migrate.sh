#!/usr/bin/env bash
# 마이그레이션: 흩어진 레거시 JSON(build-args/prebuild/links/backing) → x-marina 로 합쳐 노출.
# 비파괴 — 레거시 파일 보존(롤백 가능). docker 불요(함수 직접).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
PID="proj"; PD="$MARINA_HOME/$PID"; mkdir -p "$PD"
ROOT="$TMP/wt"; mkdir -p "$ROOT"
# stored compose (x-marina 없음) + 흩어진 레거시 JSON
cat > "$PD/docker-compose.yml" <<'YAML'
services:
  be:
    build: ./be-api
    expose: ["8081"]
    networks: [backend]
networks:
  backend:
    driver: bridge
YAML
echo '{"be":{"PROFILE":"local"}}' > "$PD/build-args.json"
echo '{"be-api":"./gradlew assemble"}' > "$PD/prebuild.json"
echo '{"links":{"mylib":{"glob":"mylib","kind":"dir"}}}' > "$PD/links.json"
echo '{"forward":{"6379":{"target":"host"}},"gatewayRoutes":{"be":["/v1.0"]}}' > "$PD/backing.json"
cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"$PID","root":"$ROOT","kind":"compose","composeFile":"docker-compose.yml"}]}
JSON

python3 - "$CTRL" "$ROOT" "$PID" <<'PY'
import importlib.util, sys, json
spec=importlib.util.spec_from_file_location("mctl", sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
from pathlib import Path
root=Path(sys.argv[2]); pid=sys.argv[3]
# 1) _migrate_to_xmarina — 흩어진 JSON → x-marina dict
xm = m._migrate_to_xmarina(pid)
assert xm.get("prebuild")=={"be-api":"./gradlew assemble"}, xm
assert xm.get("forward")=={"6379":{"target":"host"}}, xm
assert (xm.get("gateway") or {}).get("routes")=={"be":["/v1.0"]}, xm
assert "mylib" in (xm.get("links") or {}).get("symlink", []), xm   # links.json custom → symlink
# 2) unified_compose_yaml — 합쳐진 compose 반환(원래 동작 동일 정보)
proj = m.project_for(root)
yml = m.unified_compose_yaml(root, proj)
back = m._mc().parse_xmarina(yml)
assert back.get("prebuild")=={"be-api":"./gradlew assemble"}, back
assert back.get("forward")=={"6379":{"target":"host"}}, back
import yaml
doc = yaml.safe_load(yml)
svcs = doc["services"]
assert svcs["be"]["build"]["args"]=={"PROFILE":"local"}, ("build-args 통합", svcs["be"])  # build-args.json → build.args
assert (doc.get("networks") or {}).get("backend"), ("top-level networks 보존", doc.get("networks"))  # codex P2: top-level 섹션 안 드롭
print("ok migrate")
PY

# 3) 레거시 JSON 보존(비파괴)
for f in build-args.json prebuild.json links.json backing.json; do
  [[ -f "$PD/$f" ]] || { echo "FAIL: 레거시 $f 삭제됨(비파괴여야)"; exit 1; }
done

echo "PASS test-xmarina-migrate"
