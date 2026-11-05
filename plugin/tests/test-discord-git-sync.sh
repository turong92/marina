#!/usr/bin/env bash
# 방 브랜치를 '일 사이 안전한 때'에만 origin 기본 브랜치에 맞춘다(형 승인 2026-11-05).
# 살아 있는 작업 트리에서는 rebase/abort 를 하지 않는다 — 임시 워크트리에서 새 커밋을 계산하고, 적용은 HEAD·index 가 같고
# 작업 트리가 깨끗할 때만 `git reset --keep <new>` 한 번. 자동 적용 조건(push 안 한 브랜치·서명 꺼짐·서브모듈 없음·파생 브랜치 없음·
# ignored 파일과 안 겹침·진행 중 작업 없음)을 하나라도 못 채우면 이유별 알림만. 임시 git 레포(origin 베어 + 다른 클론)로 흉내 낸다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
export FD SRC TMPROOT
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a >/dev/null 2>&1 || fail "new a"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, shutil, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
import marina_discord_idle as mi
fails = []
def check(c, m):
    if not c: fails.append(m)
assert os.environ["MARINA_TMUX_SOCKET"].startswith("marina-test-")
SRC, TMP = Path(os.environ["SRC"]), Path(os.environ["TMPROOT"])
def git(cwd, *a, check_=True):
    r = subprocess.run(["git", "-C", str(cwd), *a], capture_output=True, text=True)
    if check_ and r.returncode: raise RuntimeError(f"git {a}: {r.stderr}")
    return r.stdout.strip()
bare, other = TMP / "origin.git", TMP / "other"
subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(bare)], check=True)
git(SRC, "remote", "add", "origin", str(bare)); git(SRC, "push", "-q", "origin", "main"); git(SRC, "remote", "set-head", "origin", "main")
subprocess.run(["git", "clone", "-q", str(bare), str(other)], check=True)
git(other, "config", "user.email", "o@o.invalid"); git(other, "config", "user.name", "O")
N = [0]
def push(name=None, text="o\n", force=False):
    N[0] += 1; name = name or f"o{N[0]}.txt"
    (other / name).write_text(text); git(other, "add", *(["-f"] if force else []), name); git(other, "commit", "-qm", f"other {name}"); git(other, "push", "-q", "origin", "main")
rec = ms.find_session("proj/feat/a"); root = Path(rec["root"]); sd = Path(rec["stateDir"])
git(root, "config", "user.email", "t@t.invalid"); git(root, "config", "user.name", "T")
room0 = git(root, "rev-parse", "HEAD")
gdir = Path(git(root, "rev-parse", "--absolute-git-dir"))
def mine(name="m.txt", text="m\n"):
    (root / name).write_text(text); git(root, "add", name); git(root, "commit", "-qm", f"mine {name}")
def fresh():
    """방을 처음 모습으로: 내 커밋 하나(ahead 1) + origin 이 한 커밋 앞섬(behind 1)."""
    wl = git(root, "worktree", "list", "--porcelain").split("\n\n")
    for blk in wl:
        path = blk.split("\n")[0].replace("worktree ", "")
        if "agent-" in path: git(root, "worktree", "remove", "--force", path)
    git(root, "checkout", "-q", "feat/a"); git(root, "reset", "-q", "--hard", room0); git(root, "clean", "-fdq")
    for b in git(root, "for-each-ref", "--format=%(refname:short)", "refs/heads/extra*").split():
        git(root, "branch", "-q", "-D", b)
    for f in ("MERGE_HEAD", "REVERT_HEAD", "CHERRY_PICK_HEAD", "BISECT_LOG"): (gdir / f).unlink(missing_ok=True)
    for d in ("rebase-merge", "rebase-apply", "sequencer"): shutil.rmtree(gdir / d, ignore_errors=True)
    git(root, "config", "--unset", "commit.gpgsign", check_=False)
    git(root, "push", "-q", "origin", "--delete", "feat/a", check_=False); git(root, "fetch", "-q", "--prune", "origin")
    mine(f"m{N[0]}.txt"); push()
