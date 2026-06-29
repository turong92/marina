#!/usr/bin/env bash
# 워크트리에 명시 브랜치(예: feature/foo)가 있으면 attach 가 그 *전체 이름* 을 서브레포에 미러한다.
# (crabs 등 feature 브랜치 라이프사이클 정합 — "워크트리를 feature/{task} 로 생성 = 작업 시작".)
# detached/빈 브랜치 폴백(<prefix>/<id>)은 test-attach-clean-codex-worktree 가 커버.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ATTACH_SCRIPT="$PLUGIN_DIR/scripts/attach-detached-subrepos.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/marina-attach-mirror.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

source_root="$tmp/source/mdc-main"
marina_home="$tmp/marina"
mkdir -p "$source_root" "$marina_home"
source_root="$(cd "$source_root" && pwd -P)"
marina_home="$(cd "$marina_home" && pwd -P)"

git_init_with_commit() {
  local repo="$1"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.invalid"
  git -C "$repo" config user.name "Marina Test"
  printf 'ok\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "test: initial"
}

# 부모 mdc + 서브레포 = 각각 독립 git 레포
git_init_with_commit "$source_root"
for repo in web-app-monorepo be-api ai-api; do
  git_init_with_commit "$source_root/$repo"
done

# DEST = source 의 워크트리, 브랜치 feature/foo (작업 시작 시 워크트리를 feature 이름으로 생성)
dest_root="$tmp/worktrees/feature-foo"
git -C "$source_root" worktree add -q -b feature/foo "$dest_root"
dest_root="$(cd "$dest_root" && pwd -P)"

output="$(
  MARINA_HOME="$marina_home" \
  SOURCE_ROOT="$source_root" \
  DEST_ROOT="$dest_root" \
  MARINA_SUBREPOS="web-app-monorepo be-api ai-api" \
  SYNC_IDEA=false \
  "$ATTACH_SCRIPT"
)"
printf '%s\n' "$output"

# 핵심: 서브레포 브랜치 == 워크트리 브랜치(feature/foo) 미러 — codex/<id> 가 아님
for repo in web-app-monorepo be-api ai-api; do
  [[ "$(git -C "$dest_root/$repo" rev-parse --is-inside-work-tree)" == "true" ]]
  got="$(git -C "$dest_root/$repo" branch --show-current)"
  [[ "$got" == "feature/foo" ]] || { echo "FAIL: $repo branch=$got (expected feature/foo)" >&2; exit 1; }
done

echo "PASS test-attach-branch-mirror"
