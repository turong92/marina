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

# ── 분리된 라이브러리 source (함수 정의) — 전역 설정/early dispatch 전에 로드 ──
source "$SCRIPT_DIR/marina-lib-registry.sh"
source "$SCRIPT_DIR/marina-lib-services.sh"
source "$SCRIPT_DIR/marina-lib-context.sh"
source "$SCRIPT_DIR/marina-lib-session.sh"
source "$SCRIPT_DIR/marina-lib-links.sh"
source "$SCRIPT_DIR/marina-lib-process.sh"
source "$SCRIPT_DIR/marina-lib-compose.sh"

die() {
  echo "error: $*" >&2
  exit 1
}

_MARINA_LOGIN_PATH=""

# 레지스트리/서비스 CLI 는 워크스페이스 컨텍스트(ROOT/SOURCE_ROOT) 해석 전에 처리하고 종료.
project_usage() {
  cat <<'EOF'
usage: marina project <sub>
  add <path> --compose <file> [--env-var NAME --env-default VAL]   기존 docker-compose 로 등록 (또는 대시보드 위저드)
  add <path> --external name=path                                  외부 git 레포를 서비스로 (--compose 와 함께)
  add <path> --subrepos a,b,c                                      서브레포 목록 명시
  ls                    등록 목록
  rm <id>               등록 제거
  infer <path>          추론만 (JSON 출력, 미기록)
  default <id> a,b,c    새 worktree 자동 attach 서브레포 집합 (빈 값=비움)
EOF
}
case "${1:-}" in
  project)
    shift
    case "${1:-}" in
      add)     shift; registry_add "$@";     exit $? ;;
      infer)   shift; registry_infer "$@";   exit $? ;;
      rm)      shift; registry_rm "$@";      exit $? ;;
      default) shift; registry_default "$@"; exit $? ;;
      ls)      shift; registry_ls "$@";      exit $? ;;
      help|-h|--help) project_usage; exit 0 ;;
      *) project_usage >&2; exit 2 ;;
    esac
    ;;
esac

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

# 서비스 정의 머지(marina-services.json, root ∪ 중앙) — compose 서비스는 docker-compose.yml 로 정의하고,
# 여기 정의의 service.links(glob 링크 룰)만 apply_glob_links/links_json 이 읽는다.
# 우선순위: root(SOURCE_ROOT) ∪ 중앙(~/.marina/services/<id>.json), name 충돌 시 중앙 우선.

# 서비스는 전적으로 프로젝트 root 의 marina-services.json 에서 온다 (내장 서비스 없음).
SERVICES=()
while IFS= read -r extra; do
  [[ -n "$extra" ]] || continue
  case " ${SERVICES[*]:-} " in *" $extra "*) ;; *) SERVICES+=("$extra") ;; esac
done < <(extra_services)

usage() {
  cat <<'EOF'
usage (marina.sh = 내부 launcher; 평소엔 `marina <명령>` 래퍼로 — 래퍼는 `marina start web` 처럼 서비스명을 그대로 받습니다):
  실행 (worktree 단위 — compose 프로젝트는 ~/.marina 의 docker-compose 정의에서 서비스가 옵니다):
    marina.sh start   --<service> | --all     # 특정 서비스 | 전체 스택 (docker compose up -d --build, 워크트리별 포트 자동 격리)
    marina.sh stop    --<service> | --all      # 특정 서비스 | 전체 (--all = down)
    marina.sh restart --<service> | --all      # 정의 변경분 재적용 (selected = up --build 재적용)
    marina.sh status | ports                   # 실행 상태·라이브 포트
    marina.sh logs [service]                   # docker 로그 follow
  worktree (작업 시작 — 브랜치명 지정 워크트리 생성; Claude 자동 claude/<id> 대신 feature/{task} 등):
    marina.sh worktree create <branch> [base] [--project <id>]  # git worktree(-b) + 서브레포 같은 브랜치 미러. --project=아무데서나(cwd 무관)
  project (~/.marina/projects.json, 위치 무관):
    marina.sh project add <path> --compose <file> [--env-var NAME --env-default VAL]   # compose 등록(파일을 marina 로 복사. 또는 대시보드 위저드)
    marina.sh project add <path> --external name=path # 외부 git 레포를 서비스로(워크트리마다 격리 attach)
    marina.sh project infer <path> | ls | rm <id> | default <id> <a,b,c>

note:
  start/stop/restart 는 대상 필수 — 전체는 --all (무인자 = 실수 방지 가드). compose 서비스는 --<service> 플래그로 지정합니다.
EOF
}