def tmp_left(): return [l for l in git(root, "worktree", "list", "--porcelain").split("\n") if "sync-wt" in l]
BASE = "origin/main"
# 최신
fresh()
# 1) 깨끗 + 뒤처짐 → 임시 워크트리에서 계산한 새 커밋을 reset --keep 으로 적용
head = git(root, "rev-parse", "HEAD")
r = mi.sync_to_origin(root)
check(r and r["state"] == "rebased" and r["n"] == 1 and r["base"] == BASE, f"깨끗하면 적용: {r}")
check(git(root, "rev-list", "--count", f"{BASE}..HEAD") == "1" and git(root, "rev-list", "--count", f"HEAD..{BASE}") == "0", "origin 위에 내 커밋")
check(git(root, "symbolic-ref", "--short", "HEAD") == "feat/a" and git(root, "status", "--porcelain") == "", "브랜치·작업 트리 유지")
check(tmp_left() == [], f"임시 워크트리는 남지 않는다: {tmp_left()}")
check(mi.sync_to_origin(root) is None, "이미 최신이면 아무것도 안 함")
src = Path(mi.__file__).read_text(encoding="utf-8")
check("--abort" not in src, "방 트리에서 rebase --abort 를 부르는 코드가 없다(리뷰 C1·C2)")
# 2) 충돌: 방 트리는 그대로(abort 가 필요 없다), 임시만 버림
fresh(); mine("same.txt", "mine\n"); push("same.txt", "origin\n"); head = git(root, "rev-parse", "HEAD")
r = mi.sync_to_origin(root)
check(r and r["state"] == "behind" and r["why"] == "conflict", f"충돌 예상: {r}")
check(git(root, "rev-parse", "HEAD") == head and git(root, "status", "--porcelain") == "" and not (gdir / "rebase-merge").exists(), "방 트리는 건드리지 않았다")
check(tmp_left() == [], "충돌 뒤 임시 워크트리 정리")
# 3) 더러움 / 진행 중 작업
fresh(); (root / f"m{N[0]-1}.txt").write_text("수정\n"); head = git(root, "rev-parse", "HEAD")
r = mi.sync_to_origin(root)
check(r and r["why"] == "dirty" and git(root, "rev-parse", "HEAD") == head, f"커밋 안 한 변경: {r}")
fresh(); (root / "new.txt").write_text("x\n")
check(mi.sync_to_origin(root)["why"] == "dirty", "untracked 도 더러움")
fresh(); (root / ".gitignore").write_text("ign.log\n"); git(root, "add", ".gitignore"); git(root, "commit", "-qm", "ign"); (root / "ign.log").write_text("l\n")
check(mi.sync_to_origin(root)["state"] == "rebased", "gitignore 대상은 더럽지 않다")
for marker, kind in (("MERGE_HEAD", "f"), ("REVERT_HEAD", "f"), ("CHERRY_PICK_HEAD", "f"), ("BISECT_LOG", "f"), ("sequencer", "d"), ("rebase-merge", "d"), ("rebase-apply", "d")):
    fresh(); (gdir / marker).mkdir() if kind == "d" else (gdir / marker).write_text(git(root, "rev-parse", "HEAD") + "\n")
    r = mi.sync_to_origin(root)
    check(r and r["why"] == "busy", f"진행 중 작업 {marker}: {r}")
    if kind == "d": shutil.rmtree(gdir / marker)
    else: (gdir / marker).unlink()
