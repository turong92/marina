#!/usr/bin/env bash
# Claude Code 워크트리 훅(분리 A, 스펙 3장 실측): WorktreeCreate 는 경로 한 줄을 stdout 으로, WorktreeRemove 는 거절(≠0)하면 워크트리가 남는다.
#  - 플러그인 훅이라 **모든 레포**에 걸린다 → 마리나 프로젝트가 아니면 Claude 기본 동작(<repo>/.claude/worktrees/<name>, 브랜치 worktree-<name>)
#  - 마리나 프로젝트면 `marina worktree create` 경로(브랜치 = name, 기준 = MARINA_BASE). 마리나 경로가 터지면 기본 동작으로
#  - 남이 잠근 워크트리(Discord 세션)는 /exit 자동 삭제를 거절한다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
HOOK="$SCRIPTS/marina-worktree-hook.sh"
fail() { echo "FAIL: $*"; exit 1; }
gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t; git -C "$1" config user.name t; echo a > "$1/a"; git -C "$1" add a; git -C "$1" commit -qm a; }
H="$(cd "$MARINA_HOME" && pwd -P)"
OTHER="$H/other"; gi "$OTHER"
git -C "$OTHER" checkout -q -b dev; echo d > "$OTHER/d"; git -C "$OTHER" add d; git -C "$OTHER" commit -qm d; git -C "$OTHER" checkout -q main
MP="$H/mproj"; gi "$MP"
printf '{"projects":[{"id":"mproj","root":"%s","subrepos":[],"worktreeGlobs":[".claude/worktrees/*"]}],"schemaVersion":1}\n' "$MP" > "$MARINA_HOME/projects.json"
create() { printf '{"name":"%s","cwd":"%s","session_id":"s","hook_event_name":"WorktreeCreate"}' "$1" "$2" | bash "$HOOK" create; }
remove() { printf '{"worktree_path":"%s","cwd":"%s","hook_event_name":"WorktreeRemove"}' "$1" "$1" | bash "$HOOK" remove; }

