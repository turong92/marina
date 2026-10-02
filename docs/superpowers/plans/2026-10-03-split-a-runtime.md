# 분리 A — runtime 떼기 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** runtime 코드가 dashboard·discord 코드를 전혀 부르지 않게 하고, runtime 이 혼자 도는 데 필요한 것을 갖춘다. 필요한 것은 청소 상주 프로그램, Claude Code 워크트리 훅, 잠금 판정, `bin/marina`. 이번 단계에서 지금 쓰는 기능은 하나도 안 깨진다.

**Architecture:** runtime 은 지금 폴더 `plugin/` 와 플러그인 id `marina@marina-dev` 를 그대로 쓴다. 팀원 설치·`~/.local/bin/marina`·codex 가 이 id 에 묶여 있기 때문이다.
- `marina_sessions.py`(대시보드 겸용)에 섞인 실행 쪽 함수는 새 runtime 모듈로 옮긴다.
  - git·워크트리 상태 → `marina_worktrees.py`
  - 에이전트 프로세스·git 잠금 → `marina_liveness.py`
- `marina_sessions` 는 옮긴 이름을 다시 import 해서 대시보드 쪽 호출은 그대로 둔다.
- 경계 테스트가 "runtime 모듈 목록은 목록 안의 모듈만 import 한다"를 기계로 지킨다.
- dashboard·discord 를 새 폴더로 옮기는 건 B·C 단계다.

**Tech Stack:** Python 3.9(데몬 인터프리터, PEP 604 금지), bash, git worktree, launchd/systemd --user, Claude Code hooks(WorktreeCreate/WorktreeRemove).

**Spec:** `docs/superpowers/specs/2026-10-03-runtime-plugin-boundary-design.md`

## Global Constraints

- 데몬 python = `/Library/Developer/CommandLineTools/.../Python3.framework/Versions/3.9/bin/python3` — `str | None`·`match` 금지. 새 모듈은 `from __future__ import annotations` 로 시작한다. test-py39-compat 가 통과해야 한다.
- 모든 테스트는 `. lib/harness.sh` 로 격리한다. 죽이거나 지우는 코드는 테스트에서 **자기가 만든 대상만** 건드린다(리퍼 사고).
- 실제 자동 삭제(GC)는 기록된 데몬에서만 돈다. 격리 프리뷰가 실 도커 9.2GB 를 지운 사고가 있었다.
- 커밋 메시지는 Conventional Commits 를 쓰고 Co-Authored-By 를 넣지 않는다. push·배포는 형 허락을 받고 한다.
- 지금 쓰는 동작은 하나도 바뀌지 않는다. 의도된 변경은 셋뿐이다.
  - 잠긴 워크트리 삭제 거부
  - Discord 정리 경로 변경
  - 청소 루프 이사

## Review Focus

1. **전역 훅 영향:** `WorktreeCreate`/`WorktreeRemove` 는 플러그인 훅이라 **모든 레포의** `claude --worktree`·서브에이전트 `isolation: worktree` 에 걸린다. 마리나 프로젝트가 아닌 레포와 팀원 맥에서도 기본 동작(`<repo>/.claude/worktrees/<name>`, 브랜치 `worktree-<name>`)과 같아야 한다. 마리나 쪽 경로가 예외를 내도 기본 동작으로 떨어져야 한다.
2. **낡은 잠금:** Claude Code 는 죽어도 잠금(`claude session X (pid N …)`)을 남긴다. pid 가 죽었으면 무시해야 한다. 이게 없으면 GC 가 영영 못 지운다.
3. **pid 재사용:** 잠금의 pid 가 재사용돼 다른 프로세스가 살아 있으면 잠금이 계속 지켜진다. 판정이 보수적인 쪽(안 지움)으로 틀리는 건 받아들인다.
4. **청소 이중 실행:** 업데이트 직후 옛 대시보드 데몬(청소 루프 있음)과 새 runtimed 가 같이 돌 수 있다. 도커 GC·워크트리 GC 가 두 번 돌아도 안전해야 한다. 각 tick 은 자기 상태 파일의 "마지막 실행 시각"으로 주기를 지킨다.
5. **Discord 사후 정리 오탐:** 워크트리 폴더가 잠깐 안 보이는 경우가 있다(외장 디스크·이름 바꾸기). 이때 채널을 지우면 안 된다. "두 번 연속(≥ 2분 간격) 사라짐 + git 이 그 워크트리를 모름"일 때만 정리한다.

---

### Task 1: `marina_worktrees.py` — git·워크트리 상태를 runtime 으로

**Files:**
- Create: `plugin/scripts/marina_worktrees.py`
- Modify: `plugin/scripts/marina_sessions.py` (함수 본문 제거 → `from marina_worktrees import …`)
- Modify: `plugin/scripts/marina_rooms.py` (`own_changed_paths` 본문 제거 → import)
- Modify: `plugin/scripts/marina_lifecycle.py:27`, `marina_worktree_gc.py:254`, `marina_git.py:18` (import 경로를 marina_worktrees 로)
- Test: `plugin/tests/test-runtime-boundary.sh`(신규, Task 9 에서 완성 — 여기선 marina_worktrees 만 검사)