# 4) 이미 push 한 브랜치
fresh(); git(root, "push", "-q", "origin", "feat/a"); head = git(root, "rev-parse", "HEAD")
r = mi.sync_to_origin(root)
check(r and r["why"] == "pushed" and git(root, "rev-parse", "HEAD") == head, f"push 한 브랜치는 다시 쓰지 않는다: {r}")
# 5) 내 HEAD 를 기반으로 한 다른 로컬 브랜치 / 워크트리(서브에이전트 agent-*)
fresh(); git(root, "branch", "extra1")
check(mi.sync_to_origin(root)["why"] == "derived", "파생 로컬 브랜치")
fresh(); git(root, "worktree", "add", "-q", "--detach", str(TMP / "agent-x"), "HEAD")
check(mi.sync_to_origin(root)["why"] == "derived", "HEAD 를 기반으로 한 다른 워크트리(agent-*)")
fresh()
# 6) 서명·서브모듈·ignored 덮어쓰기
git(root, "config", "commit.gpgsign", "true")
check(mi.sync_to_origin(root)["why"] == "gpg", "commit.gpgsign 이 켜져 있으면 자동 적용 안 함")
fresh(); (root / ".gitmodules").write_text("[submodule \"x\"]\n"); git(root, "add", ".gitmodules"); git(root, "commit", "-qm", "sm")
check(mi.sync_to_origin(root)["why"] == "submodule", ".gitmodules 가 있으면 안 함")
fresh(); (root / ".gitignore").write_text("gen.txt\n"); git(root, "add", ".gitignore"); git(root, "commit", "-qm", "ign2"); (root / "gen.txt").write_text("로컬 생성물\n")
push("gen.txt", "origin 파일\n", force=True); head = git(root, "rev-parse", "HEAD")
r = mi.sync_to_origin(root)
check(r and r["why"] == "ignored" and (root / "gen.txt").read_text() == "로컬 생성물\n" and git(root, "rev-parse", "HEAD") == head, f"origin 변경이 로컬 ignored 파일과 겹치면 덮어쓰지 않는다: {r}")
(root / "gen.txt").unlink()
# 7) 적용 직전 재확인: 활동·HEAD·index·작업 트리가 계산 때와 달라지면 적용하지 않는다
fresh(); head = git(root, "rev-parse", "HEAD")
check(mi.sync_to_origin(root, guard=lambda: False) is None and git(root, "rev-parse", "HEAD") == head, "guard(활동·piece_done)가 거절하면 적용 안 함")
def moved():
    mine("late.txt"); return True
fresh(); r = mi.sync_to_origin(root, guard=moved)
check(r is None and (root / "late.txt").exists() and git(root, "rev-list", "--count", f"HEAD..{BASE}") != "0", f"계산 뒤 HEAD 가 움직였으면 적용 안 함(내 새 커밋 보존): {r}")
def dirtied():
    (root / "late2.txt").write_text("x\n"); return True
fresh(); check(mi.sync_to_origin(root, guard=dirtied) is None and (root / "late2.txt").exists(), "계산 뒤 작업 트리가 더러워졌으면 적용 안 함")
def staged():
    (root / "s.txt").write_text("s\n"); git(root, "add", "s.txt"); return True
