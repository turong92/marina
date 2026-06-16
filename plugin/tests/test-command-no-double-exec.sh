#!/usr/bin/env bash
# command_for must not double-exec: a "VAR=val exec cmd" run (like be/ai) executes cleanly.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
# run mirrors be/ai: env-var prefix + self exec. Must run, not be mangled by an outer exec.
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"smoke","portBase":9988,"cwd":".","run":"FOO=bar exec echo MARKER_OK"}]}
JSON
bash "$SH" add "$P" >/dev/null
cmd="$(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" print-command smoke 2>/dev/null)" \
  || { echo "FAIL: print-command failed"; exit 1; }
out="$(bash -c "$cmd" 2>&1 || true)"
case "$out" in
  *"not found"*) echo "FAIL: double-exec — command not runnable: $out"; exit 1;; esac
case "$out" in
  *MARKER_OK*) ;; *) echo "FAIL: expected MARKER_OK, got: $out"; exit 1;; esac
# also assert the assembled command does not contain a leading "&& exec " wrapping the run
case "$cmd" in
  *"&& exec FOO=bar"*) echo "FAIL: outer exec still wraps env-prefixed run: $cmd"; exit 1;; esac
echo "PASS test-command-no-double-exec"