**Interfaces:**
- Produces (marina_worktrees, 시그니처 그대로 이동):
  - `git_output(args, cwd) -> str`, `status_lines(repo, ignore_top_level=None)`, `_repo_status_entry`, `compose_scoped_subrepos(root)`
  - `worktree_status(root) -> dict`, `worktree_status_cached(root, ttl=15.0)`
  - `svc_state(s)`, `session_payload(root, memory=None) -> dict`, `log_targets_for(root)`
  - `repo_last_commit_ts`·`repo_branch`·`repo_ahead_of_main`·`worktree_labels`·`worktree_info(root, refresh=False)`·`warm_worktree_info(roots)`, 그리고 이들이 쓰는 내부 함수·캐시 전부
  - `own_changed_paths(status_text, root) -> list[str]`(marina_rooms 에서)
  - `system_memory()`·`group_rss_mb()` 는 session_payload 계열이 쓰면 같이, 안 쓰면 그대로 둔다
- 이동 기준: 옮기는 함수가 쓰는 이름이 runtime 모듈(state·paths·registry·compose_svc·memory·cache·logtext·runtime_target·dockerfile) 밖이면 **옮기지 말고 멈춰서 Ruling 을 남긴다**

- [ ] **Step 1: 경계 테스트(작은 판) 먼저 작성**

`plugin/tests/test-runtime-boundary.sh`:
```bash
#!/usr/bin/env bash
# runtime 경계: runtime 모듈은 runtime 모듈만 import 한다(스펙 R1). 대시보드·discord 를 지워도 runtime 이 돈다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
python3 - "$SCRIPTS" <<'PY'
import ast, sys
from pathlib import Path
S = Path(sys.argv[1])
RUNTIME = {l.strip() for l in (S / "RUNTIME_MODULES").read_text().splitlines() if l.strip() and not l.startswith("#")}
bad = []
for name in sorted(RUNTIME):
    f = S / (name if name.endswith(".py") else name + ".py")
    tree = ast.parse(f.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        mods = []
        if isinstance(node, ast.Import):
            mods = [a.name for a in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module:
            mods = [node.module]
        for m in mods:
            if m.startswith("marina_") and m not in RUNTIME:
                bad.append(f"{f.name}:{node.lineno} → {m}")
if bad:
    print("FAIL: runtime 이 runtime 밖 모듈을 import:\n  " + "\n  ".join(bad)); sys.exit(1)
PY
echo "PASS test-runtime-boundary"
```
`plugin/scripts/RUNTIME_MODULES`(이번 Task 범위):
```
# runtime 모듈 목록(스펙 R1). 이 목록 안 모듈은 목록 안 모듈만 import 한다 — test-runtime-boundary
marina_state
marina_paths
marina_registry
marina_compose_svc
marina_dockerfile
marina_memory
marina_cache
marina_logtext
marina_runtime_target
marina_ssh_mux
marina_worktrees
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-runtime-boundary.sh`
Expected: FAIL — `marina_worktrees.py` 없음(FileNotFoundError)

- [ ] **Step 3: 이동**

1. `marina_sessions.py` 의 위 함수들(34–200행대·3225–3419행대·`warm_worktree_info`)을 **잘라서** `marina_worktrees.py` 로 옮긴다. 머리에 `from __future__ import annotations`, 필요한 stdlib import, runtime 모듈 import 를 단다.
2. `marina_sessions.py` 에 `from marina_worktrees import (git_output, status_lines, …)` 를 둔다(공개·내부 이름 전부). 다른 모듈·테스트가 `marina_sessions.X` 로 부르는 걸 그대로 살린다.
3. `marina_rooms.own_changed_paths` 를 옮기고 rooms 는 `from marina_worktrees import own_changed_paths` 한다.
4. lifecycle·worktree_gc·git 의 import 를 `marina_worktrees` 로 바꾼다.

옮긴 함수 안에서 `marina_term`·`marina_agent_events` 같은 runtime 밖 이름을 쓰는 게 나오면 멈춘다. 그 함수는 옮기지 않고 Ruling 으로 남긴다.

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-runtime-boundary.sh && bash plugin/tests/run-affected.sh`
Expected: PASS, run-affected 전부 PASS(이동만이라 동작 변화 0)

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina_worktrees.py plugin/scripts/RUNTIME_MODULES plugin/scripts/marina_sessions.py plugin/scripts/marina_rooms.py plugin/scripts/marina_lifecycle.py plugin/scripts/marina_worktree_gc.py plugin/scripts/marina_git.py plugin/tests/test-runtime-boundary.sh
git commit -m "refactor(runtime): git·워크트리 상태를 marina_worktrees 로 — 경계 테스트 시작"
```

---

### Task 2: `marina_liveness.py` — 에이전트 프로세스·git 잠금 판정

**Files:**
- Create: `plugin/scripts/marina_liveness.py`
- Modify: `plugin/scripts/marina_sessions.py` (`_parse_agent_pids`·`_live_agent_cwds`·`_crosses_nested_worktree`·`_root_has_live_agent` 이동 → import)
- Modify: `plugin/scripts/RUNTIME_MODULES` (+ marina_liveness)
- Test: `plugin/tests/test-liveness-lock.sh`(신규)

