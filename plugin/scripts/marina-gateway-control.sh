#!/usr/bin/env bash
# marina 게이트웨이 caddy 호스트 프로세스 제어. nohup 기본(개발), :80 은 시스템 데몬(install).
set -euo pipefail
MARINA_HOME="${MARINA_HOME:-$HOME/.marina}"
GW_DIR="$MARINA_HOME/gateway"; CFG="$GW_DIR/Caddyfile"; PID="$GW_DIR/caddy.pid"; LOG="$GW_DIR/caddy.log"
if [[ -n "${MARINA_GATEWAY_PORT:-}" ]]; then
  PORT="$MARINA_GATEWAY_PORT"
elif [[ -s "$GW_DIR/port" ]]; then
  PORT="$(cat "$GW_DIR/port")"
else
  PORT=3902
fi
ADMIN="${MARINA_GATEWAY_ADMIN:-localhost:2021}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/marina-gateway.py"
LOCK_FILE="$GW_DIR/control.flock"
mkdir -p "$GW_DIR"

case "${1:-}" in
  start|stop)
    if [[ "${MARINA_GATEWAY_LOCKED:-0}" != 1 ]]; then
      exec python3 - "$LOCK_FILE" "$0" "$@" <<'PY'
import fcntl, os, subprocess, sys

lock_path, script, *args = sys.argv[1:]
with open(lock_path, "a+") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    fd = lock.fileno()
    env = dict(os.environ, MARINA_GATEWAY_LOCKED="1", MARINA_GATEWAY_LOCK_FD=str(fd))
    raise SystemExit(subprocess.run(["bash", script, *args], env=env, pass_fds=(fd,)).returncode)
PY
    fi ;;
esac

caddy_bin() {   # 데몬 최소 PATH 엔 homebrew 등이 없어 command -v 가 놓침 → 흔한 위치 폴백
  command -v caddy 2>/dev/null && return 0
  local c; for c in "$HOME/.local/bin/caddy" /opt/homebrew/bin/caddy /usr/local/bin/caddy; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done; true
}

ensure_config() { [[ -f "$CFG" ]] || printf '{\n    admin %s\n    auto_https off\n}\n' "$ADMIN" > "$CFG"; }

