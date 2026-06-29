#!/usr/bin/env bash
# marina-lib-process.sh — marina.sh 에서 분리된 process 함수군 (source 전용, 함수 정의만).
# 동작 변경 0 — marina.sh 에서 이동만. 전역(ROOT/SOURCE_ROOT/MARINA_HOME/SERVICES 등)은 marina.sh 가 설정.

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