**Interfaces:**
- Produces:
  - `live_agent_cwds(refresh=False) -> set[Path]`. 옛 이름 `_live_agent_cwds` 도 별칭으로 남긴다.
  - `root_has_live_agent(root, live_cwds) -> bool`. 별칭 `_root_has_live_agent`.
  - `worktree_lock(root: Path) -> dict | None`. 결과는 `{"reason": str, "owner": str, "pid": int | None, "stale": bool}`.
    - 잠기지 않았으면 `None`.
    - `reason` 의 첫 낱말이 owner 다. `(pid N` 이 있으면 pid 를 읽는다.
    - stale 은 `pid 가 있고 os.kill(pid, 0) 이 ProcessLookupError` 일 때만 참이다. 권한 오류는 살아 있는 것으로 본다.
  - `lock_holds(root, me: str = "") -> dict | None`. 잠금이 유효하고 owner ≠ me 이면 그 잠금 dict 를, 아니면 `None` 을 돌려준다.
- 잠금 파일 위치: `git -C <root> rev-parse --git-dir` 결과의 `locked` 파일. 워크트리의 git-dir = `<main>/.git/worktrees/<name>`
- `lock_worktree(root, owner, desc) -> None` / `unlock_worktree(root, owner) -> bool`
  - 내부는 `git worktree lock --reason "<owner> <desc>" <root>` / `git worktree unlock <root>` 다.
  - unlock 은 owner 가 일치할 때만 한다.
  - 이미 남이 잠갔으면 lock 은 `SessionError` 대신 `RuntimeError` 를 낸다.

- [ ] **Step 1: 실패하는 테스트**

`plugin/tests/test-liveness-lock.sh`:
```bash
#!/usr/bin/env bash
# git 잠금 판정(스펙 3장 실측 6): Claude Code 는 죽어도 잠금을 남긴다 → pid 가 죽었으면 낡은 잠금
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
T="$MARINA_HOME/repo"; mkdir -p "$T"; git -C "$T" init -q; git -C "$T" commit -q --allow-empty -m i
git -C "$T" worktree add -q -b w1 "$MARINA_HOME/w1"; git -C "$T" worktree add -q -b w2 "$MARINA_HOME/w2"; git -C "$T" worktree add -q -b w3 "$MARINA_HOME/w3"
sleep 30 & LIVE=$!
( exit 0 ) & DEAD=$!; wait $DEAD
git -C "$T" worktree lock --reason "claude session w1 (pid $DEAD start x)" "$MARINA_HOME/w1"
git -C "$T" worktree lock --reason "claude session w2 (pid $LIVE start x)" "$MARINA_HOME/w2"
PYTHONPATH="$SCRIPTS" python3 - "$MARINA_HOME" <<'PY'
import sys
from pathlib import Path
import marina_liveness as lv
h = Path(sys.argv[1]); fails = []
def check(c, m):
    if not c: fails.append(m)
l1 = lv.worktree_lock(h / "w1"); l2 = lv.worktree_lock(h / "w2")
check(l1 and l1["owner"] == "claude" and l1["stale"] is True, f"죽은 pid → 낡은 잠금: {l1}")
check(l2 and l2["stale"] is False and lv.lock_holds(h / "w2"), f"산 pid → 유효: {l2}")
check(lv.lock_holds(h / "w1") is None, "낡은 잠금은 안 지킨다")
check(lv.worktree_lock(h / "w3") is None, "안 잠김")
lv.lock_worktree(h / "w3", "marina-session", "proj/feat-a")
l3 = lv.worktree_lock(h / "w3")
check(l3 and l3["owner"] == "marina-session" and l3["pid"] is None and l3["stale"] is False, f"pid 없는 잠금은 주인이 풀 때까지: {l3}")
check(lv.lock_holds(h / "w3", me="marina-session") is None and lv.lock_holds(h / "w3"), "자기 잠금은 자기에게 안 막힘")
check(lv.unlock_worktree(h / "w3", "someone-else") is False and lv.worktree_lock(h / "w3"), "남의 잠금은 못 푼다")
check(lv.unlock_worktree(h / "w3", "marina-session") is True and lv.worktree_lock(h / "w3") is None, "자기 잠금은 푼다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
kill $LIVE 2>/dev/null || true
echo "PASS test-liveness-lock"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-liveness-lock.sh`
Expected: FAIL — `No module named 'marina_liveness'`

- [ ] **Step 3: 구현**

