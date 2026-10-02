#!/usr/bin/env bash
# marina-runtimed.sh — 청소 상주 프로그램 런처(분리 A). 게이트웨이 폴링·도커/워크트리 GC·고아 리퍼.
# 대시보드 런처(marina-dashboard.sh)와 같은 감독 방식: 맥 launchd · 리눅스 systemd --user · 없으면 nohup.
#   start | stop | restart | status | ensure(안 떠 있으면 start) | logs
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MARINA_HOME="${MARINA_HOME:-$HOME/.marina}"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/marina-resolve.sh"
PID_FILE="$MARINA_HOME/runtimed.pid"
LOG_FILE="$MARINA_HOME/runtimed.log"
LABEL="marina.runtimed"
PLIST_FILE="$MARINA_HOME/$LABEL.plist"
LOGIN_PLIST_FILE="$HOME/Library/LaunchAgents/$LABEL.plist"
LAUNCHER="$MARINA_HOME/runtimed-launch.sh"
SYSTEMD_UNIT_DIR="$HOME/.config/systemd/user"
SYSTEMD_UNIT="$SYSTEMD_UNIT_DIR/marina-runtimed.service"
DAEMON_PATH="${PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
# 자동 삭제(GC·리퍼)는 실제 홈에서만 — 격리 홈(테스트·프리뷰)은 게이트웨이만
PRIMARY=0; [[ "$MARINA_HOME" == "$HOME/.marina" ]] && PRIMARY=1
ENV_KEYS=(MARINA_GATEWAY MARINA_GATEWAY_PORT MARINA_GATEWAY_ADMIN MARINA_GATEWAY_POLL MARINA_RUNTIMED_NOOP)