pid_alive() {
  [[ -s "$PID" ]] || return 1
  local p
  p="$(cat "$PID")"; [[ "$p" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$p" 2>/dev/null
}

gw_process() {
  pid_alive || return 1
  local p comm i
  p="$(cat "$PID")"
  for i in $(seq 1 10); do
    comm="$(ps -p "$p" -o comm= 2>/dev/null || true)"
    [[ "$comm" == *caddy* ]] && return 0
    kill -0 "$p" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

socket_ready() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import socket, sys
address = sys.argv[1]
host, port = address.rsplit(":", 1)
host = host.strip("[]")
with socket.create_connection((host, int(port)), timeout=.25):
    pass
PY
}

admin_ready() { socket_ready "$ADMIN"; }
gateway_ready() { MARINA_GATEWAY_ADMIN="$ADMIN" python3 "$GW" health --port "$PORT" >/dev/null 2>&1; }
config_has_sites() { grep -qE '^http://.*\{$' "$CFG" 2>/dev/null; }
expected_ready() { admin_ready && { ! config_has_sites || gateway_ready; }; }
wait_ready() {
  local i
  for i in $(seq 1 50); do expected_ready && return 0; pid_alive || return 1; sleep 0.1; done
  return 1
}

wait_pid_exit() {
  local p="$1" i
  for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

case "${1:-}" in
  start)
    cb="$(caddy_bin)"; [[ -n "$cb" ]] || { echo "caddy 미설치 — 'brew install caddy'(mac) 또는 'apt install caddy'(linux) 후 다시. 게이트웨이 없이 나머지 marina 는 정상." >&2; exit 3; }
    ensure_config
    MARINA_GATEWAY_ADMIN="$ADMIN" python3 "$GW" sync-admin --config "$CFG"
    if gw_process; then
      if expected_ready; then
        echo "이미 실행 중 (pid $(cat "$PID"), :$PORT, admin $ADMIN)"; exit 0
      fi
      if admin_ready && "$cb" reload --config "$CFG" --adapter caddyfile --address "$ADMIN" >/dev/null 2>&1 && wait_ready; then
        echo "게이트웨이 복구 (pid $(cat "$PID"), :$PORT, admin $ADMIN)"; exit 0
      fi
      old_pid="$(cat "$PID")"
      kill "$old_pid" 2>/dev/null || true
      if ! wait_pid_exit "$old_pid"; then
        echo "기존 게이트웨이 종료 대기 초과 (pid $old_pid)" >&2
        exit 2
      fi
      rm -f "$PID"
    fi
    if [[ "${MARINA_GATEWAY_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
      (
        eval "exec ${MARINA_GATEWAY_LOCK_FD}>&-"
        exec nohup "$cb" run --config "$CFG" --adapter caddyfile
      ) >>"$LOG" 2>&1 &
    else
      nohup "$cb" run --config "$CFG" --adapter caddyfile >>"$LOG" 2>&1 &
    fi
    caddy_pid=$!; echo "$caddy_pid" > "$PID"
    if wait_ready; then
      echo "게이트웨이 기동 (pid $caddy_pid, :$PORT, admin $ADMIN)"
    else
      echo "게이트웨이 기동 실패 — admin/리스너 미준비 (pid $caddy_pid, :$PORT, admin $ADMIN, log $LOG)" >&2
      gw_process || rm -f "$PID"
      exit 2
    fi ;;
  stop)
    if gw_process; then
      old_pid="$(cat "$PID")"; kill "$old_pid" 2>/dev/null || true
      if wait_pid_exit "$old_pid"; then rm -f "$PID"; echo "게이트웨이 정지"
      else echo "게이트웨이 종료 대기 초과 (pid $old_pid)" >&2; exit 2
      fi
    else rm -f "$PID"; echo "실행 중 아님"; fi ;;
  status)
    if ! gw_process; then
      echo "stopped"
    elif ! admin_ready; then
      echo "degraded pid=$(cat "$PID") port=$PORT admin=$ADMIN reason=admin-unreachable"; exit 2
    elif config_has_sites && ! gateway_ready; then
      echo "degraded pid=$(cat "$PID") port=$PORT admin=$ADMIN reason=listener-missing"; exit 2
    else
      echo "running pid=$(cat "$PID") port=$PORT admin=$ADMIN"
    fi ;;
  config)                                   # 유효 라우팅 + CORS 쌍 노출(관측 — CORS 블랙박스 방지)
    snap="$(python3 -c 'import sys,json; sys.path.insert(0,sys.argv[1]); import marina_lifecycle as ml; print(json.dumps(ml._gateway_snapshot()))' "$HERE" 2>/dev/null)" \
      || { echo "스냅샷 생성 실패(marina 환경 필요)" >&2; exit 1; }
    printf '%s' "$snap" | python3 "$GW" config --port "$PORT" ;;
  install)
    cb="$(caddy_bin)"; [[ -n "$cb" ]] || { echo "caddy 먼저 설치" >&2; exit 3; }
    ensure_config
    case "$(uname -s)" in
      Darwin)
        PL=/Library/LaunchDaemons/com.marina.gateway.plist
        cat <<PLIST | sudo tee "$PL" >/dev/null
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.marina.gateway</string>
  <key>ProgramArguments</key><array><string>$cb</string><string>run</string><string>--config</string><string>$CFG</string><string>--adapter</string><string>caddyfile</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$LOG</string><key>StandardOutPath</key><string>$LOG</string>
</dict></plist>
PLIST
        sudo launchctl bootstrap system "$PL" 2>/dev/null || sudo launchctl load "$PL"
        echo "게이트웨이 시스템 데몬 설치(:80, root). 끄기: $0 uninstall" ;;
      Linux)
        if sudo setcap cap_net_bind_service=+ep "$cb" 2>/dev/null; then
          MARINA_GATEWAY_PORT="$PORT" bash "$0" start
          echo "게이트웨이: caddy 에 cap_net_bind_service 부여 + 기동(:$PORT). 끄기: $0 uninstall"
        else
          echo "Linux :80 설치 실패(권한) — 수동: sudo setcap cap_net_bind_service=+ep $cb && $0 start (또는 systemd system unit WantedBy=multi-user.target)." >&2
          exit 2
        fi ;;
    esac ;;
  uninstall)
    case "$(uname -s)" in
      Darwin) sudo launchctl bootout system/com.marina.gateway 2>/dev/null || sudo launchctl unload /Library/LaunchDaemons/com.marina.gateway.plist 2>/dev/null || true; sudo rm -f /Library/LaunchDaemons/com.marina.gateway.plist; echo "제거" ;;
      Linux)
        bash "$0" stop >/dev/null 2>&1 || true
        sudo setcap -r "$(caddy_bin)" 2>/dev/null || echo "참고: cap 제거 실패(이미 없거나 권한) — 수동: sudo setcap -r $(caddy_bin)" >&2
        echo "게이트웨이 정지 + cap_net_bind_service 제거. (systemd unit 썼으면: sudo systemctl disable --now marina-gateway)" ;;
    esac ;;
  *) echo "usage: marina-gateway-control.sh {start|stop|status|config|install|uninstall}" >&2; exit 1 ;;
esac
