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
# (heavy/gitignored 디렉토리·설정 symlink 은 marina.sh 의 선언형 links 로 이동 — 여기선 안 함)

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
best_len = -1
for p in projects:
    pr = norm(p)
    if root == pr or root.startswith(pr + os.sep):
        if len(pr) > best_len:
            match = p; best_len = len(pr)
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

# 새 worktree 자동 attach 집합 = 레지스트리 defaultAttach(명시) → subrepos(부재 시 전체) → 미등록이면 실패(3)
registry_default_for() {
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
best_len = -1
for p in projects:
    pr = norm(p)
    if root == pr or root.startswith(pr + os.sep):
        if len(pr) > best_len:
            match = p; best_len = len(pr)
if match is None and os.path.dirname(os.path.dirname(root)) == codex_wt:
    base = os.path.basename(root)
    for p in projects:
        if os.path.basename(norm(p)) == base:
            match = p; break
if match is None and len(projects) == 1:
    match = projects[0]
if match is None:
    sys.exit(3)
da = match.get("defaultAttach")
subs = da if isinstance(da, list) else match.get("subrepos", [])
print(" ".join(str(s) for s in subs))
PY
}

registry_source_root_for() {
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
best_len = -1
for p in projects:
    pr = norm(p)
    if root == pr or root.startswith(pr + os.sep):
        if len(pr) > best_len:
            match = p; best_len = len(pr)
if match is None and os.path.dirname(os.path.dirname(root)) == codex_wt:
    base = os.path.basename(root)
    for p in projects:
        if os.path.basename(norm(p)) == base:
            match = p; break
if match is None and len(projects) == 1:
    match = projects[0]
if match is None:
    sys.exit(3)
print(norm(match))
PY
}

