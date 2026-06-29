#!/usr/bin/env bash
# project add --compose <file> 가 kind:compose 를 박고 compose 를 ~/.marina/<id>/ 로 복사한다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
cat > "$P/docker-compose.yml" <<'YML'
services:
  web: { image: "nginx", ports: ["3000:80"] }
YML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" --env-var APP_ENV --env-default local >/dev/null
python3 - "$MARINA_HOME/projects.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))["projects"][0]
assert p.get("kind")=="compose", p
assert p.get("composeFile")=="docker-compose.yml", p
assert p.get("composeEnvVar")=="APP_ENV" and p.get("composeEnvDefault")=="local", p
print("ok registry")
PY
id="$(basename "$P")"
[[ -f "$MARINA_HOME/$id/docker-compose.yml" ]] || { echo "FAIL: compose not copied"; exit 1; }
grep -q "nginx" "$MARINA_HOME/$id/docker-compose.yml" || { echo "FAIL: copy content"; exit 1; }
bash "$SH" project ls | grep -q "compose" || { echo "FAIL: ls no kind"; exit 1; }
echo "PASS test-compose-registry"
