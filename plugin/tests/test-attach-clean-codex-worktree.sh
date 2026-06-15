#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ATTACH_SCRIPT="$PLUGIN_DIR/scripts/attach-detached-subrepos.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/marina-attach-clean.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

source_root="$tmp/source/mdc-main"
dest_root="$tmp/codex-worktrees/abcd/mdc-main"
marina_home="$tmp/marina"
mkdir -p "$source_root" "$dest_root" "$marina_home"
source_root="$(cd "$source_root" && pwd -P)"
dest_root="$(cd "$dest_root" && pwd -P)"
marina_home="$(cd "$marina_home" && pwd -P)"

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

cat > "$marina_home/projects.json" <<JSON
{
  "projects": [
    {
      "id": "mdc-main",
      "root": "$source_root",
      "subrepos": ["web-app-monorepo", "be-api", "ai-api"],
      "worktreeGlobs": ["~/.codex/worktrees/*/mdc-main"]
    }
  ],
  "schemaVersion": 1
}
JSON

output="$(
  MARINA_HOME="$marina_home" \
  CODEX_WORKTREES_ROOT="$tmp/codex-worktrees" \
  DEST_ROOT="$dest_root" \
  SYNC_IDEA=false \
  "$ATTACH_SCRIPT"
)"

printf '%s\n' "$output"

case "$output" in
  *"source: $source_root"* ) ;;
  * ) echo "missing registry source root" >&2; exit 1 ;;
esac

for repo in web-app-monorepo be-api ai-api; do
  case "$output" in
    *"attach: $repo -> $dest_root/$repo"* ) ;;
    * ) echo "missing attach line for $repo" >&2; exit 1 ;;
  esac
  [[ "$(git -C "$dest_root/$repo" rev-parse --is-inside-work-tree)" == "true" ]]
  [[ "$(git -C "$dest_root/$repo" branch --show-current)" == "codex/abcd" ]]
done

case "$output" in
  *"done"* ) ;;
  * ) echo "missing done line" >&2; exit 1 ;;
esac