resolve_subrepos() {
  local from_registry
  if [[ -n "${MARINA_SUBREPOS:-}" ]]; then
    read -r -a SUBREPOS <<< "$MARINA_SUBREPOS"
    return
  fi
  # 자동 attach(env 미지정) = defaultAttach 집합 (부재 시 전체 universe). 대시보드 단일 attach 는 위 env 경로.
  if from_registry="$(registry_default_for "$DEST_ROOT")"; then
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
  local candidate common_dir source_repo source_root from_registry
  if [[ -n "${SOURCE_ROOT:-}" ]]; then
    ( cd "$SOURCE_ROOT" 2>/dev/null && pwd -P ) || die "SOURCE_ROOT 디렉토리 없음: $SOURCE_ROOT"
    return
  fi
  if from_registry="$(registry_source_root_for "$DEST_ROOT")"; then
    printf '%s\n' "$from_registry"
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

promote_dest_root_if_subrepo() {
  local repo parent parent_real
  DEST_ROOT_PROMOTED_FROM=""
  for repo in ${SUBREPOS[@]+"${SUBREPOS[@]}"}; do
    [[ "$(basename "$DEST_ROOT")" == "$repo" ]] || continue
    parent="$(dirname "$DEST_ROOT")"
    [[ -d "$parent" ]] || continue
    parent_real="$(cd "$parent" 2>/dev/null && pwd -P)" || continue
    # If the hook was invoked from a nested subrepo worktree, attach sibling
    # subrepos to the containing project worktree instead of under that subrepo.
    [[ "$(basename "$parent_real")" == "$(basename "$SOURCE_ROOT")" ]] || continue
    DEST_ROOT_PROMOTED_FROM="$DEST_ROOT"
    DEST_ROOT="$parent_real"
    return 0
  done
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
SOURCE_ROOT="$(resolve_source_root)"
promote_dest_root_if_subrepo
load_local_env_file "$DEST_ROOT/.workspace/marina/local.env"
load_local_env_file "$DEST_ROOT/.workspace/dev-sessions/local.env"
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

attach_external() {
  # 외부(프로젝트 밖) git 레포를 워크트리의 .workspace/external/<name> 에 worktree+브랜치로 — per-worktree 격리.
  local name="$1" src="$2" branch="$3"
  local dst="$DEST_ROOT/.workspace/external/$name"
  { [[ -d "$src" ]] && git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; } || {
    echo "skip external (source git 아님): $name ($src)"; return 0; }
  git -C "$src" worktree prune 2>/dev/null || true   # 제거된 워크트리의 stale 항목 정리 → 재생성 가능
  if [[ ! -e "$dst" ]]; then
    mkdir -p "$DEST_ROOT/.workspace/external"
    echo "attach external: $name -> $dst"
    git -C "$src" worktree add --detach "$dst" HEAD
  else
    echo "skip external (exists): $name"
  fi
  git -C "$dst" rev-parse --is-inside-work-tree >/dev/null
  if [[ "$(git -C "$dst" branch --show-current)" == "$branch" ]]; then
    echo "skip branch (current): $name [$branch]"
  elif git -C "$dst" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$dst" switch "$branch"
  else
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
  # 워크트리에 명시 브랜치가 있으면 그 *전체 이름* 을 서브레포에 미러 → 워크트리를 feature/{task} 로 만들면
  # 서브레포도 feature/{task} (crabs 등 feature 브랜치 라이프사이클과 정합 — "워크트리 생성=작업 시작").
  # detached/빈 브랜치(codex 루트·테스트 plain dir)면 <prefix>/<id> 폴백. claude/<id> 워크트리는 미러==폴백이라 무회귀.
  local _wtbr; _wtbr="$(git -C "$DEST_ROOT" branch --show-current 2>/dev/null || true)"
  if [[ -n "$_wtbr" ]]; then
    branch="$_wtbr"
  else
    branch="$BRANCH_PREFIX/$id"
  fi

  echo "source: $SOURCE_ROOT"
  if [[ -n "${DEST_ROOT_PROMOTED_FROM:-}" ]]; then
    echo "promote dest: $DEST_ROOT_PROMOTED_FROM -> $DEST_ROOT"
  fi
  echo "dest:   $DEST_ROOT"
  echo "branch: $branch"

  # 외부 레포 attach — 워크트리마다 git worktree 로 끌어와 격리(멱등). 서브레포 커스터마이즈 skip 과 무관하게 항상.
  # 목록 = MARINA_EXTERNAL_REPOS env(name=source 줄, marina 가 레지스트리에서 주입). main(SOURCE==DEST)은 위에서 exit.
  local _extln _enm _esrc
  while IFS= read -r _extln; do
    [[ -n "$_extln" && "$_extln" == *=* ]] || continue
    _enm="${_extln%%=*}"; _esrc="${_extln#*=}"
    attach_external "$_enm" "$_esrc" "$branch"
  done <<< "${MARINA_EXTERNAL_REPOS:-}"

  # 자동 attach(MARINA_SUBREPOS 미지정 = defaultAttach 경로)는 "첫 실행(fresh worktree)"에만.
  # universe 중 하나라도 이미 attach 돼 있으면 사용자가 커스터마이즈한 상태로 보고 건드리지 않는다.
  if [[ -z "${MARINA_SUBREPOS:-}" ]]; then
    local universe_str
    universe_str="$(registry_subrepos_for "$DEST_ROOT" || true)"
    for repo in $universe_str; do
      if [[ -e "$DEST_ROOT/$repo/.git" ]]; then
        echo "skip auto-attach: worktree already initialized ($repo attached) — 수동 attach 는 대시보드"
        return 0
      fi
    done
  fi

  for repo in ${SUBREPOS[@]+"${SUBREPOS[@]}"}; do
    attach_subrepo "$repo" "$branch"
    # heavy/gitignored 디렉토리·설정(.venv·*local.yml·.env*.local·node_modules) symlink 은
    # 더 이상 여기서 숨어서 안 함 — marina.sh 의 선언형 links(apply_glob_links, 기본 룰 _DEFAULT_LINKS_JSON)가
    # start 때 적용(보임·override 가능). 'marina link' 로 수동 적용도 가능.
  done

  sync_idea_dir

  echo "done"
}

main "$@"
