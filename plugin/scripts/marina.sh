#!/usr/bin/env bash
# marina.sh — worktree 세션별 포트/로그/프로세스 런처 + 프로젝트/서비스 CLI.
#
# 런처 (대시보드가 ROOT 를 주입해 호출, 또는 worktree 안에서 직접):
#   marina.sh start <svc..>|--all | stop <svc..>|--all | restart <svc..>|--all | status | logs [svc] | ports
# 프로젝트/서비스 CLI (위치 무관 — ~/.marina/projects.json·marina-services.json 편집):
#   marina.sh project add <path> | project infer <path> | project rm <id> | project ls | project default <id> <a,b,c>
#   marina.sh service add <id> '<json>' [--root] | service rm <id> <name> [--root] | service ls <id>

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MARINA_HOME="${MARINA_HOME:-$HOME/.marina}"
PROJECTS_FILE="$MARINA_HOME/projects.json"

die() {
  echo "error: $*" >&2
  exit 1
}

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

_MARINA_LOGIN_PATH=""
marina_login_path() {
  # 1) 명시 override (escape hatch / 테스트). 2) 프로세스 1회 메모(start --all 루프에서
  # 셸 반복 기동 방지). 3) 로그인+인터랙티브 셸로 캡처. 4) 실패 시 현재 PATH 폴백(기존 동작).
  if [[ -n "${MARINA_PATH:-}" ]]; then printf '%s' "$MARINA_PATH"; return; fi
  if [[ -n "$_MARINA_LOGIN_PATH" ]]; then printf '%s' "$_MARINA_LOGIN_PATH"; return; fi
  local sh captured
  sh="$(marina_login_shell)"
  # -i 라야 ~/.zshrc(또는 ~/.bashrc) 의 PATH 도 반영된다. </dev/null 로 tty 대기 방지·stderr 무시.
  # perl alarm 으로 8s 타임아웃 — 느리거나 부작용 있는 rc 가 데몬의 marina start 를 막지 않게. perl 없으면 그대로.
  if command -v perl >/dev/null 2>&1; then
    captured="$(perl -e 'alarm shift @ARGV; exec @ARGV' 8 "$sh" -ilc 'printf %s "$PATH"' </dev/null 2>/dev/null)" || captured=""
  else
    captured="$("$sh" -ilc 'printf %s "$PATH"' </dev/null 2>/dev/null)" || captured=""
  fi
  [[ -n "$captured" ]] || captured="$PATH"
  _MARINA_LOGIN_PATH="$captured"
  printf '%s' "$captured"
}

# ---- 프로젝트 레지스트리 CLI (~/.marina/projects.json) — 위치 무관 ----------
# 추론은 여기(registry_infer)가 단일 SoT — JSON 으로 출력만 하고 쓰지 않는다.
# registry_add 는 이걸 소비해서 ~/.marina/projects.json 에 upsert 하고, 대시보드 API(phase 3)도 이걸 shell.
registry_infer() {
  local path="${1:-}"
  [[ -n "$path" ]] || die "usage: marina project infer <project-path>"
  [[ -d "$path" ]] || die "디렉토리 없음: $path"
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  local abs; abs="$(cd "$path" && pwd -P)" || die "경로 해석 실패: $path"
  python3 - "$abs" <<'PY'
import json, os, sys
root = sys.argv[1]
# 서브레포 추론 — .git 디렉토리(=독립 클론)를 가진 1단계 하위 디렉토리.
# (.git 파일은 worktree 링크 → main 체크아웃의 서브레포가 아니므로 제외)
subrepos = sorted(
    n for n in os.listdir(root)
    if not n.startswith(".")
    and os.path.isdir(os.path.join(root, n))
    and os.path.isdir(os.path.join(root, n, ".git"))
)
# worktreeGlobs 추론 — claude 는 항상, codex 는 ~/.codex 존재 시
globs = [".claude/worktrees/*"]
base = os.path.basename(root)
if os.path.isdir(os.path.expanduser("~/.codex/worktrees")):
    globs.append(f"~/.codex/worktrees/*/{base}")
print(json.dumps({"id": base, "root": root, "subrepos": subrepos, "worktreeGlobs": globs}, ensure_ascii=False))
PY
}

registry_add() {
  local path="" subrepos_csv="" have_subrepos=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subrepos)
        have_subrepos=1
        if [[ $# -ge 2 ]]; then subrepos_csv="$2"; shift 2; else subrepos_csv=""; shift; fi
        ;;
      --subrepos=*)
        have_subrepos=1; subrepos_csv="${1#--subrepos=}"; shift ;;
      *)
        [[ -z "$path" ]] || die "add: 인자 과다 ('$1')"
        path="$1"; shift ;;
    esac
  done
  local entry; entry="$(registry_infer "$path")" || exit $?
  mkdir -p "$MARINA_HOME"
  python3 - "$PROJECTS_FILE" "$entry" "$have_subrepos" "$subrepos_csv" <<'PY'
import json, os, sys
projects_file, entry = sys.argv[1], json.loads(sys.argv[2])
have_subrepos, subrepos_csv = sys.argv[3] == "1", sys.argv[4]
# 플래그 존재 시 추론 대신 명시 집합(빈 값이면 []=모노레포). 부재 시 추론 그대로.
if have_subrepos:
    entry["subrepos"] = [s for s in (x.strip() for x in subrepos_csv.split(",")) if s]