```python
"""marina_liveness.py — 워크트리를 '누가 쓰는 중인가' (runtime).

두 신호: ① 살아 있는 claude/codex 프로세스의 cwd(ps comm → lsof cwd — argv 파싱 금지, 프롬프트 오염)
② git 표준 잠금(`git worktree lock`). Claude Code 는 자기 세션 워크트리를 'claude session <이름> (pid N …)'
로 잠그고, 죽어도 잠금을 남긴다(실측 2026-10-03) → pid 가 죽었으면 낡은 잠금으로 본다. pid 가 없는 잠금
(예: marina-session)은 주인이 풀 때까지 지킨다.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from typing import Any, Optional
# (Task 2: marina_sessions 에서 _parse_agent_pids·_live_agent_cwds·_crosses_nested_worktree·_root_has_live_agent 를
#  여기로 그대로 옮기고 공개 이름 live_agent_cwds/root_has_live_agent 를 단다. 옛 이름은 별칭.)

_PID = re.compile(r"\(pid (\d+)")


def _git_dir(root: Path) -> Optional[Path]:
    try:
        out = subprocess.run(["git", "-C", str(root), "rev-parse", "--absolute-git-dir"],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return Path(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else None


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True          # 권한 없음 = 남의 살아 있는 프로세스
    return True


def worktree_lock(root: Path) -> Optional[dict[str, Any]]:
    gd = _git_dir(root)
    if gd is None:
        return None
    f = gd / "locked"
    try:
        reason = f.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    m = _PID.search(reason)
    pid = int(m.group(1)) if m else None
    return {"reason": reason, "owner": (reason.split() or [""])[0], "pid": pid,
            "stale": bool(pid) and not _alive(pid)}


def lock_holds(root: Path, me: str = "") -> Optional[dict[str, Any]]:
    lk = worktree_lock(root)
    if not lk or lk["stale"] or (me and lk["owner"] == me):
        return None
    return lk


def lock_worktree(root: Path, owner: str, desc: str) -> None:
    lk = worktree_lock(root)
    if lk and not lk["stale"] and lk["owner"] != owner:
        raise RuntimeError(f"이미 잠김: {lk['reason']}")
    if lk:
        subprocess.run(["git", "-C", str(root), "worktree", "unlock", str(root)], capture_output=True, timeout=10)
    r = subprocess.run(["git", "-C", str(root), "worktree", "lock", "--reason", f"{owner} {desc}", str(root)],
                       capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip())


def unlock_worktree(root: Path, owner: str) -> bool:
    lk = worktree_lock(root)
    if not lk or lk["owner"] != owner:
        return False
    return subprocess.run(["git", "-C", str(root), "worktree", "unlock", str(root)],
                          capture_output=True, timeout=10).returncode == 0
```
그다음 `marina_sessions` 의 네 함수를 옮겨 붙이고 sessions 는 import 로 바꾼다. RUNTIME_MODULES 에 `marina_liveness` 를 추가한다.

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-liveness-lock.sh && bash plugin/tests/test-runtime-boundary.sh && bash plugin/tests/run-affected.sh`
Expected: 전부 PASS

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina_liveness.py plugin/scripts/marina_sessions.py plugin/scripts/RUNTIME_MODULES plugin/tests/test-liveness-lock.sh
git commit -m "feat(runtime): 워크트리 사용 판정 — 프로세스 cwd + git 잠금(낡은 잠금 무시)"
```

---

### Task 3: 워크트리 GC 를 runtime 신호만으로

**Files:**
- Modify: `plugin/scripts/marina_worktree_gc.py` (idle_verdict·gc_plan)
- Modify: `plugin/scripts/RUNTIME_MODULES` (+ marina_worktree_gc, marina_docker_gc, marina_docker_gc_cli, marina_reaper)
- Test: `plugin/tests/test-worktree-gc.sh`(케이스 추가)

**Interfaces:**
- Consumes: `marina_liveness.root_has_live_agent`, `lock_holds`, `marina_worktrees.worktree_info`
- `idle_verdict(root, info, agents, live_cwds, days=None, now=None)` — 시그니처 유지(대시보드가 agents 를 넘겨 카드에 쓴다)
  - `marina_session.has_live_session` 호출을 지우고 `lock_holds(root)` 로 바꾼다.
  - 잠겼으면 `gcIdle=False`, `gcLocked=<reason>` 이다.
- `gc_plan(...)` 은 `agents_payload` 를 부르지 않는다(`agents=None`). 근거: 붙은 에이전트는 살아 있는 프로세스이고, 그건 live_cwds 가 이미 잡는다.

- [ ] **Step 1: 실패하는 테스트**

