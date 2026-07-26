#!/usr/bin/env bash
# worktree_info 는 만료돼도 요청을 붙잡지 않는다(stale-while-revalidate).
# TTL(15s)이 끝나는 순간의 요청이 root 전체 git 서브프로세스를 기다리던 것이 첫 화면 지연의 원인이었다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import sys, time
from pathlib import Path
import marina_sessions as ms
from marina_state import _worktree_info_cache

root = Path(sys.argv[1]) / "wt"; root.mkdir(parents=True, exist_ok=True)
key = str(root)

calls = {"n": 0}
real_status = ms.worktree_status
def slow_status(r):
    calls["n"] += 1
    time.sleep(0.4)                      # 느린 git 흉내
    return real_status(r)
ms.worktree_status = slow_status

# 1) 콜드 캐시 — 계산한다(느려도 어쩔 수 없다)
_worktree_info_cache.pop(key, None)
t0 = time.time(); ms.worktree_info(root); cold = time.time() - t0
assert cold >= 0.4, cold
assert calls["n"] == 1, calls

# 2) 신선한 캐시 — 계산 없음
t0 = time.time(); ms.worktree_info(root); fresh = time.time() - t0
assert fresh < 0.2, fresh
assert calls["n"] == 1, calls

# 3) 만료된 캐시 — **즉시 반환**하고 뒤에서 갱신한다
stamp, payload = _worktree_info_cache[key]
_worktree_info_cache[key] = (stamp - (ms.WORKTREE_INFO_TTL + 1), payload)
t0 = time.time(); got = ms.worktree_info(root); stale = time.time() - t0
assert stale < 0.2, f"만료 캐시가 요청을 붙잡았다: {stale:.3f}s"
assert got is payload, "옛 값을 그대로 돌려줘야 한다"
# 갱신 '시작'이 아니라 '완료'를 기다린다 — 캐시 타임스탬프가 새로 찍히는 시점이 완료다.
stale_stamp = _worktree_info_cache[key][0]
for _ in range(60):
    if _worktree_info_cache[key][0] > stale_stamp: break
    time.sleep(0.05)
assert calls["n"] == 2, f"백그라운드 갱신이 돌지 않았다: {calls}"
assert _worktree_info_cache[key][0] > stale_stamp, "갱신 후 타임스탬프가 새로워야 한다"

# 4) 너무 오래된 캐시 — 그땐 동기 계산(무한정 옛 배지 금지)
stamp, payload = _worktree_info_cache[key]
_worktree_info_cache[key] = (stamp - (ms.WORKTREE_INFO_MAX_STALE + 1), payload)
before = calls["n"]
t0 = time.time(); ms.worktree_info(root); ancient = time.time() - t0
assert ancient >= 0.4, f"아주 오래된 캐시는 동기 계산해야 한다: {ancient:.3f}s"
assert calls["n"] == before + 1, calls
print("ok worktree_info serves stale immediately and refreshes behind")
PY

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
# 동시 요청이 몰려도 백그라운드 갱신은 한 번만 돈다(single-flight).
import sys, threading, time
from pathlib import Path
import marina_sessions as ms
from marina_state import _worktree_info_cache

root = Path(sys.argv[1]) / "wt2"; root.mkdir(parents=True, exist_ok=True)
key = str(root)
calls = {"n": 0}
real_status = ms.worktree_status
def slow_status(r):
    calls["n"] += 1
    time.sleep(0.3)
    return real_status(r)
ms.worktree_status = slow_status

ms.worktree_info(root)                       # 캐시 채우기(계산 1회)
stamp, payload = _worktree_info_cache[key]
_worktree_info_cache[key] = (stamp - (ms.WORKTREE_INFO_TTL + 1), payload)

threads = [threading.Thread(target=lambda: ms.worktree_info(root)) for _ in range(8)]
[t.start() for t in threads]
[t.join() for t in threads]
time.sleep(0.8)
assert calls["n"] == 2, f"동시 8건에 갱신이 여러 번 돌았다: {calls}"
print("ok concurrent stale reads collapse into one refresh")
PY

echo "PASS test-worktree-info-swr"
