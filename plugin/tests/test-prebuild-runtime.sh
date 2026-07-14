#!/usr/bin/env bash
# Service-scoped prebuild runtime: target selection, startGroup, legacy, events, and fail-fast.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MARINA_HOME="$TMP/home" MARINA_GATEWAY=off
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
case "$*" in
  "compose version --short") echo "2.40.3" ;;
  info) exit 0 ;;
  *"config --format json"*) cat "$DOCKER_CONFIG_FIXTURE" ;;
  *"ps --format json"*) echo '[]' ;;
  *"ps --services --status running"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" DOCKER_LOG="$TMP/docker.log"

ROOT="$TMP/project"
mkdir -p "$ROOT/be-api/user-api" "$ROOT/be-api/batch" "$ROOT/web"
touch "$ROOT/be-api/user-api/Dockerfile" "$ROOT/be-api/batch/Dockerfile" "$ROOT/web/Dockerfile"
CAPTURE="$TMP/prebuild.capture"
export CAPTURE

cat > "$ROOT/docker-compose.yml" <<YAML
services:
  user-api:
    build: {context: ./be-api/user-api}
  batch:
    build: {context: ./be-api/batch}
  web:
    build: {context: ./web}
x-marina:
  startGroup: [web, user-api]
  prebuild:
    user-api:
      cwd: be-api
      command: "printf user-api >> '$CAPTURE'"
    batch:
      cwd: be-api
      command: "printf batch >> '$CAPTURE'"
YAML

cat > "$TMP/config.json" <<JSON
{"services":{
  "user-api":{"build":{"context":"$ROOT/be-api/user-api","dockerfile":"Dockerfile"}},
  "batch":{"build":{"context":"$ROOT/be-api/batch","dockerfile":"Dockerfile"}},
  "web":{"build":{"context":"$ROOT/web","dockerfile":"Dockerfile"}}
}}
JSON
export DOCKER_CONFIG_FIXTURE="$TMP/config.json"

bash "$SH" project add "$ROOT" --compose "$ROOT/docker-compose.yml" >/dev/null
mrun() {
  (cd "$ROOT" && MARINA_HOME="$MARINA_HOME" MARINA_GATEWAY=off PATH="$TMP/bin:$PATH" \
    DOCKER_LOG="$DOCKER_LOG" DOCKER_CONFIG_FIXTURE="$DOCKER_CONFIG_FIXTURE" CAPTURE="$CAPTURE" \
    bash "$SH" "$@")
}

: > "$CAPTURE"; : > "$DOCKER_LOG"
mrun start --user-api > "$TMP/user.log" 2>&1
[[ "$(cat "$CAPTURE")" == "user-api" ]] || {
  echo "FAIL: service object prebuild selection"; cat "$TMP/user.log"; exit 1;
}
grep -Eq 'MARINA_PREBUILD_EVENT .*"services": \["user-api"\].*"status": "success"' "$TMP/user.log" || {
  echo "FAIL: structured success event"; cat "$TMP/user.log"; exit 1;
}

: > "$CAPTURE"; : > "$DOCKER_LOG"
mrun start --all > "$TMP/all.log" 2>&1
[[ "$(cat "$CAPTURE")" == "user-api" ]] || {
  echo "FAIL: startGroup prebuild selection"; cat "$TMP/all.log"; exit 1;
}

python3 - "$MARINA_HOME/project/docker-compose.yml" "$CAPTURE" <<'PY'
import sys, yaml
path, capture = sys.argv[1:]
data = yaml.safe_load(open(path, encoding="utf-8"))
data["x-marina"]["prebuild"] = {
    "be-api": f"printf legacy >> '{capture}'",
    "unused": "false",
}
open(path, "w", encoding="utf-8").write(yaml.safe_dump(data, sort_keys=False))
PY
: > "$CAPTURE"
mrun start --user-api > "$TMP/legacy.log" 2>&1
[[ "$(cat "$CAPTURE")" == "legacy" ]] || {
  echo "FAIL: legacy prebuild selection"; cat "$TMP/legacy.log"; exit 1;
}

python3 - "$MARINA_HOME/project/docker-compose.yml" <<'PY'
import sys, yaml
path = sys.argv[1]
data = yaml.safe_load(open(path, encoding="utf-8"))
data["x-marina"]["prebuild"] = {
    "user-api": {"cwd": "be-api", "command": "API_TOKEN=prebuild-secret-value; exit 9"},
}
open(path, "w", encoding="utf-8").write(yaml.safe_dump(data, sort_keys=False))
PY
: > "$DOCKER_LOG"
if mrun start --user-api > "$TMP/fail.log" 2>&1; then
  echo "FAIL: failed prebuild should stop lifecycle"; cat "$TMP/fail.log"; exit 1
fi
grep -q '"status": "failed"' "$TMP/fail.log" || {
  echo "FAIL: structured failure event"; cat "$TMP/fail.log"; exit 1;
}
if grep -q 'prebuild-secret-value' "$TMP/fail.log"; then
  echo "FAIL: structured prebuild event exposed command secret"; cat "$TMP/fail.log"; exit 1
fi
if grep -q ' up -d ' "$DOCKER_LOG"; then
  echo "FAIL: compose up ran after prebuild failure"; cat "$DOCKER_LOG"; exit 1
fi

echo "PASS test-prebuild-runtime"
