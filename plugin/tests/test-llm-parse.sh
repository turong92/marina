#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"
python3 - "$CTRL" <<'PY' || { echo "FAIL: test-llm-parse"; exit 1; }
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

# 1. bare object
d = mc._extract_service_json('{"name":"web","portBase":3000,"run":"exec x {port}"}')
assert d["name"] == "web", d

# 2. fenced ```json block with surrounding prose
raw = 'Here is the service:\n```json\n{"name":"be","portBase":8080,"run":"exec y {port}"}\n```\nDone.'
d = mc._extract_service_json(raw)
assert d["name"] == "be" and d["portBase"] == 8080, d

# 3. braces inside string values ({port}) do not confuse the scanner
d = mc._extract_service_json('prose {nope} {"name":"w","portBase":1,"run":"a {port} {profile}"}')
assert d["run"] == "a {port} {profile}", d

# 4. no JSON -> ValueError
try:
    mc._extract_service_json("sorry, I could not find a service")
    assert False, "expected ValueError"
except ValueError: pass

# 5. validate: fills cwd default, keeps optionals, rejects junk
v = mc._validate_service_def({"name":" web ","portBase":3000,"run":" exec x "})
assert v == {"name":"web","portBase":3000,"run":"exec x","cwd":"."}, v
v = mc._validate_service_def({"name":"w","portBase":1,"run":"x","cwd":"sub","cachePaths":["sub/.next"],"orphanPattern":"x"})
assert v["cachePaths"] == ["sub/.next"] and v["orphanPattern"] == "x" and v["cwd"] == "sub", v
for bad in [{"portBase":1,"run":"x"}, {"name":"w","run":"x"}, {"name":"w","portBase":True,"run":"x"}, {"name":"w","portBase":1}]:
    try:
        mc._validate_service_def(bad); assert False, ("accepted bad", bad)
    except ValueError: pass

# 6. normalize: single object OR {"services":[...]}
assert len(mc._normalize_candidates({"name":"w","portBase":1,"run":"x"})) == 1
got = mc._normalize_candidates({"services":[{"name":"a","portBase":1,"run":"x"},{"name":"b","portBase":2,"run":"y"}]})
assert [c["name"] for c in got] == ["a","b"], got
PY
echo "PASS test-llm-parse"
