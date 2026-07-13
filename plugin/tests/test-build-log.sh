#!/usr/bin/env bash
# build 가상 서비스: lifecycle 출력이 build 로그 run 으로 스트리밍되고, 실패 시 파일 끝이 busyError 로.
# log_targets_for 에 build 허용 + payload buildLogRuns 노출도 검증.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
python3 - "$HERE/../scripts" "$TMP" <<'PY'
import os, subprocess, sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
root = Path(sys.argv[2]) / "proj"; root.mkdir()
import marina_cli as mc
import marina_paths as mp
mc.script = lambda r: Path("/bin/echo")               # 성공 경로 — echo 출력이 run 파일로
mc.marina_env = lambda r: os.environ.copy()
mc._marina_cli_logged(root, "start", "--all", timeout=30)
log = mp.service_log(root, "build")
text = Path(log).read_text()
assert "$ marina start --all" in text, text
assert "start --all" in text.splitlines()[-1], text   # echo 출력 기록됨
runs = mp.log_run_payload(root, "build")
assert runs and runs[0]["id"], runs                   # run rotation 파이프라인 재사용
# 실패 경로 — rc!=0 → CalledProcessError(output=파일 끝) → busyError 500자 계약 유지 가능
mc.script = lambda r: Path("/usr/bin/false")
try:
    mc._marina_cli_logged(root, "start", "--be", timeout=30)
    raise AssertionError("CalledProcessError 기대")
except subprocess.CalledProcessError as e:
    assert "$ marina start --be" in (e.output or ""), e.output
# log_targets_for 에 build 포함 (비 compose 폴백 경로)
import marina_sessions as ms
ms.project_for = lambda r: None
assert "build" in ms.log_targets_for(root)
print("ok build log")
PY
echo "PASS test-build-log"
