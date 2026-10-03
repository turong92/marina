#!/usr/bin/env bash
# 분리 D: marina-discord 는 marina 강제 자동 업데이트 대상이 아니다 → discord 데몬이 스스로(형 결정: discord 도 자동)
#  - 1시간마다, 설치본으로 돌 때만. 깔기 전에 새 코드가 데몬 파이썬으로 import 되는지 검사 — 실패한 버전은 다시 안 깐다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
PYTHONPATH="$DSCRIPTS" python3 - "$MARINA_HOME" <<'PY'
import json, sys
from pathlib import Path
import marina_session as ms
fails = []
def check(c, m):
    if not c: fails.append(m)
runs = []
def run(argv):
    runs.append(argv[1:]); return 0, ""
ok = lambda d: (True, "")
check(ms.self_update_tick(1000.0, installed=False, run=run, preflight=ok, new_sha=lambda: "s1") == "skip:dev" and not runs, "작업 트리면 안 함")
check(ms.self_update_tick(1000.0, installed=True, run=run, preflight=ok, new_sha=lambda: "s1") == "updated", "설치본이면 받고 깐다")
check(["plugin", "marketplace", "update", "marina-dev"] in runs and ["plugin", "update", "marina-discord@marina-dev"] in runs, f"명령: {runs}")
runs.clear()
check(ms.self_update_tick(1000.0 + 600, installed=True, run=run, preflight=ok, new_sha=lambda: "s2") == "skip:not-due" and not runs, "1시간 안엔 안 함")
bad = lambda d: (False, "SyntaxError")
check(ms.self_update_tick(1000.0 + 3700, installed=True, run=run, preflight=bad, new_sha=lambda: "s3") == "rejected" , "import 실패면 안 깐다")
check(["plugin", "update", "marina-discord@marina-dev"] not in runs, "거절한 버전은 설치 명령 없음")
runs.clear()
check(ms.self_update_tick(1000.0 + 7400, installed=True, run=run, preflight=ok, new_sha=lambda: "s3") == "skip:rejected" and \
      ["plugin", "update", "marina-discord@marina-dev"] not in runs, "한 번 거절한 버전은 다시 시도 안 함")
import os
os.environ["MARINA_AUTO_UPDATE"] = "0"
check(ms.self_update_tick(1000.0 + 20000, installed=True, run=run, preflight=ok, new_sha=lambda: "s9") == "off", "MARINA_AUTO_UPDATE=0 이면 끔")
# (리뷰 I3) 끄기 값은 marina 와 같게(off/false/no 도)
for v in ("off", "false", "no", "OFF"):
    os.environ["MARINA_AUTO_UPDATE"] = v
    check(ms.self_update_tick(1000.0 + 30000, installed=True, run=run, preflight=ok, new_sha=lambda: "s9") == "off", f"{v} 도 끔")
del os.environ["MARINA_AUTO_UPDATE"]
# (리뷰 M1) 도중에 예외가 나도 lastAt 은 먼저 저장 — 1분마다 다시 받는 루프가 안 된다
def boom(): raise RuntimeError("git 멈춤")
try:
    ms.self_update_tick(1000.0 + 40000, installed=True, run=run, preflight=ok, new_sha=boom)
except RuntimeError:
    pass
check(ms.self_update_tick(1000.0 + 40060, installed=True, run=run, preflight=ok, new_sha=lambda: "s9") == "skip:not-due", "예외 뒤에도 1시간 쉼")
# (리뷰 I2) 설치본이 바뀌었어도 새 설치본이 import 안 되면 끝내지 않는다(옛 코드로 계속 — 봇 벽돌 방지)
import threading, time
calls = []
check(ms._daemon_stop_check(updated=lambda: Path("/new/scripts"), preflight=lambda d: (False, "SyntaxError"),
                            tick=lambda now: calls.append(now)) is False, "깨진 새 설치본이면 계속 돈다")
check(ms._daemon_stop_check(updated=lambda: Path("/new/scripts"), preflight=lambda d: (True, ""), tick=lambda now: None) is True,
      "멀쩡한 새 설치본이면 끝낸다")
check(ms._daemon_stop_check(updated=lambda: None, preflight=ok, tick=lambda now: None) is False, "안 바뀌었으면 계속")
# (리뷰 I4) 업데이트(최대 수 분)가 봇 루프를 막지 않는다 — 뒤에서, 하나만
gate = threading.Event()
slow_calls = []
def slow(now):
    slow_calls.append(now); gate.wait(5)
t0 = time.time()
ms._daemon_stop_check(updated=lambda: None, preflight=ok, tick=slow)
ms._daemon_stop_check(updated=lambda: None, preflight=ok, tick=slow)
check(time.time() - t0 < 1.0, "업데이트를 기다리지 않는다")
time.sleep(0.2); gate.set()
check(len(slow_calls) == 1, f"동시에 하나만: {slow_calls}")
# (리뷰 I1) 데몬이 업데이트로 끝나면 사람(훅)을 기다리지 않고 새 코드로 스스로 다시 띄운다
spawned = []
ms._spawn_daemon = lambda: spawned.append(1) or 4242
ms.daemon_pid_path().write_text(f"{os.getpid()}\n")
ms._daemon_handoff()
check(spawned == [1] and ms.daemon_pid_path().read_text().strip() == "4242", f"새 데몬 띄움: {spawned}")
# 실제 사전 검사: 지금 코드는 통과, 깨진 코드는 거절
import tempfile, shutil
okk, why = ms._preflight(Path(ms.__file__).resolve().parent)
check(okk, f"지금 코드 import 통과: {why}")
broken = Path(tempfile.mkdtemp())
for f in Path(ms.__file__).resolve().parent.glob("*.py"):
    shutil.copy(f, broken / f.name)
(broken / "marina_discord_ask.py").write_text("def x(:\n")
check(ms._preflight(broken)[0] is False, "깨진 코드는 거절")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-autoupdate"
