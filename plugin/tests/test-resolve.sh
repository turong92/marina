#!/usr/bin/env bash
# test-resolve.sh — resolver picks the install dir that actually has scripts/ (Claude installPath,
# Codex config.toml source/plugin), follows version bumps, and the emitted shim bakes a fallback.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/../scripts/marina-resolve.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/.claude"
export CODEX_HOME="$TMP/.codex"
mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
MF="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"

mkinstall() { mkdir -p "$1/scripts"; : > "$1/scripts/marina-entrypoint.sh"; }   # 유효 설치 흉내
write_manifest() { mkinstall "$1"; cat > "$MF" <<JSON
{ "plugins": { "marina@marina-dev": [ { "installPath": "$1" } ] } }
JSON
}

write_manifest "$TMP/v1"
got="$(marina_install_path)"; [[ "$got" == "$TMP/v1" ]] || { echo "FAIL v1: $got"; exit 1; }
write_manifest "$TMP/v2"   # 버전 bump 따라감
got="$(marina_install_path)"; [[ "$got" == "$TMP/v2" ]] || { echo "FAIL v2 (no follow): $got"; exit 1; }

# 매니페스트 경로에 scripts/ 없으면 무시(잘못된 경로로 exec 방지)
write_manifest "$TMP/v2"; rm -rf "$TMP/v2/scripts"
marina_install_path >/dev/null 2>&1 && { echo "FAIL: resolved a path without scripts/"; exit 1; } || true

# Codex: config.toml [marketplaces.marina-dev] source → <source>/plugin (claude 매니페스트 없음)
rm -f "$MF"
mkinstall "$TMP/mkt/plugin"
mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<TOML
[marketplaces.marina-dev]
source = "$TMP/mkt"
[plugins."marina@marina-dev"]
TOML
got="$(marina_install_path)"; [[ "$got" == "$TMP/mkt/plugin" ]] || { echo "FAIL codex source: $got"; exit 1; }

# 둘 다 없으면 해석 실패(거짓 양성 없음)
rm -f "$CODEX_HOME/config.toml"
marina_install_path >/dev/null 2>&1 && { echo "FAIL: resolved with no manifest"; exit 1; } || true

# emit launcher: self-contained(resolver+exec+codex) + baked fallback(매니페스트 다 없어도 emit 시점 경로)
write_manifest "$TMP/v3"
marina_emit_launcher "$TMP/marina" entrypoint
[[ -x "$TMP/marina" ]] || { echo "FAIL: shim not executable"; exit 1; }
grep -q 'installed_plugins.json' "$TMP/marina" || { echo "FAIL: shim missing resolver"; exit 1; }
grep -q 'marina-entrypoint.sh' "$TMP/marina" || { echo "FAIL: shim missing exec"; exit 1; }
grep -q 'config.toml' "$TMP/marina" || { echo "FAIL: shim missing codex resolver"; exit 1; }
real_plugin="$(cd "$HERE/.." && pwd -P)"
ip="$(sed 's|^exec .*|echo "$ip"|' "$TMP/marina" | CLAUDE_CONFIG_DIR=/nope CODEX_HOME=/nope bash)"
[[ "$ip" == "$real_plugin" ]] || { echo "FAIL: baked fallback: '$ip' != '$real_plugin'"; exit 1; }

echo "PASS test-resolve"
