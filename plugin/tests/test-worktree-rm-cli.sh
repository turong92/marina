#!/usr/bin/env bash
# 분리 A 실측: runtime 만 깔면 워크트리를 '지우는' 명령이 없었다(대시보드 버튼뿐) → `marina worktree rm <이름|경로> [--force]`
#  - 잠긴(쓰는 중) 워크트리·미커밋 변경은 --force 없이 거절, --force 면 지운다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
M="$SCRIPTS/marina.sh"
fail() { echo "FAIL: $*"; exit 1; }
H="$(cd "$MARINA_HOME" && pwd -P)"; P="$H/proj"; mkdir -p "$P"
git -C "$P" init -q -b main; git -C "$P" config user.email t@t; git -C "$P" config user.name t; echo a > "$P/a"; git -C "$P" add a; git -C "$P" commit -qm a
printf '{"projects":[{"id":"proj","root":"%s","subrepos":[],"worktreeGlobs":[".claude/worktrees/*"]}],"schemaVersion":1}\n' "$P" > "$MARINA_HOME/projects.json"
for b in w1 w2 w3; do (cd "$P" && bash "$M" worktree create "$b" >/dev/null 2>&1) || fail "create $b"; done
(cd "$P" && bash "$M" worktree rm w1 >/dev/null 2>&1) || fail "rm 이름으로"
[ ! -d "$P/.claude/worktrees/w1" ] || fail "w1 이 남았다"
git -C "$P" worktree lock --reason "marina-session proj/w2" "$P/.claude/worktrees/w2"
out="$(cd "$P" && bash "$M" worktree rm w2 2>&1)" && fail "잠긴 워크트리를 지웠다"
echo "$out" | grep -q "잠김" || fail "이유: $out"
(cd "$P" && bash "$M" worktree rm "$P/.claude/worktrees/w2" --force >/dev/null 2>&1) || fail "--force + 경로로"
[ ! -d "$P/.claude/worktrees/w2" ] || fail "w2 가 남았다"
echo x > "$P/.claude/worktrees/w3/dirty"
(cd "$P" && bash "$M" worktree rm w3 >/dev/null 2>&1) && fail "미커밋 있는 걸 지웠다"
[ -d "$P/.claude/worktrees/w3" ] || fail "w3 는 남아야"
(cd "$P" && bash "$M" worktree rm "$P" >/dev/null 2>&1) && fail "원본 체크아웃을 지웠다"
echo "PASS test-worktree-rm-cli"
