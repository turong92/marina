#!/usr/bin/env bash
# Direct global CLI lifecycle commands must use marina_env, same as dashboard
# lifecycle calls, so host prebuild gets Dockerfile-derived JAVA_HOME.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
EP="$HERE/../scripts/marina-entrypoint.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/marina-entrypoint-env.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export MARINA_HOME="$TMP/marina-home"
export SHELL="/bin/zsh"
FAKE_JDK="$TMP/jdk-21"
mkdir -p "$MARINA_HOME/envproj" "$FAKE_JDK" "$TMP/bin"

ROOT="$TMP/envproj"
mkdir -p "$ROOT/be-api/user-api"
printf 'FROM eclipse-temurin:21\n' > "$ROOT/be-api/user-api/Dockerfile.local"

cat > "$MARINA_HOME/projects.json" <<JSON
{
  "projects": [
    {
      "id": "envproj",
      "root": "$ROOT",
      "subrepos": ["be-api"],
      "kind": "compose",
      "composeFile": "docker-compose.yml"
    }
  ]
}
JSON

CAPTURE="$TMP/prebuild.env"
cat > "$MARINA_HOME/envproj/docker-compose.yml" <<YML
services:
  user-api:
    build: { context: ./be-api/user-api, dockerfile: Dockerfile.local }
x-marina:
  java:
    be-api: "$FAKE_JDK"
  prebuild:
    be-api: 'printf "JAVA_HOME=%s\nMARINA_JAVA_HOMES=%s\n" "\$JAVA_HOME" "\$MARINA_JAVA_HOMES" > "$CAPTURE"; exit 9'
YML

cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
  exit 0
fi
if [[ "${1:-}" == "compose" && "${2:-}" == "version" && "${3:-}" == "--short" ]]; then
  echo "2.24.4"
  exit 0
fi
echo "unexpected fake docker invocation: $*" >&2
exit 99
SH
chmod +x "$TMP/bin/docker"

# Simulate a shell whose default Java is too old. The direct CLI must replace it
# with the Dockerfile-derived SDKMAN JDK 21 before running x-marina.prebuild.
set +e
( cd "$ROOT" && PATH="$TMP/bin:$PATH" JAVA_HOME="$TMP/java-13" bash "$EP" restart user-api ) >/tmp/marina-entrypoint-env.out 2>&1
code=$?
set -e

[[ "$code" -ne 0 ]] || { echo "FAIL: prebuild should stop test with exit 9"; cat /tmp/marina-entrypoint-env.out; exit 1; }
[[ -f "$CAPTURE" ]] || { echo "FAIL: prebuild did not run"; cat /tmp/marina-entrypoint-env.out; exit 1; }

grep -q "JAVA_HOME=$FAKE_JDK" "$CAPTURE" || {
  echo "FAIL: direct CLI did not use marina_env JAVA_HOME"
  echo "--- captured ---"; cat "$CAPTURE"
  echo "--- output ---"; cat /tmp/marina-entrypoint-env.out
  exit 1
}
grep -q '"be-api": "' "$CAPTURE" || {
  echo "FAIL: direct CLI did not pass MARINA_JAVA_HOMES"
  cat "$CAPTURE"
  exit 1
}

echo "PASS test-entrypoint-lifecycle-env"
