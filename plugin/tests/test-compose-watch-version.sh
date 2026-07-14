#!/usr/bin/env bash
# Compose Watch feature gates are service-scoped and run before prebuild/up.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$HERE/../scripts/marina-compose.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("marina_compose", sys.argv[1])
mc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mc)

config = {"services": {
    "web": {"develop": {"watch": [{"action": "sync", "path": ".", "target": "/app"}]}},
    "api": {"develop": {"watch": [{"action": "sync+restart", "path": ".", "target": "/app"}]}},
    "worker": {"develop": {"watch": [{"action": "restart", "path": "./build"}]}},
    "tool": {"develop": {"watch": [{"action": "sync+exec", "path": ".", "target": "/app", "exec": {"command": "true"}}]}},
}}
assert mc.watch_version_errors(config, ["web"], "2.24.4") == []
assert mc.watch_version_errors(config, ["api"], "2.22.0")
assert mc.watch_version_errors(config, ["worker"], "2.31.9")
assert mc.watch_version_errors(config, ["worker"], "2.32.0") == []
assert mc.watch_version_errors(config, ["tool"], "2.32.1")
assert mc.watch_version_errors(config, ["tool"], "2.32.2") == []
assert mc.watch_version_errors(config, ["web"], "v2.40.3-desktop.1") == []

dependency_config = {"services": {
    "frontend": {"image": "frontend", "depends_on": ["worker"]},
    "worker": {"image": "worker", "depends_on": ["database"]},
    "database": {"image": "database", "develop": {"watch": [{"action": "restart", "path": "./build"}]}},
}}
dependency_targets, _, _ = mc.resolved_start_targets(dependency_config, {}, ["frontend"])
assert dependency_targets == ["frontend", "worker", "database"], dependency_targets
assert mc.watch_version_errors(dependency_config, dependency_targets, "2.31.9")
print("version matrix ok")
PY

export MARINA_HOME="$TMP/home" MARINA_GATEWAY=off
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
case "$*" in
  "compose version --short") echo "${COMPOSE_VERSION:-2.31.9}" ;;
  info) exit 0 ;;
  *"config --format json"*) cat "$DOCKER_CONFIG_FIXTURE" ;;
  *"ps --format json"*) echo '[]' ;;
  *"ps --services --status running"*) exit 0 ;;
  *"watch --no-up"*) sleep 30 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" DOCKER_LOG="$TMP/docker.log" COMPOSE_VERSION=2.31.9

ROOT="$TMP/project"
mkdir -p "$ROOT/web" "$ROOT/worker"
touch "$ROOT/web/Dockerfile" "$ROOT/worker/Dockerfile"
CAPTURE="$TMP/prebuild.capture"
cat > "$ROOT/docker-compose.yml" <<YAML
services:
  web: {build: {context: ./web}}
  worker: {build: {context: ./worker}}
x-marina:
  prebuild:
    worker:
      cwd: worker
      command: "printf ran > '$CAPTURE'"
YAML
cat > "$TMP/config.json" <<JSON
{"services":{
  "web":{"build":{"context":"$ROOT/web","dockerfile":"Dockerfile"},"develop":{"watch":[{"action":"sync","path":"$ROOT/web","target":"/app"}]}},
  "worker":{"build":{"context":"$ROOT/worker","dockerfile":"Dockerfile"},"develop":{"watch":[{"action":"restart","path":"$ROOT/worker/build"}]}}
}}
JSON
export DOCKER_CONFIG_FIXTURE="$TMP/config.json"
bash "$SH" project add "$ROOT" --compose "$ROOT/docker-compose.yml" >/dev/null
mrun() {
  (cd "$ROOT" && MARINA_HOME="$MARINA_HOME" MARINA_GATEWAY=off PATH="$TMP/bin:$PATH" \
    DOCKER_LOG="$DOCKER_LOG" DOCKER_CONFIG_FIXTURE="$DOCKER_CONFIG_FIXTURE" \
    COMPOSE_VERSION="$COMPOSE_VERSION" bash "$SH" "$@")
}

: > "$DOCKER_LOG"
mrun start --web > "$TMP/web.log" 2>&1
grep -q ' up -d .* web' "$DOCKER_LOG" || {
  echo "FAIL: supported selected service did not start"; cat "$TMP/web.log" "$DOCKER_LOG"; exit 1;
}

: > "$DOCKER_LOG"; rm -f "$CAPTURE"
if mrun start --worker > "$TMP/worker.log" 2>&1; then
  echo "FAIL: unsupported restart action should fail"; cat "$TMP/worker.log"; exit 1
fi
grep -q "service 'worker'.*restart.*2.32.0.*2.31.9" "$TMP/worker.log" || {
  echo "FAIL: actionable version error missing"; cat "$TMP/worker.log"; exit 1;
}
[[ ! -e "$CAPTURE" ]] || { echo "FAIL: prebuild ran before version gate"; exit 1; }
if grep -q ' up -d ' "$DOCKER_LOG"; then
  echo "FAIL: compose up ran after version gate failure"; cat "$DOCKER_LOG"; exit 1
fi

echo "PASS test-compose-watch-version"
