#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"web","portBase":3000,"cwd":".","run":"exec echo TEAM_WEB {port}"}]}
JSON
bash "$SH" add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
mkdir -p "$MARINA_HOME/services"
cat > "$MARINA_HOME/services/$id.json" <<'JSON'
{"services":[{"name":"web","portBase":3000,"cwd":".","run":"exec echo MY_WEB {port}"}]}
JSON
cmd="$(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" print-command web 2>/dev/null)"
case "$cmd" in *MY_WEB*) ;; *) echo "FAIL: launcher did not merge central override: $cmd"; exit 1;; esac
echo "PASS test-launcher-merge"
