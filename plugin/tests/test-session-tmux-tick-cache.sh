#!/usr/bin/env bash
# (2026-10-23 loadlog) 데몬 한 판(4초)마다 tmux 가 100번 넘게(실측 109) 떠 CPU 를 상시 20~40% 썼다
#  → 판 안에서는 같은 조회를 한 번만(세션 생존은 list-sessions 한 번). 키 입력이 끼면 버리고, 1.5초 넘으면 다시 읽는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import subprocess, sys, threading, time
import marina_session as ms
fails = []
def check(c, m):
    if not c: fails.append(m)
base = ms._tmux_base()
subprocess.run(base + ["new-session", "-d", "-s", "tc-a", "sh", "-c", "printf 'one\\n'; exec cat"], check=True)
time.sleep(0.3)
n = [0]; real = subprocess.run
def spy(args, *a, **k):
    n[0] += 1
    return real(args, *a, **k)
subprocess.run = spy

with ms.tmux_tick_cache():
    check(ms.tmux_alive("tc-a") and not ms.tmux_alive("tc-zz") and ms.tmux_alive("tc-a"), "생존 판정은 그대로")
    first = n[0]
    check(first == 1, f"세션 목록 한 번으로 전부: {first}")
    a = ms._tmux("capture-pane", "-p", "-t", "tc-a").stdout
    b = ms._tmux("capture-pane", "-p", "-t", "tc-a").stdout
    check(a == b and "one" in a and n[0] == first + 1, f"같은 화면 읽기는 한 번: {n[0]}")
    ms._tmux("send-keys", "-t", "tc-a", "-l", "two"); ms._tmux("send-keys", "-t", "tc-a", "Enter"); time.sleep(0.3)
    c = ms._tmux("capture-pane", "-p", "-t", "tc-a").stdout
    check("two" in c, f"키 입력이 끼면 다시 읽는다: {c!r}")
    k = n[0]; ms.TICK_TTL, old = 0.1, ms.TICK_TTL; time.sleep(0.2)
    ms._tmux("capture-pane", "-p", "-t", "tc-a"); ms.TICK_TTL = old
    check(n[0] == k + 1, "오래되면 다시 읽는다")
    seen = []
    t = threading.Thread(target=lambda: seen.append(ms._tmux("capture-pane", "-p", "-t", "tc-a") is not None and n[0]))
    k = n[0]; t.start(); t.join()
    check(n[0] == k + 1, "다른 스레드는 캐시를 안 쓴다")
subprocess.run(base + ["new-session", "-d", "-s", "tc-ab", "sh", "-c", "exec cat"], check=True)
with ms.tmux_tick_cache():
    check(ms.tmux_alive("tc-ab") and not ms.tmux_alive("tc") and not ms.tmux_alive("tc-a-"), "이름은 정확히 일치할 때만")
    k = n[0]; ms._tmux("capture-pane", "-p", "-t", "tc-a"); ms.tmux_tick_fresh(); ms._tmux("capture-pane", "-p", "-t", "tc-a")
    check(n[0] == k + 2, "tmux_tick_fresh 뒤엔 다시 읽는다")
    with ms.tmux_tick_cache():
        pass
    check(ms._TICK.cache is not None, "안쪽 판이 끝나도 바깥 판 캐시는 그대로")
try:
    with ms.tmux_tick_cache():
        raise RuntimeError("x")
except RuntimeError:
    pass
check(getattr(ms._TICK, "cache", None) is None, "예외로 빠져도 캐시가 남지 않는다")
subprocess.run(base + ["kill-session", "-t", "tc-ab"], capture_output=True)
k = n[0]
ms._tmux("capture-pane", "-p", "-t", "tc-a"); ms._tmux("capture-pane", "-p", "-t", "tc-a")
check(n[0] == k + 2, "판 밖에선 매번 읽는다")
subprocess.run = real
subprocess.run(base + ["kill-session", "-t", "tc-a"], capture_output=True)
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-tmux-tick-cache"
