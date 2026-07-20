#!/usr/bin/env bash
# marina — 전역 dev 런처 + 관제 대시보드 진입점.
#
#   marina start|stop|restart|rebuild|clean-rebuild <svc..> # 현재 worktree(cwd) 의 서비스 (전체는 --all)
#   marina status | ports | logs [svc]       # 현재 worktree 상태/포트/로그
#   marina project {add|rm|ls|default|infer} # 프로젝트 레지스트리 (~/.marina/projects.json)
#   marina dashboard [start|stop|status|open]# 전역 대시보드(:3900). 무인자 marina = dashboard start
#
# 스크립트는 모두 이 파일의 형제(scripts/) — 어디서 실행하든 위치독립.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SESSION="$SCRIPT_DIR/marina.sh"
DASHBOARD="$SCRIPT_DIR/marina-dashboard.sh"
ATTACH="$SCRIPT_DIR/attach-detached-subrepos.sh"
RESOLVE="$SCRIPT_DIR/marina-resolve.sh"
CLI="$SCRIPT_DIR/marina_cli.py"
# shellcheck source=/dev/null
source "$RESOLVE"

exec_session_with_env() {
  local py="${MARINA_PYTHON:-}"
  [[ -n "$py" ]] || py="$(command -v python3 || echo /usr/bin/python3)"
  exec "$py" "$CLI" exec "$@"
}

usage() {
  cat <<'EOF'
usage (marina = 전역 CLI):
  실행 (현재 worktree — 서비스명 그대로, 전체는 --all):
    marina start|stop|restart|rebuild|clean-rebuild <svc> # 예: marina rebuild web · 전체: marina start --all
    marina status | ports | logs [svc]
  프로젝트 등록 (~/.marina/projects.json — 위치 무관):
    marina project add <path> --compose <file>      # 기존 docker-compose 로 등록 (또는 대시보드 위저드)
    marina project add <path> --external name=path  # 외부 git 레포를 서비스로 (워크트리마다 격리)
    marina project ls | rm <id> | default <id> a,b,c | infer <path>
  워크트리 (작업 시작 — 브랜치명 지정 생성 + 서브레포 미러):
    marina worktree create <branch> [base] [--project <id>]
  게이트웨이 (호스트 브라우저 → <wt>.<proj>.localhost, 보통 start 시 자동 기동):
    marina gateway start|stop|status|config|install|uninstall
  링크 (main checkout 의 deps·빌드산출물·설정을 워크트리로):
    marina link
  dashboard (:3900):
    marina dashboard [start|stop|status|open]    # 무인자 marina = dashboard start
  mobile:
    marina mobile enable|url|address|open|token|rotate|status|doctor|disable [host-or-base-url]
  setup: marina attach | install-cli | uninstall-cli
EOF
}

print_dashboard_url() {
  echo
  echo "Dashboard: http://${MARINA_CONTROL_HOST:-localhost}:${MARINA_CONTROL_PORT:-3900}"
  echo
}

mobile_token_file() { echo "${MARINA_HOME:-$HOME/.marina}/mobile-token"; }

mobile_ensure_token() {
  local f; f="$(mobile_token_file)"
  mkdir -p "$(dirname "$f")"
  if [[ -s "$f" ]]; then
    head -n 1 "$f"
    return
  fi
  "${MARINA_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}" - <<'PY' > "$f"
import secrets
print(secrets.token_urlsafe(32))
PY
  chmod 600 "$f" 2>/dev/null || true
  head -n 1 "$f"
}

mobile_rotate_token() {
  local f; f="$(mobile_token_file)"
  mkdir -p "$(dirname "$f")"
  "${MARINA_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}" - <<'PY' > "$f"
import secrets
print(secrets.token_urlsafe(32))
PY
  chmod 600 "$f" 2>/dev/null || true
  head -n 1 "$f"
}

mobile_detect_host() {
  if [[ -n "${MARINA_MOBILE_HOST:-}" ]]; then
    echo "$MARINA_MOBILE_HOST"
    return
  fi
  local host="${MARINA_CONTROL_HOST:-localhost}" guess
  case "$host" in
    localhost|127.*|::1|0.0.0.0|::|"")
      if command -v tailscale >/dev/null 2>&1; then
        guess="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
        [[ -n "$guess" ]] && { echo "$guess"; return; }
      fi
      guess="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
      echo "${guess:-localhost}"
      ;;
    *)
      echo "$host"
      ;;
  esac
}

mobile_base_url() {
  local host="${1:-}" port
  [[ -n "$host" ]] || host="$(mobile_detect_host)"
  if [[ "$host" == *"://"* ]]; then
    host="${host%/}"
    host="${host%/mobile}"
    echo "${host%/}"
  else
    port="${MARINA_CONTROL_PORT:-3900}"
    echo "http://$host:$port"
  fi
}

mobile_print_address() {
  echo "$(mobile_base_url "${1:-}")/mobile"
}

mobile_print_url() {
  local token
  token="$(mobile_ensure_token)"
  echo "$(mobile_print_address "${1:-}")?token=$token"
}

mobile_access_hint() {
  local host="${MARINA_CONTROL_HOST:-localhost}" port="${MARINA_CONTROL_PORT:-3900}"
  case "$host" in
    localhost|127.*|::1)
      echo "phone access: local-only dashboard bind ($host:$port). Use Tailscale/tunnel, or restart dashboard with MARINA_CONTROL_HOST=0.0.0.0 on a trusted network."
      ;;
    0.0.0.0|::|"")
      echo "phone access: network-bind dashboard ($host:$port). Keep it behind Tailscale/VPN/tunnel or a trusted network; only /mobile accepts the mobile token remotely."
      ;;
    *)
      echo "phone access: custom dashboard host ($host:$port). Make sure the phone can resolve and reach that host; prefer Tailscale/VPN/tunnel."
      ;;
  esac
}

