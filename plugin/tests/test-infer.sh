#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P/frontend/.git" "$P/backend/.git" "$P/docs"

out="$(bash "$SH" project infer "$P")"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["subrepos"]==["backend","frontend"],d; assert d["id"]=="proj",d' \
  || { echo "FAIL: infer json wrong: $out"; exit 1; }
[[ ! -f "$MARINA_HOME/projects.json" ]] || { echo "FAIL: infer wrote projects.json"; exit 1; }

M="$TMP/mono"; mkdir -p "$M/src"
out="$(bash "$SH" project infer "$M")"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["subrepos"]==[],d' \
  || { echo "FAIL: mono subrepos not empty: $out"; exit 1; }
echo "PASS test-infer"
