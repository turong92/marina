#!/usr/bin/env bash
# marina-lib-context.sh — marina.sh 에서 분리된 context 함수군 (source 전용, 함수 정의만).
# 동작 변경 0 — marina.sh 에서 이동만. 전역(ROOT/SOURCE_ROOT/MARINA_HOME/SERVICES 등)은 marina.sh 가 설정.

# ---- 서비스 기동 PATH 정상화 -------------------------------------------------
# marina 가 띄우는 서비스는 런처(데몬 launchd / CLI / 하네스)의 PATH 를 상속한다.
# 데몬(launchd)은 빈약한 PATH(시스템 dir 뿐)라 `bash -lc` 로도 homebrew·node 등이
# 안 잡힌다 — login bash 는 사용자의 zsh `~/.zshrc` PATH 를 읽지 않기 때문(zsh PATH
# 가 거기 있어도). 그래서 search 의 npx(hyperframes)·ffprobe(TTS) 가 FileNotFoundError
# 로 터지고, 그동안 서비스 run 에 머신 고유 PATH 핀으로 우회해 왔다(whack-a-mole).
#
# 근본 해결: 사용자의 로그인+인터랙티브 셸을 한 번 띄워 실제 PATH 를 결정적으로 얻는다.
# 인터랙티브 셸은 rc(zprofile·zshrc / bash_profile·bashrc)를 source 해 PATH 를 *빌드*
# 하므로, 호출 컨텍스트(데몬이든 세션이든)의 빈약한 PATH 와 무관하게 항상 같은 결과다.
marina_login_shell() {
  local s="${SHELL:-}"
  if [[ -n "$s" && -x "$s" ]]; then printf '%s' "$s"; return; fi
  s="$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk -F': ' '{print $2}')"   # macOS
  if [[ -n "$s" && -x "$s" ]]; then printf '%s' "$s"; return; fi
  s="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"                          # Linux
  if [[ -n "$s" && -x "$s" ]]; then printf '%s' "$s"; return; fi
  printf '/bin/zsh'
}

# ---- 워크스페이스 컨텍스트 (런처 명령용) — 위치독립 -------------------------
# ROOT = 대시보드가 주입한 worktree, 또는 직접 CLI 시 현재 git 최상위. (구 AGENTS.md+shared/ 탐색 제거)
resolve_root() {
  if [[ -n "${ROOT:-}" ]]; then
    ( cd "$ROOT" 2>/dev/null && pwd -P ) || die "ROOT 디렉토리 없음: $ROOT"
    return
  fi
  ( cd "$(pwd)" && git rev-parse --show-toplevel 2>/dev/null ) || pwd -P
}

resolve_subrepos() {
  local from_registry
  if [[ -n "${MARINA_SUBREPOS:-}" ]]; then
    read -r -a SUBREPOS <<< "$MARINA_SUBREPOS"
    return
  fi
  if from_registry="$(registry_subrepos_for "$ROOT")"; then
    read -r -a SUBREPOS <<< "$from_registry"
    return
  fi
  SUBREPOS=()
}