fresh(); check(mi.sync_to_origin(root, guard=staged) is None and git(root, "diff", "--cached", "--name-only") == "s.txt", "index 가 달라졌으면 적용 안 함")
git(root, "reset", "-q", "--hard")
# 잠금을 못 잡으면 적용 안 함
import contextlib
@contextlib.contextmanager
def nolock(): yield False
fresh(); check(mi.sync_to_origin(root, lock=nolock) is None, "방 잠금을 못 잡으면 적용 안 함")
# 2-b) 바뀐 경로의 상위 경로: origin 이 x/y 를 추가, 방에는 ignored 파일 x — reset --keep 이 x 를 지운다
fresh(); (root / ".gitignore").write_text("x\n"); git(root, "add", ".gitignore"); git(root, "commit", "-qm", "ign3"); (root / "x").write_text("로컬 ignored\n")
(other / "x").mkdir(exist_ok=True); push("x/y", "origin\n", force=True); head = git(root, "rev-parse", "HEAD")
r = mi.sync_to_origin(root)
check(r and r["why"] == "ignored" and (root / "x").read_text() == "로컬 ignored\n" and git(root, "rev-parse", "HEAD") == head, f"상위 경로 x 가 ignored 파일이면 겹침: {r}")
(root / "x").unlink()
# 4) 방의 이전 커밋에서 갈라진 브랜치도 잡는다(첫 커밋 기준)
fresh(); mine("second.txt"); first = git(root, "rev-list", "--reverse", f"{BASE}..HEAD").split()[0]; git(root, "branch", "extra2", first)
check(mi.sync_to_origin(root)["why"] == "derived", "첫 커밋에서 갈라진 브랜치(HEAD 를 포함하진 않는다)")
git(root, "branch", "-D", "extra2")
# 3·1) 임시 rebase 는 사용자 rebase 설정을 고정하고, 적용용 reset --keep 은 타임아웃·SIGKILL 이 없다
seen = []
real_run0 = mi._run
def spy(argv, **kw): seen.append((argv, kw)); return real_run0(argv, **kw)
mi._run = spy
fresh(); git(root, "config", "rebase.updateRefs", "true"); git(root, "config", "rebase.rebaseMerges", "true")
r = mi.sync_to_origin(root)
git(root, "config", "--unset", "rebase.updateRefs"); git(root, "config", "--unset", "rebase.rebaseMerges")
mi._run = real_run0
rb = [a for a, k in seen if "rebase" in a and "--abort" not in a]
check(r and r["state"] == "rebased" and rb and all("rebase.updateRefs=false" in a and "rebase.rebaseMerges=false" in a for a in rb), f"사용자 rebase 설정 고정: {rb}")
rk = [k for a, k in seen if "reset" in a and "--keep" in a]
check(rk and rk[0].get("timeout") is None, f"reset --keep 은 타임아웃 없음: {rk}")
# 타임아웃 시 SIGTERM 먼저(정리 기회) → 안 죽으면 SIGKILL
flag = TMP / "term-flag"
t0 = time.time()
try: mi._run(["sh", "-c", f"trap 'echo t > {flag}; exit 0' TERM; sleep 30 & wait"], timeout=1.0)
except subprocess.TimeoutExpired: pass
check(flag.exists(), "타임아웃은 SIGTERM 을 먼저 보낸다")
t0 = time.time()
try: mi._run(["sh", "-c", "trap '' TERM; sleep 30"], timeout=1.0, term_grace=1.0)
except subprocess.TimeoutExpired: pass
check(time.time() - t0 < 10, "TERM 을 무시해도 몇 초 뒤 SIGKILL")
# 판정용 git 호출이 실패하면 아무것도 안 한다
fresh(); head = git(root, "rev-parse", "HEAD")
for bad in ("status", "rev-list", "for-each-ref", "write-tree"):
    def failing(argv, _bad=bad, **kw):
        if _bad in argv and "--keep" not in argv: return subprocess.CompletedProcess(argv, 128, "", "boom")
        return real_run0(argv, **kw)
    mi._run = failing
    check(mi.sync_to_origin(root) is None and git(root, "rev-parse", "HEAD") == head and tmp_left() == [], f"{bad} 가 실패하면 아무것도 안 함")
mi._run = real_run0
# 8) 제외·예외 경로
check(mi.sync_to_origin(SRC) is None, "워크트리가 아닌 본체 체크아웃은 제외")
fresh(); git(root, "checkout", "-q", "--detach"); check(mi.sync_to_origin(root) is None, "분리 HEAD 제외"); git(root, "checkout", "-q", "feat/a")
git(root, "remote", "set-url", "origin", "/nonexistent/x.git"); check(mi.sync_to_origin(root) is None, "fetch 실패는 조용히"); git(root, "remote", "set-url", "origin", str(bare))
real_run = mi._run
def boom(argv, **kw):
    if "rebase" in argv: raise OSError("디스크 오류")
    return real_run(argv, **kw)
