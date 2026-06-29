#!/usr/bin/env bash
# compose-only daemon guard: native lifecycle helpers/API/config defaults stay removed.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P" "$MARINA_HOME"
cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"proj","root":"$P","kind":"native","subrepos":[],"worktreeGlobs":[]}]}
JSON
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"web","portBase":3000,"cwd":".","run":"exec sleep 30"}]}
JSON
mkdir -p "$P/.workspace/marina/main"
cat > "$P/.workspace/marina/main/overrides.env" <<'ENV'
SERVICE_PORT_WEB=3999
SERVICE_PROFILE_WEB=dev
ENV

MARINA_HOME="$MARINA_HOME" python3 - "$CTRL" "$P" <<'PY'
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("mctl", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = Path(sys.argv[2])

assert m.read_config(root) == {}, m.read_config(root)

removed_symbols = [
    "process_snapshot", "listener_map", "listener_pids", "pid_alive", "read_pid",
    "terminate_pid_tree", "probe_http", "service_health", "service_status",
    "port_offset_for", "ports_for", "reset_health", "orphan_processes",
    "kill_orphans", "fix_port_conflict", "tracked_pid_groups",
    "extra_services_for", "services_for",
]
present = [name for name in removed_symbols if hasattr(m, name)]
assert present == [], present

source = Path(sys.argv[1]).read_text(encoding="utf-8")
removed_paths = [
    "/api/orphans", "/api/kill-orphans", "/api/fix-port-conflict",
    "/api/add-service", "/api/remove-service",
]
left = [path for path in removed_paths if path in source]
assert left == [], left
print("ok compose-only daemon guard")
PY
echo "PASS test-compose-only-control-api"
