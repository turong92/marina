#!/usr/bin/env bash
# worktree status/info: compose projects scan root + subrepos used by compose services, not every registered repo.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$ROOT" "$TMP" <<'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1])
tmp = Path(sys.argv[2])
sys.path.insert(0, str(repo / "plugin" / "scripts"))

import marina_sessions as s

root = tmp / "project"
for path in (root, root / "used", root / "unused"):
    path.mkdir(parents=True)
    (path / ".git").mkdir()

project = {"id": "proj", "root": root, "kind": "compose", "subrepos": ["used", "unused"]}
s.project_for = lambda r: project
s.project_label = lambda r: "project"
s.subrepos_of = lambda r: ["used", "unused"]
s.compose_service_subrepos = lambda r, p: {"web": "used"}
s.status_lines = lambda path, ignore_top_level=None: [" M changed.txt"] if Path(path).name == "unused" else []
s.repo_last_commit_ts = lambda path: 10
s.repo_ahead_of_main = lambda path: 7 if Path(path).name == "unused" else 0
s.repo_branch = lambda path: "feature/unused" if Path(path).name == "unused" else "feature/used"
s.session_dir = lambda r: tmp / "session-missing"
s.is_source_checkout = lambda r: False
s.default_attach_of = lambda r: None
s.cache_category_mb = lambda r: {}
s.disk_usage_mb = lambda r: 0
s.read_meta = lambda r: {"alias": ""}
s.root_source = lambda r: "test"
s.session_id = lambda r: "sid"
s.repo_head_subject = lambda r: "subject"

status = s.worktree_status(root)
names = [item["name"] for item in status["repos"]]
assert names == ["project", "used"], names
assert status["clean"] is True, status

info = s.worktree_info(root, refresh=True)
assert "unused" not in info["ahead"], info["ahead"]
assert "unused" not in info["branches"], info["branches"]
assert info["aheadTotal"] == 0, info
print("ok worktree compose scope")
PY

echo "PASS test-worktree-compose-scope"
