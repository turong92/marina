#!/usr/bin/env bash
# marina 게이트웨이 caddy 호스트 프로세스 제어. nohup 기본(개발), :80 은 시스템 데몬(install).
set -euo pipefail
MARINA_HOME="${MARINA_HOME:-$HOME/.marina}"
GW_DIR="$MARINA_HOME/gateway"; CFG="$GW_DIR/Caddyfile"; PID="$GW_DIR/caddy.pid"; LOG="$GW_DIR/caddy.log"
PORT="${MARINA_GATEWAY_PORT:-3902}"   # 비특권 기본(권한·:80 충돌 회피) — marina_state 와 일치
mkdir -p "$GW_DIR"

caddy_bin() {   # 데몬 최소 PATH 엔 homebrew 등이 없어 command -v 가 놓침 → 흔한 위치 폴백
  command -v caddy 2>/dev/null && return 0
  local c; for c in "$HOME/.local/bin/caddy" /opt/homebrew/bin/caddy /usr/local/bin/caddy; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done; true
}

ensure_config() { [[ -f "$CFG" ]] || printf '{\n    admin localhost:2021\n    auto_https off\n}\n' > "$CFG"; }   # marina 전용 admin(코덱스 P2)

gw_running() { [[ -f "$PID" ]] && kill -0 "$(cat "$PID")" 2>/dev/null; }

case "${1:-}" in
  start)
    cb="$(caddy_bin)"; [[ -n "$cb" ]] || { echo "caddy 미설치 — 'brew install caddy'(mac) 또는 'apt install caddy'(linux) 후 다시. 게이트웨이 없이 나머지 marina 는 정상." >&2; exit 3; }
    gw_running && { echo "이미 실행 중 (pid $(cat "$PID"))"; exit 0; }
    ensure_config
    nohup "$cb" run --config "$CFG" --adapter caddyfile >>"$LOG" 2>&1 &
    echo $! > "$PID"; echo "게이트웨이 기동 (pid $!, :$PORT, admin :2019)" ;;
  stop)
    if gw_running; then kill "$(cat "$PID")" 2>/dev/null || true; rm -f "$PID"; echo "게이트웨이 정지"; else echo "실행 중 아님"; fi ;;
  status)
    if gw_running; then echo "running pid=$(cat "$PID") port=$PORT"; else echo "stopped"; fi ;;
  config)                                   # 유효 라우팅 + CORS 쌍 노출(관측 — CORS 블랙박스 방지)
    HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    snap="$(python3 -c 'import sys,json; sys.path.insert(0,sys.argv[1]); import marina_lifecycle as ml; print(json.dumps(ml._gateway_snapshot()))' "$HERE" 2>/dev/null)" \
      || { echo "스냅샷 생성 실패(marina 환경 필요)" >&2; exit 1; }
    printf '%s' "$snap" | python3 "$HERE/marina-gateway.py" config --port "$PORT" ;;
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