mi._run = boom
check(mi.sync_to_origin(root) is None and tmp_left() == [] and git(root, "status", "--porcelain") == "", "계산 중 예외도 방 트리를 안 건드리고 임시를 정리")
mi._run = real_run
# git 호출 환경 · 타임아웃 시 프로세스 그룹째 정리
env = mi._git_env()
check(env["GIT_TERMINAL_PROMPT"] == "0" and "BatchMode=yes" in env["GIT_SSH_COMMAND"] and env["GCM_INTERACTIVE"] == "never", "묻지 않는 환경")
t0 = time.time()
try:
    mi._run(["sh", "-c", "sleep 30 & wait"], timeout=1.0); got = False
except subprocess.TimeoutExpired: got = True
check(got and time.time() - t0 < 10, f"타임아웃은 빨리 끝나고 예외: {time.time() - t0:.1f}s")
# 9) 봇이 중간에 죽어 남은 임시 워크트리는 시작 때 정리
dead = 4000000
while True:
    try: os.kill(dead, 0); dead += 1
    except ProcessLookupError: break
    except PermissionError: dead += 1
wt = ms.marina_home() / "sync-wt" / f"{dead}-1"; wt.parent.mkdir(parents=True, exist_ok=True)
live = ms.marina_home() / "sync-wt" / f"{os.getpid()}-2"
git(root, "worktree", "add", "-q", "--detach", str(wt), "HEAD"); git(root, "worktree", "add", "-q", "--detach", str(live), "HEAD")
keepwt = TMP / "keep-wt"; git(root, "worktree", "add", "-q", "--detach", str(keepwt), "HEAD")
mi.cleanup_orphan_worktrees([root])
check(not wt.exists() and "sync-wt/%d-1" % dead not in git(root, "worktree", "list", "--porcelain"), "pid 가 죽은 고아 임시 워크트리만 정리")
check(live.exists() and keepwt.exists(), "살아 있는 pid 의 임시·sync-wt 밖 워크트리는 안 건드린다(맨 prune 금지)")
git(root, "worktree", "remove", "--force", str(live)); git(root, "worktree", "remove", "--force", str(keepwt))
check('"worktree", "prune"' not in src, "맨 git worktree prune 을 부르지 않는다")
# ── keep_tick 연결: 일 조각 끝 + 50분 쉼에서 활동 시각당 한 번 · 하던 중이면 안 함 · 채팅·코덱스 방 제외 ──
fresh()
T0 = time.time() + 100; H0 = T0 + 5; MIN = 60.0
(sd / "turn-at").write_text(str(T0)); (sd / "stopped-at").write_text(str(H0))
mb._spawn_type = lambda *a, **k: None
blockers = [[]]
mb.restart_blockers = lambda r: list(blockers[0]); mb.restart_status = lambda: None
mi._work_stale = lambda *a: False; mi._attached = lambda n: False
calls = []
real_sync = mi.sync_to_origin
mi.sync_to_origin = lambda p, **kw: (calls.append(str(p)), real_sync(p, **kw))[1]
def K_():
    k = mi.Idler(started=0.0); k.sync_inline = True; return k
K = K_()
K.keep_tick(H0 + 40 * MIN, {})
check(calls == [], "50분 전엔 안 한다")
blockers[0] = ["백그라운드 셸 1"]; K.keep_tick(H0 + 55 * MIN, {})
check(calls == [], "하던 중이면 안 한다")
blockers[0] = []; (sd / "keep.json").unlink(missing_ok=True); K = K_()
K.keep_tick(H0 + 55 * MIN, {})
check(calls == [str(root)], f"끝나고 50분 쉬면 한다: {calls}")
check(json.loads((sd / "git-sync.json").read_text())["state"] == "rebased", "기록")
K.keep_tick(H0 + 70 * MIN, {}); K = K_(); K.keep_tick(H0 + 80 * MIN, {})
check(len(calls) == 1, "같은 활동 시각엔 다시 안 한다")
# 적용 직전에 사람이 말을 걸면(활동 시각 변화) 적용하지 않는다
fresh(); (sd / "keep.json").unlink(missing_ok=True); (sd / "git-sync.json").unlink(missing_ok=True); head = git(root, "rev-parse", "HEAD")
orig_apply = mi.sync_to_origin
def talk(p, guard=None, lock=None):
    (sd / "turn-at").write_text(str(H0 + 56 * MIN)); return real_sync(p, guard=guard, lock=lock)
