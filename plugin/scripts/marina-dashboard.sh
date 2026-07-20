#!/usr/bin/env bash
# marina-dashboard.sh — 전역 관제 대시보드 런처.
# 등록된(~/.marina/projects.json) 모든 프로젝트의 worktree 를 한 데몬(:3900)이 관리한다.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MARINA_HOME="${MARINA_HOME:-$HOME/.marina}"
PROJECTS_FILE="$MARINA_HOME/projects.json"

# 스크립트는 형제 — 위치독립 (구 $ROOT/shared/skills/... 가정 제거)
ATTACH_SCRIPT="$SCRIPT_DIR/attach-detached-subrepos.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/marina-resolve.sh"
# 전역 단일 데몬 — 런타임 데이터(pid/log/plist)는 worktree 가 아니라 ~/.marina 에 둔다.
DASHBOARD_DIR="$MARINA_HOME"
PID_FILE="$DASHBOARD_DIR/dashboard.pid"
LOG_FILE="$DASHBOARD_DIR/dashboard.log"
LABEL="marina.dashboard"
PLIST_FILE="$DASHBOARD_DIR/$LABEL.plist"
LAUNCHER="$DASHBOARD_DIR/dashboard-launch.sh"
SYSTEMD_UNIT_DIR="$HOME/.config/systemd/user"
SYSTEMD_UNIT="$SYSTEMD_UNIT_DIR/marina-dashboard.service"
BIND_FILE="$DASHBOARD_DIR/dashboard-bind.env"

persisted_control_value() {
  local key="$1" value=""
  if [[ -f "$BIND_FILE" ]]; then
    value="$(sed -n "s/^${key}=//p" "$BIND_FILE" | tail -n 1)"
  fi
  if [[ -z "$value" && -f "$PLIST_FILE" ]]; then
    value="$(awk -v marker="<key>${key}</key>" '
      index($0, marker) { getline; gsub(/^.*<string>|<\/string>.*$/, ""); print; exit }
    ' "$PLIST_FILE")"
  fi
  if [[ -z "$value" && -f "$SYSTEMD_UNIT" ]]; then
    value="$(sed -n "s/^Environment=${key}=//p" "$SYSTEMD_UNIT" | tail -n 1)"
  fi
  printf '%s' "$value"
}

HOST="${MARINA_CONTROL_HOST:-$(persisted_control_value MARINA_CONTROL_HOST)}"
PORT="${MARINA_CONTROL_PORT:-$(persisted_control_value MARINA_CONTROL_PORT)}"
HOST="${HOST:-localhost}"
PORT="${PORT:-3900}"
CODEX_WORKTREES_ROOT="${CODEX_WORKTREES_ROOT:-$HOME/.codex/worktrees}"
MARINA_GATEWAY="${MARINA_GATEWAY:-}"            # 게이트웨이 옵트인(빈=off) — supervised 기동에도 전파(코덱스 P2)
MARINA_GATEWAY_PORT="${MARINA_GATEWAY_PORT:-3902}"   # 비특권 기본(권한·:80 충돌 회피, marina_state 와 일치) — 빈 문자열 export 로 데몬 int('') 크래시 방지(코덱스 P1)
MARINA_GATEWAY_ADMIN="${MARINA_GATEWAY_ADMIN:-localhost:2021}"
MARINA_GATEWAY_POLL="${MARINA_GATEWAY_POLL:-5}"

