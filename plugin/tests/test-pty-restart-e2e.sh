#!/usr/bin/env bash
# PTY 영속화 실-fork e2e — 진짜 term_open(pty.fork) 자식을 만들고, marina-control 재시작을 시뮬레이션
# (인메모리 레지스트리 리셋)한 뒤, 디스크 메타에서 그 세션이 재구성되어 reachable 인지 못박는다.
# (리뷰어 ⚠️: "실제 에이전트가 재시작을 살아남고 재구성되나" 를 실 프로세스로 검증.)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

MARINA_HOME="$TMP/marina" python3 - "$SCRIPTS" "$TMP" <<'PY'
import sys, os, time, importlib
from pathlib import Path
scripts, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)

import marina_term as mt
fails = []
child_pid = None
try:
    root = Path(tmp) / "wt"; root.mkdir(parents=True, exist_ok=True)

    # 1) 진짜 PTY 세션 오픈(pty.fork → 로그인 셸). 입력 없이도 셸은 살아있다.
    res = mt.term_open(root, cols=80, rows=24)
    tid = str(res["tid"])
    child_pid = mt._by_tid[tid].pid
    meta = Path(os.environ["MARINA_HOME"]) / "terms" / f"{tid}.json"
    if not meta.is_file():
        fails.append(f"meta 파일 미기록: {meta}")
    if not any(t.get("tid") == tid for t in mt.term_list().get("sessions", [])):
        fails.append("open 직후 term_list 에 없음")

    # 2) 재시작 시뮬레이션 — 인메모리 레지스트리를 통째 날린다(새 프로세스 로드처럼).
    #    자식(셸)은 이 파이썬의 자식이라 계속 살아있다 = "에이전트가 marina 재시작 살아남음" 재현.
    mt._by_tid.clear(); mt._by_key.clear()
    mt._reconstructed = False   # 재구성 1회 가드 리셋

    # 3) 재구성 — term_list 진입 시 lazy 재구성. 살아있는 pid+pid_start 일치 → detached 로 복귀.
    sessions = mt.term_list().get("sessions", [])
    row = next((t for t in sessions if t.get("tid") == tid), None)
    if row is None:
        fails.append("재시작 후 재구성 실패 — term_list 에 없음(reachable 아님)")
    else:
        if not row.get("alive", True):
            fails.append(f"재구성된 세션이 alive 아님: {row}")
        term = mt._by_tid.get(tid)
        if term is None or getattr(term, "fd", 0) != -1 or not getattr(term, "detached", False):
            fails.append(f"재구성 세션은 fd=-1 detached 여야: {term and (term.fd, getattr(term,'detached',None))}")
        # reuse-by-key: 같은 셸 세션이 중복 spawn 되지 않고 그대로 잡히는지(_by_key 복원)
        if term is not None and term.key and mt._by_key.get(term.key) is not term:
            fails.append("reuse-by-key(_by_key) 복원 실패")

    # 4) detached 세션에 term_input → 우아한 실패(ValueError), 크래시 아님.
    try:
        mt.term_input(tid, "echo hi\n")
        fails.append("detached term_input 이 예외 없이 통과함(우아한 실패여야)")
    except ValueError:
        pass
    except Exception as e:
        fails.append(f"detached term_input 이 ValueError 아닌 예외: {type(e).__name__}: {e}")

    # 5) 자식 종료 → 재구성/reap 시 죽은 세션 정리 + 메타 삭제.
    os.kill(child_pid, 9); child_pid = None
    time.sleep(0.3)
    mt._by_tid.clear(); mt._by_key.clear(); mt._reconstructed = False
    sessions2 = mt.term_list().get("sessions", [])
    if any(t.get("tid") == tid for t in sessions2):
        fails.append("죽은 세션이 재구성에서 정리 안 됨")
    if meta.is_file():
        fails.append("죽은 세션 메타 파일 미삭제")
finally:
    if child_pid:
        try: os.kill(child_pid, 9)
        except OSError: pass

if fails:
    print("FAIL"); [print("  -", f) for f in fails]; sys.exit(1)
print("PASS: real fork → persisted → simulated restart → reconstructed reachable(detached) → dead purged")
PY
