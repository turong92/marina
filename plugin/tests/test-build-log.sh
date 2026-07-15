#!/usr/bin/env bash
# build 가상 서비스: lifecycle 출력이 build 로그 run 으로 스트리밍되고, 실패 시 파일 끝이 busyError 로.
# log_targets_for 에 build 허용 + payload buildLogRuns 노출도 검증.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
python3 - "$HERE/../scripts" "$TMP" <<'PY'
import concurrent.futures, os, subprocess, sys, threading
sys.path.insert(0, sys.argv[1])
from pathlib import Path
root = Path(sys.argv[2]) / "proj"; root.mkdir()
import marina_cli as mc
import marina_build as mb
import marina_memory as mm
import marina_paths as mp

pressure_summaries = iter([
    {"hostAvailableMinMb": 3800, "containersPeakMb": 700, "dockerTotalMb": 8192, "sampleCount": 1, "partial": False},
    {"hostAvailableMinMb": 3900, "containersPeakMb": 650, "dockerTotalMb": 8192, "sampleCount": 1, "partial": False},
    {"hostAvailableMinMb": 3700, "containersPeakMb": 720, "dockerTotalMb": 8192, "sampleCount": 1, "partial": True},
])
pressure_tokens = []
finished_pressure_tokens = []
mc.start_pressure_observation = lambda: pressure_tokens.append(f"pressure-{len(pressure_tokens) + 1}") or pressure_tokens[-1]
mc.finish_pressure_observation = lambda token: finished_pressure_tokens.append(token) or next(pressure_summaries)
marker = root / "lifecycle-finished"
runner = root / "fake-marina.sh"
runner.write_text(
    """#!/bin/sh
printf '%s\\n' '{"version":1,"status":"ok","services":{"api":{"dockerfile":{"api/Dockerfile":"file:one"},"rebuild":{},"buildArgs":{}}}}' > "$MARINA_BUILD_INPUT_SNAPSHOT"
touch "$PWD/lifecycle-finished"
printf '%s\\n' "$*"
""",
    encoding="utf-8",
)
runner.chmod(0o755)
mc.script = lambda r: runner
mc.marina_env = lambda r: os.environ.copy()
mc._marina_cli_logged(root, "start", "--all", timeout=30)
log = mp.service_log(root, "build")
text = Path(log).read_text()
assert "$ marina start --all" in text, text
assert "start --all" in text.splitlines()[-1], text   # echo 출력 기록됨
runs = mp.log_run_payload(root, "build")
assert runs and runs[0]["id"], runs                   # run rotation 파이프라인 재사용
success_log = mp.selected_log(root, "build", runs[0]["id"])
success_meta = mb.read_build_meta(success_log)
assert success_meta["status"] == "success", success_meta
assert success_meta["op"] == "start", success_meta
assert success_meta["exitCode"] == 0, success_meta
assert success_meta["endedAt"] >= success_meta["startedAt"], success_meta
assert success_meta["durationSec"] >= 0, success_meta
assert success_meta["inputs"]["services"]["api"]["dockerfile"], success_meta
assert success_meta["memoryPressure"]["sampleCount"] >= 1, success_meta
assert success_meta["memoryPressure"]["hostAvailableMinMb"] == 3800, success_meta
assert marker.exists(), marker
assert not success_log.with_suffix(".inputs.json").exists(), "snapshot handoff file must be removed"
# 실패 경로 — rc!=0 → CalledProcessError(output=파일 끝) → busyError 500자 계약 유지 가능
os.environ["MARINA_LOG_KEEP"] = "1"
mc.script = lambda r: Path("/usr/bin/false")
try:
    mc._marina_cli_logged(root, "start", "--be", timeout=30)
    raise AssertionError("CalledProcessError 기대")
except subprocess.CalledProcessError as e:
    assert "$ marina start --be" in (e.output or ""), e.output
failure_log = mp.selected_log(root, "build", "run-002.log")
failure_meta = mb.read_build_meta(failure_log)
assert failure_meta["status"] == "failed", failure_meta
assert failure_meta["op"] == "start", failure_meta
assert failure_meta["exitCode"] != 0, failure_meta
assert failure_meta["inputs"] == {"version": 1, "status": "unknown"}, failure_meta
assert failure_meta["memoryPressure"]["hostAvailableMinMb"] == 3900, failure_meta
assert not failure_log.with_suffix(".inputs.json").exists(), "failed snapshot handoff file must be removed"
assert not success_log.exists(), success_log
assert not mb.build_meta_path(success_log).exists(), mb.build_meta_path(success_log)

