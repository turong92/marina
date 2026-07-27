#!/usr/bin/env bash
# PTY 자식 수거(reaping). 세션이 끝나도 좀비(<defunct>)로 남으면 안 된다.
# EOF 직후 waitpid(WNOHANG) 을 **한 번만** 부르면 그 순간 자식이 아직 안 끝난 경우 빈손으로
# 돌아오고, 그 좀비를 다시 거둘 사람이 없어 프로세스 테이블에 영원히 남는다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

PYTHONPATH="$SCR" python3 - <<'PY'
# 진짜 자식 프로세스로 진짜 좀비를 만든다(subprocess 는 스스로 거둬가므로 posix_spawn 을 쓴다).
import os, signal, subprocess, sys, time
import marina_term as mt

def state(pid):
    out = subprocess.run(["ps", "-o", "state=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    return out

pid = os.posix_spawn(sys.executable, [sys.executable, "-c", "import time; time.sleep(60)"], os.environ)
os.kill(pid, signal.SIGKILL)
for _ in range(50):                       # 좀비가 될 때까지
    if state(pid).startswith("Z"): break
    time.sleep(0.05)
assert state(pid).startswith("Z"), f"좀비를 만들지 못했다: {state(pid)!r}"

# 수거 등록 후 한 번의 스윕이면 사라져야 한다
mt._register_reap(pid)
for _ in range(50):
    if not state(pid): break
    mt._reap_children()
    time.sleep(0.05)
assert not state(pid), f"좀비가 수거되지 않았다: {state(pid)!r}"
assert pid not in mt._pending_reap, mt._pending_reap
print("ok dead PTY children are reaped, not left as zombies")
PY

PYTHONPATH="$SCR" python3 - <<'PY'
# 아직 안 끝난 자식은 계속 물고 있다가(재시도) 끝나는 순간 거둔다 — 이게 한 번짜리 WNOHANG 과의 차이.
import os, signal, subprocess, sys, time
import marina_term as mt

def state(pid):
    return subprocess.run(["ps", "-o", "state=", "-p", str(pid)],
                          capture_output=True, text=True).stdout.strip()

pid = os.posix_spawn(sys.executable, [sys.executable, "-c", "import time; time.sleep(0.6)"], os.environ)
mt._register_reap(pid)                    # 살아있는 동안 등록 — 첫 시도는 빈손이다
assert pid in mt._pending_reap, "살아있는 자식을 놓아버렸다(그러면 나중에 좀비로 남는다)"
time.sleep(1.2)                           # 자식이 스스로 끝난다
for _ in range(50):
    mt._reap_children()
    if not state(pid): break
    time.sleep(0.05)
assert not state(pid), f"뒤늦게 끝난 자식이 좀비로 남았다: {state(pid)!r}"
assert pid not in mt._pending_reap, mt._pending_reap
print("ok a child that exits later is still reaped on a subsequent sweep")
PY

PYTHONPATH="$SCR" python3 - <<'PY'
# 남의 자식은 건드리지 않는다. waitpid(-1) 로 싹쓸이하면 subprocess.run 이 기다리던 자식을
# 가로채 ECHILD 로 깨진다 — marina 는 git/ps 를 subprocess 로 계속 부른다.
import subprocess
import marina_term as mt

proc = subprocess.Popen(["sleep", "1"])
mt._register_reap(999999)                 # 우리 자식이 아닌 pid — 조용히 놓아준다
mt._reap_children()
assert 999999 not in mt._pending_reap, mt._pending_reap
assert proc.wait(timeout=5) == 0, "subprocess 의 자식을 가로챘다"
print("ok reaping never steals another waiter's child")
PY

# 배선: 세션이 끝나는 모든 길목(리더 EOF·term_kill)이 수거를 등록하고, 폴마다 재시도한다.
SRC="$SCR/marina_term.py"
grep -q "_register_reap(term.pid)" "$SRC" || { echo "FAIL: 세션 종료 경로가 수거를 등록하지 않는다"; exit 1; }
test "$(grep -c "_register_reap(term.pid)" "$SRC")" -ge 2 \
  || { echo "FAIL: 리더 EOF·term_kill 양쪽에서 등록해야 한다"; exit 1; }
grep -q "_reap_children()" "$SRC" || { echo "FAIL: 재시도 스윕이 없다"; exit 1; }
grep -q "os.waitpid(-1" "$SRC" && { echo "FAIL: waitpid(-1) 은 남의 자식을 가로챈다"; exit 1; }

echo "PASS test-term-reap"