try:
    data = json.load(open(projects_file, encoding="utf-8"))
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}
norm = lambda p: os.path.realpath(os.path.expanduser(p))
projects = [p for p in data.get("projects", []) if norm(p.get("root","")) != norm(entry["root"])]
projects.append(entry)
data["projects"] = projects
data.setdefault("schemaVersion", 1)
json.dump(data, open(projects_file, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"added: {entry['id']}  root={entry['root']}")
print(f"  subrepos: {', '.join(entry['subrepos']) or '(none)'}")
print(f"  worktreeGlobs: {', '.join(entry['worktreeGlobs'])}")
PY
}

registry_rm() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: marina project rm <id>"
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  [[ -f "$PROJECTS_FILE" ]] || die "레지스트리 없음: $PROJECTS_FILE"
  python3 - "$PROJECTS_FILE" "$id" <<'PY'
import json, sys
projects_file, target = sys.argv[1], sys.argv[2]
data = json.load(open(projects_file, encoding="utf-8"))
projects = data.get("projects", [])
kept = [p for p in projects if p.get("id") != target]
if len(kept) == len(projects):
    print(f"not found: {target}", file=sys.stderr)
    sys.exit(1)
data["projects"] = kept
with open(projects_file, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
print(f"removed: {target}")
PY
}

registry_default() {
  local id="${1:-}" csv="${2-}"
  [[ -n "$id" ]] || die "usage: marina project default <id> <a,b,c>  (빈 값=전부 비움)"
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  [[ -f "$PROJECTS_FILE" ]] || die "레지스트리 없음: $PROJECTS_FILE"
  python3 - "$PROJECTS_FILE" "$id" "$csv" <<'PY'
import json, sys
projects_file, target, csv = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(projects_file, encoding="utf-8"))
projects = data.get("projects", [])
match = next((p for p in projects if p.get("id") == target), None)
if match is None:
    print(f"not found: {target}", file=sys.stderr); sys.exit(1)
universe = [str(s) for s in match.get("subrepos", [])]
want = [s for s in (x.strip() for x in csv.split(",")) if s]
bad = [s for s in want if s not in universe]
if bad:
    print(f"not in subrepos ({', '.join(universe) or 'none'}): {', '.join(bad)}", file=sys.stderr)
    sys.exit(1)
match["defaultAttach"] = want
with open(projects_file, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
print(f"defaultAttach[{target}]: {', '.join(want) or '(none — 새 worktree 자동 attach 없음)'}")
PY
}

# id → 레지스트리 root 경로 (없으면 die). id→root 해석의 canonical resolver — service ls·service_target_file 가 공유.
registry_root_for() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "registry_root_for: id 필요"
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  local root; root="$(python3 - "$PROJECTS_FILE" "$id" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: sys.exit(1)
m=next((p for p in d.get("projects",[]) if p.get("id")==sys.argv[2]),None)
print(m["root"] if m else "", end="")
PY
)"; [[ -n "$root" ]] || die "unknown id: $id"; printf '%s\n' "$root"
}

