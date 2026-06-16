#!/usr/bin/env bash
# marina.sh — worktree 세션별 포트/로그/프로세스 런처 + 프로젝트 레지스트리 CLI.
#
# 런처 (대시보드가 ROOT 를 주입해 호출, 또는 worktree 안에서 직접):
#   marina.sh start --web | status | logs web | stop | ports
# 레지스트리 CLI (위치 무관 — ~/.marina/projects.json 편집):
#   marina.sh add <project-path> | infer <project-path> | rm <id> | ls

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MARINA_HOME="${MARINA_HOME:-$HOME/.marina}"
PROJECTS_FILE="$MARINA_HOME/projects.json"

die() {
  echo "error: $*" >&2
  exit 1
}

# ---- 프로젝트 레지스트리 CLI (~/.marina/projects.json) — 위치 무관 ----------
# 추론은 여기(registry_infer)가 단일 SoT — JSON 으로 출력만 하고 쓰지 않는다.
# registry_add 는 이걸 소비해서 ~/.marina/projects.json 에 upsert 하고, 대시보드 API(phase 3)도 이걸 shell.
registry_infer() {
  local path="${1:-}"
  [[ -n "$path" ]] || die "usage: marina.sh infer <project-path>"
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
  local entry; entry="$(registry_infer "${1:-}")" || exit $?
  mkdir -p "$MARINA_HOME"
  python3 - "$PROJECTS_FILE" "$entry" <<'PY'
import json, os, sys
projects_file, entry = sys.argv[1], json.loads(sys.argv[2])
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
  [[ -n "$id" ]] || die "usage: marina.sh rm <id>"
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

registry_ls() {
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    echo "(레지스트리 비어 있음: $PROJECTS_FILE — marina.sh add <path> 로 등록)"
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

# 레지스트리 CLI 는 워크스페이스 컨텍스트(ROOT/SOURCE_ROOT) 해석 전에 처리하고 종료.
case "${1:-}" in
  add)         shift; registry_add "$@";   exit $? ;;
  infer)       shift; registry_infer "$@"; exit $? ;;
  rm)          shift; registry_rm "$@";    exit $? ;;
  ls|projects) registry_ls;               exit $? ;;
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

# 서비스 정의: 프로젝트 root 의 marina-services.json (내장 서비스 없음 — 전부 여기서).
#   {"services": [{"name":"echo","portBase":8200,"cwd":".","run":"{python} -m http.server {port}"}]}
# run 치환자: {port}{python}{root}{profile} + 세션 경로 {env_file}{tmp}{session}.
# worktree 자체 파일 우선, 없으면 원본(SOURCE_ROOT)에서 — control.py 와 동일 파일을 읽도록.
SERVICES_FILE="$ROOT/marina-services.json"
[[ -f "$SERVICES_FILE" ]] || SERVICES_FILE="$SOURCE_ROOT/marina-services.json"

extra_services() {
  [[ -f "$SERVICES_FILE" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$SERVICES_FILE" <<'PY'
import json, sys
try:
    for s in json.load(open(sys.argv[1])).get("services", []):
        name = str(s.get("name", "")).strip()
        if name and name.isidentifier() and isinstance(s.get("portBase"), int):
            print(name)
except Exception:
    pass
PY
}

service_json_field() {
  local name="$1" field="$2"
  [[ -f "$SERVICES_FILE" ]] || return 0
  python3 - "$SERVICES_FILE" "$name" "$field" <<'PY'
import json, sys
path, name, field = sys.argv[1:4]
try:
    for s in json.load(open(path)).get("services", []):
        if s.get("name") == name:
            value = s.get(field, "")
            if isinstance(value, (str, int)):
                print(value)
            break
except Exception:
    pass
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
    marina.sh start [--<service>...] [--all] [--changed]
    marina.sh foreground [service]
    marina.sh stop [service...]
    marina.sh status | status-all | ports
    marina.sh logs [service]
  registry (~/.marina/projects.json, 위치 무관):
    marina.sh add <project-path>     # 서브레포·worktreeGlobs 자동 추론 후 등록
    marina.sh infer <project-path>   # 추론만 — JSON 출력, 미기록
    marina.sh rm <id>
    marina.sh ls

defaults:
  start without service flags starts all defined services.
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
  #   {name, portBase, cwd, run}  run 치환자: {port}{python}{root}{profile} + 세션 경로 {env_file}{tmp}{session}
  #   복잡한 기동(env 준비·의존성 링크 등)은 run 이 프로젝트 쪽 헬퍼 스크립트를 호출한다.
  local service="$1" offset="$2" cwd run
  cwd="$(service_json_field "$service" cwd)"
  run="$(service_json_field "$service" run)"
  [[ -n "$run" ]] || die "unknown service: $service (marina-services.json 에 run 필요)"
  run="${run//\{port\}/$(port_for "$service" "$offset")}"
  run="${run//\{python\}/$(python_bin)}"
  run="${run//\{root\}/$ROOT}"
  run="${run//\{profile\}/$(service_profile "$service")}"
  run="${run//\{env_file\}/$(env_file "$service")}"
  run="${run//\{tmp\}/$(session_tmp)}"
  run="${run//\{session\}/$(session_id)}"
  printf 'cd %q && exec %s' "$ROOT/${cwd:-.}" "$run"
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

  (
    set -m # 백그라운드 잡을 새 프로세스 그룹으로 분리 — stop 시 kill_tree 가 그룹 단위로 정리
    nohup bash -lc "$command" >> "$log_path" 2>&1 &
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
  bash -lc "$command" 2>&1 | redact_stream | tee -a "$log_path"
  exit "${PIPESTATUS[0]}"
}

main() {
  local command="${1:-status}" offset service
  shift || true

  case "$command" in
    start)
      prepare
      offset="$(port_offset)"
      while IFS= read -r service; do
        start_service "$service" "$offset"
      done < <(selected_services_from_args "$@")
      print_status
      ;;
    foreground)
      run_foreground "${1:-}"
      ;;
    stop)
      if [[ $# -eq 0 ]]; then
        for service in ${SERVICES[@]+"${SERVICES[@]}"}; do
          stop_service "$service"
        done
      else
        for service in "$@"; do
          stop_service "$service"
        done
      fi
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
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
