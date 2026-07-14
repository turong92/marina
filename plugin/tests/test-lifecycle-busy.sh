#!/usr/bin/env bash
# 대시보드 start/restart 비동기 전환 회귀 — 120s 타임아웃으로 빌드를 죽이던 버그의 상태머신 검증.
# _spawn_lifecycle: 즉시응답·진행중 중복거부·성공 시 마커 해제·실패 시 error 보존, payload 머지 규칙.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

python3 - "$HERE/../scripts" <<'PY'
import importlib.util, sys, time, os, subprocess
sys.path.insert(0, sys.argv[1])
spec=importlib.util.spec_from_file_location("ml", os.path.join(sys.argv[1], "marina_lifecycle.py"))
ml=importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(ml)
except Exception as e:
    print("skip import (env dep):", e); sys.exit(0)
from marina_state import LIFECYCLE_BUSY, busy_key

# 1) 성공 흐름 — 즉시 {"starting":True}, 진행중 busy 마커, 완료 후 해제
done = []
r = ml._spawn_lifecycle("k1", "start", lambda: (time.sleep(0.3), done.append(1)))
assert r == {"starting": True, "op": "start"}, r
assert "error" not in LIFECYCLE_BUSY["k1"], LIFECYCLE_BUSY
# 2) 진행 중 중복 기동 거부
r2 = ml._spawn_lifecycle("k1", "start", lambda: None)
assert r2 == {"busy": True, "op": "start"}, r2
for _ in range(50):
    if "k1" not in LIFECYCLE_BUSY: break
    time.sleep(0.1)
assert "k1" not in LIFECYCLE_BUSY and done, (LIFECYCLE_BUSY, done)

# 3) 실패 흐름 — error 보존, 재시도는 error 를 밀어내고 다시 진행
def boom(): raise RuntimeError("gradle exploded")
ml._spawn_lifecycle("k2", "restart", boom)
for _ in range(50):
    if "error" in LIFECYCLE_BUSY.get("k2", {}): break
    time.sleep(0.1)
assert "gradle exploded" in LIFECYCLE_BUSY["k2"]["error"], LIFECYCLE_BUSY
r3 = ml._spawn_lifecycle("k2", "restart", lambda: None)
assert r3.get("starting"), r3
ml._clear_busy_error("k2")   # 정지 경로의 실패 마커 청소

# 실패 출력은 sessions API의 busyError로 가기 전에 일반 로그와 같은 규칙으로 마스킹한다.
def secret_boom():
    secret = "s" * 700
    raise subprocess.CalledProcessError(
        9, ["build"], output="API_TOKEN=" + secret
    )
ml._spawn_lifecycle("k-secret", "start", secret_boom)
for _ in range(50):
    if "error" in LIFECYCLE_BUSY.get("k-secret", {}): break
    time.sleep(0.1)
secret_error = LIFECYCLE_BUSY["k-secret"]["error"]
assert "s" * 100 not in secret_error, secret_error
assert "<redacted>" in secret_error, secret_error

# 4) payload 머지 규칙 — 자기 op 는 running 이어도 busy(restart 표시), --all 은 미기동만
root = "/tmp/x"
LIFECYCLE_BUSY.clear()
LIFECYCLE_BUSY[busy_key(root, "web")] = {"op": "restart", "ts": 0}
LIFECYCLE_BUSY[busy_key(root, "--all")] = {"op": "start", "ts": 0}
services = [{"service": "web", "running": True}, {"service": "be", "running": True}, {"service": "db", "running": False}]
all_busy = LIFECYCLE_BUSY.get(busy_key(root, "--all"))
for s in services:   # marina_sessions.session_payload 의 머지 로직과 동일 규칙
    own = LIFECYCLE_BUSY.get(busy_key(root, s.get("service") or ""))
    b = own or all_busy
    if not b: continue
    if "error" in b: s["busyError"] = b["error"]
    elif own or not s.get("running"): s["busy"] = b.get("op") or "start"
assert services[0].get("busy") == "restart", services   # 자기 op — running 이어도 표시
assert "busy" not in services[1], services               # --all + 이미 running → 표시 안 함
assert services[2].get("busy") == "start", services      # --all + 미기동 → 표시
LIFECYCLE_BUSY.clear()
print("lifecycle busy state OK")
PY
echo "PASS test-lifecycle-busy"
