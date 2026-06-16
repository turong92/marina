#!/usr/bin/env bash
# attach-detached-subrepos.sh auto-attach honors defaultAttach + first-run gate
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ATTACH="$HERE/../scripts/attach-detached-subrepos.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
src="$tmp/source/proj"; dst="$tmp/codex/abcd/proj"; home="$tmp/marina"
mkdir -p "$src" "$dst" "$home"
src="$(cd "$src" && pwd -P)"; dst="$(cd "$dst" && pwd -P)"; home="$(cd "$home" && pwd -P)"
gi() { mkdir -p "$1"; git -C "$1" init -q; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm i; }
for r in a b c; do gi "$src/$r"; done
cat > "$home/projects.json" <<JSON
{"projects":[{"id":"proj","root":"$src","subrepos":["a","b","c"],"defaultAttach":["a"],"worktreeGlobs":["~/.codex/worktrees/*/proj"]}],"schemaVersion":1}
JSON
run() { MARINA_HOME="$home" CODEX_WORKTREES_ROOT="$tmp/codex" DEST_ROOT="$dst" SYNC_IDEA=false "$ATTACH" 2>&1; }

# fresh worktree → only the default set (a) attaches
out="$(run)"; printf '%s\n' "$out"
[[ -e "$dst/a/.git" ]] || { echo "FAIL: default a not attached"; exit 1; }
[[ ! -e "$dst/b/.git" ]] || { echo "FAIL: non-default b attached"; exit 1; }
[[ ! -e "$dst/c/.git" ]] || { echo "FAIL: non-default c attached"; exit 1; }

# second run → a already attached → gate skips, b/c stay absent (user-detached defaults are NOT revived)
out2="$(run)"; printf '%s\n' "$out2"
case "$out2" in *"skip auto-attach"*) ;; *) echo "FAIL: gate did not skip on initialized worktree"; exit 1;; esac
[[ ! -e "$dst/b/.git" ]] || { echo "FAIL: re-run attached b"; exit 1; }

# explicit MARINA_SUBREPOS bypasses the gate (dashboard single attach)
MARINA_SUBREPOS=b MARINA_HOME="$home" CODEX_WORKTREES_ROOT="$tmp/codex" DEST_ROOT="$dst" SYNC_IDEA=false "$ATTACH" >/dev/null 2>&1
[[ -e "$dst/b/.git" ]] || { echo "FAIL: explicit MARINA_SUBREPOS=b did not attach"; exit 1; }

echo "PASS test-auto-attach-default"
