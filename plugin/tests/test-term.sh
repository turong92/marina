#!/usr/bin/env bash
# 터미널 탭 백엔드(marina_term) — PTY 세션 열기/워크트리당 재사용/입력→출력 왕복/리사이즈/종료,
# 핸들러 게이트웨이 가드(X-Forwarded 거부)·프론트 문법 계약.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SCR" "$TMP" <<'PY'
import sys, time
from pathlib import Path
scr, tmp = sys.argv[1:3]
sys.path.insert(0, scr)
import marina_term as mt

d = mt.term_open(Path(tmp), 80, 24)
assert not d["reused"] and d["tid"], d
d2 = mt.term_open(Path(tmp), 100, 30)
assert d2["reused"] and d2["tid"] == d["tid"], "워크트리당 세션 1개 재사용 계약"
tid = d["tid"]

mt.term_input(tid, "echo TERM_$((40+2))\n")
term = mt._by_tid[tid]
deadline = time.time() + 15   # -il 셸 기동(rc 로드) 여유
while time.time() < deadline:
    with term.cond:
        if b"TERM_42" in bytes(term.history):
            break
    time.sleep(0.2)
else:
    raise AssertionError(f"PTY 출력 미도착: {bytes(term.history)[-300:]!r}")

mt.term_resize(tid, 120, 40)   # 예외 없이 통과하면 충분(WINSZ ioctl)
mt.term_kill(tid)
try:
    mt.term_input(tid, "x")
    raise AssertionError("kill 후 입력이 살아있음")
except ValueError:
    pass
d3 = mt.term_open(Path(tmp), 80, 24)
assert not d3["reused"], "kill 후엔 새 세션이어야"
mt.term_kill(d3["tid"])
print("ok term open/reuse/io/resize/kill")
PY

# 핸들러 계약 — 터미널 = 원격 코드 실행: 게이트웨이 경유(X-Forwarded-*) 거부 + 엔드포인트 존재
grep -q 'x-forwarded-for' "$SCR/marina_handler.py" || { echo "FAIL: 터미널 게이트웨이 가드 없음"; exit 1; }
grep -q '"/api/term-stream"' "$SCR/marina_handler.py" || { echo "FAIL: term-stream 엔드포인트 없음"; exit 1; }
grep -q '"/api/term-open"' "$SCR/marina_handler.py" || { echo "FAIL: term-open 엔드포인트 없음"; exit 1; }

# 프론트 계약 — 입력 직렬 큐(병렬 fetch 유실 방지)·vendor 로드·탭 활성화
J="$SCR/marina-web/app-10-term.js"
grep -q "termSendChain" "$J" || { echo "FAIL: 입력 직렬 큐 없음(병렬 fetch 는 글자 유실)"; exit 1; }
grep -q "WS_VIEWS.term" "$J" || { echo "FAIL: 터미널 탭 등록 없음"; exit 1; }
grep -q "vendor-xterm.js" "$SCR/marina-web/index.html" || { echo "FAIL: xterm vendor 로드 없음"; exit 1; }
! grep -q 'data-ws-tab="term" disabled' "$SCR/marina-web/index.html" || { echo "FAIL: 터미널 탭이 여전히 disabled"; exit 1; }
if command -v node >/dev/null 2>&1; then node --check "$J" || { echo "FAIL: 문법 오류 $J"; exit 1; }; fi
echo "PASS test-term"
