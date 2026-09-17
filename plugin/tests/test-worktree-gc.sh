#!/usr/bin/env bash
# 유휴 워크트리 판정 + 삭제 전 안전 가드 (marina_worktree_gc) + CLI `marina worktree gc`.
#
# 유휴 = 붙은 세션 0 + cwd 프로세스 0(기존 liveness 규칙) + 커밋·파일 mtime 모두 K일 초과.
# 가드 = (a) detached HEAD 임시 브랜치 (b) 서브레포의 원격에 없는 커밋 → 메인 클론 backup/ 브랜치
#        (c) 서브레포 밖 진짜 untracked/미커밋 → 대상 제외 + 사유.
# 진짜 git 저장소(+bare 원격)로 확인한다 — "원격에 없는 커밋"은 git 이 답해야 한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
SH="$SCR/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

OLD="$(date -v-30d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '30 days ago' '+%Y-%m-%dT%H:%M:%S')"
export GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD"    # 모든 커밋은 30일 전(활성 워크트리만 나중에 최신 커밋)
gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm i; }

# 메인 클론: 루트 레포 + 중첩 서브레포 sub(원격 bare 있음, main 은 push 됨) — mdc-main 과 같은 구조
SRC="$TMP/proj"; gi "$SRC"
git init -q --bare "$TMP/remote-sub.git"
gi "$SRC/sub"; git -C "$SRC/sub" remote add origin "$TMP/remote-sub.git"; git -C "$SRC/sub" push -q -u origin main
printf 'node_modules/\n' > "$SRC/.gitignore"; git -C "$SRC" add .gitignore; git -C "$SRC" commit -qm ignore
mkdir -p "$SRC/.claude/worktrees"
mkwt() {   # 루트 detached 워크트리 + 서브레포 워크트리(브랜치 codex/<name>)
  git -C "$SRC" worktree add -q --detach "$SRC/.claude/worktrees/$1" HEAD
  git -C "$SRC/sub" worktree add -q -b "codex/$1" "$SRC/.claude/worktrees/$1/sub" main
}
mkwt wt-idle; mkwt wt-active; mkwt wt-untracked; mkwt wt-nested-dirty
# wt-idle: 루트에 detached 새 커밋(어느 ref 도 못 닿음) + 서브레포에 원격 없는 커밋
echo detached > "$SRC/.claude/worktrees/wt-idle/d.txt"; git -C "$SRC/.claude/worktrees/wt-idle" add d.txt; git -C "$SRC/.claude/worktrees/wt-idle" commit -qm detached-work
echo unpushed > "$SRC/.claude/worktrees/wt-idle/sub/u.txt"; git -C "$SRC/.claude/worktrees/wt-idle/sub" add u.txt; git -C "$SRC/.claude/worktrees/wt-idle/sub" commit -qm unpushed
# ignore 된 node_modules 의 최신 파일은 활동이 아니다
mkdir -p "$SRC/.claude/worktrees/wt-idle/node_modules"; echo x > "$SRC/.claude/worktrees/wt-idle/node_modules/fresh.js"
# wt-untracked: 서브레포 밖 진짜 untracked 파일
echo notes > "$SRC/.claude/worktrees/wt-untracked/notes.txt"
# wt-nested-dirty: 서브레포 안 미커밋 수정(remove 는 서브레포를 --force 로 지운다 — 잃는다)
echo dirty > "$SRC/.claude/worktrees/wt-nested-dirty/sub/r"
# wt-active: 최근 커밋
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
echo now > "$SRC/.claude/worktrees/wt-active/n.txt"; git -C "$SRC/.claude/worktrees/wt-active" add n.txt; git -C "$SRC/.claude/worktrees/wt-active" commit -qm recent
# 파일 mtime 을 전부 30일 전으로(활성 워크트리 제외) — node_modules/fresh.js 만 지금
find "$SRC/.claude/worktrees" -path '*/wt-active' -prune -o -not -path '*/node_modules/*' -print0 | xargs -0 touch -t "$(date -v-30d '+%Y%m%d%H%M' 2>/dev/null || date -d '30 days ago' '+%Y%m%d%H%M')"

cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"proj","root":"$SRC","subrepos":["sub"],"worktreeGlobs":[".claude/worktrees/*"],"kind":"compose","composeFile":"docker-compose.yml"}]}
JSON
mkdir -p "$MARINA_HOME/proj"; printf 'services: {}\n' > "$MARINA_HOME/proj/docker-compose.yml"

PYTHONPATH="$SCR" python3 - "$SRC" "$TMP" <<'PY'
import os
import subprocess
import sys
import time
from pathlib import Path

src, tmp = Path(sys.argv[1]), Path(sys.argv[2])
import marina_sessions as ms
import marina_worktree_gc as gc
from marina_registry import discover_all_roots

ms._du_info = lambda root, is_main, refresh: (10, {}, 20, {})     # du·docker 는 여기 관심사가 아니다
discover_all_roots(refresh=True)
W = lambda n: src / ".claude/worktrees" / n
def git(repo, *a):
    return subprocess.run(["git", "-C", str(repo), *a], capture_output=True, text=True).stdout.strip()

fails = []
def check(cond, msg):
    if not cond:
        fails.append(msg)

# ── 판정 ──────────────────────────────────────────────────────────
info_idle = ms.worktree_info(W("wt-idle"), refresh=True)
v = gc.idle_verdict(W("wt-idle"), info_idle, [], set(), days=14)
check(v["gcIdle"] is True and v["gcIdleDays"] and v["gcIdleDays"] > 14, f"30일 전 커밋·mtime 이면 유휴여야 한다: {v}")
# node_modules(ignored)의 최신 파일은 활동으로 안 본다 — 위에서 이미 유휴로 판정됐다는 게 그 증거. 명시적으로도:
check(gc.latest_file_mtime(W("wt-idle"), refresh=True) < time.time() - 20 * 86400, "ignored 파일의 mtime 이 활동으로 잡혔다")
# ① 붙은 세션이 있으면 유휴 아님 (작업중/대기/차단·reachable), 끝난 세션은 무시
for agents in ([{"status": "working"}], [{"status": "waiting"}], [{"status": "completed", "reachable": True}]):
    v2 = gc.idle_verdict(W("wt-idle"), info_idle, agents, set(), days=14)
    check(v2["gcIdle"] is False and v2["gcAgents"] == 1, f"붙은 세션이 있으면 유휴가 아니다: {agents} → {v2}")
v3 = gc.idle_verdict(W("wt-idle"), info_idle, [{"status": "completed"}, {"status": "idle"}], set(), days=14)
check(v3["gcIdle"] is True and v3["gcAgents"] == 0, f"끝난/idle 트랜스크립트는 붙은 세션이 아니다: {v3}")
# ② cwd 프로세스 — 기존 liveness 규칙(root 자신·하위 = live, 부모·중첩 워크트리 = 아님)
v4 = gc.idle_verdict(W("wt-idle"), info_idle, [], {W("wt-idle") / "sub"}, days=14)
check(v4["gcIdle"] is False and v4["gcLiveProcess"], f"하위 폴더 cwd 프로세스가 있으면 유휴 아님: {v4}")
v5 = gc.idle_verdict(W("wt-idle"), info_idle, [], {src}, days=14)
check(v5["gcIdle"] is True, f"부모(main) cwd 는 이 워크트리의 프로세스가 아니다: {v5}")
# ③ 최근 커밋이면 활성(스캔 없이)
v6 = gc.idle_verdict(W("wt-active"), ms.worktree_info(W("wt-active"), refresh=True), [], set(), days=14)
check(v6["gcIdle"] is False and v6["gcIdleDays"] < 1, f"최근 커밋 워크트리가 유휴로 잡혔다: {v6}")
# 커밋은 옛날인데 파일만 최근 수정 → 활성(둘 다 넘겨야 유휴)
(W("wt-nested-dirty") / "touched.md").write_text("recent", encoding="utf-8")
v7 = gc.idle_verdict(W("wt-nested-dirty"), ms.worktree_info(W("wt-nested-dirty"), refresh=True), [], set(), days=14)
check(v7["gcIdle"] is False, f"파일 mtime 이 최근이면 유휴 아님: {v7}")
(W("wt-nested-dirty") / "touched.md").unlink(); gc._mtime_cache.clear()

