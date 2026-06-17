#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/proj"; mkdir -p "$P"

# fake LLM: emits the contents of $MARINA_HOME/out-<callcount>, falling back to out-1
cat > "$TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
c="$MARINA_HOME/calls"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
f="$MARINA_HOME/out-$n"; [[ -f "$f" ]] || f="$MARINA_HOME/out-1"; cat "$f"
EOF
chmod +x "$TMP/fake.sh"; export MARINA_LLM_FAKE="$TMP/fake.sh"

# valid on first call
printf '%s' '```json
{"name":"web","portBase":5173,"run":"exec npm run dev -- --port {port}"}
```' > "$MARINA_HOME/out-1"
rm -f "$MARINA_HOME/calls"
python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: analyze valid"; exit 1; }
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
got = mc.llm_analyze(Path(sys.argv[2]))
assert got[0]["name"] == "web" and got[0]["portBase"] == 5173, got
PY

# garbage on call 1, valid on call 2 -> retry succeeds (exactly 2 calls)
printf '%s' 'no json here' > "$MARINA_HOME/out-1"
printf '%s' '{"name":"be","portBase":8080,"run":"exec x {port}"}' > "$MARINA_HOME/out-2"
rm -f "$MARINA_HOME/calls"
python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: analyze retry"; exit 1; }
import importlib.util, sys, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
got = mc.llm_analyze(Path(sys.argv[2]))
assert got[0]["name"] == "be", got
assert open(os.path.join(os.environ["MARINA_HOME"], "calls")).read().strip() == "2"
PY

# garbage on both calls -> ValueError (no third call)
printf '%s' 'nope' > "$MARINA_HOME/out-1"; rm -f "$MARINA_HOME/out-2" "$MARINA_HOME/calls"
python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: analyze giveup"; exit 1; }
import importlib.util, sys, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
try:
    mc.llm_analyze(Path(sys.argv[2])); assert False, "expected ValueError"
except ValueError: pass
assert open(os.path.join(os.environ["MARINA_HOME"], "calls")).read().strip() == "2"
PY
# sibling-port awareness: _analyze_prompt lists siblings + {<name>_port} guidance; omits when none
python3 - "$CTRL" <<'PY' || { echo "FAIL: analyze prompt siblings"; exit 1; }
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
p = mc._analyze_prompt(Path("/x"), "", "", None, None, ["api", "worker"])
assert "api" in p and "worker" in p and "{<name>_port}" in p and "{api_port}" in p, p
p0 = mc._analyze_prompt(Path("/x"), "", "", None, None, [])
assert "{<name>_port}" not in p0, p0
PY

# integration: llm_analyze injects registered sibling service names into the prompt
P2="$TMP/proj2"; mkdir -p "$P2"; bash "$SH" project add "$P2" >/dev/null
id2="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
bash "$SH" service add "$id2" '{"name":"api","portBase":8080,"cwd":".","run":"x"}' >/dev/null
cat > "$TMP/fake-cap.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$MARINA_HOME/last-prompt"
printf '%s' '{"name":"web","portBase":3000,"run":"exec x --api http://localhost:{api_port}"}'
EOF
chmod +x "$TMP/fake-cap.sh"
MARINA_LLM_FAKE="$TMP/fake-cap.sh" python3 - "$CTRL" "$P2" <<'PY' || { echo "FAIL: analyze sibling injection"; exit 1; }
import importlib.util, sys, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
got = mc.llm_analyze(Path(sys.argv[2]))
prompt = open(os.path.join(os.environ["MARINA_HOME"], "last-prompt")).read()
assert "api" in prompt and "{<name>_port}" in prompt, prompt
assert got[0]["name"] == "web", got
PY
echo "PASS test-llm-analyze"
