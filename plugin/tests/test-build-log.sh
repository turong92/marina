#!/usr/bin/env bash
# build 가상 서비스: lifecycle 출력이 build 로그 run 으로 스트리밍되고, 실패 시 파일 끝이 busyError 로.
# log_targets_for 에 build 허용 + payload buildLogRuns 노출도 검증.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
python3 - "$HERE/../scripts" "$TMP" <<'PY'
import concurrent.futures, os, subprocess, sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
root = Path(sys.argv[2]) / "proj"; root.mkdir()
import marina_cli as mc
import marina_build as mb
import marina_paths as mp
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
assert not failure_log.with_suffix(".inputs.json").exists(), "failed snapshot handoff file must be removed"
assert not success_log.exists(), success_log
assert not mb.build_meta_path(success_log).exists(), mb.build_meta_path(success_log)
# Concurrent lifecycle requests must receive distinct build runs and handoff paths.
concurrent_root = Path(sys.argv[2]) / "concurrent"; concurrent_root.mkdir()
mp._session_id_cache[str(concurrent_root)] = "main"
with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
    allocated = list(pool.map(lambda _: mp.next_log_path(concurrent_root, "build", active=True), range(32)))
assert len(set(allocated)) == len(allocated), allocated
assert all(path.exists() for path in allocated), allocated
for path in allocated:
    mp.finish_log_path(concurrent_root, "build", path)
assert len(list(mp.log_dir(concurrent_root, "build").glob("run-*.log"))) == 1
assert not list(mp.log_dir(concurrent_root, "build").glob("run-*.active"))
# log_targets_for 에 build 포함 (비 compose 폴백 경로)
import marina_sessions as ms
ms.project_for = lambda r: None
assert "build" in ms.log_targets_for(root)
print("ok build log")
PY
echo "PASS test-build-log"