service_target_file() {  # <id> [--root] → 쓸 파일 경로
  local id="$1" use_root="${2:-}"
  if [[ "$use_root" == "--root" ]]; then
    local root; root="$(registry_root_for "$id")" || exit $?
    printf '%s\n' "$root/marina-services.json"
  else printf '%s\n' "$MARINA_HOME/services/$id.json"; fi
}
service_add() {
  local id="${1:-}" svc_json="${2:-}" root_flag="${3:-}"
  [[ -n "$id" && -n "$svc_json" ]] || die "usage: marina service add <id> '<json>' [--root]"
  local file; file="$(service_target_file "$id" "$root_flag")" || exit $?
  mkdir -p "$(dirname "$file")"
  python3 - "$file" "$svc_json" <<'PY'
import json,sys
file,raw=sys.argv[1],sys.argv[2]
try: svc=json.loads(raw)
except Exception as e: print(f"bad json: {e}",file=sys.stderr); sys.exit(1)
name=str(svc.get("name","")).strip()
if not name or not name.isidentifier(): print("name must be an identifier",file=sys.stderr); sys.exit(1)
if not isinstance(svc.get("portBase"),int): print("portBase must be int",file=sys.stderr); sys.exit(1)
if not str(svc.get("run","")).strip(): print("run must be non-empty",file=sys.stderr); sys.exit(1)
try: data=json.load(open(file,encoding="utf-8"))
except Exception: data={"services":[]}
if not isinstance(data,dict): data={"services":[]}
svcs=[s for s in data.get("services",[]) if s.get("name")!=name]
svcs.append(svc); data["services"]=svcs
json.dump(data,open(file,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
print(f"service {name} -> {file}")
PY
}
service_rm() {
  local id="${1:-}" name="${2:-}" root_flag="${3:-}"
  [[ -n "$id" && -n "$name" ]] || die "usage: marina service rm <id> <name> [--root]"
  local file; file="$(service_target_file "$id" "$root_flag")" || exit $?
  [[ -f "$file" ]] || { echo "no services file: $file"; return 0; }
  python3 - "$file" "$name" <<'PY'
import json,sys
file,name=sys.argv[1],sys.argv[2]
try: data=json.load(open(file,encoding="utf-8"))
except Exception: data={"services":[]}
if not isinstance(data,dict): data={"services":[]}
data["services"]=[s for s in data.get("services",[]) if s.get("name")!=name]
json.dump(data,open(file,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
print(f"removed {name} from {file}")
PY
}

# 머지된 서비스 정의(root ∪ 중앙) json 출력. status(런타임)와 구분되는 정의 조회.
# 워크스페이스 컨텍스트 해석 전에 호출되므로 ROOT/SOURCE_ROOT 를 id 의 root 로 직접 세팅한다
# (merged_services_json 이 둘로 레지스트리를 매칭해 중앙 서비스 pid 를 해석).
service_ls() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: marina service ls <id>"
  local root; root="$(registry_root_for "$id")" || exit $?
  ROOT="$root" SOURCE_ROOT="$root" merged_services_json
}

registry_ls() {
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    echo "(레지스트리 비어 있음: $PROJECTS_FILE — marina project add <path> 로 등록)"
    return 0
  fi
  python3 - "$PROJECTS_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
projects = data.get("projects", [])
if not projects:
    print("(등록된 프로젝트 없음)")
    sys.exit(0)
for p in projects:
    print(f"{p.get('id')}\t{p.get('root')}")
    subs = p.get("subrepos", [])
    if subs:
        print(f"  subrepos: {', '.join(subs)}")
    globs = p.get("worktreeGlobs", [])
    if globs:
        print(f"  worktrees: {', '.join(globs)}")
PY
}

# root ∪ 중앙 서비스 머지 JSON 을 stdout 으로 (name 중앙 우선). 서비스 조회가 이걸 파싱한다.
# early dispatch(service ls)에서도 호출되므로 워크스페이스 컨텍스트 해석 위에 정의한다 —
# ROOT/SOURCE_ROOT/PROJECTS_FILE/MARINA_HOME 을 positional 로만 받아 그 시점 의존이 없다.
merged_services_json() {
  python3 - "$ROOT" "$SOURCE_ROOT" "$PROJECTS_FILE" "$MARINA_HOME" <<'PY'
import json, os, sys
root, source_root, projects_file, home = sys.argv[1:5]
def read(p):
    try:
        d = json.load(open(p, encoding="utf-8"))
        return d.get("services", []) if isinstance(d, dict) else []
    except Exception:
        return []
def norm(p): return os.path.realpath(os.path.expanduser(p))
pid = ""; proot = source_root
try:
    data = json.load(open(projects_file, encoding="utf-8"))
    tgt = {norm(source_root), norm(root)}
    for p in data.get("projects", []):
        pr = norm(p.get("root", ""))
        if pr in tgt or any(t == pr or t.startswith(pr + os.sep) for t in tgt):
            pid = p.get("id", ""); proot = p.get("root", ""); break
except Exception:
    pass
merged = {}
root_file = os.path.join(norm(proot), "marina-services.json")
for s in read(root_file):
    n = s.get("name")
    if n: merged[n] = {**s, "source": "root"}
if pid:
    for s in read(os.path.join(norm(home), "services", pid + ".json")):
        n = s.get("name")
        if n: merged[n] = {**s, "source": "central"}
print(json.dumps({"services": list(merged.values())}, ensure_ascii=False))
PY
}

# 레지스트리/서비스 CLI 는 워크스페이스 컨텍스트(ROOT/SOURCE_ROOT) 해석 전에 처리하고 종료.
case "${1:-}" in
  project)
    shift
    case "${1:-}" in
      add)     shift; registry_add "$@";     exit $? ;;
      infer)   shift; registry_infer "$@";   exit $? ;;
      rm)      shift; registry_rm "$@";      exit $? ;;
      default) shift; registry_default "$@"; exit $? ;;
      ls)      shift; registry_ls "$@";      exit $? ;;
      *) die "usage: marina project {add|rm|ls|default|infer} …" ;;
    esac
    ;;
  service)
    shift
    case "${1:-}" in
      add) shift; service_add "$@"; exit $? ;;
      rm)  shift; service_rm "$@";  exit $? ;;
      ls)  shift; service_ls "$@";  exit $? ;;
      *) die "usage: marina service {add|rm|ls} …" ;;
    esac
    ;;
esac

# ---- 워크스페이스 컨텍스트 (런처 명령용) — 위치독립 -------------------------
# ROOT = 대시보드가 주입한 worktree, 또는 직접 CLI 시 현재 git 최상위. (구 AGENTS.md+shared/ 탐색 제거)
resolve_root() {
  if [[ -n "${ROOT:-}" ]]; then
    ( cd "$ROOT" 2>/dev/null && pwd -P ) || die "ROOT 디렉토리 없음: $ROOT"
    return
  fi
  ( cd "$(pwd)" && git rev-parse --show-toplevel 2>/dev/null ) || pwd -P
}

# subrepos = MARINA_SUBREPOS env(대시보드 주입) → 레지스트리(직접 CLI) → 없음(미등록 프로젝트)
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