# ── 가드 (dry) ─────────────────────────────────────────────────────
date = "20260914"
r = gc.guard_report(W("wt-idle"), apply=False, date=date)
check(r["eligible"] is True and r["reasons"] == [], f"wt-idle 은 적격이어야: {r}")
kinds = {(b.get("subrepo") or "root"): b for b in r["backups"]}
check(set(kinds) == {"root", "sub"}, f"루트 detached + 서브레포 미푸시 둘 다 계획돼야: {r['backups']}")
check(all(not b["created"] for b in r["backups"]), "dry 인데 created 가 True")
check(kinds["root"]["branch"] == f"backup/worktree-wt-idle-{date}", kinds["root"]["branch"])
check(not git(src, "branch", "--list", "backup/*"), "dry 인데 루트에 브랜치가 생겼다")
check(not git(src / "sub", "branch", "--list", "backup/*"), "dry 인데 서브레포에 브랜치가 생겼다")
# (c) untracked → 부적격 + 사유
r2 = gc.guard_report(W("wt-untracked"), apply=False, date=date)
check(r2["eligible"] is False and any("untracked" in x and "notes.txt" in x for x in r2["reasons"]), f"untracked 사유가 없다: {r2}")
# 서브레포 안 미커밋 → 부적격(--force 로 지워지면 잃는다)
r3 = gc.guard_report(W("wt-nested-dirty"), apply=False, date=date)
check(r3["eligible"] is False and any(x.startswith("sub:") for x in r3["reasons"]), f"서브레포 미커밋 사유가 없다: {r3}")
# 원격 확인 자체가 실패하면(git 락·타임아웃) "안전"이 아니라 "모름" — 제외 + 사유(fail-closed, 리뷰 지적)
_orig_unpushed = gc._unpushed_count
gc._unpushed_count = lambda repo: None
r_unknown = gc.guard_report(W("wt-idle"), apply=False, date=date)
check(r_unknown["eligible"] is False and any("원격 확인 불가" in x for x in r_unknown["reasons"]), f"원격 확인 실패를 안전으로 읽었다: {r_unknown}")
gc._unpushed_count = _orig_unpushed
# main 은 절대 대상 아님
check(gc.guard_report(src)["eligible"] is False, "원본 체크아웃이 적격으로 나왔다")

# ── 계획(gc_plan) — 유휴만, main 제외, 부적격은 사유와 함께 ─────────────
plan = {e["id"]: e for e in gc.gc_plan(days=14, apply=False, refresh=True)}
check(set(plan) == {"wt-idle", "wt-untracked", "wt-nested-dirty"}, f"유휴 목록: {sorted(plan)}")
check(plan["wt-idle"]["eligible"] and not plan["wt-untracked"]["eligible"] and not plan["wt-nested-dirty"]["eligible"], "적격 판정 불일치")
check(plan["wt-idle"]["diskMb"] == 10 and plan["wt-idle"]["imageMb"] == 20, f"용량이 계획에 안 실렸다: {plan['wt-idle']}")

# 서브레포 밖 tracked 수정(" M r" — porcelain 첫 레코드 앞 공백) → 미커밋 수정으로 분류
(W("wt-untracked") / "r").write_text("changed", encoding="utf-8")
mod, unt = gc._own_changes(W("wt-untracked"))
check(mod == ["r"] and unt == ["notes.txt"], f"_own_changes 분류 오류: {mod} {unt}")
_old = time.time() - 30 * 86400; os.utime(W("wt-untracked") / "r", (_old, _old)); gc._mtime_cache.clear()   # 방금 쓴 mtime 을 되돌린다(CLI 절이 유휴로 봐야)

