#!/usr/bin/env bash
# 방 브랜치를 '일 사이 안전한 때'에만 origin 기본 브랜치에 맞춘다(형 승인 2026-11-05):
# 일 조각이 끝나고 50분 쉰 방 → fetch 뒤, 작업 트리가 깨끗하면 rebase(충돌이면 abort+기록), 더러우면 뒤처진 수만 기록.
# 사람의 첫 입력(hook_prompt)에 기록을 한 줄로 알리고 지운다. 임시 git 레포(origin 베어 + 다른 클론)로 흉내 — 형의 레포는 안 건드린다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
export FD SRC TMPROOT
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a >/dev/null 2>&1 || fail "new a"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, subprocess, sys, time
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
def push(name, text):
    (other / name).write_text(text); git(other, "add", name); git(other, "commit", "-qm", f"other {name}"); git(other, "push", "-q", "origin", "main")
rec = ms.find_session("proj/feat/a"); root = Path(rec["root"]); sd = Path(rec["stateDir"])
git(root, "config", "user.email", "t@t.invalid"); git(root, "config", "user.name", "T")
def mine(name, text):
    (root / name).write_text(text); git(root, "add", name); git(root, "commit", "-qm", f"mine {name}")
# 최신
check(mi.sync_to_origin(root) is None, "이미 최신이면 아무것도 안 함")
# 뒤처짐 + 깨끗 → rebase (내 커밋은 남는다)
mine("m1.txt", "m1\n"); push("o1.txt", "o1\n")
r = mi.sync_to_origin(root)
check(r == {"state": "rebased", "n": 1, "base": "origin/main"}, f"깨끗하면 rebase: {r}")
check((root / "o1.txt").exists() and (root / "m1.txt").exists() and git(root, "rev-list", "--count", "origin/main..HEAD") == "1", "origin 커밋 위에 내 커밋")
# 뒤처짐 + 충돌 → abort + 기록
push("same.txt", "origin\n"); (root / "same.txt").write_text("mine\n"); git(root, "add", "same.txt"); git(root, "commit", "-qm", "mine same")
head = git(root, "rev-parse", "HEAD")
r = mi.sync_to_origin(root)
check(r and r["state"] == "conflict" and r["n"] == 1, f"충돌: {r}")
check(git(root, "rev-parse", "HEAD") == head and not (Path(git(root, "rev-parse", "--absolute-git-dir")) / "rebase-merge").exists()
      and git(root, "status", "--porcelain") == "", "충돌이면 rebase --abort 로 원래대로")
git(root, "reset", "-q", "--hard", "HEAD~1")
# 더러움 → 알림만
(root / "m1.txt").write_text("수정\n"); head = git(root, "rev-parse", "HEAD")
r = mi.sync_to_origin(root)
check(r == {"state": "behind", "n": 1, "base": "origin/main"}, f"커밋 안 한 변경이 있으면 rebase 안 함: {r}")
check(git(root, "rev-parse", "HEAD") == head, "HEAD 불변")
git(root, "checkout", "-q", "--", "m1.txt")
(root / "new.txt").write_text("x\n")
check(mi.sync_to_origin(root)["state"] == "behind", "untracked 도 더러움")
(root / ".gitignore").write_text("ign.log\n"); git(root, "add", ".gitignore"); git(root, "commit", "-qm", "ignore"); (root / "new.txt").unlink(); (root / "ign.log").write_text("l\n")
check(mi.sync_to_origin(root)["state"] == "rebased", "gitignore 대상은 더럽지 않다")
# 진행 중인 rebase/merge 가 있으면 rebase 안 함
push("o3.txt", "o3\n")
(Path(git(root, "rev-parse", "--absolute-git-dir")) / "MERGE_HEAD").write_text(git(root, "rev-parse", "HEAD") + "\n")
check(mi.sync_to_origin(root)["state"] == "behind", "진행 중인 merge 가 있으면 건드리지 않는다")
(Path(git(root, "rev-parse", "--absolute-git-dir")) / "MERGE_HEAD").unlink()
# 본체 체크아웃·기본 브랜치 자체는 제외
check(mi.sync_to_origin(SRC) is None, "워크트리가 아닌 본체 체크아웃은 제외")
git(root, "checkout", "-q", "--detach")
check(mi.sync_to_origin(root) is None, "브랜치가 없으면(분리 HEAD) 제외")
git(root, "checkout", "-q", "feat/a")
# fetch 실패는 조용히
git(root, "remote", "set-url", "origin", "/nonexistent/x.git")
check(mi.sync_to_origin(root) is None, "fetch 실패는 조용히 넘김")
git(root, "remote", "set-url", "origin", str(bare))
# ── keep_tick 연결: 일 조각 끝 + 50분 쉼에서 활동 시각당 한 번 · 하던 중이면 안 함 · 채팅방 제외 · 코덱스 포함 ──
T0 = time.time() + 100; H0 = T0 + 5; MIN = 60.0
(sd / "turn-at").write_text(str(T0)); (sd / "stopped-at").write_text(str(H0))
mb._spawn_type = lambda *a, **k: None
blockers = [[]]
mb.restart_blockers = lambda r: list(blockers[0]); mb.restart_status = lambda: None
mi._work_stale = lambda *a: False; mi._attached = lambda n: False
calls = []
real_sync = mi.sync_to_origin
mi.sync_to_origin = lambda p: (calls.append(str(p)), real_sync(p))[1]
def K_():
    k = mi.Idler(started=0.0); k.sync_inline = True; return k
