#!/usr/bin/env bash
# Projected Docker pressure policy: learned peaks protect stopped services without guessing unknowns.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

python3 - "$HERE/../scripts" <<'PY'
import importlib
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, sys.argv[1])
mm = importlib.import_module("marina_memory")
mc = importlib.import_module("marina_state")._mc()
session_id = importlib.import_module("marina_paths").session_id


def snapshot(*, host_free=16000, docker_used=11060, containers=None):
    return {
        "host": {"availableMb": host_free},
        "docker": {"totalMb": 16000, "usedMb": docker_used, "available": True, "usageComplete": True},
        "containers": containers or [],
    }


with tempfile.TemporaryDirectory() as temp:
    home = Path(temp) / "home"
    root = Path(temp) / "worktree"
    root.mkdir()
    os.environ["MARINA_HOME"] = str(home)
    saved_minimums = {name: os.environ.get(name) for name in ("MIN_FREE_MB", "MARINA_MIN_FREE_MB")}
    os.environ.pop("MIN_FREE_MB", None)
    os.environ.pop("MARINA_MIN_FREE_MB", None)
    project = {"id": "demo", "kind": "compose", "composeFile": "docker-compose.yml"}
    mm.project_for = lambda candidate: project
    history_path = home / "demo" / "memory-history.json"
    history_path.parent.mkdir(parents=True)
    history_path.write_text(json.dumps({"version": 1, "services": {
        "web": {"peakMb": 9144, "imageId": "sha256:web", "observedAt": "2026-07-15T00:00:00Z"},
        "api": {"peakMb": 3000, "imageId": "sha256:api", "observedAt": "2026-07-15T00:00:00Z"},
        "worker": {"peakMb": 3000, "imageId": "sha256:worker", "observedAt": "2026-07-15T00:00:00Z"},
    }}), encoding="utf-8")

    projected = mm.memory_guard(root, ["web"], snapshot=snapshot())
    assert projected["blocked"] == "low-memory", projected
    assert projected["reason"] == "docker-projected", projected
    assert projected["hostFreeMb"] == 16000, projected
    assert projected["dockerTotalMb"] == 16000, projected
    assert projected["dockerUsedMb"] == 11060, projected
    assert projected["estimatedAdditionalMb"] == 9144, projected
    assert projected["reserveMb"] == 4096, projected
    assert projected["projectedFreeMb"] == -4204, projected
    assert projected["estimatedServices"] == [
        {"service": "web", "memoryMb": 9144, "confidence": "same-service"},
    ], projected
    assert projected["unknownServices"] == [], projected
    assert mm.memory_guard(root, ["web"], force=True, snapshot=snapshot()) is None

    host_critical = mm.memory_guard(root, ["web"], snapshot=snapshot(host_free=4095))
    assert host_critical["reason"] == "host-critical", host_critical
    assert host_critical["hostFreeMb"] == 4095, host_critical

    os.environ["MIN_FREE_MB"] = "1"
    os.environ["MARINA_MIN_FREE_MB"] = "17000"
    prefixed_override = mm.memory_guard(root, ["web"], snapshot=snapshot())
    assert prefixed_override["reason"] == "host-critical", prefixed_override
    assert prefixed_override["minFreeMb"] == 17000, prefixed_override
    os.environ.pop("MIN_FREE_MB", None)
    os.environ.pop("MARINA_MIN_FREE_MB", None)

    docker_unavailable = mm.memory_guard(root, ["web"], snapshot={
        "host": {"availableMb": 4095},
        "docker": {"available": False, "totalMb": None, "usedMb": None},
        "containers": [],
    })
    assert docker_unavailable["reason"] == "host-critical", docker_unavailable
    assert docker_unavailable["dockerTotalMb"] is None, docker_unavailable
    assert docker_unavailable["projectedFreeMb"] is None, docker_unavailable

    current = mm.memory_guard(root, ["unknown"], snapshot=snapshot(docker_used=12000))
    assert current["reason"] == "docker-current", current
    assert current["estimatedAdditionalMb"] == 0, current
    assert current["unknownServices"] == ["unknown"], current

    assert mm.memory_guard(root, ["unknown"], snapshot=snapshot()) is None

    incomplete = mm.memory_guard(root, ["unknown"], snapshot={
        **snapshot(),
        "partial": True,
        "docker": {"totalMb": 16000, "usedMb": None, "available": True, "usageComplete": False},
    })
    assert incomplete["reason"] == "docker-unknown", incomplete

    mm.memory_snapshot = lambda force=False: snapshot(docker_used=7000)
    first_block, first_token = mm.acquire_memory_reservation(root, ["api"])
    assert first_block is None and first_token, (first_block, first_token)
    second_block, second_token = mm.acquire_memory_reservation(root, ["worker"])
    assert second_block["reason"] == "docker-projected", second_block
    assert second_block["pendingAdditionalMb"] == 3000, second_block
    assert second_token is None
    mm.release_memory_reservation(first_token)

    project_name = mc.compose_project_name(project["id"], session_id(root))
    running = mm.memory_guard(root, ["web"], snapshot=snapshot(containers=[{
        "composeProject": project_name,
        "composeService": "web",
        "running": True,
        "memoryUsageMb": 9144,
        "imageId": "sha256:web",
    }]))
    assert running is None, running

    old_override = os.environ.get("MARINA_DOCKER_RESERVE_MB")
    os.environ["MARINA_DOCKER_RESERVE_MB"] = "5000"
    try:
        overridden = mm.memory_guard(root, ["unknown"], snapshot=snapshot(docker_used=11500))
    finally:
        if old_override is None:
            os.environ.pop("MARINA_DOCKER_RESERVE_MB", None)
        else:
            os.environ["MARINA_DOCKER_RESERVE_MB"] = old_override
    assert overridden["reason"] == "docker-current", overridden
    assert overridden["reserveMb"] == 5000, overridden

    compose_svc = importlib.import_module("marina_compose_svc")
    compose_svc.MARINA_HOME = home
    stored = home / "demo" / "docker-compose.yml"
    stored.write_text("services:\n  web:\n    image: demo\n  db:\n    image: postgres\n", encoding="utf-8")
    original_config_reader = compose_svc._docker_compose_config_json
    compose_svc._docker_compose_config_json = lambda path, candidate: ({
        "services": {
            "web": {"image": "demo", "depends_on": {"db": {"condition": "service_started"}}},
            "db": {"image": "postgres"},
        },
    }, "")
    try:
        assert compose_svc.compose_start_targets(root, project, ["web"]) == ["web", "db"]
    finally:
        compose_svc._docker_compose_config_json = original_config_reader

    # Lifecycle paths reserve explicit services plus transitive dependencies.
    # Restart has no additional target because it reuses an already-running image.
    ml = importlib.import_module("marina_lifecycle")
    decisions, commands = [], []
    ml.compose_start_targets = lambda candidate, proj, names: [*names, "db"] if names else ["web", "api", "db"]
    ml.acquire_memory_reservation = lambda candidate, names, force=False: (
        decisions.append((candidate, names, force)) or (None, f"token-{len(decisions)}")
    )
    ml.release_memory_reservation = lambda token: None
    ml._marina_cli_logged = lambda candidate, *args, **kwargs: commands.append((args, kwargs))
    ml.refresh_gateway = lambda: None
    ml._spawn_lifecycle = lambda key, op, fn, reservation_token=None: (fn(), {"starting": True, "op": op})[1]
    ml.project_for = lambda candidate: project

    ml.start_service(root, "web")
    ml.rebuild_service(root, "web", force=True)
    ml.restart_service(root, "web")
    assert decisions[:3] == [
        (root, ["web", "db"], False),
        (root, ["web", "db"], True),
        (root, [], False),
    ], decisions

    ml._compose_services = lambda candidate, proj: [
        {"service": "web", "running": False, "inStartGroup": True},
        {"service": "api", "running": True, "inStartGroup": True},
        {"service": "worker", "running": False, "inStartGroup": False},
    ]
    ml.start_all(root, force=True)
    assert decisions[-1] == (root, ["web", "db"], True), decisions
    assert commands[-1][0] == ("start", "--web", "--db"), commands

    ml._compose_services = lambda candidate, proj: [
        {"service": "web", "running": False, "inStartGroup": True},
        {"service": "api", "running": True, "inStartGroup": True},
        {"service": "worker", "running": False, "inStartGroup": True},
    ]
    ml.compose_start_targets = lambda candidate, proj, names: ["web", "api", "worker", "db"]
    ml.start_all(root)
    assert decisions[-1] == (root, ["web", "worker", "db"], False), decisions
    assert commands[-1][0] == ("start", "--web", "--worker", "--db"), commands

    ml.compose_start_targets = lambda candidate, proj, names: (_ for _ in ()).throw(
        ValueError("compose config failed")
    )
    try:
        ml.start_all(root)
    except ValueError as exc:
        assert "compose config failed" in str(exc)
    else:
        raise AssertionError("start_all must not report alreadyRunning after config failure")

    for name, value in saved_minimums.items():
        if value is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = value

print("memory guard policy OK")
PY

echo "PASS test-memory-guard"