usage() {
  cat <<'EOF'
usage:
  marina-dashboard.sh start
  marina-dashboard.sh stop
  marina-dashboard.sh restart
  marina-dashboard.sh status
  marina-dashboard.sh logs
EOF
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE")"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

listener_pids() {
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true
}

prepare_known_worktrees() {
  # 등록된 모든 프로젝트(레지스트리)의 worktree 에 서브레포 attach (best-effort).
  [[ -x "$ATTACH_SCRIPT" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "$PROJECTS_FILE" ]] || return 0
  local src dest
  while IFS=$'\t' read -r src dest; do
    [[ -n "$dest" ]] || continue
    SOURCE_ROOT="$src" DEST_ROOT="$dest" SYNC_IDEA="${SYNC_IDEA:-false}" "$ATTACH_SCRIPT" >/dev/null 2>&1 || \
      echo "warn: worktree prepare failed: $dest" >&2
  done < <(python3 - "$PROJECTS_FILE" <<'PY'
import glob, json, os, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
for p in data.get("projects", []):
    root = os.path.realpath(os.path.expanduser(p.get("root", "")))
    for pat in p.get("worktreeGlobs", []):
        pat = os.path.expanduser(pat)
        if not os.path.isabs(pat):
            pat = os.path.join(root, pat)
        for m in glob.glob(pat):
            if os.path.isdir(m) and os.path.exists(os.path.join(m, ".git")):
                print(f"{root}\t{os.path.realpath(m)}")
PY
  )
}

use_launchctl() {
  [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1
}

launchctl_domain() {
  echo "gui/$(id -u)"
}

write_plist() {
  cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$LAUNCHER</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MARINA_CONTROL_HOST</key>
    <string>$HOST</string>
    <key>MARINA_CONTROL_PORT</key>
    <string>$PORT</string>
    <key>CODEX_WORKTREES_ROOT</key>
    <string>$CODEX_WORKTREES_ROOT</string>
    <key>MARINA_HOME</key>
    <string>$MARINA_HOME</string>
    <key>PYTHONUNBUFFERED</key>
    <string>1</string>
    <key>MARINA_GATEWAY</key>
    <string>$MARINA_GATEWAY</string>
    <key>MARINA_GATEWAY_PORT</key>
    <string>$MARINA_GATEWAY_PORT</string>
    <key>MARINA_GATEWAY_ADMIN</key>
    <string>$MARINA_GATEWAY_ADMIN</string>
    <key>MARINA_GATEWAY_POLL</key>
    <string>$MARINA_GATEWAY_POLL</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$LOG_FILE</string>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF
}

write_launcher() { marina_emit_launcher "$LAUNCHER" dashboard; }

persist_bind() {
  local tmp="$BIND_FILE.tmp.$$"
  umask 077
  printf 'MARINA_CONTROL_HOST=%s\nMARINA_CONTROL_PORT=%s\n' "$HOST" "$PORT" > "$tmp"
  mv "$tmp" "$BIND_FILE"
}

supervisor() {
  if [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
    echo launchd
  elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    echo systemd
  else
    echo nohup
  fi
}

write_systemd_unit() {
  mkdir -p "$SYSTEMD_UNIT_DIR"
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=marina dashboard
After=default.target

[Service]
ExecStart=$LAUNCHER
Restart=on-failure
Environment=MARINA_CONTROL_HOST=$HOST
Environment=MARINA_CONTROL_PORT=$PORT
Environment=MARINA_HOME=$MARINA_HOME
Environment=CODEX_WORKTREES_ROOT=$CODEX_WORKTREES_ROOT
Environment=PYTHONUNBUFFERED=1
Environment=MARINA_GATEWAY=$MARINA_GATEWAY
Environment=MARINA_GATEWAY_PORT=$MARINA_GATEWAY_PORT
Environment=MARINA_GATEWAY_ADMIN=$MARINA_GATEWAY_ADMIN
Environment=MARINA_GATEWAY_POLL=$MARINA_GATEWAY_POLL

[Install]
WantedBy=default.target
EOF
}

start_nohup() {
  CODEX_WORKTREES_ROOT="$CODEX_WORKTREES_ROOT" MARINA_HOME="$MARINA_HOME" MARINA_CONTROL_HOST="$HOST" MARINA_CONTROL_PORT="$PORT" MARINA_GATEWAY="$MARINA_GATEWAY" MARINA_GATEWAY_PORT="$MARINA_GATEWAY_PORT" MARINA_GATEWAY_ADMIN="$MARINA_GATEWAY_ADMIN" MARINA_GATEWAY_POLL="$MARINA_GATEWAY_POLL" PYTHONUNBUFFERED=1 nohup "$LAUNCHER" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  echo "dashboard started pid=$(cat "$PID_FILE") url=http://$HOST:$PORT log=$LOG_FILE"
}

start() {
  mkdir -p "$DASHBOARD_DIR"
  write_launcher
  persist_bind
  local sup listeners; sup="$(supervisor)"
  echo "supervisor=$sup"

  if [[ "${MARINA_DRY_RUN:-}" == "1" ]]; then
    case "$sup" in
      launchd) write_plist ;;
      systemd) write_systemd_unit ;;
    esac
    echo "dry-run: wrote launcher + $sup config; not starting"
    return 0
  fi

  prepare_known_worktrees

  if is_running; then
    echo "dashboard already running pid=$(cat "$PID_FILE") url=http://$HOST:$PORT"
    return 0
  fi
  listeners="$(listener_pids | paste -sd, -)"
  if [[ -n "$listeners" ]]; then
    echo "dashboard port already has listener pid=$listeners url=http://$HOST:$PORT"
    return 0
  fi

  { echo; echo "=== dashboard start $(date '+%Y-%m-%d %H:%M:%S') ==="; } >> "$LOG_FILE"

  case "$sup" in
    launchd)
      write_plist
      launchctl bootout "$(launchctl_domain)" "$PLIST_FILE" >/dev/null 2>&1 || true
      if launchctl bootstrap "$(launchctl_domain)" "$PLIST_FILE"; then
        launchctl kickstart -k "$(launchctl_domain)/$LABEL" >/dev/null 2>&1 || true
        sleep 1
        listeners="$(listener_pids | paste -sd, -)"
        if [[ -n "$listeners" ]]; then
          echo "$listeners" | cut -d, -f1 > "$PID_FILE"
          echo "dashboard started pid=$(cat "$PID_FILE") url=http://$HOST:$PORT log=$LOG_FILE"
          return 0
        fi
      fi
      echo "launchctl failed; falling back to nohup" >> "$LOG_FILE"
      start_nohup
      ;;
    systemd)
      write_systemd_unit
      loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      if systemctl --user enable --now marina-dashboard >/dev/null 2>&1; then
        sleep 1
        listeners="$(listener_pids | paste -sd, -)"
        [[ -n "$listeners" ]] && { echo "$listeners" | cut -d, -f1 > "$PID_FILE"; }
        echo "dashboard started (systemd user) url=http://$HOST:$PORT log=$LOG_FILE"
        return 0
      fi
      echo "systemctl failed; falling back to nohup" >> "$LOG_FILE"
      start_nohup
      ;;
    nohup)
      echo "warn: no launchd/systemd available — auto-restart NOT configured" >&2
      start_nohup
      ;;
  esac
}

