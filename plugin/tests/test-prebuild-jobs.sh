#!/usr/bin/env bash
# x-marina.prebuild planner: service objects, legacy subrepos, dedupe, and cwd isolation.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/root/be-api/user-api" "$TMP/root/be-api/batch" \
  "$TMP/root/web" "$TMP/root/.workspace/external/ext-api/app"

python3 - "$HERE/../scripts" "$TMP/root" <<'PY'
import importlib.util
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from marina_prebuild import PrebuildConfigError, plan_prebuild_jobs

compose_spec = importlib.util.spec_from_file_location(
    "marina_compose", Path(sys.argv[1]) / "marina-compose.py"
)
marina_compose = importlib.util.module_from_spec(compose_spec)
compose_spec.loader.exec_module(marina_compose)

root = Path(sys.argv[2]).resolve()
config = {
    "services": {
        "user-api": {"build": {"context": str(root / "be-api/user-api")}},
        "batch": {"build": {"context": str(root / "be-api/batch")}},
        "external": {"build": {"context": str(root / ".workspace/external/ext-api/app")}},
        "web": {"build": {"context": str(root / "web")}},
    }
}

raw = {
    "user-api": {"cwd": "be-api", "command": "./gradlew :user-api:bootJar"},
    "batch": {"cwd": "be-api", "command": "./gradlew :batch:bootJar"},
    "external": {"cwd": ".workspace/external/ext-api", "command": "make build"},
}
jobs = plan_prebuild_jobs(raw, config, ["user-api"], root)
assert [(job.services, job.cwd, job.command) for job in jobs] == [
    (("user-api",), "be-api", "./gradlew :user-api:bootJar")
], jobs

external = plan_prebuild_jobs(raw, config, ["external"], root)
assert len(external) == 1, external
assert external[0].cwd == ".workspace/external/ext-api", external
assert external[0].java_key == "ext-api", external

deduped = plan_prebuild_jobs({
    "user-api": {"cwd": "be-api", "command": "make shared"},
    "batch": {"cwd": "be-api", "command": "make shared"},
}, config, ["user-api", "batch"], root)
assert len(deduped) == 1, deduped
assert deduped[0].services == ("batch", "user-api"), deduped
assert deduped[0].id == "prebuild-1", deduped

legacy = plan_prebuild_jobs(
    {"be-api": "./gradlew assemble", "other": "false"},
    config,
    ["user-api", "web"],
    root,
)
assert len(legacy) == 1 and legacy[0].legacy, legacy
assert legacy[0].cwd == "be-api", legacy
assert legacy[0].services == ("user-api",), legacy

legacy_external = plan_prebuild_jobs(
    {"ext-api": "make legacy"}, config, ["external"], root
)
assert legacy_external[0].cwd == ".workspace/external/ext-api", legacy_external

for invalid in (
    {"ghost": {"cwd": "be-api", "command": "true"}},
    {"user-api": {"cwd": "", "command": "true"}},
    {"user-api": {"cwd": "be-api", "command": ""}},
    {"user-api": {"cwd": "be-api", "command": "true", "extra": "no"}},
    {"user-api": ["not", "a", "mapping"]},
):
    try:
        plan_prebuild_jobs(invalid, config, ["user-api"], root)
    except PrebuildConfigError:
        pass
    else:
        raise AssertionError(f"invalid prebuild accepted: {invalid}")

outside = root.parent / "outside"
outside.mkdir(exist_ok=True)
(root / "escape").symlink_to(outside, target_is_directory=True)
try:
    plan_prebuild_jobs(
        {"user-api": {"cwd": "escape", "command": "true"}},
        config,
        ["user-api"],
        root,
    )
except PrebuildConfigError as exc:
    assert "worktree root" in str(exc), exc
else:
    raise AssertionError("symlink escape accepted")

# Optional, unselected services still receive schema validation but do not require cwd materialization.
optional = plan_prebuild_jobs(
    {"batch": {"cwd": "not-attached-yet", "command": "true"}},
    config,
    ["user-api"],
    root,
)
assert optional == [], optional

dependency_config = {"services": {
    "frontend": {"image": "frontend", "depends_on": {"worker": {"condition": "service_started"}}},
    "worker": {"image": "worker"},
}}
dependency_targets, _, _ = marina_compose.resolved_start_targets(
    dependency_config, {}, ["frontend"]
)
dependency_jobs = plan_prebuild_jobs(
    {"worker": {"cwd": "be-api", "command": "make worker"}},
    dependency_config,
    dependency_targets,
    root,
)
assert dependency_targets == ["frontend", "worker"], dependency_targets
assert [job.services for job in dependency_jobs] == [("worker",)], dependency_jobs

print("planner assertions ok")
PY

echo "PASS test-prebuild-jobs"
