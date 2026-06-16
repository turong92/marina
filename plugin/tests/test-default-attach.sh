#!/usr/bin/env bash
# marina.sh default <id> a,b,c — writes registry defaultAttach (subset of subrepos)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P/a/.git" "$P/b/.git" "$P/c/.git"
reg="$MARINA_HOME/projects.json"

bash "$SH" add "$P" --subrepos a,b,c >/dev/null
id="$(python3 -c "import json; print(json.load(open('$reg'))['projects'][0]['id'])")"

# subset
bash "$SH" default "$id" a,b >/dev/null
python3 -c "import json; p=json.load(open('$reg'))['projects'][0]; assert p.get('defaultAttach')==['a','b'],p" \
  || { echo "FAIL: default subset"; exit 1; }

# empty clears to []
bash "$SH" default "$id" "" >/dev/null
python3 -c "import json; p=json.load(open('$reg'))['projects'][0]; assert p.get('defaultAttach')==[],p" \
  || { echo "FAIL: default empty"; exit 1; }

# reject value outside universe — non-zero, registry unchanged
if bash "$SH" default "$id" a,zzz >/dev/null 2>&1; then echo "FAIL: accepted non-universe"; exit 1; fi
python3 -c "import json; p=json.load(open('$reg'))['projects'][0]; assert p.get('defaultAttach')==[],p" \
  || { echo "FAIL: rejected write still mutated registry"; exit 1; }

# unknown id → non-zero
if bash "$SH" default nope a >/dev/null 2>&1; then echo "FAIL: accepted unknown id"; exit 1; fi

echo "PASS test-default-attach"