ROOT="$(resolve_root)"
resolve_subrepos
load_local_env_file "$(session_data_dir "$ROOT")/local.env"
SESSION_ROOT="$(session_data_dir "$ROOT")"
ATTACH_SCRIPT="$SCRIPT_DIR/attach-detached-subrepos.sh"
SOURCE_ROOT="$(resolve_source_root)"
# 서비스 run 템플릿이 헬퍼 스크립트에서 원본 경로를 쓸 수 있게 노출 (예: node_modules 링크)
export MARINA_SOURCE_ROOT="$SOURCE_ROOT" MARINA_ROOT="$ROOT"
if [[ "$SOURCE_ROOT" != "$ROOT" ]]; then
  load_local_env_file "$(session_data_dir "$SOURCE_ROOT")/local.env"
fi
CODEX_WORKTREES_ROOT="${CODEX_WORKTREES_ROOT:-$HOME/.codex/worktrees}"
CODEX_NODE_BIN="${CODEX_NODE_BIN:-$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin}"
if [[ -x "$CODEX_NODE_BIN/node" ]]; then
  export PATH="$CODEX_NODE_BIN:$PATH"
fi
export COREPACK_ENABLE_PROJECT_SPEC="${COREPACK_ENABLE_PROJECT_SPEC:-0}"

# 서비스 정의: root ∪ 중앙 서비스 머지 (내장 서비스 없음 — 전부 marina-services.json 에서).
#   {"services": [{"name":"echo","portBase":8200,"cwd":".","run":"{python} -m http.server {port}"}]}
# run 치환자: {port}{<name>_port}{python}{root}{profile} + 세션 경로 {env_file}{tmp}{session}.
# 우선순위: root(SOURCE_ROOT) ∪ 중앙(~/.marina/services/<id>.json), name 충돌 시 중앙 우선.
# merged_services_json 정의는 service ls(early dispatch)에서도 쓰므로 위쪽에 둔다.

extra_services() {
  command -v python3 >/dev/null 2>&1 || return 0
  local _merged; _merged="$(merged_services_json)"
  python3 - "$_merged" <<'PY'
import json, sys
try:
    for s in json.loads(sys.argv[1]).get("services", []):
        name = str(s.get("name", "")).strip()
        if name and name.isidentifier() and isinstance(s.get("portBase"), int):
            print(name)
except Exception:
    pass
PY
}

service_json_field() {
  local name="$1" field="$2"
  local _merged; _merged="$(merged_services_json)"
  python3 - "$_merged" "$name" "$field" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
service, field = sys.argv[2], sys.argv[3]
svc = next((s for s in data.get("services", []) if s.get("name") == service), None)
if svc:
    value = svc.get(field, "")
    if isinstance(value, (str, int)):
        print(value, end="")
PY
}

# 서비스는 전적으로 프로젝트 root 의 marina-services.json 에서 온다 (내장 서비스 없음).
SERVICES=()
while IFS= read -r extra; do
  [[ -n "$extra" ]] || continue
  case " ${SERVICES[*]:-} " in *" $extra "*) ;; *) SERVICES+=("$extra") ;; esac
done < <(extra_services)

usage() {
  cat <<'EOF'
usage:
  launcher (worktree 단위 — 서비스는 프로젝트 root 의 marina-services.json 에서 정의):
    marina.sh start <service..> | --all [--changed]
    marina.sh stop <service..> | --all
    marina.sh restart <service..> | --all
    marina.sh foreground [service]
    marina.sh status | status-all | ports
    marina.sh logs [service]
  project (~/.marina/projects.json, 위치 무관):
    marina.sh project add <project-path> [--subrepos a,b,c]   # 등록. --subrepos 생략=자동 추론, 명시=정확히 그 집합(빈 값=모노레포)
    marina.sh project infer <project-path>   # 추론만 — JSON 출력, 미기록
    marina.sh project rm <id>
    marina.sh project ls
    marina.sh project default <id> <a,b,c>   # 새 worktree 자동 attach 서브레포 집합 (빈 값=비움)
  service (root marina-services.json ∪ ~/.marina/services/<id>.json):
    marina.sh service add <id> '<json>' [--root]   # --root=프로젝트 root 파일, 생략=중앙
    marina.sh service rm <id> <name> [--root]
    marina.sh service ls <id>   # root ∪ 중앙 머지 정의 JSON

note:
  start/stop/restart 는 인자 필수 — 전체 대상은 --all 로 명시 (무인자 = 전체 실수 방지 가드).
EOF
}

session_id() {
  # codex 레이아웃은 <id>/<projectBasename>, claude 는 .claude/worktrees/<name> 그 자체가 루트.
  # 무조건 dirname 을 쓰면 claude worktree 가 전부 "worktrees" 로 뭉개진다.
  # codex worktree 의 basename 은 원본(SOURCE_ROOT) basename 과 같다 → 부모(<id>)명을 세션 id 로.
  if [[ "$ROOT" == "$SOURCE_ROOT" ]]; then
    echo "main"
  elif [[ "$(basename "$ROOT")" == "$(basename "$SOURCE_ROOT")" ]]; then
    basename "$(dirname "$ROOT")"
  else
    basename "$ROOT"
  fi
}