`test-worktree-gc.sh` 에 추가한다(기존 v1–v7 뒤, W(...)·info_idle 재사용):
```python
import subprocess, marina_liveness as lv
subprocess.run(["git", "-C", str(W("wt-idle")), "worktree", "lock", "--reason", "marina-session proj/x", str(W("wt-idle"))], check=True)
v8 = gc.idle_verdict(W("wt-idle"), info_idle, [], set(), days=14)
check(v8["gcIdle"] is False and "marina-session" in (v8.get("gcLocked") or ""), f"잠긴 워크트리는 정리 안 함: {v8}")
subprocess.run(["git", "-C", str(W("wt-idle")), "worktree", "unlock", str(W("wt-idle"))], check=True)
subprocess.run(["git", "-C", str(W("wt-idle")), "worktree", "lock", "--reason", "claude session x (pid 999999 start y)", str(W("wt-idle"))], check=True)
v9 = gc.idle_verdict(W("wt-idle"), info_idle, [], set(), days=14)
check(v9["gcIdle"] is True, f"죽은 Claude 잠금은 무시: {v9}")
subprocess.run(["git", "-C", str(W("wt-idle")), "worktree", "unlock", str(W("wt-idle"))], check=True)
src = Path(gc.__file__).read_text()
check("marina_session" not in src and "agents_payload" not in src, "GC 는 discord·대시보드 코드를 안 부른다")
```
(테스트 파일에 이미 있는 check/fails 관례를 따른다. W() 가 git 워크트리가 아니면 `git worktree add` 로 만든 픽스처를 쓴다 — 실행 전 파일을 읽고 맞춘다.)

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-worktree-gc.sh`
Expected: FAIL — v8 gcIdle True(잠금 무시), 소스에 marina_session 있음

- [ ] **Step 3: 구현** — idle_verdict:
```python
    from marina_liveness import lock_holds, root_has_live_agent
    ...
    live_proc = root_has_live_agent(root, live_cwds or set())
    lock = None if live_proc else lock_holds(root)
    out = {..., "gcLiveProcess": bool(live_proc), "gcLocked": (lock or {}).get("reason")}
    ...
    if attached or live_proc or lock:
        return out   # gcIdle False
```
gc_plan: `from marina_liveness import live_agent_cwds`, `from marina_worktrees import worktree_info` 를 쓴다. `agents = None` 이다.
RUNTIME_MODULES 에 marina_worktree_gc·marina_docker_gc·marina_docker_gc_cli·marina_reaper 를 추가한다. 경계 테스트에서 또 위반이 나오면(예: lifecycle import), Task 4 에서 풀 것은 `RUNTIME_PENDING`(테스트가 경고만 내는 목록)에 잠시 둔다. 그 목록은 Task 9 에서 비운다.

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-worktree-gc.sh && bash plugin/tests/test-worktree-gc-auto.sh && bash plugin/tests/test-worktree-gc-api.sh && bash plugin/tests/test-runtime-boundary.sh`
Expected: 전부 PASS

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(gc): 워크트리 정리는 프로세스·git 잠금만 본다 — Discord·대시보드 코드 호출 제거"
```

---

### Task 4: 워크트리 삭제 — 잠금 존중, Discord 직접 호출 제거

**Files:**
- Modify: `plugin/scripts/marina_lifecycle.py:440-470` (remove_worktree)
- Modify: `plugin/scripts/RUNTIME_MODULES` (+ marina_lifecycle, marina_cli, marina_build, marina_build_inputs, marina_prebuild, marina_pretooluse, marina_protected_write)
- Test: `plugin/tests/test-worktree-remove-lock.sh`(신규)

**Interfaces:**
- `remove_worktree(root, force=False, volumes=..., )` 의 동작이 셋 바뀐다.
  - (a) `lock_holds(root)` 가 있고 force 가 아니면 `ValueError("잠김: <reason> — force 로 지울 수 있다")` 를 낸다.
  - (b) force 면 `git worktree unlock` 뒤에 진행한다.
  - (c) `teardown_for_root` 호출과 `discord_warnings` 를 지운다. Discord 정리는 Task 5 의 사후 정리가 맡는다.
- `marina worktree rm` CLI 는 이 ValueError 를 그대로 보여 준다(기존 경로).

- [ ] **Step 1: 실패하는 테스트** — `test-worktree-remove-lock.sh`:
  - 기존 `test-worktree-remove-reclaim.sh` 의 픽스처 만들기를 그대로 쓴다(파일을 읽고 복사).
  - 워크트리를 `marina-session proj/x` 로 잠근 뒤 단언한다.
    - `remove_worktree(root)` 가 ValueError 를 내고 메시지에 "잠김" 이 있다.
    - 폴더가 남아 있다.
    - `remove_worktree(root, force=True)` 는 성공한다.
    - `Path(marina_lifecycle.__file__).read_text()` 에 `marina_session` 이 없다.

- [ ] **Step 2: 실패 확인** — Expected: FAIL(잠금 무시하고 지움)

- [ ] **Step 3: 구현** — `stop_all(root)` **앞에**:
```python
    from marina_liveness import lock_holds, unlock_worktree
    lk = lock_holds(root)
    if lk and not force:
        raise ValueError(f"잠김: {lk['reason']} — 쓰는 중인 워크트리다(force 로 지울 수 있다)")
    if lk:
        subprocess.run(["git", "-C", str(root), "worktree", "unlock", str(root)], capture_output=True, timeout=10)
