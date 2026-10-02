#!/usr/bin/env bash
# Claude Code WorktreeCreate/WorktreeRemove 훅 래퍼(분리 A). create: stdout = 워크트리 경로 한 줄. remove: ≠0 이면 워크트리가 남는다.
# 플러그인 훅이라 모든 레포에 걸린다 — 판단·폴백은 marina_worktree_hooks.py 가 한다.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$SCRIPT_DIR/marina_worktree_hooks.py" "$@"