# SOURCE_ROOT = 이 worktree 의 원본(main) 체크아웃. env 주입 우선, 없으면 서브레포 git 토폴로지.
resolve_source_root() {
  local candidate common_dir source_repo source_root
  if [[ -n "${SOURCE_ROOT:-}" ]]; then
    ( cd "$SOURCE_ROOT" 2>/dev/null && pwd -P ) || die "SOURCE_ROOT 디렉토리 없음: $SOURCE_ROOT"
    return
  fi
  for candidate in ${SUBREPOS[@]+"${SUBREPOS[@]}"}; do
    if [[ -d "$ROOT/$candidate" ]] && git -C "$ROOT/$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      common_dir="$(git -C "$ROOT/$candidate" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
      if [[ -n "$common_dir" ]]; then
        source_repo="$(dirname "$common_dir")"
        source_root="$(dirname "$source_repo")"
        if [[ -d "$source_root/$candidate" ]]; then
          printf '%s\n' "$source_root"
          return 0
        fi
      fi
    fi
  done
  # 서브레포로 못 찾으면(단일 레포·main 체크아웃) ROOT 자신
  printf '%s\n' "$ROOT"
}

# 브랜치명 지정 워크트리 생성(= 작업 시작). git worktree add + 서브레포 attach(브랜치 전체 미러).
# Claude 자동 워크트리는 claude/<id> 로 명명되므로, feature/{task} 등 원하는 브랜치로 만들 때 사용.
# 기존 브랜치면 체크아웃, 없으면 새로 생성([base] 지정 시 그 위에서). 서브레포도 같은 브랜치로 즉시 정렬.
worktree_create() {
  local branch="" base="" proj_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) proj_id="${2:-}"; shift 2 || true ;;
      *) if [[ -z "$branch" ]]; then branch="$1"; elif [[ -z "$base" ]]; then base="$1"; fi; shift ;;
    esac
  done
  [[ -n "$branch" ]] || die "usage: marina worktree create <branch> [base] [--project <id>]"
  local src san wt
  if [[ -n "$proj_id" ]]; then
    # --project: cwd 무관하게 레지스트리에서 그 프로젝트 root 조회 (shim 으로 아무데서나)
    src="$(python3 -c "import json,os; d=json.load(open(os.path.expanduser('$MARINA_HOME/projects.json'))); print(next((os.path.realpath(os.path.expanduser(p.get('root',''))) for p in d.get('projects',[]) if p.get('id')=='$proj_id'),''))" 2>/dev/null || true)"
    [[ -n "$src" ]] || die "프로젝트 미등록: $proj_id ('marina project ls' 로 확인)"
  else
    src="${SOURCE_ROOT:-$ROOT}"   # 기본: cwd 로 해석된 프로젝트(다른 marina 명령과 동일)
  fi
  git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git 레포가 아님: $src"
  san="$(printf '%s' "$branch" | tr '/:' '--')"
  wt="$src/.claude/worktrees/$san"
  [[ -e "$wt" ]] && die "이미 존재: $wt — 그 디렉토리에서 세션을 열거나 다른 브랜치명을 쓰세요"
  mkdir -p "$src/.claude/worktrees"
  if git -C "$src" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "기존 브랜치 체크아웃: $branch"
    git -C "$src" worktree add "$wt" "$branch" || die "worktree add 실패"
  else
    echo "새 브랜치 생성: $branch${base:+ (base=$base)}"
    git -C "$src" worktree add -b "$branch" "$wt" ${base:+"$base"} || die "worktree add 실패"
  fi
  # 서브레포 attach — 워크트리 브랜치명을 전체 미러(정합). start 안 기다리고 즉시.
  if [[ -n "${ATTACH_SCRIPT:-}" && -f "${ATTACH_SCRIPT:-}" ]]; then
    DEST_ROOT="$wt" SOURCE_ROOT="$src" SYNC_IDEA=false bash "$ATTACH_SCRIPT" 2>&1 | sed 's/^/  /' || true
  fi
  echo
  echo "✓ 워크트리: $wt"
  echo "  브랜치:   $branch (서브레포도 동일 미러)"
  echo "  열기:     cd '$wt' && claude"
}

load_local_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  set -a
  # shellcheck source=/dev/null
  source "$file"
  set +a
}

# marina 우선, 구 dev-sessions 폴백 — 기존 worktree 의 세션 데이터(alias·overrides·로그) 보존.
# 1회 mv 마이그레이션은 최상위 진입점(루트 marina.sh)에서만 수행한다.
session_data_dir() {
  local base="$1"
  if [[ -d "$base/.workspace/marina" || ! -d "$base/.workspace/dev-sessions" ]]; then
    printf '%s\n' "$base/.workspace/marina"
  else
    printf '%s\n' "$base/.workspace/dev-sessions"
  fi
}
