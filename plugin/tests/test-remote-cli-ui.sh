#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MARINA_HOME="$TMP/home"
export MARINA_AUTH_DB="$MARINA_HOME/auth.db"
export MARINA_AUTH_PBKDF2_ITERATIONS=1000
export MARINA_TAILSCALE_BIN="$TMP/missing-tailscale"

PYTHONPATH="$SCR" python3 - <<'PY'
import os
from pathlib import Path
from marina_auth import AuthStore
store = AuthStore(Path(os.environ["MARINA_AUTH_DB"]), pbkdf2_iterations=1000)
store.bootstrap_admin("owner", "Owner", "owner-password")
PY

status="$($SCR/marina-entrypoint.sh remote status)"
grep -q '^state=unavailable$' <<<"$status"
grep -q '^installed=false$' <<<"$status"
if MARINA_REMOTE_NO_RESTART=1 "$SCR/marina-entrypoint.sh" remote serve >/dev/null 2>&1; then
  echo "FAIL: remote serve succeeded without Tailscale"
  exit 1
fi

node --check "$SCR/marina-web/app-6d-remote.js"
grep -q 'id="remoteAccessDialog"' "$SCR/marina-web/index.html"
grep -q 'id="remotePublicStatus"' "$SCR/marina-web/index.html"
grep -q "mutate('funnel')" "$SCR/marina-web/app-6d-remote.js"

echo "PASS test-remote-cli-ui"
