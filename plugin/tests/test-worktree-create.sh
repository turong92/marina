#!/usr/bin/env bash
# marina worktree create <branch> — 브랜치명 지정 워크트리 생성(=작업 시작):
# git worktree add(-b) + 서브레포 attach(브랜치 전체 미러). 워크트리·서브레포가 같은 브랜치로 정렬.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MARINA="$SCRIPT_DIR/../scripts/marina.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/marina-wt-create.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

src="$tmp/proj"; mh="$tmp/marina"
mkdir -p "$src" "$mh"
src="$(cd "$src" && pwd -P)"; mh="$(cd "$mh" && pwd -P)"

gi() {
  git -C "$1" init -q
  git -C "$1" config user.email "t@example.invalid"
  git -C "$1" config user.name "Marina Test"
  printf 'ok\n' > "$1/r"; git -C "$1" add r; git -C "$1" commit -qm init
}
gi "$src"
for r in a b; do mkdir -p "$src/$r"; gi "$src/$r"; done

printf '{"projects":[{"id":"proj","root":"%s","subrepos":["a","b"]}],"schemaVersion":1}\n' "$src" > "$mh/projects.json"

( cd "$src" && MARINA_HOME="$mh" bash "$MARINA" worktree create feature/foo ) >/dev/null 2>&1

wt="$src/.claude/worktrees/feature-foo"
[[ -d "$wt" ]] || { echo "FAIL: 워크트리 디렉토리 없음 ($wt)" >&2; exit 1; }
[[ "$(git -C "$wt" branch --show-current)" == "feature/foo" ]] || { echo "FAIL: 워크트리 브랜치 != feature/foo" >&2; exit 1; }
for r in a b; do
  got="$(git -C "$wt/$r" branch --show-current 2>/dev/null)"
  [[ "$got" == "feature/foo" ]] || { echo "FAIL: 서브레포 $r 브랜치=$got (expected feature/foo)" >&2; exit 1; }
done

# --project <id>: cwd 무관(프로젝트 밖에서도) 레지스트리로 대상 프로젝트 해석
( cd "$tmp" && MARINA_HOME="$mh" bash "$MARINA" worktree create feature/bar --project proj ) >/dev/null 2>&1
wt2="$src/.claude/worktrees/feature-bar"
[[ "$(git -C "$wt2" branch --show-current)" == "feature/bar" ]] || { echo "FAIL: --project 워크트리 브랜치" >&2; exit 1; }
for r in a b; do
  [[ "$(git -C "$wt2/$r" branch --show-current 2>/dev/null)" == "feature/bar" ]] || { echo "FAIL: --project 서브레포 $r" >&2; exit 1; }
done

echo "PASS test-worktree-create"
