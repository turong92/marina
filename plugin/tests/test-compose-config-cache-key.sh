#!/usr/bin/env bash
# compose config cache: build Dockerfile paths are root-specific and must not leak across worktrees.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MARINA_HOME="$TMP/marina-home"
mkdir -p "$MARINA_HOME/proj"
printf 'services:\n  web:\n    build: ./web\n' > "$MARINA_HOME/proj/docker-compose.yml"

python3 - "$ROOT" "$TMP" <<'PY'
import json
import os
import sys
from pathlib import Path

repo = Path(sys.argv[1])
tmp = Path(sys.argv[2])
sys.path.insert(0, str(repo / "plugin" / "scripts"))

import marina_compose_svc as svc
from marina_state import _SUBREPO_MAP_CACHE

old_path = os.environ.get("PATH", "")
os.environ["PATH"] = "/usr/bin:/bin"
try:
    docker_cmd = svc._docker_cmd("compose")[0]
finally:
    os.environ["PATH"] = old_path
if Path("/usr/local/bin/docker").exists() or Path("/opt/homebrew/bin/docker").exists():
    assert docker_cmd != "docker", docker_cmd

root_a = tmp / "a"
root_b = tmp / "b"
(root_a / "web").mkdir(parents=True)
(root_b / "web").mkdir(parents=True)
(root_a / "web" / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
project = {"id": "proj", "composeFile": "docker-compose.yml", "kind": "compose"}

def fake_check_output(args, **kwargs):
    root = Path(args[args.index("--project-directory") + 1])
    return json.dumps({"services": {"web": {"build": {"context": str(root / "web"), "dockerfile": "Dockerfile"}}}})

svc.subprocess.check_output = fake_check_output
_SUBREPO_MAP_CACHE.clear()

sub_a, degraded_a, _ports_a = svc._compose_config_maps(root_a, project)
sub_b, degraded_b, _ports_b = svc._compose_config_maps(root_b, project)

assert sub_a == {"web": "web"}, sub_a
assert degraded_a == {}, degraded_a
assert sub_b == {"web": "web"}, sub_b
assert "web" in degraded_b and str(root_b / "web" / "Dockerfile") in degraded_b["web"], degraded_b
print("ok compose config cache key")
PY

echo "PASS test-compose-config-cache-key"
