#!/usr/bin/env bash
# 채널 수명 = 워크트리 수명 — 분리 A 의 새 계약(스펙 3장): runtime 은 Discord 를 모른다.
#  - discord 는 개발 세션 워크트리를 git 표준 잠금('marina-session <ref>')으로 잠근다 → runtime 삭제·7일 정리가 건너뜀
#  - 워크트리가 밖에서 지워지면(force·git) discord 가 사라진 걸 두 번(≥2분 간격) 보고 채널·세션을 정리한다
#  - rm 은 잠금을 풀고(워크트리는 그대로), lock-all 은 기존 세션을 한 번에 잠근다. sessions.json 이 깨져도 예외 없음
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new a"
msess new proj feat/b --no-start >/dev/null 2>&1 || fail "new b"

PYTHONPATH="$SCRIPTS" python3 - "$SRC" "$FD" <<'PY'
import json, subprocess, sys, time
from pathlib import Path
src, fd = Path(sys.argv[1]), Path(sys.argv[2])
import marina_session as ms
import marina_lifecycle
import marina_liveness as lv
import marina_worktree_gc as gc
from marina_registry import discover_all_roots
discover_all_roots(refresh=True)
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
a = ms.find_session("proj/feat/a"); b = ms.find_session("proj/feat/b")
ra, rb = Path(a["root"]), Path(b["root"])
marina_lifecycle.stop_all = lambda root: {"stoppedAll": True}
marina_lifecycle.cleanup_session = lambda root: {"removed": ""}
marina_lifecycle.bootout_session_dashboard = lambda sid: None

# 1) 만들면 잠긴다
la = lv.worktree_lock(ra)
check(la and la["owner"] == "marina-session" and "proj/feat/a" in la["reason"], f"새 세션 워크트리는 잠긴다: {la}")

# 2) runtime 은 잠금만 본다 — 삭제는 force 없이 거절, 7일 정리는 건너뜀
try:
    marina_lifecycle.remove_worktree(ra, keep_images=True); check(False, "잠긴 세션 워크트리를 지웠다")
except ValueError as exc:
    check("잠김" in str(exc), f"이유: {exc}")
v = gc.idle_verdict(ra, {"lastCommitTs": time.time() - 30 * 86400}, [], set(), days=14)
check(v["gcIdle"] is False and v.get("gcLocked"), f"세션 워크트리는 정리 안 함: {v}")

# 3) 밖에서 지워지면(force) — 바로는 안 지우고, 2분 넘게 계속 없을 때 채널·세션 정리
marina_lifecycle.remove_worktree(ra, force=True, keep_images=True)
check(not ra.exists(), "force 삭제")
t = time.time()
check(ms.reconcile_gone(t) == [], "처음 본 순간엔 정리 안 함")
check(ms.reconcile_gone(t + 60) == [], "2분 안엔 정리 안 함")
check(ms.reconcile_gone(t + 121) == ["proj/feat/a"], "2분 넘게 없으면 정리")
log = (fd / "log.jsonl").read_text()
check(f'"DELETE", "p": "/channels/{a["channelId"]}"' in log, "채널 삭제 요청")
check(all(s.get("task") != "feat/a" for s in ms.load_sessions()), "기록 삭제")
check(any(s.get("task") == "feat/b" for s in ms.load_sessions()), "다른 세션은 그대로")

# 4) 잠깐 사라졌다 돌아오면 정리 안 함
tmp = rb.with_name(rb.name + ".moved"); rb.rename(tmp)
check(ms.reconcile_gone(t) == [], "b 사라짐 첫 관찰")
tmp.rename(rb)
check(ms.reconcile_gone(t + 30) == [], "돌아오면 기록 지움")
rb.rename(tmp)
check(ms.reconcile_gone(t + 200) == [], "다시 사라지면 처음부터 센다(이전 관찰 무효)")
tmp.rename(rb)
ms.reconcile_gone(t + 210)

# 5) rm 은 잠금을 풀고 워크트리는 남긴다
check(ms.main(["rm", "proj/feat/b"]) == 0, "rm")
check(rb.exists() and lv.worktree_lock(rb) is None, "rm → 잠금 풀림, 워크트리 남음")

# 6) lock-all — 배포 전에 만든(잠금 없는) 세션도 잠근다. 채팅방·로비·메인 체크아웃은 건너뜀
items = ms.load_sessions()
items.append({"project": "proj", "task": "old", "root": str(rb), "channelId": "C9", "tmux": "x", "stateDir": "", "createdAt": 0})
items.append({"project": "chat", "task": "c1", "kind": "chat", "root": str(src), "channelId": "C8", "tmux": "y", "stateDir": "", "createdAt": 0})
items.append({"project": "proj", "task": "main", "root": str(src), "channelId": "C7", "tmux": "z", "stateDir": "", "createdAt": 0})
ms.save_sessions(items)
check(ms.main(["lock-all"]) == 0, "lock-all 성공(메인 체크아웃은 잠글 수 없어도 실패 아님)")
check((lv.worktree_lock(rb) or {}).get("owner") == "marina-session", "기존 세션 잠금")

# 8) 리뷰 I5: 배포 전부터 돌던 세션(잠금 없음)은 reconcile 이 알아서 잠근다(lock-all 을 안 쳐도)
subprocess.run(["git", "-C", str(src), "worktree", "unlock", str(rb)], capture_output=True)
ms.reconcile_gone(time.time())
check((lv.worktree_lock(rb) or {}).get("owner") == "marina-session", "잠금 없는 기존 세션을 reconcile 이 잠근다")
# 9) 리뷰 I4: 데스크톱 claude --worktree 대화를 adopt — Claude 자기 잠금(살아 있어도)은 marina-session 으로 바꿔 건다
subprocess.run(["git", "-C", str(src), "worktree", "unlock", str(rb)], capture_output=True)
import os
subprocess.run(["git", "-C", str(src), "worktree", "lock", "--reason", f"claude session feat-b (pid {os.getpid()} start x)", str(rb)], check=True)
why = ms.lock_root({"project": "proj", "task": "old", "root": str(rb)})
check(why == "" and (lv.worktree_lock(rb) or {}).get("owner") == "marina-session", f"Claude 잠금은 넘겨받는다: {why} {lv.worktree_lock(rb)}")
subprocess.run(["git", "-C", str(src), "worktree", "unlock", str(rb)], capture_output=True)
subprocess.run(["git", "-C", str(src), "worktree", "lock", "--reason", "someone-else x", str(rb)], check=True)
check(ms.lock_root({"project": "proj", "task": "old", "root": str(rb)}) != "", "다른 주인 잠금은 안 뺏는다(이유를 돌려줌)")
subprocess.run(["git", "-C", str(src), "worktree", "unlock", str(rb)], capture_output=True)

# 7) sessions.json 이 깨져도 예외 없음
ms.sessions_path().write_text("{broken")
check(ms.reconcile_gone(time.time()) == [], "깨진 기록 → 정리할 것 없음")
check("marina_session" not in Path(gc.__file__).read_text() + Path(marina_lifecycle.__file__).read_text(),
      "runtime 은 Discord 코드를 안 부른다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-worktree-hooks"