port_offset() {
  local id hex
  if [[ "$ROOT" == "$SOURCE_ROOT" ]]; then
    echo 0
    return 0
  fi
  id="$(session_id)"
  if [[ "$id" =~ ^[0-9a-fA-F]+$ ]]; then
    hex="${id: -4}"
    echo $(((16#$hex % 80) + 10))
    return 0
  fi
  printf '%s' "$id" | cksum | awk '{ print ($1 % 80) + 10 }'
}

upper_service() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# 서비스별 프로파일 — config 의 SERVICE_PROFILE_<NAME> 값, 기본 local. {profile} 치환자로 run 에 전달.
service_profile() {
  local service="$1"
  config_value "SERVICE_PROFILE_$(upper_service "$service")" "local"
}

python_bin() {
  # {python} 치환자용 — MARINA_PYTHON_BIN 우선, 없으면 시스템 python3/python.
  # (프로젝트별 venv 는 marina-services.json run 에서 직접 경로를 쓰거나 MARINA_PYTHON_BIN 으로 지정)
  if [[ -n "${MARINA_PYTHON_BIN:-}" && -x "$MARINA_PYTHON_BIN" ]]; then
    printf '%s\n' "$MARINA_PYTHON_BIN"
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  elif command -v python >/dev/null 2>&1; then
    command -v python
  else
    die "python 실행 파일을 찾지 못함 (python3 또는 MARINA_PYTHON_BIN 필요)"
  fi
}

default_port_for() {
  # 포트는 전적으로 marina-services.json 의 portBase + 세션 오프셋. (내장 서비스 없음)
  local service="$1" offset="$2" base
  base="$(service_json_field "$service" portBase)"
  [[ -n "$base" ]] || die "unknown service: $service (marina-services.json 에 portBase 필요)"
  echo $((base + offset))
}

port_for() {
  local service="$1" offset="$2"
  if [[ "${MARINA_IGNORE_PORT_OVERRIDES:-0}" == "1" ]]; then
    default_port_for "$service" "$offset"
    return 0
  fi
  config_value "SERVICE_PORT_$(upper_service "$service")" "$(default_port_for "$service" "$offset")"
}

session_dir() {
  echo "$SESSION_ROOT/$(session_id)"
}

pid_file() {
  echo "$(session_dir)/$1.pid"
}

log_file() {
  echo "$(session_dir)/$1.log"
}

config_file() {
  echo "$(session_dir)/overrides.env"
}

config_value() {
  local key="$1" default_value="$2" config_path
  local value=""
  config_path="$(config_file)"
  if [[ -f "$config_path" ]]; then
    value="$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; found=1 } END { exit found ? 0 : 1 }' "$config_path" || true)"
  fi
  echo "${value:-$default_value}"
}

# overrides.env 에 key=value upsert — 포트 자동 이동 결과를 박제해 전 구간(env·URL·status) 일관 유지
set_config_value() {
  local key="$1" value="$2" config_path tmp
  config_path="$(config_file)"
  mkdir -p "$(dirname "$config_path")"
  touch "$config_path"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$config_path" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$config_path"
}

# 이 세션의 다른 서비스 기본/오버라이드 포트 목록 (자동 이동 시 회피 대상)
session_ports() {
  local s offset
  offset="$(port_offset)"
  for s in ${SERVICES[@]+"${SERVICES[@]}"}; do
    port_for "$s" "$offset"
  done
}

# desired 부터 위로 빈 포트 탐색 (서비스 무관, +99 창 안에서).
free_port_near() {
  local service="$1" desired="$2" candidate limit session_port_list
  candidate="$desired"
  limit=$((desired + 99))
  session_port_list="$(session_ports)"
  while ((candidate <= limit)); do
    if ! grep -qx "$candidate" <<< "$session_port_list" && [[ -z "$(listener_pids "$candidate")" ]]; then
      echo "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done
  return 1
}

log_dir() {
  echo "$(session_dir)/logs/$1"
}

# run 로그 누적 방지: 최신 keep 개만 유지 (기본 10, MARINA_LOG_KEEP)
prune_old_runs() {
  local service="$1" current_log="$2" keep="${MARINA_LOG_KEEP:-10}" dir total old_log
  dir="$(log_dir "$service")"
  total="$(ls -1 "$dir"/run-*.log 2>/dev/null | wc -l | tr -d ' ')"
  if ((keep > 0 && total > keep)); then
    # 사전순은 run-1000 < run-999 로 역전 → 시퀀스 숫자 기준 정렬
    while IFS= read -r old_log; do
      [[ "$old_log" == "$current_log" ]] && continue
      rm -f "$old_log"
    done < <(ls -1 "$dir"/run-*.log | sort -t- -k2 -n | sed -n "1,$((total - keep))p")
  fi
}

next_run_log() {
  local service="$1" seq_path seq log_path
  mkdir -p "$(log_dir "$service")"
  seq_path="$(session_dir)/$service.seq"
  if [[ -f "$seq_path" ]]; then
    seq="$(cat "$seq_path")"
  else
    seq=0
  fi
  seq=$((10#$seq + 1))
  printf '%03d\n' "$seq" > "$seq_path"
  log_path="$(log_dir "$service")/run-$(printf '%03d' "$seq").log"
  : > "$log_path"
  ln -sfn "$log_path" "$(log_file "$service")"
  prune_old_runs "$service" "$log_path"
  echo "$log_path"
}

ensure_current_log() {
  local service="$1" current
  current="$(log_file "$service")"
  if [[ -e "$current" ]]; then
    echo "$current"
  else
    next_run_log "$service"
  fi
}

reset_console_log_for_web_run() {
  next_run_log console >/dev/null
}

redact_stream() {
  perl -pe "s/([A-Z0-9_-]*(?:KEY|SECRET|TOKEN|PASSWORD|ACCESS|WEBHOOK|CREDENTIAL|PRIVATE)[A-Z0-9_-]*[[:space:]]*=[[:space:]]*)[^[:space:]│,}]+/\${1}<redacted>/gi; s/('[^']*(?:key|secret|token|password|access|webhook|credential|private)[^']*'[[:space:]]*:[[:space:]]*')[^']*(')/\${1}<redacted>\${2}/gi; s/(\"[^\"]*(?:key|secret|token|password|access|webhook|credential|private)[^\"]*\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\${1}<redacted>\${2}/gi"
}

env_file() {
  echo "$(session_dir)/$1.env"
}

session_tmp() {
  echo "$(session_dir)/tmp"
}

backup_path() {
  echo "$(session_dir)/backup-$1-$(date +%Y%m%d%H%M%S)"
}

is_running() {
  local pid_path="$1"
  [[ -f "$pid_path" ]] || return 1
  local pid
  pid="$(cat "$pid_path")"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

pgid_of() {
  ps -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]'
}

# pid 가 속한 프로세스 그룹 전체에 시그널을 보낸다.
# 자기 자신 그룹·init 그룹이면 단일 pid 로 폴백 (macOS 에 setsid 바이너리가 없어 set -m 그룹 기동과 짝).
kill_tree() {
  local pid="$1" sig="${2:-TERM}" pgid self_pgid
  pgid="$(pgid_of "$pid")"
  self_pgid="$(pgid_of $$)"
  if [[ -n "$pgid" && "$pgid" != "0" && "$pgid" != "1" && "$pgid" != "$self_pgid" ]]; then
    # pgid 조회 후 pid 가 죽고 pgid 가 재사용됐을 수 있다 → kill 직전 생존 재확인으로 오살 창 축소
    if kill -0 "$pid" 2>/dev/null; then
      kill "-$sig" -- "-$pgid" 2>/dev/null && return 0
    fi
  fi
  kill "-$sig" "$pid" 2>/dev/null || true
}

# pid 가 사라질 때까지 최대 N 데시초(0.1s 단위) 대기. 살아있으면 1 반환.
wait_gone() {
  local pid="$1" deadline_ds="${2:-50}" i
  for ((i = 0; i < deadline_ds; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  ! kill -0 "$pid" 2>/dev/null
}

listener_pids() {
  local port="$1"
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
}

repo_changed() {
  local repo="$1"
  [[ -d "$ROOT/$repo" ]] || return 1
  [[ -n "$(git -C "$ROOT/$repo" status --porcelain)" ]]
}

selected_services_from_args() {
  local changed=false any=false
  SELECTED=()

  local flag_name
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) SELECTED=(${SERVICES[@]+"${SERVICES[@]}"}); any=true ;;
      --changed) changed=true ;;
      -h|--help) usage; exit 0 ;;
      --*)
        # SERVICES (내장 + marina-services.json) 에 있는 이름이면 동적 허용
        flag_name="${1#--}"
        case " ${SERVICES[*]:-} " in
          *" $flag_name "*) SELECTED+=("$flag_name"); any=true ;;
          *) die "unknown option: $1" ;;
        esac
        ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done

  if [[ "$changed" == "true" ]]; then
    # 각 서비스의 cwd 최상위 디렉토리(서브레포)에 변경분 있으면 선택 — generic (구 web/be/ai 매핑 제거)
    local svc svc_cwd subrepo
    for svc in ${SERVICES[@]+"${SERVICES[@]}"}; do
      svc_cwd="$(service_json_field "$svc" cwd)"
      subrepo="${svc_cwd%%/*}"
      # subrepo 빈 값(run 에 cwd 생략)이면 "." 로 폴백 — cwd="." 는 %%/* 가 이미 "." 반환.
      # 둘 다 repo_changed "." (= ROOT 자체 git status) 로 판정 → 단일레포에서도 잡음 (구: skip 돼 누락)
      [[ -n "$subrepo" ]] || subrepo="."
      repo_changed "$subrepo" && SELECTED+=("$svc")
    done
    any=true
  fi

  if [[ "$any" == "false" || ${#SELECTED[@]} -eq 0 ]]; then
    # 기본: 정의된 전 서비스 (구 "web only" 제거)
    SELECTED=(${SERVICES[@]+"${SERVICES[@]}"})
  fi

  printf '%s\n' ${SELECTED[@]+"${SELECTED[@]}"} | awk '!seen[$0]++'
}

prepare() {
  [[ -d "$ROOT" ]] || die "ROOT 없음: $ROOT"
  mkdir -p "$(session_dir)"
  mkdir -p "$(session_tmp)"

  # 대시보드가 이미 worktree prepare 를 끝낸 경우 중복 attach 스킵 (MARINA_SKIP_PREPARE=1)
  if [[ "${MARINA_SKIP_PREPARE:-0}" != "1" && -x "$ATTACH_SCRIPT" ]]; then
    "$ATTACH_SCRIPT" >/dev/null
  fi
}

command_for() {
  # 모든 서비스는 프로젝트 root 의 marina-services.json 에서 정의 (내장 서비스 없음 — 완전 generic).
  #   {name, portBase, cwd, run}  run 치환자: {port}{<name>_port}{python}{root}{profile} + 세션 경로 {env_file}{tmp}{session}
  #   복잡한 기동(env 준비·의존성 링크 등)은 run 이 프로젝트 쪽 헬퍼 스크립트를 호출한다.
  local service="$1" offset="$2" cwd run sib
  cwd="$(service_json_field "$service" cwd)"
  run="$(service_json_field "$service" run)"
  [[ -n "$run" ]] || die "unknown service: $service (marina-services.json 에 run 필요)"
  run="${run//\{port\}/$(port_for "$service" "$offset")}"
  # 형제 서비스 포트 치환자 {<name>_port} — 자동 이동(override) 반영된 각 서비스의 실제 포트.
  # 서비스 간 호출에서 형제의 실제 포트를 주입한다 (uniform offset 추정 금지).
  for sib in ${SERVICES[@]+"${SERVICES[@]}"}; do
    run="${run//\{${sib}_port\}/$(port_for "$sib" "$offset")}"
  done
  run="${run//\{python\}/$(python_bin)}"
  run="${run//\{root\}/$ROOT}"
  run="${run//\{profile\}/$(service_profile "$service")}"
  run="${run//\{env_file\}/$(env_file "$service")}"
  run="${run//\{tmp\}/$(session_tmp)}"
  run="${run//\{session\}/$(session_id)}"
  printf 'cd %q && %s' "$ROOT/${cwd:-.}" "$run"
}

start_service() {
  local service="$1" offset="$2" pid_path log_path command port listeners
  pid_path="$(pid_file "$service")"
  port="$(port_for "$service" "$offset")"

  if is_running "$pid_path"; then
    echo "skip running: $service pid=$(cat "$pid_path")"
    return 0
  fi

  listeners="$(listener_pids "$port" | paste -sd, -)"
  if [[ -n "$listeners" ]]; then
    # 외부 점유 → 빈 포트로 자동 이동 (override 박제 후 port_for 전 구간이 새 포트를 읽음)
    local shifted_port
    if shifted_port="$(free_port_near "$service" "$((port + 1))")"; then
      set_config_value "SERVICE_PORT_$(upper_service "$service")" "$shifted_port"
      echo "port shifted: $service $port -> $shifted_port (점유 pid=$listeners)"
      port="$shifted_port"
    else
      die "$service 빈 포트 확보 실패: $port 이후 없음 (점유 pid=$listeners)"
    fi
  fi

  if ! command="$(command_for "$service" "$offset")"; then
    die "$service command 생성 실패"
  fi
  log_path="$(next_run_log "$service")"
  [[ "$service" == "web" ]] && reset_console_log_for_web_run
  {
    echo "session=$(session_id)"
    echo "service=$service"
    echo "port=$(port_for "$service" "$offset")"
    echo "cwd=$ROOT"
    echo "command=$command"
    echo "---"
  } > "$log_path"

  local launch_path
  launch_path="$(marina_login_path)"   # 사용자 로그인 PATH 주입(데몬 빈약 PATH 보정) — 메모라 루프서 1회 캡처
  (
    set -m # 백그라운드 잡을 새 프로세스 그룹으로 분리 — stop 시 kill_tree 가 그룹 단위로 정리
    nohup env PATH="$launch_path" bash -lc "$command" >> "$log_path" 2>&1 &
    echo $! > "$pid_path"
  )
  echo "started: $service port=$(port_for "$service" "$offset") pid=$(cat "$pid_path") log=$log_path"
}

stop_service() {
  local service="$1" pid_path pid offset port listener stopped_any=false
  pid_path="$(pid_file "$service")"
  offset="$(port_offset)"
  port="$(port_for "$service" "$offset")"
  if [[ -f "$pid_path" ]]; then
    pid="$(cat "$pid_path")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill_tree "$pid" TERM
      if wait_gone "$pid" 50; then
        echo "stopped: $service pid=$pid"
      else
        kill_tree "$pid" KILL
        wait_gone "$pid" 20 || true
        echo "killed (SIGKILL): $service pid=$pid"
      fi
      stopped_any=true
    else
      echo "stale pid: $service pid=${pid:-?}"
      stopped_any=true
    fi
    rm -f "$pid_path"
  fi

  while IFS= read -r listener; do
    [[ -n "$listener" ]] || continue
    kill_tree "$listener" TERM
    if ! wait_gone "$listener" 30; then
      kill_tree "$listener" KILL
      wait_gone "$listener" 20 || true
    fi
    echo "stopped listener: $service port=$port pid=$listener"
    stopped_any=true
  done < <(listener_pids "$port")

  if [[ "$stopped_any" == "false" ]]; then
    echo "skip stopped: $service"
  fi
}

print_ports() {
  local offset
  offset="$(port_offset)"
  echo "session=$(session_id)"
  for service in ${SERVICES[@]+"${SERVICES[@]}"}; do
    echo "$service=$(port_for "$service" "$offset")"
  done
}

print_status() {
  local offset service pid_path state port listeners
  offset="$(port_offset)"
  print_ports
  for service in ${SERVICES[@]+"${SERVICES[@]}"}; do
    port="$(port_for "$service" "$offset")"
    pid_path="$(pid_file "$service")"
    listeners="$(listener_pids "$port" | paste -sd, -)"
    if is_running "$pid_path"; then
      state="running pid=$(cat "$pid_path")"
    elif [[ -n "$listeners" ]]; then
      state="listening pid=$listeners"
    else
      state="stopped"
    fi
    echo "$service: $state log=$(log_file "$service")"
  done
}

print_status_for_root() {
  # ATTACH_SCRIPT 는 전역 상수($SCRIPT_DIR)라 root 별 재할당 불요.
  local target_root="$1" old_root="$ROOT" old_session_root="$SESSION_ROOT"
  ROOT="$target_root"
  SESSION_ROOT="$(session_data_dir "$ROOT")"
  echo
  echo "==> $(session_id)  $ROOT"
  print_status
  ROOT="$old_root"
  SESSION_ROOT="$old_session_root"
}

print_status_all() {
  # codex worktree = <id>/<projectBasename>. 원본(SOURCE_ROOT) basename 으로 일반화.
  local candidate base found=false
  base="$(basename "$SOURCE_ROOT")"
  for candidate in "$CODEX_WORKTREES_ROOT"/*/"$base"; do
    [[ -d "$candidate" ]] || continue
    [[ -e "$candidate/.git" ]] || continue
    found=true
    print_status_for_root "$candidate"
  done
  [[ "$found" == "true" ]] || echo "no '$base' worktrees found under $CODEX_WORKTREES_ROOT"
}

tail_logs() {
  local service="${1:-}"
  if [[ -z "$service" ]]; then
    tail -n 80 -f "$(session_dir)"/*.log
  else
    tail -n 120 -f "$(ensure_current_log "$service")"
  fi
}

run_foreground() {
  # 서비스 미지정 시 정의된 첫 서비스 (내장 'web' 기본값 제거)
  local service="${1:-${SERVICES[0]:-}}" offset command log_path
  [[ -n "$service" ]] || die "foreground: 서비스명을 지정해줘 (marina-services.json 에 정의된 것)"
  prepare
  offset="$(port_offset)"
  if ! command="$(command_for "$service" "$offset")"; then
    die "$service command 생성 실패"
  fi
  log_path="$(next_run_log "$service")"
  [[ "$service" == "web" ]] && reset_console_log_for_web_run
  echo "session=$(session_id)"
  echo "service=$service"
  echo "port=$(port_for "$service" "$offset")"
  echo "command=$command"
  echo "---"
  {
    echo
    echo "=== foreground $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "session=$(session_id)"
    echo "service=$service"
    echo "port=$(port_for "$service" "$offset")"
    echo "command=$command"
    echo "---"
  } >> "$log_path"
  local launch_path; launch_path="$(marina_login_path)"   # 사용자 로그인 PATH 주입 (start_service 와 동일)
  env PATH="$launch_path" bash -lc "$command" 2>&1 | redact_stream | tee -a "$log_path"
  exit "${PIPESTATUS[0]}"
}

main() {
  local command="${1:-status}" offset service
  shift || true

  case "$command" in
    start|stop|restart)
      # 무인자 가드: 전체 정지/기동 실수 방지 — 명시적 --all 만 전체로 확장.
      if [[ $# -eq 0 ]]; then
        echo "usage: marina $command <service..>   (전체: marina $command --all)" >&2
        echo "서비스: ${SERVICES[*]:-(없음)}" >&2
        exit 2
      fi
      offset="$(port_offset)"
      case "$command" in
        start)   prepare; while IFS= read -r service; do start_service "$service" "$offset"; done < <(selected_services_from_args "$@"); print_status ;;
        stop)    while IFS= read -r service; do stop_service "$service"; done < <(selected_services_from_args "$@") ;;
        restart) prepare; while IFS= read -r service; do stop_service "$service"; start_service "$service" "$offset"; done < <(selected_services_from_args "$@"); print_status ;;
      esac
      ;;
    foreground)
      run_foreground "${1:-}"
      ;;
    status)
      print_status
      ;;
    status-all)
      print_status_all
      ;;
    logs)
      tail_logs "${1:-}"
      ;;
    ports)
      print_ports
      ;;
    print-command)
      # 서비스의 resolved 명령어를 stdout 에 출력하고 종료 (디버그·테스트용).
      local svc="${1:-${SERVICES[0]:-}}"
      [[ -n "$svc" ]] || die "print-command: service name required"
      offset="$(port_offset)"
      command_for "$svc" "$offset"
      ;;
    print-launch-path)
      # 서비스 기동에 쓰일 로그인 PATH 를 출력하고 종료 (디버그·테스트용).
      marina_login_path; echo
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
