#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
ENTRY="$SCR/marina-entrypoint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
export MARINA_AUTH_DB="$MARINA_HOME/auth.db"
export MARINA_AUTH_PBKDF2_ITERATIONS=1000

status_out="$($ENTRY auth status)"
grep -q '^enabled=false$' <<<"$status_out"

$ENTRY user add teammate --name 'Team Mate' | grep -q 'teammate'
$ENTRY user list | grep -q $'teammate\tmember\tunclaimed'
if $ENTRY user approve teammate >/dev/null 2>&1; then
  echo "FAIL: approve unexpectedly succeeded before claim"
  exit 1
fi

PYTHONPATH="$SCR" python3 - <<'PY'
import os
from pathlib import Path
from marina_auth import AuthStore

store = AuthStore(Path(os.environ["MARINA_AUTH_DB"]), pbkdf2_iterations=1000)
store.initialize()
store.bootstrap_admin("owner", "Owner", "owner-password")
store.claim_user("teammate", "teammate-password")
PY

$ENTRY user approve teammate | grep -q $'teammate\tmember\tactive'
$ENTRY user reset-password teammate | grep -q $'teammate\tmember\tunclaimed'

if $ENTRY auth disable >/dev/null 2>&1; then
  echo "FAIL: auth disable succeeded without --yes"
  exit 1
else
  [[ "$?" == "2" ]]
fi

printf 'new-owner-password\n' | $ENTRY auth reset-admin owner --password-stdin | grep -q 'owner'
PYTHONPATH="$SCR" python3 - <<'PY'
import os
from pathlib import Path
from marina_auth import AuthStore

store = AuthStore(Path(os.environ["MARINA_AUTH_DB"]), pbkdf2_iterations=1000)
assert store.authenticate("owner", "new-owner-password").status == "active"
session = store.create_session(store.authenticate("owner", "new-owner-password").id)
assert store.resolve_session(session.token)
PY

$ENTRY auth disable --yes | grep -q 'enabled=false'
$ENTRY auth status | grep -q '^enabled=false$'
PYTHONPATH="$SCR" python3 - <<'PY'
import os, sqlite3
from pathlib import Path

db = Path(os.environ["MARINA_AUTH_DB"])
with sqlite3.connect(db) as conn:
    assert conn.execute("select count(*) from auth_sessions").fetchone()[0] == 0
    assert conn.execute("select count(*) from users where status != 'unclaimed'").fetchone()[0] == 0
    assert conn.execute("select count(*) from users where password_hash is not null").fetchone()[0] == 0
    assert conn.execute("select count(*) from audit_events").fetchone()[0] > 0
PY

echo "PASS test-auth-cli"