# 1) 마리나 아닌 레포 = Claude 기본과 같다
out="$(create t1 "$OTHER" 2>/dev/null)"
[ "$out" = "$OTHER/.claude/worktrees/t1" ] || fail "기본 경로: '$out'"
[ "$(git -C "$out" branch --show-current)" = "worktree-t1" ] || fail "기본 브랜치 worktree-t1"
[ "$(create t1 "$OTHER" 2>/dev/null)" = "$out" ] || fail "다시 불러도 같은 경로(오류 없음)"
# 하위 폴더에서 불러도 같은 레포
mkdir -p "$OTHER/sub"; [ "$(create t1 "$OTHER/sub" 2>/dev/null)" = "$out" ] || fail "하위 폴더 cwd"
# 2) 기준 브랜치는 띄울 때 준 환경변수로
out2="$(MARINA_BASE=dev create t2 "$OTHER" 2>/dev/null)"
[ -f "$out2/d" ] || fail "MARINA_BASE=dev 에서 시작"
# 3) 마리나 프로젝트 = marina worktree create 경로(브랜치 = name)
out3="$(create feat-x "$MP" 2>/dev/null)"
[ "$out3" = "$MP/.claude/worktrees/feat-x" ] || fail "마리나 경로: '$out3'"
[ "$(git -C "$out3" branch --show-current)" = "feat-x" ] || fail "마리나 브랜치 = name"
PYTHONPATH="$SCRIPTS" python3 -c "
import sys; from pathlib import Path
from marina_registry import discover_all_roots
sys.exit(0 if Path('$out3').resolve() in [r.resolve() for r in discover_all_roots(refresh=True)] else 1)" || fail "마리나가 워크트리로 안다"
[ "$(create feat-x "$MP" 2>/dev/null)" = "$out3" ] || fail "마리나도 다시 부르면 같은 경로"
# 4) 마리나 경로가 터져도 기본 동작으로 떨어진다
cp "$MARINA_HOME/projects.json" "$MARINA_HOME/projects.bak"; echo '{broken' > "$MARINA_HOME/projects.json"
out4="$(create t4 "$MP" 2>/dev/null)"
[ "$out4" = "$MP/.claude/worktrees/t4" ] && [ -d "$out4" ] || fail "고장 시 기본 동작: '$out4'"
mv "$MARINA_HOME/projects.bak" "$MARINA_HOME/projects.json"
# 5) remove — 남의 잠금은 거절(워크트리 남음), 자기(claude)·잠금 없음은 지운다
git -C "$OTHER" worktree lock --reason "marina-session other/t1" "$out"
set +e; remove "$out" 2>/dev/null; rc=$?; set -e
[ "$rc" -ne 0 ] && [ -d "$out" ] || fail "잠긴 워크트리 삭제 거절(rc=$rc)"
git -C "$OTHER" worktree unlock "$out"
git -C "$OTHER" worktree lock --reason "claude session t1 (pid $$ start x)" "$out"
remove "$out" 2>/dev/null || fail "claude 자기 잠금은 막지 않는다"
[ ! -d "$out" ] || fail "지워져야"
remove "$out2" 2>/dev/null && [ ! -d "$out2" ] || fail "잠금 없으면 지운다"
remove "$out3" 2>/dev/null && [ ! -d "$out3" ] || fail "마리나 워크트리도 지운다"
# 6) stdout 은 경로 한 줄뿐(다른 출력이 섞이면 Claude 가 그걸 경로로 쓴다)
[ "$(create t6 "$MP" | wc -l | tr -d ' ')" = 1 ] || fail "stdout 한 줄"
# ── 리뷰 지적 ──
# I1: 마리나 경로도 기준 = 띄운 자리의 HEAD(부모 에이전트가 커밋한 게 서브에이전트에 보여야). origin/HEAD 로 fetch 하지 않는다
FW="$(create feat-base "$MP" 2>/dev/null)"
echo b > "$FW/b"; git -C "$FW" add b; git -C "$FW" commit -qm b
SUB="$(create agent-1 "$FW" 2>/dev/null)"
[ -f "$SUB/b" ] || fail "I1: 서브에이전트 워크트리가 부모 워크트리 HEAD 에서 시작해야"
# I2: 지우면 훅이 만든 브랜치도(머지된 것만 -d) — 아무 레포나 서브에이전트마다 브랜치가 쌓이면 안 된다
o7="$(create t7 "$OTHER" 2>/dev/null)"; remove "$o7" 2>/dev/null
git -C "$OTHER" show-ref --verify --quiet refs/heads/worktree-t7 && fail "I2: 기본 경로 브랜치 worktree-t7 이 남았다"
remove "$SUB" 2>/dev/null
git -C "$MP" show-ref --verify --quiet refs/heads/agent-1 || fail "I2: 머지 안 된 커밋이 있는 브랜치는 남긴다(-d)"
S2="$(create agent-2 "$MP" 2>/dev/null)"; remove "$S2" 2>/dev/null
git -C "$MP" show-ref --verify --quiet refs/heads/agent-2 && fail "I2: 마리나 경로 브랜치 agent-2 가 남았다"
# M1: worktree_path 가 없으면 아무것도 안 지운다(cwd 로 대신하면 돌던 워크트리를 지운다)
set +e; printf '{"cwd":"%s","hook_event_name":"WorktreeRemove"}' "$FW" | bash "$HOOK" remove 2>/dev/null; rc=$?; set -e
[ "$rc" -ne 0 ] && [ -d "$FW" ] || fail "M1: worktree_path 없으면 거절하고 남긴다(rc=$rc)"
# C1: 서브레포에 미커밋 변경이 있으면 거절 — Claude 는 루트만 보고 '변경 없음'으로 묻지 않고 지운다
PYTHONPATH="$SCRIPTS" python3 - "$FW" <<'PY2'
import sys
from pathlib import Path
import marina_worktree_hooks as h, marina_worktrees
marina_worktrees.worktree_status = lambda root: {"clean": False, "repos": [
    {"name": "mproj", "dirty": False}, {"name": "backend", "dirty": True, "changeCount": 2}]}
code, msg = h.remove({"worktree_path": sys.argv[1]})
assert code != 0 and "backend" in msg and Path(sys.argv[1]).exists(), (code, msg)
marina_worktrees.worktree_status = lambda root: {"clean": False, "repos": [{"name": "mproj", "dirty": True}]}
code, msg = h.remove({"worktree_path": sys.argv[1]})
assert code == 0 and not Path(sys.argv[1]).exists(), "루트만 더러우면 Claude 가 이미 물어본 것 — 지운다"
PY2
# 실측(homeserver): 서브레포에도 같은 이름 브랜치가 생긴다(attach 미러) — 지울 때 서브레포 브랜치도 정리(-d)
SP="$H/sproj"; gi "$SP"; gi "$SP/sub"; printf 'sub/\n' > "$SP/.gitignore"; git -C "$SP" add .gitignore; git -C "$SP" commit -qm ig
python3 - "$MARINA_HOME/projects.json" "$SP" <<'PY3'
import json, sys
d = json.load(open(sys.argv[1])); d["projects"].append({"id": "sproj", "root": sys.argv[2], "subrepos": ["sub"], "worktreeGlobs": [".claude/worktrees/*"]})
json.dump(d, open(sys.argv[1], "w"))
PY3
SW="$(create agent-s "$SP" 2>/dev/null)"
[ -e "$SW/sub/.git" ] || fail "서브레포 attach"
git -C "$SP/sub" show-ref --verify --quiet refs/heads/agent-s || fail "서브레포에 같은 이름 브랜치(실측 전제)"
remove "$SW" 2>/dev/null || fail "remove sproj"
git -C "$SP/sub" show-ref --verify --quiet refs/heads/agent-s && fail "서브레포 브랜치 agent-s 가 남았다"
echo "PASS test-worktree-hooks"