```
teardown_for_root 블록을 지우고 반환값의 `discord_warnings` 도 뺀다. 대시보드가 그 필드를 읽는지 grep 하고, 읽으면 빈 리스트로 둔다.

- [ ] **Step 4: 통과 확인** — `bash plugin/tests/test-worktree-remove-lock.sh && bash plugin/tests/test-worktree-remove-reclaim.sh && bash plugin/tests/test-runtime-boundary.sh && bash plugin/tests/run-affected.sh`

- [ ] **Step 5: Commit** — `git commit -am "feat(runtime): 잠긴 워크트리는 force 없이 안 지운다, Discord 정리 직접 호출 제거"`

---

### Task 5: discord — 세션 워크트리 잠금 + 사후 정리

**Files:**
- Modify: `plugin/scripts/marina_session.py` (new/start/stop/rm, 새 함수 `reconcile_gone`)
- Modify: `plugin/scripts/marina_discord_bot.py` (Loop.step 에서 1분마다 reconcile_gone)
- Test: `plugin/tests/test-session-lock-reconcile.sh`(신규)

**Interfaces:**
- Consumes: `marina_liveness.lock_worktree/unlock_worktree`. 이번 단계에선 discord 가 아직 plugin/ 안이라 import 해도 된다. B 단계에서 discord 는 자기 사본 `git worktree lock` 호출로 바꾼다. 경계는 runtime→discord 방향만 금지라 지금은 위반이 아니다.
- 개발 세션(kind ≠ chat)과 잠금:
  - `new`/`start` 때 `lock_worktree(root, "marina-session", ref)` 를 건다.
  - `rm` 때 unlock 한 뒤 기존 삭제를 한다(force).
  - `stop` 은 잠금을 유지한다(꺼져 있어도 형의 채널이 있는 워크트리다).
- `reconcile_gone(now) -> list[str]` 의 동작:
  - 개발 세션의 root 가 없고 `git -C <source> worktree list` 에도 없으면 `goneSince` 를 기록한다.
  - 다음 호출에서 ≥ 120초가 지났고 여전히 없으면 `teardown_for_root(root)` 를 부르고 ref 를 돌려준다.
  - 다시 보이면 `goneSince` 를 지운다.

- [ ] **Step 1: 실패하는 테스트**
  - 세션 픽스처(`lib/session_fixture.sh`, `msess new proj feat/a --no-start`)로 만든 워크트리가 `marina-session` 으로 잠겼는지 확인한다.
  - `marina worktree rm`(=remove_worktree) 가 잠김으로 거절하는지 확인한다.
  - 폴더를 `git worktree remove --force` 로 지운다(남이 지운 상황).
  - `reconcile_gone(t)` → [] 이고 `reconcile_gone(t+121)` → [ref] 인지 확인한다.
  - 그 뒤 fake discord 로그에 채널 DELETE(또는 teardown 이 하는 요청)가 있는지 확인한다.
  - 폴더가 한 번 사라졌다 다시 생기면 정리 안 됨도 확인한다.

- [ ] **Step 2: 실패 확인** — Expected: FAIL(잠금 없음, reconcile_gone 없음)

- [ ] **Step 3: 구현** — 위 Interfaces 대로. Loop.step 에 `if now - self.last_reconcile >= 60: reconcile_gone(now)` 를 넣는다(예외는 삼키고 _log).

- [ ] **Step 4: 통과 확인** — `bash plugin/tests/test-session-lock-reconcile.sh` + `for t in plugin/tests/test-session-*.sh plugin/tests/test-discord-*.sh; do bash $t; done`

- [ ] **Step 5: Commit** — `git commit -am "feat(session): 개발 세션 워크트리를 잠그고, 밖에서 지워지면 2분 뒤 채널 정리"`

---

### Task 6: Claude Code 워크트리 훅 (WorktreeCreate·WorktreeRemove)

**Files:**
- Create: `plugin/scripts/marina_worktree_hooks.py`
- Modify: `plugin/hooks/hooks.json` (WorktreeCreate·WorktreeRemove → `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-worktree-hook.sh" create|remove`)
- Create: `plugin/scripts/marina-worktree-hook.sh` (python 찾기 + exec)
- Modify: `plugin/scripts/RUNTIME_MODULES` (+ marina_worktree_hooks)
- Test: `plugin/tests/test-worktree-hooks.sh`(신규)

**Interfaces:**
- `create(payload: dict, env: dict) -> str`(경로)
  - payload 는 `{name, cwd, session_id, …}` 다(스펙 실측 1).
  - **마리나 프로젝트면**(`project_for(cwd 의 원본 체크아웃)` 가 있으면):
    - 기존 `marina worktree create <name> [<MARINA_BASE>] --project <id>` 와 같은 코드 경로로 만든다. 서브레포 붙이기·포트 등록 포함이다.
    - 함수가 있으면 직접 부르고, 없으면 `bash marina.sh worktree create …` 를 부른다.
    - 경로를 돌려준다.
  - **아니면, 또는 마리나 경로가 예외를 내면** 기본 동작을 한다.
    - `git -C <cwd 의 toplevel> worktree add <toplevel>/.claude/worktrees/<name> -b worktree-<name>` (기준 = `MARINA_BASE` 또는 HEAD)
    - 이미 있으면 그 경로를 그대로 돌려준다.
- `remove(payload) -> tuple[int, str]`
  - `lock_holds(worktree_path, me="claude")` 가 있으면 `(2, "잠김: …")` 다(Claude Code 는 워크트리를 남긴다, 실측 5).
  - 마리나 워크트리면 `remove_worktree(path, force=True)` 다(Claude 가 깨끗하거나 사람이 '지움'을 고른 경우만 부른다, 실측 4).
  - 아니면 `git worktree remove --force` 다.