mobile_print_status() {
  local host="${1:-}" f
  f="$(mobile_token_file)"
  if [[ -s "$f" ]]; then
    echo "mobile enabled token=$f"
    echo "address=$(mobile_print_address "$host")"
    echo "login-url=$(mobile_print_url "$host")"
    mobile_access_hint
  else
    echo "mobile disabled"
    echo "address=$(mobile_print_address "$host")"
    mobile_access_hint
  fi
}

mobile_probe_dashboard() {
  local host="${MARINA_CONTROL_HOST:-localhost}" port="${MARINA_CONTROL_PORT:-3900}" base code
  case "$host" in
    0.0.0.0|::|"") host="127.0.0.1" ;;
  esac
  base="http://$host:$port"
  if ! command -v curl >/dev/null 2>&1; then
    echo "dashboard-http=unknown reason=curl-missing url=$base/mobile"
    return
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "$base/mobile" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    echo "dashboard-http=ok url=$base/mobile"
  else
    echo "dashboard-http=fail status=${code:-000} url=$base/mobile"
  fi
}

command="${1:-dashboard}"
shift || true

case "$command" in
  project|worktree|gateway|link)
    # 그룹 → marina.sh dispatch 로 위임 (project {add|rm|ls|...} · worktree create · gateway {start|...} · link)
    # worktree/gateway 누락이 "설치 shim 은 이 명령 없음" 증상의 원인이었음(도그푸드에서 발견)
    "$SESSION" "$command" "$@"
    ;;
  start|stop|restart|rebuild|clean-rebuild)
    # bare 서비스명(web)을 marina.sh 가 받는 --flag 로 변환. 이미 --(--all 등)는 그대로 패스.
    # 무인자는 변환 결과도 빈 인자 → marina.sh 무인자 가드(usage·exit 2)에 위임.
    lifecycle_args=()
    for arg in "$@"; do
      case "$arg" in
        --*) lifecycle_args+=("$arg") ;;
        *)   lifecycle_args+=("--$arg") ;;
      esac
    done
    exec_session_with_env "$command" ${lifecycle_args[@]+"${lifecycle_args[@]}"}
    ;;
  status|ports|logs)
    # 변환 불요(단일/무인자)
    exec_session_with_env "$command" "$@"
    ;;
  dashboard)
    case "${1:-start}" in
      start|"") "$DASHBOARD" start; print_dashboard_url ;;
      stop)     "$DASHBOARD" stop ;;
      status)   "$DASHBOARD" status ;;
      open)     shift; exec "$0" open ;;
      *) echo "usage: marina dashboard {start|stop|status|open}" >&2; exit 2 ;;
    esac
    ;;
  mobile)
    case "${1:-url}" in
      enable)
        shift || true
        url="$(mobile_print_url "${1:-}")"
        echo "mobile enabled"
        echo "$url"
        echo
        mobile_access_hint
        ;;
      url|"")
        shift || true
        mobile_print_url "${1:-}"
        ;;
      address)
        shift || true
        mobile_print_address "${1:-}"
        ;;
      open)
        shift || true
        url="$(mobile_print_address "${1:-}")"
        if command -v open >/dev/null 2>&1; then open "$url"
        elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url"
        else echo "$url"
        fi
        ;;
      token)
        mobile_ensure_token
        ;;
      rotate)
        shift || true
        new_token="$(mobile_rotate_token)"
        echo "mobile token rotated"
        echo "token=$new_token"
        mobile_print_url "${1:-}"
        echo
        mobile_access_hint
        ;;
      status)
        shift || true
        mobile_print_status "${1:-}"
        ;;
      doctor)
        shift || true
        echo "mobile doctor"
        mobile_print_status "${1:-}"
        mobile_probe_dashboard
        ;;
      disable)
        rm -f "$(mobile_token_file)"
        echo "mobile disabled"
        ;;
      *) echo "usage: marina mobile {enable|url|address|open|token|rotate|status|doctor|disable} [host-or-base-url]" >&2; exit 2 ;;
    esac
    ;;
  open)
    url="http://${MARINA_CONTROL_HOST:-localhost}:${MARINA_CONTROL_PORT:-3900}"
    if command -v open >/dev/null 2>&1; then open "$url"        # macOS
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url"  # Linux
    else echo "$url"
    fi
    ;;
  attach|prepare)
    "$ATTACH"
    ;;
  -h|--help|help)
    usage
    ;;
  install-cli)
    bindir="${MARINA_BIN_DIR:-$HOME/.local/bin}"; target="$bindir/marina"
    if [[ -e "$target" ]] && ! grep -q 'AUTO-GENERATED by marina' "$target" 2>/dev/null && [[ "${1:-}" != "--force" ]]; then
      echo "error: $target exists and is not a marina shim (use --force)" >&2; exit 1
    fi
    marina_emit_launcher "$target" entrypoint
    echo "installed: $target"
    case ":$PATH:" in
      *":$bindir:"*) : ;;
      *) echo; echo "note: $bindir is not on PATH. Add:"; echo "  export PATH=\"$bindir:\$PATH\"" ;;
    esac
    ;;
  uninstall-cli)
    target="${MARINA_BIN_DIR:-$HOME/.local/bin}/marina"
    if [[ -e "$target" ]] && grep -q 'AUTO-GENERATED by marina' "$target" 2>/dev/null; then
      rm -f "$target"; echo "removed: $target"
    else
      echo "nothing to remove (not a marina shim): $target"
    fi
    ;;
  *)
    echo "error: unknown command: $command" >&2
    usage >&2
    exit 1
    ;;
esac
