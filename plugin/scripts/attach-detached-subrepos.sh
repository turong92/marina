#!/usr/bin/env bash
# attach-detached-subrepos.sh — Codex/Claude worktree 안에 독립 서브레포(중첩 레포)를 붙이고 IDE 설정을 동기화한다.
# 서브레포 목록은 MARINA_SUBREPOS env 또는 레지스트리(~/.marina/projects.json)에서 온다.
#
# 환경 변수:
#   SOURCE_ROOT=/path/to/project        # 원본 체크아웃
#   DEST_ROOT=/path/to/worktree         # attach 대상 worktree
#   MARINA_SUBREPOS="repo-a repo-b"     # 붙일 서브레포 (없으면 레지스트리)
#   BRANCH_PREFIX=codex
#   SYNC_IDEA=true
#   SYNC_LOCAL_YML=true
#   SYNC_LOCAL_ENV=true
#   SYNC_VENV=true

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MARINA_HOME="${MARINA_HOME:-$HOME/.marina}"
PROJECTS_FILE="$MARINA_HOME/projects.json"

die() {
  echo "error: $*" >&2
  exit 1
}

# subrepos = MARINA_SUBREPOS env(대시보드/훅 주입) → 레지스트리(DEST_ROOT 의 프로젝트) → 없음(미등록)
registry_subrepos_for() {
  command -v python3 >/dev/null 2>&1 || return 3
  [[ -f "$PROJECTS_FILE" ]] || return 3
  python3 - "$PROJECTS_FILE" "$1" <<'PY'
import json, os, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(3)
root = os.path.realpath(os.path.expanduser(sys.argv[2]))
codex_wt = os.path.realpath(os.path.expanduser(os.environ.get("CODEX_WORKTREES_ROOT") or "~/.codex/worktrees"))
projects = data.get("projects", [])
norm = lambda p: os.path.realpath(os.path.expanduser(p.get("root", "")))
match = None
for p in projects:
    pr = norm(p)
    if root == pr or root.startswith(pr + os.sep):
        match = p; break
# basename 패스는 codex 레이아웃(<worktrees>/<id>/<basename>) 한정 — 동일 basename 다중 프로젝트 오매핑 방지
if match is None and os.path.dirname(os.path.dirname(root)) == codex_wt:
    base = os.path.basename(root)
    for p in projects:
        if os.path.basename(norm(p)) == base:
            match = p; break
if match is None and len(projects) == 1:
    match = projects[0]
if match is None:
    sys.exit(3)
print(" ".join(str(s) for s in match.get("subrepos", [])))
PY
}

resolve_subrepos() {
  local from_registry
  if [[ -n "${MARINA_SUBREPOS:-}" ]]; then
    read -r -a SUBREPOS <<< "$MARINA_SUBREPOS"
    return
  fi
  if from_registry="$(registry_subrepos_for "$DEST_ROOT")"; then
    read -r -a SUBREPOS <<< "$from_registry"
    return
  fi
  SUBREPOS=()
}

# DEST_ROOT = attach 대상 worktree. env 우선, 없으면 cwd git 최상위. (구 AGENTS.md+shared/ 탐색 제거)
resolve_dest_root() {
  if [[ -n "${DEST_ROOT:-}" ]]; then
    ( cd "$DEST_ROOT" 2>/dev/null && pwd -P ) || die "DEST_ROOT 디렉토리 없음: $DEST_ROOT"
    return
  fi
  ( cd "$(pwd)" && git rev-parse --show-toplevel 2>/dev/null ) || pwd -P
}

# SOURCE_ROOT = 원본(main) 체크아웃. env 우선, 없으면 서브레포 git 토폴로지, 없으면 DEST_ROOT.
resolve_source_root() {
  local candidate common_dir source_repo source_root
  if [[ -n "${SOURCE_ROOT:-}" ]]; then
    ( cd "$SOURCE_ROOT" 2>/dev/null && pwd -P ) || die "SOURCE_ROOT 디렉토리 없음: $SOURCE_ROOT"
    return
  fi
  for candidate in "${SUBREPOS[@]}"; do
    if [[ -d "$DEST_ROOT/$candidate" ]] && git -C "$DEST_ROOT/$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      common_dir="$(git -C "$DEST_ROOT/$candidate" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
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
  printf '%s\n' "$DEST_ROOT"
}

load_local_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  set -a
  # shellcheck source=/dev/null
  source "$file"
  set +a
}

DEST_ROOT="$(resolve_dest_root)"
resolve_subrepos
load_local_env_file "$DEST_ROOT/.workspace/marina/local.env"
load_local_env_file "$DEST_ROOT/.workspace/dev-sessions/local.env"
SOURCE_ROOT="$(resolve_source_root)"
if [[ "$SOURCE_ROOT" != "$DEST_ROOT" ]]; then
  load_local_env_file "$SOURCE_ROOT/.workspace/marina/local.env"
  load_local_env_file "$SOURCE_ROOT/.workspace/dev-sessions/local.env"
