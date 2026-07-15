#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/api"
printf 'FROM python:3.11-slim\nCOPY . .\n' > "$TMP/api/Dockerfile.local"
printf 'fastapi==1.0\n' > "$TMP/api/requirements.txt"

python3 - "$HERE/../scripts" "$TMP" <<'PY'
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from marina_build_inputs import (
    build_decision,
    build_input_snapshot,
    compare_build_inputs,
    load_build_input_key,
    merge_build_baseline,
    read_build_baseline,
)

root = Path(sys.argv[2])
config = {
    "services": {
        "api": {
            "build": {
                "context": str(root / "api"),
                "dockerfile": "Dockerfile.local",
                "args": {"PROFILE": "local", "TOKEN": "hunter2"},
            },
            "develop": {
                "watch": [
                    {"action": "sync", "path": str(root / "api"), "target": "/app"},
                    {"action": "rebuild", "path": str(root / "api" / "requirements.txt")},
                    {"action": "rebuild", "path": str(root / "api" / "Dockerfile.local")},
                ]
            },
        }
    }
}
key = b"k" * 32
before = build_input_snapshot(root, config, ["api"], {}, key)
serialized = json.dumps(before, sort_keys=True)
assert "hunter2" not in serialized, serialized
assert before["version"] == 1, before
empty = build_input_snapshot(root, config, [], {}, key)
assert empty["services"] == {}, empty
assert compare_build_inputs(empty, None, "start") == [], empty
assert compare_build_inputs({"version": 1, "status": "pending"}, before, "start") == []

(root / "api" / "Dockerfile.local").write_text(
    "FROM python:3.12-slim\nCOPY . .\n", encoding="utf-8"
)
(root / "api" / "requirements.txt").write_text("fastapi==2.0\n", encoding="utf-8")
after_config = json.loads(json.dumps(config))
after_config["services"]["api"]["build"]["args"] = {
    "PROFILE": "dev",
    "NEW_ARG": "local-secret",
}
after = build_input_snapshot(root, after_config, ["api"], {}, key)
serialized = json.dumps(after, sort_keys=True)
assert "local-secret" not in serialized, serialized

reasons = compare_build_inputs(after, before, "rebuild")
got = {(item["kind"], item["label"], item["change"]) for item in reasons}
assert ("dockerfile", "api/Dockerfile.local", "changed") in got, got
assert ("rebuild-input", "api/Dockerfile.local", "changed") not in got, got
assert ("rebuild-input", "api/requirements.txt", "changed") in got, got
assert ("build-arg", "PROFILE", "changed") in got, got
assert ("build-arg", "NEW_ARG", "added") in got, got
assert ("build-arg", "TOKEN", "removed") in got, got

first = compare_build_inputs(before, None, "start")
assert first == [{
    "kind": "first-run",
    "service": "",
    "label": "이전 build 입력 기록 없음",
    "change": "unknown",
}], first

same = compare_build_inputs(after, after, "rebuild")
assert same == [{
    "kind": "explicit-rebuild",
    "service": "",
    "label": "사용자가 Rebuild 실행",
    "change": "requested",
}], same

should_build, decision_reasons = build_decision(after, before)
assert should_build is True, decision_reasons
decision_got = {(item["kind"], item["label"], item["change"]) for item in decision_reasons}
assert ("dockerfile", "api/Dockerfile.local", "changed") in decision_got, decision_got
assert ("rebuild-input", "api/requirements.txt", "changed") in decision_got, decision_got
assert ("build-arg", "PROFILE", "changed") in decision_got, decision_got
assert build_decision(after, after) == (False, [])
assert build_decision(before, None)[0] is True
assert build_decision(after, after, explicit=True) == (True, [{
    "kind": "explicit-rebuild",
    "service": "",
    "label": "사용자가 Rebuild 실행",
    "change": "requested",
}])
unknown = {"version": 1, "status": "unknown"}
assert build_decision(unknown, before) == (False, [{
    "kind": "unknown",
    "service": "",
    "label": "build 입력 수집 실패",
    "change": "unknown",
}])
assert build_decision(empty, None) == (False, [])

baseline_path = root / "session" / "build-baseline.json"
assert read_build_baseline(baseline_path) is None
merge_build_baseline(baseline_path, before)
assert read_build_baseline(baseline_path) == before
assert baseline_path.stat().st_mode & 0o777 == 0o600
lock_path = baseline_path.with_name(baseline_path.name + ".lock")
assert lock_path.stat().st_mode & 0o777 == 0o600

corrupt_path = root / "session" / "corrupt.json"
corrupt_path.write_text("not json", encoding="utf-8")
assert read_build_baseline(corrupt_path) is None
merge_build_baseline(corrupt_path, unknown)
assert corrupt_path.read_text(encoding="utf-8") == "not json"

concurrent_path = root / "concurrent" / "build-baseline.json"
snapshots = []
for index in range(8):
    snapshots.append({
        "version": 1,
        "status": "ok",
        "services": {f"service-{index}": before["services"]["api"]},
    })
with ThreadPoolExecutor(max_workers=8) as executor:
    list(executor.map(lambda snapshot: merge_build_baseline(concurrent_path, snapshot), snapshots))
concurrent = read_build_baseline(concurrent_path)
assert concurrent is not None
assert set(concurrent["services"]) == {f"service-{index}" for index in range(8)}, concurrent

key_home = root / "key-home"
with ThreadPoolExecutor(max_workers=8) as executor:
    keys = list(executor.map(lambda _index: load_build_input_key(key_home), range(8)))
assert len(set(keys)) == 1, "concurrent key readers returned different keys"
assert (key_home / "build-input.key.lock").is_file(), "key creation must use a process lock"
print("build input assertions ok")
PY

echo "PASS test-build-inputs"