- `marina-worktree-hook.sh create` 는 stdin JSON 을 받아 stdout 에 **경로 한 줄만** 낸다. 로그는 stderr 와 `~/.marina/worktree-hook.log` 로 보낸다.

- [ ] **Step 1: 실패하는 테스트** — `test-worktree-hooks.sh`:
  1. 마리나 프로젝트가 아닌 임시 레포에서 다음을 확인한다.
     - `echo '{"name":"t1","cwd":"<repo>"}' | marina-worktree-hook.sh create` 의 stdout 이 `<repo>/.claude/worktrees/t1` 이다.
     - 그 경로에 브랜치 `worktree-t1` 의 git 워크트리가 있다.
     - 다시 부르면 같은 경로가 나오고 오류가 없다.
  2. `MARINA_BASE=<다른 브랜치>` 로 만들면 그 브랜치 커밋에서 시작한다.
  3. 등록된 마리나 프로젝트(기존 테스트의 프로젝트 등록 픽스처를 재사용 — `test-session-*.sh` 의 msess/registry 픽스처를 읽고 맞춘다)에서 create 하면 `marina worktree create` 와 같은 위치·메타가 생긴다(`marina_registry.discover_all_roots(refresh=True)` 에 잡힘).
  4. remove 를 확인한다.
     - `marina-session x` 로 잠긴 워크트리면 종료 코드 2, 폴더가 남는다.
     - `claude session t1 (pid <살아있는 내 pid>)` 잠금은 me="claude" 라 막지 않고 지운다.
     - 잠금이 없으면 지운다.
  5. 마리나 경로를 일부러 깨뜨려도(`MARINA_HOME` 의 projects 파일을 깨진 JSON 으로) create 가 기본 동작으로 경로를 낸다.

- [ ] **Step 2: 실패 확인** — Expected: FAIL(스크립트 없음)

- [ ] **Step 3: 구현** — 위 Interfaces 대로. hooks.json 에 추가한다:
```json
"WorktreeCreate": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/marina-worktree-hook.sh\" create"}]}],
"WorktreeRemove": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/marina-worktree-hook.sh\" remove"}]}]
```
codex-hooks.json 은 건드리지 않는다(codex 엔 이 이벤트가 없다).

- [ ] **Step 4: 통과 확인** — `bash plugin/tests/test-worktree-hooks.sh && bash plugin/tests/test-runtime-boundary.sh && bash plugin/tests/test-py39-compat.sh`

- [ ] **Step 5: 실측(로컬, 배포 전)** — 스크래치 레포에서 이 플러그인 디렉터리를 `--plugin-dir` 로 물려 확인한다(형 설치본은 안 건드림).
  - `env -u CLAUDECODE claude --plugin-dir <worktree>/plugin -p --worktree probe "pwd"` 가 우리 훅 경로를 쓴다.
  - 대화형 `/exit` 가 잠긴 워크트리를 남긴다.
  - 결과를 ledger 에 적는다.

- [ ] **Step 6: Commit** — `git add … && git commit -m "feat(runtime): Claude Code 워크트리 훅 — --worktree·서브에이전트 격리를 마리나로, 잠금 존중"`

---

### Task 7: 청소 상주 프로그램 `marina-runtimed`

**Files:**
- Create: `plugin/scripts/marina_runtimed.py` (run_forever: gateway 갱신·리퍼·도커 GC tick·워크트리 auto tick)
- Create: `plugin/scripts/marina-runtimed.sh` (start|stop|restart|status — `marina-dashboard.sh` 의 launchd/systemd/nohup 부분을 본떠 라벨 `com.marina.runtimed`)
- Modify: `plugin/scripts/marina_handler.py:3296-3367` (gw·reaper·gc 루프 제거 → 대신 기동 때 `marina-runtimed.sh ensure`)
- Modify: `plugin/scripts/marina_docker_gc.py` `daemon_tick(port)`·`marina_worktree_gc.auto_tick(port)` 의 "기록된 데몬만" 판정 → runtimed 용 `primary()`(runtimed flock 쥔 프로세스 + MARINA_HOME 이 기록된 홈)
- Modify: `plugin/scripts/marina_autoupdate.py` (재시작 때 runtimed 도 restart)
- Modify: `plugin/scripts/RUNTIME_MODULES` (+ marina_runtimed, marina_gateway 관련 모듈은 이미 lifecycle 경유)
- Test: `plugin/tests/test-runtimed.sh`(신규)

**Interfaces:**
- `marina_runtimed.Loop.step(now) -> None`: 아래 셋을 한다(각 예외는 삼키고 로그).
  - gateway 켜져 있으면(`MARINA_GATEWAY` 판정 — handler 의 `_GATEWAY_ON` 과 같은 함수로 옮김) 5초마다 `marina_lifecycle.refresh_gateway()`
  - 600초마다 `daemon_tick`·`auto_tick`
  - 리퍼는 `marina_reaper.run_forever` 스레드 1개
