#!/usr/bin/env bash
# Cross-platform host/Docker memory snapshot: parsing, fallbacks, and single-flight refresh.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

python3 - "$HERE/../scripts" <<'PY'
import importlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, sys.argv[1])
mm = importlib.import_module("marina_memory")

assert mm.parse_size_mb("8.93GiB") == 9144
assert mm.parse_size_mb("638MiB") == 638
assert mm.parse_size_mb("1GB") == 953
assert mm.parse_size_mb("garbage") is None

meminfo = """MemTotal:       32768000 kB
MemFree:          1234567 kB
MemAvailable:    16777216 kB
"""
mm.platform.system = lambda: "Linux"
mm.open = lambda path, *args, **kwargs: __import__("io").StringIO(meminfo)
host = mm.host_memory()
assert host == {
    "totalMb": 32000,
    "availableMb": 16384,
    "availablePercent": 51,
}

info = '{"MemTotal":16747806720,"OperatingSystem":"Docker Desktop","ServerVersion":"27.0.0"}'
stats = '\n'.join((
    '{"ID":"abc123","Name":"demo-web-1","MemUsage":"8.93GiB / 15.6GiB","MemPerc":"57.24%"}',
    '{"ID":"def456","Name":"demo-worker-1","MemUsage":"638MiB / 15.6GiB","MemPerc":"3.99%"}',
))
ps = '\n'.join((
    '{"ID":"abc123","Names":"demo-web-1","Labels":"com.docker.compose.project=demo,com.docker.compose.service=web"}',
    '{"ID":"def456","Names":"demo-worker-1","Labels":"com.docker.compose.project=demo,com.docker.compose.service=worker"}',
))
inspect = {
    "abc123": '{"Id":"abc123","State":{"OOMKilled":false},"HostConfig":{"Memory":0},"Config":{"Labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"web"}}}',
    "def456": '{"Id":"def456","State":{"OOMKilled":true},"HostConfig":{"Memory":1073741824},"Config":{"Labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"worker"}}}',
}
calls = []

def fake_run(args, timeout):
    calls.append((tuple(args), timeout))
    if args[:2] == ["docker", "info"]:
        return info
    if args[:2] == ["docker", "stats"]:
        return stats
    if args[:2] == ["docker", "ps"]:
        return ps
    if args[:2] == ["docker", "inspect"]:
        return inspect[args[-1]]
    raise AssertionError(args)

mm._run = fake_run
mm._snapshot_cache = None
mm._inspect_cache.clear()
snapshot = mm.memory_snapshot(force=True)
assert snapshot["docker"]["totalMb"] == 15972
assert snapshot["docker"]["usedMb"] == 9782
assert snapshot["docker"]["availableMb"] == 6190
assert snapshot["containers"][0]["composeService"] == "web"
assert snapshot["containers"][0]["oomKilled"] is False
assert snapshot["containers"][1]["memoryLimitMb"] == 1024
assert snapshot["containers"][1]["oomKilled"] is True
assert snapshot["partial"] is False and snapshot["stale"] is False and snapshot["error"] is None
assert snapshot["capturedAt"]
assert all(timeout > 0 for _, timeout in calls)

# A refresh failure returns the prior snapshot marked stale instead of raising.
def timeout_run(args, timeout):
    raise subprocess.TimeoutExpired(args, timeout)

mm._run = timeout_run
stale = mm.memory_snapshot(force=True)
assert stale["stale"] is True and stale["partial"] is True
assert stale["error"] and "TimeoutExpired" in stale["error"]
assert stale["containers"] == snapshot["containers"]

# A shared failed refresh marks every waiting caller stale, then caches that failure.
mm._snapshot_cache = (time.monotonic() - mm._CACHE_TTL_SECONDS - 1, snapshot)
timeout_calls = 0
timeout_lock = threading.Lock()

def slow_timeout_run(args, timeout):
    global timeout_calls
    if args[:2] == ["docker", "info"]:
        with timeout_lock:
            timeout_calls += 1
        time.sleep(0.06)
    raise subprocess.TimeoutExpired(args, timeout)

mm._run = slow_timeout_run
failure_barrier = threading.Barrier(8)
failure_answers = []

def collect_failure():
    failure_barrier.wait()
    failure_answers.append(mm.memory_snapshot())

failure_threads = [threading.Thread(target=collect_failure) for _ in range(8)]
for thread in failure_threads:
    thread.start()
for thread in failure_threads:
    thread.join()
assert len(failure_answers) == 8
assert timeout_calls == 1, timeout_calls
assert all(answer["stale"] and answer["partial"] and "TimeoutExpired" in answer["error"] for answer in failure_answers)
cached_failure = mm.memory_snapshot()
assert cached_failure["stale"] and cached_failure["partial"] and "TimeoutExpired" in cached_failure["error"]
assert timeout_calls == 1, timeout_calls

# Eight callers share one refresh; only one docker stats invocation may run.
mm._snapshot_cache = None
mm._inspect_cache.clear()
stats_calls = 0
stats_lock = threading.Lock()

def slow_run(args, timeout):
    global stats_calls
    if args[:2] == ["docker", "stats"]:
        with stats_lock:
            stats_calls += 1
        time.sleep(0.06)
    return fake_run(args, timeout)

mm._run = slow_run
barrier = threading.Barrier(8)
answers = []

def collect():
    barrier.wait()
    answers.append(mm.memory_snapshot())

threads = [threading.Thread(target=collect) for _ in range(8)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
assert len(answers) == 8
assert stats_calls == 1, stats_calls
assert all(answer["docker"]["usedMb"] == 9782 for answer in answers)
print("ok memory-snapshot")
PY

echo "PASS test-memory-snapshot"