supervisor() {
  if [[ -n "${MARINA_RUNTIMED_SUPERVISOR:-}" ]]; then echo "$MARINA_RUNTIMED_SUPERVISOR"
  # 격리 홈(테스트·프리뷰)은 launchd/systemd 라벨을 안 쓴다 — 라벨은 사용자 전역이라 실제 runtimed 를 내릴 수 있다
  elif [[ "$PRIMARY" != 1 ]]; then echo nohup
  elif [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then echo launchd
  elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then echo systemd
  else echo nohup; fi
}
domain() { echo "gui/$(id -u)"; }

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

find_pid() {   # launchd/systemd 가 띄운 것 — 런처가 exec 한 python 의 pid
  pgrep -f "marina_runtimed.py" 2>/dev/null | while read -r p; do
    if [[ "$(ps -o command= -p "$p" 2>/dev/null)" == *marina_runtimed.py* ]] && \
       ps eww -p "$p" 2>/dev/null | grep -q "MARINA_HOME=$MARINA_HOME\( \|$\)"; then echo "$p"; break; fi
  done
}

env_xml() {
  local k
  printf '    <key>PATH</key><string>%s</string>\n    <key>MARINA_HOME</key><string>%s</string>\n    <key>PYTHONUNBUFFERED</key><string>1</string>\n    <key>MARINA_RUNTIMED_PRIMARY</key><string>%s</string>\n' "$DAEMON_PATH" "$MARINA_HOME" "$PRIMARY"
  for k in "${ENV_KEYS[@]}"; do if [[ -n "${!k:-}" ]]; then printf '    <key>%s</key><string>%s</string>\n' "$k" "${!k}"; fi; done
  return 0
}

write_plist() {
  cat > "$PLIST_FILE" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$LAUNCHER</string></array>
  <key>EnvironmentVariables</key>
  <dict>
$(env_xml)
  </dict>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
XML
  # 재부팅 뒤에도 뜨게 — 기본 홈일 때만(테스트·격리 프리뷰가 실제 로그인 항목을 덮지 않게)
  if [[ "$PRIMARY" == 1 ]]; then mkdir -p "$(dirname "$LOGIN_PLIST_FILE")"; cp "$PLIST_FILE" "$LOGIN_PLIST_FILE"; fi
}

write_unit() {
  mkdir -p "$SYSTEMD_UNIT_DIR"
  { echo "[Unit]"; echo "Description=marina runtimed"; echo; echo "[Service]"; echo "ExecStart=$LAUNCHER"; echo "Restart=always"; echo "RestartSec=10"
    echo "Environment=PATH=$DAEMON_PATH"; echo "Environment=MARINA_HOME=$MARINA_HOME"; echo "Environment=PYTHONUNBUFFERED=1"
    echo "Environment=MARINA_RUNTIMED_PRIMARY=$PRIMARY"
    for k in "${ENV_KEYS[@]}"; do if [[ -n "${!k:-}" ]]; then echo "Environment=$k=${!k}"; fi; done
    echo; echo "[Install]"; echo "WantedBy=default.target"; } > "$SYSTEMD_UNIT"
}

start_nohup() {
  MARINA_HOME="$MARINA_HOME" MARINA_RUNTIMED_PRIMARY="$PRIMARY" PYTHONUNBUFFERED=1 nohup "$LAUNCHER" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
}

start() {
  mkdir -p "$MARINA_HOME"
  if is_running; then echo "runtimed already running pid=$(cat "$PID_FILE")"; return 0; fi
  local p; p="$(find_pid || true)"
  if [[ -n "$p" ]]; then echo "$p" > "$PID_FILE"; echo "runtimed already running pid=$p"; return 0; fi
  marina_emit_launcher "$LAUNCHER" runtimed
  { echo; echo "=== runtimed start $(date '+%Y-%m-%d %H:%M:%S') ==="; } >> "$LOG_FILE"
  case "$(supervisor)" in
    launchd)
      write_plist
      launchctl bootout "$(domain)" "$PLIST_FILE" >/dev/null 2>&1 || true
      if launchctl bootstrap "$(domain)" "$PLIST_FILE"; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do p="$(find_pid || true)"; [[ -n "$p" ]] && break; sleep 0.3; done
        [[ -n "$p" ]] && echo "$p" > "$PID_FILE"
      else
        echo "launchctl failed; nohup" >> "$LOG_FILE"; start_nohup
      fi ;;
    systemd)
      write_unit
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      if systemctl --user enable --now marina-runtimed >/dev/null 2>&1; then
        sleep 1; p="$(find_pid || true)"; [[ -n "$p" ]] && echo "$p" > "$PID_FILE"
      else
        echo "systemctl failed; nohup" >> "$LOG_FILE"; start_nohup
      fi ;;
    *) start_nohup ;;
  esac
  echo "runtimed started pid=$(cat "$PID_FILE" 2>/dev/null || echo ?) log=$LOG_FILE"
}

stop() {
  case "$(supervisor)" in
    launchd)
      [[ -f "$PLIST_FILE" ]] && launchctl bootout "$(domain)" "$PLIST_FILE" >/dev/null 2>&1 || true
      [[ "$PRIMARY" == 1 ]] && rm -f "$LOGIN_PLIST_FILE" ;;
    systemd) systemctl --user disable --now marina-runtimed >/dev/null 2>&1 || true ;;
  esac
  local p
  for p in $(cat "$PID_FILE" 2>/dev/null) $(find_pid || true); do kill "$p" 2>/dev/null || true; done
  rm -f "$PID_FILE"
  echo "runtimed stopped"
}

status() {
  if is_running || [[ -n "$(find_pid || true)" ]]; then echo "runtimed running pid=$(cat "$PID_FILE" 2>/dev/null || find_pid)"
  else echo "runtimed stopped"; fi
}

case "${1:-}" in
  start|ensure) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  logs) tail -n "${2:-80}" "$LOG_FILE" ;;
  *) echo "usage: marina-runtimed.sh start|stop|restart|status|ensure|logs" >&2; exit 2 ;;
esac