- 단일 실행: `~/.marina/runtimed.lock` flock. 못 잡으면 바로 끝낸다.
- `marina-runtimed.sh ensure`: 안 떠 있으면 띄운다. 대시보드 start·restart 와 autoupdate 재시작이 부른다. 그래서 형·팀원은 업데이트만 받으면 자동으로 runtimed 가 생긴다.

- [ ] **Step 1: 실패하는 테스트** — `test-runtimed.sh`:
  - (a) `Loop` 에 가짜 tick 함수들을 주입해 step(t0)·step(t0+4)·step(t0+600) 의 호출 횟수를 확인한다. gateway 는 5초 주기, gc 는 600초 주기다.
  - (b) 두 번째 Loop 인스턴스는 lock 을 못 잡아 아무것도 안 한다.
  - (c) `grep -n "_gc_loop\|_gw_loop\|marina_reaper" marina_handler.py` 가 비어 있다.
  - (d) `MARINA_HOME` 격리 상태에서 `marina-runtimed.sh start` → `status` running → `stop`. launchd 를 쓰지 않는 nohup 경로를 강제하는 환경변수가 dashboard.sh 에 있으면 그대로 쓴다. 파일을 읽고 맞춘다.

- [ ] **Step 2: 실패 확인**

- [ ] **Step 3: 구현** — 위대로. `marina_handler.main` 에서 gw/reaper/gc 스레드 블록을 지운다. 대신 다음 한 줄을 둔다.
```python
    subprocess.Popen(["bash", str(Path(__file__).with_name("marina-runtimed.sh")), "ensure"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
```
이 한 줄은 기록된 데몬일 때만 돈다(격리 프리뷰 제외 — 기존 판정 재사용). handler 의 `refresh_gateway` 이벤트 훅(즉시 반영)은 그대로 둔다.

- [ ] **Step 4: 통과 확인** — `bash plugin/tests/test-runtimed.sh && bash plugin/tests/test-gateway-config.sh && bash plugin/tests/test-reaper.sh && bash plugin/tests/test-worktree-gc-auto.sh && bash plugin/tests/test-py39-compat.sh && bash plugin/tests/run-affected.sh --deep`

- [ ] **Step 5: Commit** — `git commit -m "feat(runtime): 청소 상주 프로그램 marina-runtimed — 게이트웨이·GC·리퍼를 대시보드에서 분리"`

---

### Task 8: `bin/marina` — 플러그인 PATH 명령

**Files:**
- Create: `plugin/bin/marina` (`exec "$(dirname "$0")/../scripts/marina-entrypoint.sh" "$@"`)
- Test: `plugin/tests/test-entrypoint-routing.sh`(케이스 추가: `plugin/bin/marina --help` 가 entrypoint 와 같은 출력)

- [ ] **Step 1: 실패 테스트 추가** → **Step 2: 실패 확인** → **Step 3: 파일 생성(chmod +x)** → **Step 4: 통과** → **Step 5: Commit** `feat(runtime): 플러그인 bin/marina`

---

### Task 9: 경계 테스트 완성

**Files:**
- Modify: `plugin/scripts/RUNTIME_MODULES` — 최종 목록. 다음 모듈과 그 의존 중 runtime 쪽인 것.
  - state·paths·registry·compose_svc·dockerfile·memory·cache·logtext·runtime_target·ssh_mux·worktrees·liveness·worktree_gc·docker_gc·docker_gc_cli·reaper·lifecycle·cli·build·build_inputs·prebuild·pretooluse·protected_write·worktree_hooks·runtimed
  - 하이픈 파일 `marina-compose.py`·`marina-gateway.py`
- Modify: `test-runtime-boundary.sh` — 하이픈 파일도 검사하고 `RUNTIME_PENDING` 경고 목록을 없앤다. 그리고 셸 스크립트(`marina.sh`·`marina-lib-*.sh`)가 runtime 밖 python 모듈을 `python3 -c "import marina_X"` 식으로 부르는지 grep 으로 검사한다.

- [ ] **Step 1:** 목록 확정·PENDING 제거 → **Step 2:** 실패 나오면 그 import 를 Task 1–7 방식으로 푼다(각각 Ruling) → **Step 3:** `bash plugin/tests/test-runtime-boundary.sh` PASS → **Step 4:** `bash plugin/tests/run-affected.sh --deep` 전부 PASS → **Step 5:** Commit `test(runtime): 경계 테스트 — runtime 모듈 목록 확정`

---

## 끝난 뒤 (형 허락 필요)

- 브랜치 전체 리뷰(code-reviewer, 가장 좋은 모델).
- 배포 순서:
  1. push
  2. 플러그인 업데이트
  3. `marina dashboard restart`. 대시보드가 runtimed 를 ensure 한다.
- 배포 후 확인할 것:
  - `marina-runtimed.sh status` 가 running 이다.
  - 대시보드 로그·runtimed 로그에 Traceback 이 0 이다.
  - 게이트웨이 주소가 열린다.
  - `claude --worktree` 실측을 한 번 한다.
  - Discord 세션 워크트리들이 잠겼다. 기존 세션은 잠금이 없으니 `marina session` 쪽에 `lock-all` 일회성 명령을 Task 5 에 포함한다.
