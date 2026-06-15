#!/usr/bin/env bash
# marina SessionStart hook (Claude Code · Codex 공용): 등록된 프로젝트의 worktree 면 서브레포 attach.
# 플러그인 hooks/hooks.json 에서 호출된다 (또는 직접). 위치독립 — 형제 attach 스크립트를 부른다.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MARINA_HOME="${MARINA_HOME:-$HOME/.marina}"
PROJECTS_FILE="$MARINA_HOME/projects.json"

DIR="${CODEX_WORKSPACE_DIR:-$PWD}"
# worktree 루트 = git toplevel (마커 무관 — 위치독립. 구 AGENTS.md+shared/ walk-up 제거)
ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -n "$ROOT" ]] || exit 0

# 등록된 marina 프로젝트의 worktree 가 아니면 무해 종료 (비-marina repo 에 .workspace 안 만듦)
is_registered() {
  command -v python3 >/dev/null 2>&1 || return 1
  [[ -f "$PROJECTS_FILE" ]] || return 1
  python3 - "$PROJECTS_FILE" "$ROOT" <<'PY'
import json, os, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
root = os.path.realpath(os.path.expanduser(sys.argv[2]))
codex_wt = os.path.realpath(os.path.expanduser(os.environ.get("CODEX_WORKTREES_ROOT") or "~/.codex/worktrees"))
in_codex = os.path.dirname(os.path.dirname(root)) == codex_wt  # <worktrees>/<id>/<basename>
for p in data.get("projects", []):
    pr = os.path.realpath(os.path.expanduser(p.get("root", "")))
    if not pr:
        continue
    # 프로젝트 root 자신/하위(claude) 또는 codex 레이아웃 한정 basename 일치 (project_for 와 정합)
    if root == pr or root.startswith(pr + os.sep):
        sys.exit(0)
    if in_codex and os.path.basename(root) == os.path.basename(pr):
        sys.exit(0)
sys.exit(1)
PY
}
is_registered || exit 0

LOG_DIR="$ROOT/.workspace/marina/hooks"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/session-start.log"
{
  echo
  echo "=== SessionStart $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "root=$ROOT"
} >> "$LOG_FILE"

# attach 는 레지스트리에서 subrepos·source 를 스스로 해석 (DEST_ROOT 만 넘김)
if [[ -x "$SCRIPT_DIR/attach-detached-subrepos.sh" ]]; then
  DEST_ROOT="$ROOT" SYNC_IDEA=false "$SCRIPT_DIR/attach-detached-subrepos.sh" >> "$LOG_FILE" 2>&1 || true
fi
