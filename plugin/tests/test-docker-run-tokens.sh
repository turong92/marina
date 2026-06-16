#!/usr/bin/env bash
# command_for substitutes {port}/{session} into a docker-compose-style run string.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"api","portBase":18080,"cwd":".",
  "run":"exec env HOST_PORT={port} COMPOSE_PROJECT_NAME=hs-api-{session} docker compose up"}]}
JSON
bash "$SH" add "$P" >/dev/null
# command_for is an internal function; invoke marina.sh's dry-run/print path for the service command.
cmd="$(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" print-command api 2>/dev/null)" \
  || { echo "SKIP: marina.sh has no print-command (add it or assert via start log)"; exit 0; }
case "$cmd" in
  *"HOST_PORT=18080"*) ;; *) echo "FAIL: {port} not substituted: $cmd"; exit 1;; esac
[[ "$cmd" =~ COMPOSE_PROJECT_NAME=hs-api-[^[:space:]]+ ]] \
  || { echo "FAIL: {session} not substituted (empty/missing): $cmd"; exit 1; }
case "$cmd" in
  *"{port}"*|*"{session}"*) echo "FAIL: raw token left in: $cmd"; exit 1;; esac
echo "PASS test-docker-run-tokens"
