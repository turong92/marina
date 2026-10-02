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
echo "PASS test-worktree-hooks"
