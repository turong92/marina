#!/usr/bin/env bash
# live 스택의 부팅 지속성 유닛 설치/제거.
#
# marina-dashboard.sh 와 같은 방식이다 — `launchctl bootstrap` 은 이번 로그인 세션에만
# 등록되므로 ~/Library/LaunchAgents 에도 써서 재부팅을 넘긴다. Linux 는 systemd user unit
# + `loginctl enable-linger`(없으면 로그아웃과 함께 죽는다).
#
# **등록은 MARINA_HOME 이 실제 ~/.marina 일 때만 한다** — marina-dashboard.sh 의
# install_login_plist 와 같은 가드다. 테스트가 형의 기계에 launchd 잡을 심는 것을 막는다.
#
# 유닛 설치 실패는 기동을 되돌리지 않는다(지금 돌고 있는 것이 더 중요하다). 대신
# `marina live status` 가 "재부팅 후 자동 기동: 안 됨" 을 계속 보여준다.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ACTION="${1:-}"
PROJECT="${2:-}"
[[ -n "$ACTION" && -n "$PROJECT" ]] || { echo "usage: marina-live-unit.sh install|uninstall|status <프로젝트>" >&2; exit 2; }
case "$ACTION" in install|uninstall|status) ;; *) echo "usage: marina-live-unit.sh install|uninstall|status <프로젝트>" >&2; exit 2 ;; esac

MARINA_HOME="${MARINA_HOME:-$HOME/.marina}"
export MARINA_HOME
MARINA_BIN="${MARINA_BIN:-$(command -v marina || echo "$SCRIPT_DIR/marina-entrypoint.sh")}"

# 경로·라벨·내용은 marina_live.py 가 한 곳에서 정한다
# shlex.quote 로 인용해서 내보낸다 — MARINA_HOME 경로에 공백이 있으면 인용 없는 eval 이
# 값을 쪼개 엉뚱한 경로에 유닛을 쓰려 한다(실측: "줄 25: space/ovation/live/unit.plist").
eval "$(PYTHONPATH="$SCRIPT_DIR" python3 - "$PROJECT" <<'PY'
import shlex, sys
import marina_live as L
pid = sys.argv[1]
try:
    print("UNIT=%s" % shlex.quote(str(L.unit_path(pid))))
    print("LABEL=%s" % shlex.quote(L.unit_label(pid)))
    print("ROOT=%s" % shlex.quote(str(L.live_root(pid))))
except L.LiveConfigError as exc:
    print("echo %s >&2; exit 2" % shlex.quote(str(exc)))
PY
)"
# eval 이 아무것도 못 받으면(import 실패·읽을 수 없는 MARINA_HOME 등) set -u 가
# "$UNIT: unbound variable" 로 죽어 원인을 가리키지 못한다 — 여기서 분명히 말한다.
: "${UNIT:?live 유닛 경로를 계산하지 못했다 — MARINA_HOME($MARINA_HOME) 과 프로젝트 id($PROJECT) 를 확인해라}"
: "${LABEL:?live 유닛 라벨을 계산하지 못했다}"

# 실제 홈이 아니면 기계에 등록하지 않는다 (테스트 격리)
REGISTER=0
[[ "$MARINA_HOME" == "$HOME/.marina" ]] && REGISTER=1

write_unit() {
  PYTHONPATH="$SCRIPT_DIR" python3 - "$PROJECT" "$MARINA_BIN" <<'PY'
import sys
import marina_live as L
L.write_unit(sys.argv[1], sys.argv[2])
PY
}

case "$ACTION" in
  install)
    write_unit
    if [[ "$REGISTER" != "1" ]]; then
      echo "자동 기동 유닛 작성: $UNIT (MARINA_HOME 이 ~/.marina 가 아니라 기계 등록 생략)"
      exit 0
    fi
    if [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
      mkdir -p "$HOME/Library/LaunchAgents"
      cp "$UNIT" "$HOME/Library/LaunchAgents/$LABEL.plist"
      launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
      if ! launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist"; then
        # 비0으로 끝낸다 — 호출부(cmd_up)가 이 경고를 사용자에게 흘려야 한다.
        # exit 0 이면 경고가 캡처된 채 조용히 버려지고, status 도 거짓으로 '등록됨' 이 된다.
        echo "경고: launchd 등록 실패 — 지금 돌고 있는 것은 유지된다. 재부팅 후 자동 기동은 안 된다." >&2
        exit 1
      fi
    elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
      mkdir -p "$HOME/.config/systemd/user"
      cp "$UNIT" "$HOME/.config/systemd/user/$LABEL.service"
      loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      if ! systemctl --user enable "$LABEL.service" >/dev/null 2>&1; then
        echo "경고: systemd 등록 실패 — 재부팅 후 자동 기동은 안 된다." >&2
        exit 1
      fi
    else
      echo "경고: launchd·systemd 가 없다 — 재부팅 후 자동 기동은 안 된다." >&2
      exit 1
    fi
    echo "자동 기동 등록: $LABEL"
    ;;
  uninstall)
    if [[ "$REGISTER" == "1" ]]; then
      if [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
      elif command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now "$LABEL.service" >/dev/null 2>&1 || true
        rm -f "$HOME/.config/systemd/user/$LABEL.service"
      fi
    fi
    rm -f "$UNIT"
    echo "자동 기동 해제: $LABEL"
    ;;
  status)
    # **유닛 파일 존재로 판정하지 않는다** — 그 파일은 marina 가 방금 썼고, 그 뒤의
    # launchctl/systemctl 등록이 실패해도 남는다. 감독자에게 직접 묻는다.
    PYTHONPATH="$SCRIPT_DIR" python3 - "$PROJECT" <<'PY'
import sys
import marina_live as L
st = L.autostart_state(sys.argv[1])
if st["registered"]:
    print("자동 기동: 등록됨 (%s, %s)" % (st["how"], st["detail"]))
else:
    print("자동 기동: 안 됨 — %s" % (st["detail"] or "등록되지 않았다"))
PY
    ;;
esac