fi
# 서브레포 브랜치 프리픽스 — DEST_ROOT 의 worktree 브랜치가 claude/* 면 claude, 아니면 codex (env 명시가 우선)
if [[ -z "${BRANCH_PREFIX:-}" ]]; then
  _dest_branch="$(git -C "$DEST_ROOT" branch --show-current 2>/dev/null || true)"
  # codex worktree 루트는 보통 detached HEAD(빈 문자열) → codex 폴백이 정상 경로
  case "$_dest_branch" in
    claude/*) BRANCH_PREFIX="claude" ;;
    *) BRANCH_PREFIX="codex" ;;
  esac
fi
SYNC_IDEA="${SYNC_IDEA:-true}"
SYNC_LOCAL_YML="${SYNC_LOCAL_YML:-true}"
SYNC_LOCAL_ENV="${SYNC_LOCAL_ENV:-true}"
SYNC_VENV="${SYNC_VENV:-true}"
# SUBREPOS 는 위에서 resolve_subrepos 로 채움 (MARINA_SUBREPOS env → 레지스트리 → 기본값)

worktree_id() {
  # codex 레이아웃은 <id>/<projectBasename> → 부모명, claude 레이아웃은 .claude/worktrees/<name> → 자신명.
  # (marina.sh session_id() 와 동일 규칙 — codex worktree basename 은 원본(SOURCE_ROOT) basename 과 같다)
  local base
  base="$(basename "$DEST_ROOT")"
  if [[ "$base" == "$(basename "$SOURCE_ROOT")" ]]; then
    base="$(basename "$(dirname "$DEST_ROOT")")"
  fi
  if [[ -z "$base" || "$base" == "." || "$base" == "/" ]]; then
    die "worktree id 추론 실패: DEST_ROOT=$DEST_ROOT"
  fi
  printf '%s\n' "$base"
}

attach_subrepo() {
  local repo="$1" branch="$2" src="$SOURCE_ROOT/$repo" dst="$DEST_ROOT/$repo"

  if [[ -d "$src" && -d "$dst" && "$(cd "$src" && pwd -P)" == "$(cd "$dst" && pwd -P)" ]]; then
    echo "skip attach (source is dest): $repo"
    return 0
  fi

  if [[ ! -e "$dst" ]]; then
    # source 서브레포가 없으면 skip(no-op) — 비-marina repo·미클론 서브레포에서 안전 (구: die)
    [[ -d "$src" ]] || { echo "skip attach (source 없음): $repo"; return 0; }
    git -C "$src" rev-parse --is-inside-work-tree >/dev/null
  fi

  if [[ ! -e "$dst" ]]; then
    echo "attach: $repo -> $dst"
    git -C "$src" worktree add --detach "$dst" HEAD
  else
    echo "skip attach (exists): $repo"
  fi

  git -C "$dst" rev-parse --is-inside-work-tree >/dev/null

  if [[ "$(git -C "$dst" branch --show-current)" == "$branch" ]]; then
    echo "skip branch (current): $repo [$branch]"
  elif git -C "$dst" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "switch: $repo [$branch]"
    git -C "$dst" switch "$branch"
  else
    echo "create branch: $repo [$branch]"
    git -C "$dst" switch -c "$branch"
  fi
}

sync_idea_dir() {
  local src="$SOURCE_ROOT/.idea" dst="$DEST_ROOT/.idea"
  [[ "$SYNC_IDEA" == "true" ]] || return 0
  [[ -d "$src" ]] || { echo "skip idea sync (source 없음): $src"; return 0; }

  mkdir -p "$dst"
  echo "sync: .idea"
  rsync -a \
    --exclude 'shelf/' \
    --exclude 'httpRequests/' \
    "$src/" "$dst/"

  # 원본 IDE workspace.xml 에 남아있는 absolute tool path 를 새 worktree 로 돌린다.
  while IFS= read -r -d '' file; do
    SRC_ROOT="$SOURCE_ROOT" DEST_ROOT="$DEST_ROOT" perl -0pi -e 's/\Q$ENV{SRC_ROOT}\E/$ENV{DEST_ROOT}/g' "$file"
  done < <(find "$dst" -type f \( -name '*.xml' -o -name '*.iml' \) -print0)
}

sync_local_yml_files() {
  local repo="$1" src_repo="$SOURCE_ROOT/$repo" dst_repo="$DEST_ROOT/$repo"
  local src rel dst
  [[ "$SYNC_LOCAL_YML" == "true" ]] || return 0
  [[ -d "$src_repo" && -d "$dst_repo" ]] || return 0
  [[ "$(cd "$src_repo" && pwd -P)" != "$(cd "$dst_repo" && pwd -P)" ]] || return 0

  while IFS= read -r -d '' src; do
    rel="${src#"$src_repo"/}"
    dst="$dst_repo/$rel"
    mkdir -p "$(dirname "$dst")"

    if [[ -L "$dst" ]]; then
      ln -sfn "$src" "$dst"
      echo "link local yml: $repo/$rel"
    elif [[ -e "$dst" ]]; then
      if cmp -s "$src" "$dst"; then
        rm -f "$dst"
        ln -s "$src" "$dst"
        echo "replace copy with link: $repo/$rel"
      else
        echo "warn local yml exists and differs, skip: $repo/$rel"
      fi
    else
      ln -s "$src" "$dst"
      echo "link local yml: $repo/$rel"
    fi
  done < <(find "$src_repo" \( -name node_modules -o -name .git -o -name .venv -o -name .next -o -name build \) -prune -o -path '*/src/main/resources/*local.yml' -type f -print0)
}

sync_local_env_files() {
  local repo="$1" src_repo="$SOURCE_ROOT/$repo" dst_repo="$DEST_ROOT/$repo"
  local src rel dst
  [[ "$SYNC_LOCAL_ENV" == "true" ]] || return 0
  [[ -d "$src_repo" && -d "$dst_repo" ]] || return 0
  [[ "$(cd "$src_repo" && pwd -P)" != "$(cd "$dst_repo" && pwd -P)" ]] || return 0

  while IFS= read -r -d '' src; do
    rel="${src#"$src_repo"/}"
    dst="$dst_repo/$rel"
    mkdir -p "$(dirname "$dst")"

    if [[ -L "$dst" ]]; then
      ln -sfn "$src" "$dst"
      echo "link local env: $repo/$rel"
    elif [[ -e "$dst" ]]; then
      if cmp -s "$src" "$dst"; then
        rm -f "$dst"
        ln -s "$src" "$dst"
        echo "replace copy with link: $repo/$rel"
      else
        echo "warn local env exists and differs, skip: $repo/$rel"
      fi
    else
      ln -s "$src" "$dst"
      echo "link local env: $repo/$rel"
    fi
  done < <(find "$src_repo" \( -name node_modules -o -name .git -o -name .venv -o -name .next -o -name build \) -prune -o -name '.env*.local' -type f -print0)
}

sync_venv_dir() {
  # 서브레포에 .venv 가 있으면 worktree 로 심볼릭링크 (python 서브레포 공통). MARINA_VENV_PATH 로 경로 지정 가능.
  local repo="$1" src="${MARINA_VENV_PATH:-$SOURCE_ROOT/$repo/.venv}" dst="$DEST_ROOT/$repo/.venv"
  [[ "$SYNC_VENV" == "true" ]] || return 0
  [[ -d "$src" && -d "$DEST_ROOT/$repo" ]] || return 0
  [[ "$(cd "$SOURCE_ROOT/$repo" && pwd -P)" != "$(cd "$DEST_ROOT/$repo" && pwd -P)" ]] || return 0

  if [[ -L "$dst" ]]; then
    ln -sfn "$src" "$dst"
    echo "link venv: $repo/.venv"
  elif [[ -e "$dst" ]]; then
    echo "warn venv exists, skip: $repo/.venv"
  else
    ln -s "$src" "$dst"
    echo "link venv: $repo/.venv"
  fi
}

main() {
  local id branch repo
  [[ -d "$SOURCE_ROOT" ]] || die "SOURCE_ROOT 없음: $SOURCE_ROOT"
  [[ -d "$DEST_ROOT" ]] || die "DEST_ROOT 없음: $DEST_ROOT"

  # SOURCE==DEST → 원본(main) 체크아웃 또는 단일레포: attach 할 서브레포 없음.
  # (main 에서 돌면 실제 서브레포 클론을 codex/<부모명> 브랜치로 잘못 스위치할 위험 → 차단)
  if [[ "$SOURCE_ROOT" == "$DEST_ROOT" ]]; then
    echo "skip: source==dest ($SOURCE_ROOT) — main 체크아웃/단일레포라 attach 대상 없음"
    exit 0
  fi

  id="$(worktree_id)"
  branch="$BRANCH_PREFIX/$id"

  echo "source: $SOURCE_ROOT"
  echo "dest:   $DEST_ROOT"
  echo "branch: $branch"

  for repo in ${SUBREPOS[@]+"${SUBREPOS[@]}"}; do
    attach_subrepo "$repo" "$branch"
    sync_local_yml_files "$repo"
    sync_local_env_files "$repo"
    sync_venv_dir "$repo"
  done

  sync_idea_dir

  echo "done"
}

main "$@"
