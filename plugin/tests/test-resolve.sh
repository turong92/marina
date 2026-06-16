#!/usr/bin/env bash
# test-resolve.sh — resolver returns current installPath and follows version bumps.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/../scripts/marina-resolve.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/.claude"
export CODEX_HOME="$TMP/.codex"   # absent -> skipped
mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
MF="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"

write_manifest() { cat > "$MF" <<JSON
{ "plugins": { "marina@marina-dev": [ { "installPath": "$1" } ] } }
JSON
}

write_manifest "/tmp/fake/v1"
got="$(marina_install_path)"; [[ "$got" == "/tmp/fake/v1" ]] || { echo "FAIL v1: $got"; exit 1; }

write_manifest "/tmp/fake/v2"
got="$(marina_install_path)"; [[ "$got" == "/tmp/fake/v2" ]] || { echo "FAIL v2 (no follow): $got"; exit 1; }

# emit a launcher and assert it is self-contained (no source of plugin files)
marina_emit_launcher "$TMP/marina" entrypoint
[[ -x "$TMP/marina" ]] || { echo "FAIL: shim not executable"; exit 1; }
grep -q 'installed_plugins.json' "$TMP/marina" || { echo "FAIL: shim missing resolver"; exit 1; }
grep -q 'marina-entrypoint.sh' "$TMP/marina" || { echo "FAIL: shim missing exec"; exit 1; }

echo "PASS test-resolve"