# ── 가드 적용 ──────────────────────────────────────────────────────
head_root = git(W("wt-idle"), "rev-parse", "HEAD")
head_sub = git(W("wt-idle") / "sub", "rev-parse", "HEAD")
r = gc.guard_report(W("wt-idle"), apply=True, date=date)
check(all(b["created"] for b in r["backups"]) and r["eligible"], f"apply 결과: {r}")
check(git(src, "rev-parse", f"backup/worktree-wt-idle-{date}") == head_root, "루트 detached 커밋이 메인 클론 backup 브랜치에 없다")
check(git(src / "sub", "rev-parse", f"backup/worktree-wt-idle-{date}") == head_sub, "서브레포 미푸시 커밋이 메인 서브레포 backup 브랜치에 없다")
# 두 번째 적용(멱등) — 루트 detached 는 이제 backup 브랜치에서 닿으니 계획에서 빠지고,
# 서브레포는 여전히 원격에 없으니 다시 잡히되 같은 sha 의 같은 이름을 재사용(existed, created=False)
r_again = gc.guard_report(W("wt-idle"), apply=True, date=date)
again = {(b.get("subrepo") or "root"): b for b in r_again["backups"]}
check(set(again) == {"sub"}, f"두 번째 적용: 루트는 이미 보존됐으니 빠져야: {r_again}")
check(again["sub"]["branch"] == kinds["sub"]["branch"] and again["sub"]["existed"] and not again["sub"]["created"], f"서브레포 백업 멱등 아님: {again}")
check(len(git(src / "sub", "branch", "--list", "backup/*").split()) == 1, "백업 브랜치가 중복 생성됐다")
# 부적격(untracked)엔 백업을 만들지 않는다(가드는 삭제 전 단계 — 삭제 안 할 것에 브랜치를 남기지 않는다)
_old_iso = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(_old))
subprocess.run(["git", "-C", str(W("wt-untracked") / "sub"), "commit", "-qm", "sub-unpushed", "--allow-empty"],
               env={**os.environ, "GIT_AUTHOR_DATE": _old_iso, "GIT_COMMITTER_DATE": _old_iso}, check=True)   # 30일 전 커밋(유휴 유지)
r4 = gc.guard_report(W("wt-untracked"), apply=True, date=date)
check(r4["backups"] and not any(b["created"] for b in r4["backups"]), f"부적격인데 백업을 만들었다: {r4}")

if fails:
    print("FAIL test-worktree-gc"); [print("  -", f) for f in fails]; sys.exit(1)
print("PASS test-worktree-gc(python)")
PY

# ── CLI: marina worktree gc ──────────────────────────────────────────────
cd "$TMP"
out="$(bash "$SH" worktree gc --dry-run --days 14 --json)"
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["dryRun"] is True and d["days"] == 14, d
ids = sorted(e["id"] for e in d["items"])
assert ids == ["wt-idle", "wt-nested-dirty", "wt-untracked"], ids
idle = next(e for e in d["items"] if e["id"] == "wt-idle")
# 루트 detached 는 위 python 절에서 이미 보존됐으니(ref 에서 닿음) 여기선 서브레포 백업만 남는다.
# `existed` 는 보지 않는다 — 위 절은 날짜를 20260914 로 고정해 브랜치를 만들고 CLI 는 오늘 날짜로 이름을 짓는다.
# 그래서 9/15 부터 이 줄이 날짜 때문에 실패했다(가드는 정상). 날짜와 무관한 사실만 확인한다.
assert idle["eligible"] and [b.get("subrepo") for b in idle["backups"]] == ["sub"], idle
assert idle["backups"][0].get("sha") and not idle["backups"][0].get("error"), idle
PY
text="$(bash "$SH" worktree gc --dry-run --days 14)"
grep -q "유휴 워크트리 3개" <<<"$text" || { echo "FAIL: CLI 요약 줄 없음: $text"; exit 1; }
grep -q "✗ wt-untracked" <<<"$text" || { echo "FAIL: 부적격 표시 없음: $text"; exit 1; }
grep -q "untracked 1개: notes.txt" <<<"$text" || { echo "FAIL: 사유 표시 없음: $text"; exit 1; }
grep -q "대시보드" <<<"$text" || { echo "FAIL: 삭제는 대시보드 안내가 없다: $text"; exit 1; }
# --days 를 크게 주면 아무것도 유휴가 아니다
bash "$SH" worktree gc --dry-run --days 90 | grep -q "유휴 워크트리 없음" || { echo "FAIL: --days 90 이면 없음이어야"; exit 1; }
# 워크트리 폴더는 CLI 가 절대 지우지 않는다
[[ -d "$SRC/.claude/worktrees/wt-idle" ]] || { echo "FAIL: CLI 가 워크트리를 지웠다"; exit 1; }
echo "PASS test-worktree-gc"
