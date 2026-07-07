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
        print(p.get("id", ""))
        sys.exit(0)
    if in_codex and os.path.basename(root) == os.path.basename(pr):
        print(p.get("id", ""))
        sys.exit(0)
sys.exit(1)
PY
}
# 매칭 시 project id 를 stdout 으로 받는다 (없으면 비-marina → 종료). service ls <id> 에 사용.
PROJECT_ID="$(is_registered)" || exit 0

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

# --- 편집 위치 감지 (worktree 세션 한정) ---
# 서브레포는 worktree 마다 attach 돼 있을 수도/없을 수도 있다($ROOT/<sub>/.git 존재로 판정 —
# attach-detached-subrepos.sh 와 동일 기준). 실제 붙은 미러만 "여기서 편집" 으로 안내한다.
# marina 는 이 미러(브랜치)를 실행하므로, 프로젝트 루트의 같은 이름 서브레포(= 다른 브랜치)를
# 편집하면 실행/배포가 어긋난다. main 체크아웃 세션($ROOT==프로젝트 루트)은 혼동이 없어 생략.
edit_rules=""
if command -v python3 >/dev/null 2>&1 && [[ -f "$PROJECTS_FILE" ]]; then
  _proj_line="$(python3 - "$PROJECTS_FILE" "$ROOT" <<'PY'
import json, os, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
root = os.path.realpath(os.path.expanduser(sys.argv[2]))
best = None; best_len = -1
for p in data.get("projects", []):
    pr = os.path.realpath(os.path.expanduser(p.get("root", "")))
    if pr and (root == pr or root.startswith(pr + os.sep)) and len(pr) > best_len:
        best = p; best_len = len(pr)
if best:
    pr = os.path.realpath(os.path.expanduser(best.get("root", "")))
    print(pr + "\t" + ",".join(str(s) for s in best.get("subrepos", [])))
PY
)"
  if [[ "$_proj_line" == *$'\t'* ]]; then
    proj_root="${_proj_line%%$'\t'*}"
    proj_subs="${_proj_line#*$'\t'}"
    if [[ -n "$proj_root" && "$ROOT" != "$proj_root" ]]; then
      attached=""
      IFS=',' read -r -a _subs <<< "$proj_subs"
      for sub in "${_subs[@]}"; do
        [[ -n "$sub" && -e "$ROOT/$sub/.git" ]] && attached="${attached}· $ROOT/$sub"$'\n'
      done
      if [[ -n "$attached" ]]; then
        edit_rules="[marina] 코드 편집 위치 — 이 worktree 에 attach 된 서브레포(marina 가 실행하는 브랜치)에서만 편집:
${attached}프로젝트 루트($proj_root)의 같은 이름 서브레포는 다른 브랜치라 marina 가 실행/배포하지 않습니다 — 절대경로로 거기를 편집하지 마세요. 위 목록에 없는 서브레포는 이 worktree 에 attach 되지 않았습니다."
      fi
    fi
  fi
fi

# --- 규칙 주입 (pull 모델): LLM 이 marina 로 서버를 다루게 한다. stdout=순수 JSON 한 줄. ---
# attach 출력은 위에서 모두 파일로 갔으므로 여기서부터의 stdout 만 호출자(하네스)가 본다.

# 명령 호출자 resolve: PATH 의 marina 셰임 우선, 없으면 entrypoint 절대경로.
caller="marina"; command -v marina >/dev/null 2>&1 || caller="$SCRIPT_DIR/marina-entrypoint.sh"

read -r -d '' rules <<EOF || true
[marina] 이 worktree 는 marina 가 관리합니다. dev 서버는 직접(npm/gradlew 등) 띄우지 말고 $caller 로 — worktree 별 포트가 자동 격리됩니다.
· 기동:   $caller start <서비스>     (전체는 --all)
· 정지:   $caller stop <서비스>      (전체는 --all)
· 재시작: $caller restart <서비스>   (전체는 --all)
· 상태·포트: $caller status      · 로그: $caller logs <서비스>
문제 해결:
· 포트 충돌은 자동으로 빈 포트로 이동 — 실제 포트는 $caller status 로 확인
· compose 정의(서비스·env·마운트) 변경: 대시보드 ✎ compose 편집·위저드 또는 $caller project add <path> --compose
EOF

# 편집 위치 규칙(worktree 세션에서 attach 된 미러가 있을 때만)을 서버 규칙 뒤에 덧붙인다.
[[ -n "$edit_rules" ]] && rules="$rules"$'\n'"$edit_rules"

# JSON escape (bash 파라미터 치환 — superpowers session-start 훅 방식).
escape_for_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
esc="$(escape_for_json "$rules")"

# 플랫폼 분기: Claude=hookSpecificOutput.additionalContext / 기타 SDK(Codex 등)=top-level additionalContext.
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -z "${COPILOT_CLI:-}" ]]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
else
  printf '{"additionalContext":"%s"}\n' "$esc"
fi
