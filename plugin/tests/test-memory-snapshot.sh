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
mm._bin = lambda name: name

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
    '{"ID":"abc123","Names":"demo-web-1","State":"running","Labels":"com.docker.compose.project=demo,com.docker.compose.service=web"}',
    '{"ID":"def456","Names":"demo-worker-1","State":"running","Labels":"com.docker.compose.project=demo,com.docker.compose.service=worker"}',
    '{"ID":"oom789","Names":"demo-crashed-1","State":"exited","Labels":"com.docker.compose.project=demo,com.docker.compose.service=crashed"}',
))
inspect = {
    "abc123": '{"Id":"abc123","State":{"OOMKilled":false},"HostConfig":{"Memory":0},"Config":{"Labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"web"}}}',
    "def456": '{"Id":"def456","State":{"OOMKilled":true},"HostConfig":{"Memory":1073741824},"Config":{"Labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"worker"}}}',
    "oom789": '{"Id":"oom789","State":{"Status":"exited","OOMKilled":true},"HostConfig":{"Memory":536870912},"Config":{"Labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"crashed"}}}',
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
        return '[' + ','.join(inspect[item] for item in args[2:]) + ']'
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
crashed = next(row for row in snapshot["containers"] if row["composeService"] == "crashed")
assert crashed["running"] is False and crashed["oomKilled"] is True
assert snapshot["partial"] is False and snapshot["stale"] is False and snapshot["error"] is None
assert snapshot["capturedAt"]
assert all(timeout > 0 for _, timeout in calls)
inspect_calls = [args for args, _ in calls if args[:2] == ("docker", "inspect")]
assert len(inspect_calls) == 1 and set(inspect_calls[0][2:]) == {"abc123", "def456", "oom789"}, inspect_calls

# A refresh failure returns the prior snapshot marked stale instead of raising.
def timeout_run(args, timeout):
    raise subprocess.TimeoutExpired(args, timeout)

mm._run = timeout_run
mm.host_memory = lambda: {"totalMb": 32000, "availableMb": 2048, "availablePercent": 6}
stale = mm.memory_snapshot(force=True)
assert stale["stale"] is True and stale["partial"] is True
assert stale["error"] and "TimeoutExpired" in stale["error"]
assert stale["containers"] == snapshot["containers"]
assert stale["host"]["availableMb"] == 2048, stale["host"]

# Missing stats for a running container is incomplete telemetry, never a valid 0 MiB sample.
def incomplete_run(args, timeout):
    if args[:2] == ["docker", "info"]:
        return info
    if args[:2] == ["docker", "stats"]:
        return ""
    if args[:2] == ["docker", "ps"]:
        return '{"ID":"abc123","Names":"demo-web-1","State":"running","Labels":"com.docker.compose.project=demo,com.docker.compose.service=web"}'
    if args[:2] == ["docker", "inspect"]:
        return '[' + inspect["abc123"] + ']'
    raise AssertionError(args)

mm._run = incomplete_run
mm._snapshot_cache = None
mm._inspect_cache.clear()
incomplete = mm.memory_snapshot(force=True)
assert incomplete["partial"] is True, incomplete
assert incomplete["docker"]["usageComplete"] is False, incomplete
assert incomplete["docker"]["usedMb"] is None, incomplete

# A waiter that times out behind another Docker refresh still reads current host pressure.
old_docker_timeout = mm._DOCKER_TIMEOUT_SECONDS
old_inspect_timeout = mm._INSPECT_TIMEOUT_SECONDS
mm._DOCKER_TIMEOUT_SECONDS = 0
mm._INSPECT_TIMEOUT_SECONDS = 0
mm._snapshot_cache = (time.monotonic() - mm._CACHE_TTL_SECONDS - 1, {
    "host": {"totalMb": 32000, "availableMb": 8000, "availablePercent": 25},
    "docker": {"available": False, "totalMb": None, "usedMb": None, "usageComplete": False},
    "containers": [], "stale": False, "partial": True, "error": "docker unavailable",
    "capturedAt": "old",
})
mm._refreshing = True
mm.host_memory = lambda: {"totalMb": 32000, "availableMb": 1000, "availablePercent": 3}
try:
    waiter_fallback = mm.memory_snapshot()
finally:
    mm._refreshing = False
    mm._DOCKER_TIMEOUT_SECONDS = old_docker_timeout
    mm._INSPECT_TIMEOUT_SECONDS = old_inspect_timeout
assert waiter_fallback["host"]["availableMb"] == 1000, waiter_fallback

# Mutable inspect state must refresh when a running container later exits by OOM.
transition = {"exited": False}
def transition_run(args, timeout):
    if args[:2] == ["docker", "info"]:
        return info
    if args[:2] == ["docker", "stats"]:
        return "" if transition["exited"] else '{"ID":"abc123","Name":"demo-web-1","MemUsage":"512MiB / 15.6GiB"}'
    if args[:2] == ["docker", "ps"]:
        state = "exited" if transition["exited"] else "running"
        return '{"ID":"abc123","Names":"demo-web-1","State":"' + state + '","Labels":"com.docker.compose.project=demo,com.docker.compose.service=web"}'
    if args[:2] == ["docker", "inspect"]:
        state = "exited" if transition["exited"] else "running"
        oom = "true" if transition["exited"] else "false"
        return '[{"Id":"abc123","State":{"Status":"' + state + '","OOMKilled":' + oom + '},"HostConfig":{"Memory":0},"Config":{"Labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"web"}}}]'
    raise AssertionError(args)

mm._run = transition_run
mm._snapshot_cache = None
mm._inspect_cache.clear()
running_snapshot = mm.memory_snapshot(force=True)
assert running_snapshot["containers"][0]["running"] is True
transition["exited"] = True
exited_snapshot = mm.memory_snapshot(force=True)
exited_web = next(row for row in exited_snapshot["containers"] if row["composeService"] == "web")
assert exited_web["running"] is False and exited_web["oomKilled"] is True, exited_web

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