# compose 서비스 로그를 네이티브와 동일한 run-NNN.log 로 캡처하는 tailer (백그라운드, idempotent).
# 데몬/CLI 가 띄워도 nohup + fd 리다이렉트로 detach (start_service 와 동일 패턴).
_compose_logtail_start() {  # $1=compose project name, $2=service
  local name="$1" service="$2" log_path tpf _o
  tpf="$(session_dir)/${service}.logtail.pid"
  if [[ -f "$tpf" ]]; then
    _o="$(cat "$tpf" 2>/dev/null || true)"
    [[ -n "$_o" ]] && kill -0 "$_o" 2>/dev/null && kill "$_o" 2>/dev/null || true
    rm -f "$tpf"
  fi
  log_path="$(next_run_log "$service")"   # run-NNN 생성 + <svc>.log 심링크 + prune (네이티브 헬퍼 재사용)
  {
    echo "service=$service (compose)"
    echo "project=$name"
    echo "---"
  } > "$log_path"
  ( set -m
    nohup docker compose -p "$name" logs -f --no-log-prefix "$service" >> "$log_path" 2>&1 &
    echo $! > "$tpf"
  )
  return 0
}

_compose_logtail_stop() {  # $1=service (없으면 전체). set -e 안전 — 항상 0 반환.
  local sd f p; sd="$(session_dir)"
  if [[ -n "${1:-}" ]]; then
    f="$sd/${1}.logtail.pid"
    if [[ -f "$f" ]]; then p="$(cat "$f" 2>/dev/null || true)"; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null || true; rm -f "$f"; fi
  else
    shopt -s nullglob
    for f in "$sd"/*.logtail.pid; do p="$(cat "$f" 2>/dev/null || true)"; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null || true; rm -f "$f"; done
    shopt -u nullglob
  fi
  return 0
}

main() {
  local command="${1:-status}"
  shift || true
  case "$command" in
    start|stop|restart|status|logs|ports)
      if [[ "$(project_kind)" == "compose" ]]; then
        compose_main "$command" "$@"
        return $?
      fi
      die "compose 프로젝트가 아닙니다(compose 전용) — 'marina project add <root> --compose' 로 등록하거나 대시보드 위저드를 쓰세요." ;;
    print-session-dir)
      session_dir ;;
    link)
      # opt-in 링크(x-marina.links{symlink,copy} 우선, 없으면 기본<central<service<override)를 수동 적용 — IDE 등 start 없이.
      local _lmeta _lpid _lcfile _lstored="" _lcp="$SCRIPT_DIR/marina-compose.py"
      _lmeta="$(project_meta 2>/dev/null || true)"
      if [[ -n "$_lmeta" ]]; then
        _lpid="$(printf '%s' "$_lmeta"   | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')"
        _lcfile="$(printf '%s' "$_lmeta" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("composeFile") or "")')"
        [[ -n "$_lpid" && -n "$_lcfile" && -f "$MARINA_HOME/$_lpid/$_lcfile" ]] && _lstored="$MARINA_HOME/$_lpid/$_lcfile"
      fi
      if [[ ${#SERVICES[@]} -gt 0 ]]; then
        local _ls; for _ls in "${SERVICES[@]}"; do apply_glob_links "$_ls" "$_lstored" "$_lcp"; done
      else
        apply_glob_links "" "$_lstored" "$_lcp"
      fi
      echo "link: 적용 완료 (opt-in 심링크/복제)" ;;
    links-json)
      local svc="${1:-}"
      [[ -n "$svc" ]] || die "links-json: service name required"
      links_json "$svc" "${2:-}" ;;
    gateway)
      # 호스트 브라우저 게이트웨이 caddy 제어 — 설치 사용자도 PATH 의 marina 로 도달(코덱스 P2). marina gateway {start|stop|status|install|uninstall}
      exec bash "$SCRIPT_DIR/marina-gateway-control.sh" "$@" ;;
    worktree)
      # 브랜치명 지정 워크트리 생성(= 작업 시작) — git worktree + 서브레포 attach(브랜치 전체 미러).
      # Claude 자동 워크트리는 claude/<id> 라, feature/{task} 등 원하는 이름으로 만들 때 사용.
      case "${1:-}" in
        create|new|add) shift; worktree_create "$@" ;;
        ""|-h|--help) echo "usage: marina worktree create <branch> [base]" >&2; exit 2 ;;
        *) die "worktree: 미지원 하위명령 '${1}' — create <branch> [base]" ;;
      esac ;;
    -h|--help|help)
      usage ;;
    *)
      die "unknown command: $command" ;;
  esac
}

main "$@"
