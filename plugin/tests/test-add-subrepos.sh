#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P/frontend/.git" "$P/backend/.git" "$P/extra/.git" "$P/docs"
reg="$MARINA_HOME/projects.json"

# no flag → infer all (sorted)
bash "$SH" add "$P" >/dev/null
python3 -c "import json; p=json.load(open('$reg'))['projects'][0]; assert p['subrepos']==['backend','extra','frontend'],p" \
  || { echo "FAIL: add without flag should infer all"; exit 1; }

# --subrepos curated subset + upsert (still one project)
bash "$SH" add "$P" --subrepos backend,frontend >/dev/null
python3 -c "import json; d=json.load(open('$reg')); assert len(d['projects'])==1,d; assert d['projects'][0]['subrepos']==['backend','frontend'],d['projects'][0]" \
  || { echo "FAIL: --subrepos curated set / upsert"; exit 1; }

# --subrepos "" explicit empty (monorepo)
bash "$SH" add "$P" --subrepos "" >/dev/null
python3 -c "import json; assert json.load(open('$reg'))['projects'][0]['subrepos']==[]" \
  || { echo "FAIL: --subrepos empty should record []"; exit 1; }

# whitespace + stray names tolerated (trimmed, blanks dropped)
bash "$SH" add "$P" --subrepos " backend , frontend ," >/dev/null
python3 -c "import json; assert json.load(open('$reg'))['projects'][0]['subrepos']==['backend','frontend']" \
  || { echo "FAIL: --subrepos should trim and drop blanks"; exit 1; }

echo "PASS test-add-subrepos"