stop() {
  local pid
  if use_launchctl; then
    [[ -f "$PLIST_FILE" ]] && launchctl bootout "$(launchctl_domain)" "$PLIST_FILE" >/dev/null 2>&1 || true
  fi
  if command -v systemctl >/dev/null 2>&1 && [[ -f "$SYSTEMD_UNIT" ]]; then
    systemctl --user disable --now marina-dashboard >/dev/null 2>&1 || true
  fi
  if is_running; then
    pid="$(cat "$PID_FILE")"
    kill "$pid" 2>/dev/null || true
    echo "dashboard stopped pid=$pid"
  else
    echo "dashboard stopped"
  fi
  for pid in $(listener_pids); do
    kill "$pid" 2>/dev/null || true
  done
  rm -f "$PID_FILE"
}

status() {
  local listeners
  listeners="$(listener_pids | paste -sd, -)"
  if is_running; then
    echo "dashboard running pid=$(cat "$PID_FILE") url=http://$HOST:$PORT log=$LOG_FILE"
  elif [[ -n "$listeners" ]]; then
    echo "dashboard listening pid=$listeners url=http://$HOST:$PORT log=$LOG_FILE"
  else
    echo "dashboard stopped url=http://$HOST:$PORT log=$LOG_FILE"
  fi
}

case "${1:-status}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  logs) tail -n 120 -f "$LOG_FILE" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
