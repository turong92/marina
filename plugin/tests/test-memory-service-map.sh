#!/usr/bin/env bash
# Map one Docker snapshot to its Compose worktree and retain conservative service peaks.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

python3 - "$HERE/../scripts" <<'PY'
import importlib
import json
import os
import sys
import tempfile
from email.message import Message
from pathlib import Path

sys.path.insert(0, sys.argv[1])
mm = importlib.import_module("marina_memory")
mc = importlib.import_module("marina_state")._mc()
session_id = importlib.import_module("marina_paths").session_id

with tempfile.TemporaryDirectory() as temp:
    home = Path(temp) / "home"
    os.environ["MARINA_HOME"] = str(home)
    root = Path(temp) / "root-a"
    other_root = Path(temp) / "root-b"
    root.mkdir()
    other_root.mkdir()
    project = {"id": "demo", "kind": "compose"}
    mm.project_for = lambda candidate: project
    root_project = mc.compose_project_name(project["id"], session_id(root))
    other_project = mc.compose_project_name(project["id"], session_id(other_root))

    snapshot = {
        "containers": [
            {
                "composeProject": root_project,
                "composeService": "web",
                "memoryUsageMb": 9144,
                "memoryLimitMb": 16000,
                "memoryPercent": 57,
                "oomKilled": False,
                "imageId": "sha256:web-v1",
            },
            {
                "composeProject": other_project,
                "composeService": "api",
                "memoryUsageMb": 300,
                "memoryLimitMb": 1000,
                "memoryPercent": 30,
                "oomKilled": True,
                "imageId": "sha256:api-v1",
            },
            {
                "composeProject": other_project,
                "composeService": "web",
                "memoryUsageMb": 700,
                "memoryLimitMb": 16000,
                "memoryPercent": 4,
                "oomKilled": False,
                "imageId": "sha256:web-v1",
            },
            {
                "composeProject": other_project,
                "composeService": "old-api",
                "memoryUsageMb": None,
                "memoryLimitMb": None,
                "memoryPercent": None,
                "oomKilled": None,
                "imageId": "sha256:old-api-v2",
            },
        ],
    }
    services = [{"service": "web", "rssMb": None}, {"service": "api", "rssMb": None}]
    mm.enrich_session_memory(root, project, services, snapshot)
    web, api = services
    assert web["memoryUsageMb"] == 9144
    assert web["memoryPeakMb"] == 9144
    assert web["memoryLimitMb"] == 16000
    assert web["memoryPercent"] == 57
    assert web["oomKilled"] is False
    assert web["rssMb"] == 9144
    # The other Compose-project label must not leak into this worktree payload.
    assert api["memoryUsageMb"] is None and api["memoryPeakMb"] is None
    assert api["memoryLimitMb"] is None and api["oomKilled"] is None

    history_path = home / "demo" / "memory-history.json"
    history_path.parent.mkdir(parents=True, exist_ok=True)
    seed = json.loads(history_path.read_text(encoding="utf-8"))
    seed["services"].update({
        "old-api": {"peakMb": 512, "imageId": "sha256:old-api-v1", "observedAt": "2099-01-01T00:00:00Z"},
        **{
            f"old-{index}": {"peakMb": 1, "imageId": None, "observedAt": "2000-01-01T00:00:00Z"}
            for index in range(mm._HISTORY_MAX_SERVICES + 10)
        },
    })
    history_path.write_text(json.dumps(seed) + "\n", encoding="utf-8")

    lower = {"containers": [{
        **snapshot["containers"][0], "memoryUsageMb": 1024, "memoryPercent": 6, "imageId": "sha256:web-v2",
    }]}
    mm.enrich_session_memory(root, project, [{"service": "web", "rssMb": None}], lower)
    history = json.loads(history_path.read_text(encoding="utf-8"))
    assert history["version"] == 1
    assert history["services"]["web"]["peakMb"] == 9144
    assert history["services"]["web"]["imageId"] == "sha256:web-v1"
    assert len(history["services"]) <= mm._HISTORY_MAX_SERVICES
    assert not list(history_path.parent.glob("memory-history.json.*"))

    estimated, unknown = mm.estimate_services(other_root, ["web", "old-api", "new-api"], snapshot)
    assert estimated == [
        {"service": "web", "memoryMb": 9144, "confidence": "same-image"},
        {"service": "old-api", "memoryMb": 512, "confidence": "same-service"},
    ]
    assert unknown == ["new-api"]

    handler_module = importlib.import_module("marina_handler")
    snapshot_calls, payload_memories, responses = [], [], []
    handler_module.memory_snapshot = lambda: snapshot_calls.append(True) or snapshot
    handler_module.discover_roots = lambda: [root, other_root]
    handler_module.session_payload = lambda candidate, memory: payload_memories.append(memory) or {"root": str(candidate)}
    handler = object.__new__(handler_module.Handler)
    handler.path = "/api/sessions"
    handler.headers = Message()
    handler.send_json = lambda payload, status=200: responses.append((payload, status))
    handler.do_GET()
    assert len(snapshot_calls) == 1
    assert payload_memories == [snapshot, snapshot]
    assert len(responses) == 1 and responses[0][1] == 200
    assert responses[0][0]["memory"] is snapshot
    assert responses[0][0]["sessions"] == [
        {"root": str(root), "webPortConflictWith": []},
        {"root": str(other_root), "webPortConflictWith": []},
    ]

print("ok memory-service-map")
PY

echo "PASS test-memory-service-map"