K = K_()
git(root, "reset", "-q", "--hard", "HEAD")
K.keep_tick(H0 + 40 * MIN, {})
check(calls == [], "50분 전엔 안 한다")
blockers[0] = ["백그라운드 셸 1"]
K.keep_tick(H0 + 55 * MIN, {})
check(calls == [], "하던 중이면 안 한다")
blockers[0] = []
(sd / "keep.json").unlink(missing_ok=True); K = K_()
K.keep_tick(H0 + 55 * MIN, {})
check(calls == [str(root)], f"끝나고 50분 쉬면 한다: {calls}")
note = json.loads((sd / "git-sync.json").read_text())
check(note["state"] == "rebased", f"기록: {note}")
K.keep_tick(H0 + 70 * MIN, {}); K = K_(); K.keep_tick(H0 + 80 * MIN, {})
check(len(calls) == 1, f"같은 활동 시각엔 다시 안 한다: {calls}")
real_load = ms.load_sessions
ms.load_sessions = lambda: [dict(r_, kind="chat") for r_ in real_load()]
(sd / "keep.json").unlink(); K = K_(); K.keep_tick(H0 + 55 * MIN, {})
check(len(calls) == 1, "채팅·로비 방은 제외")
ms.load_sessions = real_load
real_codex = ms.is_codex; ms.is_codex = lambda r_: True
(sd / "keep.json").unlink(); K = K_(); K.keep_tick(H0 + 55 * MIN, {})
check(len(calls) == 2, "코덱스 방도 한다(git 은 하네스 무관)")
typed_codex = []
ms.is_codex = real_codex
# ── 알림: 사람의 첫 입력에 한 줄, 알린 뒤 기록 삭제. 캐시 유지 글은 기록을 가져가지 않는다 ──
os.environ["DISCORD_STATE_DIR"] = str(sd); ms._ensure_daemon_quiet = lambda: None
tr = ms.transcript_path(root, "aaaaaaaa-0000-1111-2222-333344445555"); tr.parent.mkdir(parents=True, exist_ok=True); tr.write_text("")
def prompt(text):
    return ms.hook_prompt({"hook_event_name": "UserPromptSubmit", "prompt": text, "transcript_path": str(tr)})
def ctx(out): return ((out or {}).get("hookSpecificOutput") or {}).get("additionalContext", "")
for state, n, want in (("rebased", 3, "쉬는 동안 origin/main 으로 rebase 함(3커밋)"),
                       ("behind", 2, "origin/main 이 2커밋 앞섬, 커밋 안 한 변경이 있어 rebase 안 함"),
                       ("conflict", 1, "자동 rebase 충돌로 되돌림 — 직접 rebase 필요")):
    (sd / "git-sync.json").write_text(json.dumps({"state": state, "n": n, "base": "origin/main"}))
    check(ctx(prompt(ms.KEEPALIVE_TEXT)) == "" and (sd / "git-sync.json").exists(), "캐시 유지 글은 기록을 가져가지 않는다")
    c = ctx(prompt("진짜 말"))
    check("[마리나]" in c and want in c, f"{state} 알림: {c!r}")
    check(not (sd / "git-sync.json").exists(), "알린 뒤 기록 삭제")
    check(ctx(prompt("또 말")) == "", "한 번만 알린다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-git-sync"