mi.sync_to_origin = talk
K = K_(); K.keep_tick(H0 + 55 * MIN, {})
check(git(root, "rev-parse", "HEAD") == head and not (sd / "git-sync.json").exists(), "계산 도중 사람이 말하면 적용하지 않는다")
(sd / "turn-at").write_text(str(T0)); mi.sync_to_origin = lambda p, **kw: (calls.append(str(p)), real_sync(p, **kw))[1]
n0 = len(calls)
real_load = ms.load_sessions
ms.load_sessions = lambda: [dict(r_, kind="chat") for r_ in real_load()]
(sd / "keep.json").unlink(missing_ok=True); K = K_(); K.keep_tick(H0 + 55 * MIN, {})
check(len(calls) == n0, "채팅·로비 방은 제외")
ms.load_sessions = real_load
real_codex = ms.is_codex; ms.is_codex = lambda r_: True
(sd / "keep.json").unlink(missing_ok=True); K = K_(); K.keep_tick(H0 + 55 * MIN, {})
check(len(calls) == n0, "코덱스 방은 제외(추가 컨텍스트 알림을 확인할 수 없어 조용히 바꾸지 않는다)")
ms.is_codex = real_codex
# ── 알림(이유별): 사람의 첫 입력에 한 줄, 알린 뒤 기록 삭제. 캐시 유지 글은 기록을 가져가지 않는다 ──
os.environ["DISCORD_STATE_DIR"] = str(sd); ms._ensure_daemon_quiet = lambda: None
tr = ms.transcript_path(root, "aaaaaaaa-0000-1111-2222-333344445555"); tr.parent.mkdir(parents=True, exist_ok=True); tr.write_text("")
def prompt(text):
    return ms.hook_prompt({"hook_event_name": "UserPromptSubmit", "prompt": text, "transcript_path": str(tr)})
def ctx(out): return ((out or {}).get("hookSpecificOutput") or {}).get("additionalContext", "")
cases = [({"state": "rebased", "n": 3}, "쉬는 동안 origin/main 으로 rebase 함(3커밋)"),
         ({"state": "behind", "why": "dirty", "n": 2}, "origin/main 이 2커밋 앞섬, 커밋 안 한 변경이 있어 rebase 안 함"),
         ({"state": "behind", "why": "busy", "n": 2}, "진행 중인 git 작업"),
         ({"state": "behind", "why": "pushed", "n": 2}, "이미 push 한 브랜치"),
         ({"state": "behind", "why": "derived", "n": 2}, "서브에이전트"),
         ({"state": "behind", "why": "conflict", "n": 2}, "충돌 예상"),
         ({"state": "behind", "why": "gpg", "n": 2}, "서명"),
         ({"state": "behind", "why": "submodule", "n": 2}, "서브모듈"),
         ({"state": "behind", "why": "ignored", "n": 2}, "ignored")]
for rec_, want in cases:
    (sd / "git-sync.json").write_text(json.dumps(dict(rec_, base="origin/main")))
    check(ctx(prompt(ms.KEEPALIVE_TEXT)) == "" and (sd / "git-sync.json").exists(), "캐시 유지 글은 기록을 가져가지 않는다")
    c = ctx(prompt("진짜 말"))
    check("[마리나]" in c and want in c, f"{rec_} 알림: {c!r}")
    check(not (sd / "git-sync.json").exists() and ctx(prompt("또 말")) == "", "알린 뒤 기록 삭제·한 번만")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-git-sync"
