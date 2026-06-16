#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DASH="$HERE/../scripts/marina-dashboard.sh"

run_case() {  # $1=uname-output  $2=expected supervisor
  local os="$1" exp="$2" TMP; TMP="$(mktemp -d)"
  export MARINA_HOME="$TMP/.marina" HOME="$TMP" CLAUDE_CONFIG_DIR="$TMP/.claude"
  mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
  cat > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" <<JSON
{ "plugins": { "marina@marina-dev": [ { "installPath": "$TMP/plug" } ] } }
JSON
  local FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
  printf '#!/usr/bin/env bash\necho %s\n' "$os" > "$FAKE/uname"; chmod +x "$FAKE/uname"
  if [[ "$exp" == systemd ]]; then
    for c in systemctl loginctl; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$c"; chmod +x "$FAKE/$c"; done
  fi
  if [[ "$exp" == launchd ]]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/launchctl"; chmod +x "$FAKE/launchctl"
  fi

  local out
  out="$(PATH="$FAKE:$PATH" MARINA_DRY_RUN=1 bash "$DASH" start 2>&1)"
  echo "$out" | grep -q "supervisor=$exp" || { echo "FAIL[$os]: not $exp: $out"; exit 1; }
  [[ -x "$MARINA_HOME/dashboard-launch.sh" ]] || { echo "FAIL[$os]: launcher missing"; exit 1; }
  grep -q "$TMP/plug/scripts/marina-control.py" "$MARINA_HOME/dashboard-launch.sh" && { echo "FAIL[$os]: launcher baked version path"; exit 1; }

  if [[ "$exp" == systemd ]]; then
    local U="$HOME/.config/systemd/user/marina-dashboard.service"
    [[ -f "$U" ]] || { echo "FAIL: unit missing"; exit 1; }
    grep -q "ExecStart=$MARINA_HOME/dashboard-launch.sh" "$U" || { echo "FAIL: ExecStart not launcher"; exit 1; }
  fi
  if [[ "$exp" == launchd ]]; then
    local P="$MARINA_HOME/marina.dashboard.plist"
    [[ -f "$P" ]] || { echo "FAIL: plist missing"; exit 1; }
    grep -q "$MARINA_HOME/dashboard-launch.sh" "$P" || { echo "FAIL: plist not pointing at launcher"; exit 1; }
    grep -q 'marina-control.py' "$P" && { echo "FAIL: plist still references control.py"; exit 1; }
  fi
  rm -rf "$TMP"
}

# Regression (review #1): production reaches this script via the resolver, so $SCRIPT_DIR is
# the versioned (<SHA>) plugin dir. Run a copy from a fake versioned dir and assert NO
# versioned path leaks into the launchd plist (WorkingDirectory used to bake $SCRIPT_DIR).
assert_no_versioned_path_in_plist() {
  local TMP; TMP="$(mktemp -d)"
  export MARINA_HOME="$TMP/.marina" HOME="$TMP" CLAUDE_CONFIG_DIR="$TMP/.claude"
  mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
  cat > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" <<JSON
{ "plugins": { "marina@marina-dev": [ { "installPath": "$TMP/plug" } ] } }
JSON
  local SHA="deadbeef0000" VDIR="$TMP/cache/marina-dev/marina/deadbeef0000/scripts"
  mkdir -p "$VDIR"
  cp "$HERE/../scripts/marina-dashboard.sh" "$HERE/../scripts/marina-resolve.sh" "$VDIR/"
  local FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$FAKE/uname"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/launchctl"
  chmod +x "$FAKE/"*
  PATH="$FAKE:$PATH" MARINA_DRY_RUN=1 bash "$VDIR/marina-dashboard.sh" start >/dev/null 2>&1
  local P="$MARINA_HOME/marina.dashboard.plist"
  [[ -f "$P" ]] || { echo "FAIL[versioned]: plist missing"; exit 1; }
  grep -q "$SHA" "$P" && { echo "FAIL[versioned]: plist bakes the versioned plugin dir ($SHA)"; exit 1; }
  rm -rf "$TMP"
}

run_case Linux  systemd
run_case Darwin launchd
assert_no_versioned_path_in_plist
echo "PASS test-dashboard-launch"
