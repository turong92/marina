#!/usr/bin/env bash
# When the attach hook runs from inside an attached subrepo, it must promote
# DEST_ROOT to the project worktree root before attaching sibling subrepos.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ATTACH_SCRIPT="$PLUGIN_DIR/scripts/attach-detached-subrepos.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/marina-attach-from-subrepo.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

source_root="$tmp/source/mdc-main"
dest_root="$tmp/codex-worktrees/abcd/mdc-main"
mkdir -p "$source_root" "$dest_root"
source_root="$(cd "$source_root" && pwd -P)"
dest_root="$(cd "$dest_root" && pwd -P)"

git_init_with_commit() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.invalid"
  git -C "$repo" config user.name "Marina Test"
  printf 'ok\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "test: initial"
}

for repo in web-app-monorepo be-api ai-api; do
  git_init_with_commit "$source_root/$repo"
done

git -C "$source_root/be-api" worktree add -q --detach "$dest_root/be-api" HEAD

output="$(
  SOURCE_ROOT="$source_root" \
  DEST_ROOT="$dest_root/be-api" \
  MARINA_SUBREPOS="web-app-monorepo be-api ai-api" \
  CODEX_WORKTREES_ROOT="$tmp/codex-worktrees" \
  SYNC_IDEA=false \
  "$ATTACH_SCRIPT"
)"

printf '%s\n' "$output"

case "$output" in
  *"promote dest: $dest_root/be-api -> $dest_root"* ) ;;
  * ) echo "missing promoted dest line" >&2; exit 1 ;;
esac

for repo in web-app-monorepo be-api ai-api; do
  [[ "$(git -C "$dest_root/$repo" rev-parse --is-inside-work-tree)" == "true" ]]
done

[[ ! -e "$dest_root/be-api/ai-api" ]] || {
  echo "FAIL: nested ai-api was attached under be-api" >&2
  exit 1
}

echo "PASS test-attach-from-subrepo-root"