# Timeout must still finalize the observation through the same finally path.
timeout_runner = root / "timeout-marina.sh"
timeout_runner.write_text("#!/bin/sh\nsleep 2\n", encoding="utf-8")
timeout_runner.chmod(0o755)
mc.script = lambda r: timeout_runner
try:
    mc._marina_cli_logged(root, "start", "--slow", timeout=0.01)
    raise AssertionError("TimeoutExpired expected")
except subprocess.TimeoutExpired:
    pass
timeout_log = mp.selected_log(root, "build", "run-003.log")
timeout_meta = mb.read_build_meta(timeout_log)
assert timeout_meta["status"] == "timeout", timeout_meta
assert timeout_meta["memoryPressure"]["hostAvailableMinMb"] == 3700, timeout_meta
assert finished_pressure_tokens == ["pressure-1", "pressure-2", "pressure-3"], finished_pressure_tokens

# Telemetry must not prevent a lifecycle command from running or finalizing.
mc.script = lambda r: runner
mc.start_pressure_observation = lambda: (_ for _ in ()).throw(RuntimeError("start telemetry unavailable"))
mc.finish_pressure_observation = lambda token: (_ for _ in ()).throw(RuntimeError("finish should not run"))
mc._marina_cli_logged(root, "start", "--telemetry-start", timeout=30)
start_failure_log = mp.selected_log(root, "build", "run-004.log")
start_failure_meta = mb.read_build_meta(start_failure_log)
assert "start --telemetry-start" in start_failure_log.read_text(encoding="utf-8"), start_failure_log.read_text(encoding="utf-8")
assert start_failure_meta["status"] == "success", start_failure_meta
assert start_failure_meta["memoryPressure"]["partial"] is True, start_failure_meta
assert start_failure_meta["memoryPressure"]["sampleCount"] == 0, start_failure_meta

mc.start_pressure_observation = lambda: "finish-fails"
mc.finish_pressure_observation = lambda token: (_ for _ in ()).throw(RuntimeError("finish telemetry unavailable"))
mc._marina_cli_logged(root, "start", "--telemetry-finish", timeout=30)
finish_failure_log = mp.selected_log(root, "build", "run-005.log")
finish_failure_meta = mb.read_build_meta(finish_failure_log)
assert "start --telemetry-finish" in finish_failure_log.read_text(encoding="utf-8"), finish_failure_log.read_text(encoding="utf-8")
assert finish_failure_meta["status"] == "success", finish_failure_meta
assert finish_failure_meta["memoryPressure"]["partial"] is True, finish_failure_meta
assert finish_failure_meta["memoryPressure"]["sampleCount"] == 0, finish_failure_meta

# Tokens share one daemon sampler but summarize only their own active intervals.
original_interval = mm._PRESSURE_SAMPLE_INTERVAL_SECONDS
original_sample = mm._pressure_sample
samples = iter([
    {"hostAvailableMb": 4000, "containersMb": 100, "dockerTotalMb": 8192, "partial": False},
    {"hostAvailableMb": 3800, "containersMb": 200, "dockerTotalMb": 8192, "partial": False},
    {"hostAvailableMb": 3900, "containersMb": 300, "dockerTotalMb": 8192, "partial": True},
])
first_sampled = threading.Event()
def deterministic_sample():
    value = next(samples)
    first_sampled.set()
    return value
mm._PRESSURE_SAMPLE_INTERVAL_SECONDS = 60
mm._pressure_sample = deterministic_sample
try:
    first_token = mm.start_pressure_observation()
    assert first_sampled.wait(2), "sampler did not take its initial sample"
    shared_sampler = mm._pressure_sampler
    second_token = mm.start_pressure_observation()
    assert mm._pressure_sampler is shared_sampler and shared_sampler is not None, "one sampler per build"
    mm._record_pressure_sample()
    first_pressure = mm.finish_pressure_observation(first_token)
    mm._record_pressure_sample()
    second_pressure = mm.finish_pressure_observation(second_token)
finally:
    mm._PRESSURE_SAMPLE_INTERVAL_SECONDS = original_interval
    mm._pressure_sample = original_sample
