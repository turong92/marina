#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""; cleanup(){ [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"; bash "$SH" project add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"

# real http.server on a free port -> _await_service_ok True; dead port -> False (fast via short timeout)
PORT=39811; python3 -m http.server "$PORT" >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done
python3 - "$CTRL" "$P" "$PORT" "$id" <<'PY' || { echo "FAIL: verify-helpers"; exit 1; }
import importlib.util, sys, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
root = Path(sys.argv[2]); port = sys.argv[3]
ok, _ = mc._await_service_ok(root, "x", port, 5.0); assert ok, "live port should be ok"
ok, why = mc._await_service_ok(root, "x", "39812", 1.0); assert not ok and why, ("dead port", why)

# central-file ops: add, read, rm
proj = mc.project_for(root)
mc._service_add_central(proj, {"name":"web","portBase":3000,"cwd":".","run":"x"})
assert mc._central_def(proj, "web")["portBase"] == 3000
mc._service_rm_central(proj, "web"); assert mc._central_def(proj, "web") is None

# launch seam: MARINA_FAKE_VERIFY scripts outcomes per attempt
os.environ["MARINA_FAKE_VERIFY"] = "fail,ok"
assert mc._launch_and_verify(root, "web", 1.0, 1)[0] is False
assert mc._launch_and_verify(root, "web", 1.0, 2)[0] is True
PY
echo "PASS test-llm-verify-helpers"