shared_sampler.join(2)
assert first_pressure == {
    "hostAvailableMinMb": 3800,
    "containersPeakMb": 200,
    "dockerTotalMb": 8192,
    "sampleCount": 2,
    "partial": False,
}, first_pressure
assert second_pressure == {
    "hostAvailableMinMb": 3800,
    "containersPeakMb": 300,
    "dockerTotalMb": 8192,
    "sampleCount": 2,
    "partial": True,
}, second_pressure

# A sample belongs to tokens active when capture begins, not when it completes.
original_interval = mm._PRESSURE_SAMPLE_INTERVAL_SECONDS
original_sample = mm._pressure_sample
initial_sampled = threading.Event()
capture_started = threading.Event()
release_capture = threading.Event()
finish_returned = threading.Event()
unexpected_sample = threading.Event()
sample_calls = 0
def blocked_sample():
    global sample_calls
    sample_calls += 1
    if sample_calls == 1:
        initial_sampled.set()
        return {"hostAvailableMb": 4000, "containersMb": 100, "dockerTotalMb": 8192, "partial": False}
    if sample_calls == 2:
        capture_started.set()
        assert release_capture.wait(2), "blocked sample was not released"
        return {"hostAvailableMb": 3800, "containersMb": 200, "dockerTotalMb": 8192, "partial": False}
    unexpected_sample.set()
    return {"hostAvailableMb": 3600, "containersMb": 300, "dockerTotalMb": 8192, "partial": False}
mm._PRESSURE_SAMPLE_INTERVAL_SECONDS = 60
mm._pressure_sample = blocked_sample
capture_thread = None
finish_thread = None
race_sampler = None
second_race_token = None
try:
    first_race_token = mm.start_pressure_observation()
    assert initial_sampled.wait(2), "sampler did not take its initial sample"
    race_sampler = mm._pressure_sampler
    capture_thread = threading.Thread(target=mm._record_pressure_sample)
    capture_thread.start()
    assert capture_started.wait(2), "manual capture did not start"
    second_race_token = mm.start_pressure_observation()
    race_result = {}
    def finish_first_token():
        race_result.update(mm.finish_pressure_observation(first_race_token))
        finish_returned.set()
    finish_thread = threading.Thread(target=finish_first_token)
    finish_thread.start()
    assert not finish_returned.wait(0.1), "token active at capture start must wait for that sample"
    release_capture.set()
    capture_thread.join(2)
    assert not unexpected_sample.wait(1), "condition notification triggered a premature sample"
    finish_thread.join(2)
    assert finish_returned.is_set(), "finish did not return after sample capture"
    assert race_result["sampleCount"] == 2, race_result
    with mm._pressure_condition:
        assert mm._pressure_tokens[second_race_token] == [], "mid-capture token received an older sample"
finally:
    release_capture.set()
    if capture_thread is not None:
        capture_thread.join(2)
    if finish_thread is not None:
        finish_thread.join(2)
    if second_race_token is not None:
        mm.finish_pressure_observation(second_race_token)
    if race_sampler is not None:
        race_sampler.join(2)
    mm._PRESSURE_SAMPLE_INTERVAL_SECONDS = original_interval
    mm._pressure_sample = original_sample
# Concurrent lifecycle requests must receive distinct build runs and handoff paths.
concurrent_root = Path(sys.argv[2]) / "concurrent"; concurrent_root.mkdir()
mp._session_id_cache[str(concurrent_root)] = "main"
with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
    allocated = list(pool.map(lambda _: mp.next_log_path(concurrent_root, "build", active=True), range(32)))
assert len(set(allocated)) == len(allocated), allocated
assert all(path.exists() for path in allocated), allocated
ordered = sorted(allocated)
for path in reversed(ordered):
    mp.finish_log_path(concurrent_root, "build", path)
remaining = list(mp.log_dir(concurrent_root, "build").glob("run-*.log"))
assert remaining == [ordered[-1]], remaining
assert mp.service_log(concurrent_root, "build").resolve() == ordered[-1].resolve()
assert not list(mp.log_dir(concurrent_root, "build").glob("run-*.active"))
# log_targets_for 에 build 포함 (비 compose 폴백 경로)
import marina_sessions as ms
ms.project_for = lambda r: None
assert "build" in ms.log_targets_for(root)
print("ok build log")
PY
echo "PASS test-build-log"
