#!/usr/bin/env bash
# 대시보드 "꺼 둠" 표시: `marina dashboard off`(= stop + 표시)가 <MARINA_HOME>/dashboard-off 를 만든다.
# `marina dashboard stop` 은 원래대로(표시 안 만듦 — 팀원 동작 불변). `on`(= 표시 삭제 + start)·명시적 start|restart 가 표시를 지운다.
# 표시가 있으면 인자 없는 marina·marina remote serve|funnel 의 사후 restart 가 대시보드를 안 띄운다.
# 표시가 없으면 기존 동작 그대로. 실 대시보드·launchctl·~/.marina 는 안 건드린다(가짜 기동 스크립트 + 격리 MARINA_HOME).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/marina-dashoff.XXXXXX")"
trap 'rm -rf "${TMP:?}"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# 진입점 사본 + 가짜 기동 스크립트(부른 인자만 기록)
mkdir -p "$TMP/scripts"
cp "$HERE/../scripts/marina-entrypoint.sh" "$HERE/../scripts/marina-resolve.sh" "$TMP/scripts/"
cat > "$TMP/scripts/marina-dashboard.sh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$TMP/dash-calls"
SH
chmod +x "$TMP/scripts/marina-dashboard.sh"
EP="$TMP/scripts/marina-entrypoint.sh"
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
export HOME="$TMP/fakehome"; mkdir -p "$HOME"
: > "$TMP/dash-calls"
calls() { cat "$TMP/dash-calls"; }
reset() { : > "$TMP/dash-calls"; }
MARK="$MARINA_HOME/dashboard-off"

# 1) 표시 없음 = 기존 동작: 무인자 marina 는 start
bash "$EP" >/dev/null 2>&1 || true
[[ "$(calls)" == "start" ]] || fail "표시 없을 때 bare marina 는 dashboard start: [$(calls)]"
reset

# 2) stop 은 원래대로 — 표시를 안 만든다
bash "$EP" dashboard stop >/dev/null 2>&1
[[ ! -e "$MARK" ]] || fail "dashboard stop 이 표시를 만들었다(팀원 동작 변경)"
[[ "$(calls)" == "stop" ]] || fail "stop 은 기동 스크립트 stop 을 불러야: [$(calls)]"
reset

# 2b) off = stop + 표시
bash "$EP" dashboard off >/dev/null 2>&1
[[ -e "$MARK" ]] || fail "dashboard off 가 표시를 안 만듦"
[[ "$(calls)" == "stop" ]] || fail "off 는 기동 스크립트 stop 을 불러야: [$(calls)]"
reset

# 3) 표시 있음: bare marina(빈 인자 하나 포함)는 기동 스크립트를 안 부르고 안내 + 종료 코드 0
for variant in "" "empty"; do
  if [[ -z "$variant" ]]; then out="$(bash "$EP" 2>&1)" || fail "표시 있을 때 bare marina 종료 코드 != 0"
  else out="$(bash "$EP" "" 2>&1)" || fail "표시 있을 때 marina '' 종료 코드 != 0"; fi
  [[ -z "$(calls)" ]] || fail "표시 있을 때 bare marina($variant)가 기동 스크립트를 불렀다: [$(calls)]"
  echo "$out" | grep -q "대시보드는 꺼 둠 — 켜려면 marina dashboard start" || fail "안내 문구 없음($variant): $out"
  echo "$out" | grep -q "usage" || fail "평소 도움말이 없음($variant): $out"
  [[ -e "$MARK" ]] || fail "bare marina($variant)가 표시를 지웠다"
done

# 4) 표시 있어도 status 는 그대로 통과(읽기 전용), 표시 유지
bash "$EP" dashboard status >/dev/null 2>&1
[[ "$(calls)" == "status" && -e "$MARK" ]] || fail "status 는 표시와 무관: [$(calls)]"
reset

# 4b) 표시가 있는 상태의 `marina dashboard`(하위명령 없음 = 사람이 친 명시적 호출)는 평소대로 start + 표시 삭제
bash "$EP" dashboard >/dev/null 2>&1
[[ "$(calls)" == "start" && ! -e "$MARK" ]] || fail "marina dashboard 는 명시적 start: [$(calls)] mark=$([[ -e "$MARK" ]] && echo yes || echo no)"
reset

# 5) 명시적 start → 표시 지우고 평소대로 뜸
touch "$MARK"
bash "$EP" dashboard start >/dev/null 2>&1
[[ ! -e "$MARK" ]] || fail "명시적 start 가 표시를 안 지움"
[[ "$(calls)" == "start" ]] || fail "명시적 start 는 기동: [$(calls)]"
reset

# 6) 명시적 restart·on 도 표시를 지움
touch "$MARK"
bash "$EP" dashboard restart >/dev/null 2>&1
[[ ! -e "$MARK" && "$(calls)" == "restart" ]] || fail "명시적 restart: [$(calls)]"
reset; touch "$MARK"
bash "$EP" dashboard on >/dev/null 2>&1
[[ ! -e "$MARK" && "$(calls)" == "start" ]] || fail "on = 표시 삭제 + start: [$(calls)]"
reset

# 6b) MARINA_DRY_RUN=1 이면 off 는 표시를 안 만든다
MARINA_DRY_RUN=1 bash "$EP" dashboard off >/dev/null 2>&1
[[ ! -e "$MARK" ]] || fail "DRY_RUN 인데 off 가 표시를 만들었다"
reset

# 6c) stop 이 실패하면 표시도 안 만들고 그 종료 코드를 돌려준다
cat > "$TMP/scripts/marina-dashboard.sh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$TMP/dash-calls"
exit 3
SH
rc=0; bash "$EP" dashboard off >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 ]] || fail "stop 실패 종료 코드를 그대로: $rc"
[[ ! -e "$MARK" ]] || fail "stop 이 실패했는데 표시를 만들었다"
cat > "$TMP/scripts/marina-dashboard.sh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$TMP/dash-calls"
SH
reset

# 7) 내부 경로(기동 스크립트를 직접 부르는 restart·restart 안의 stop keep-login)는 표시를 안 만든다
rm -f "$MARK"
real="$HERE/../scripts/marina-dashboard.sh"
( MARINA_DRY_RUN=1 bash "$real" restart >/dev/null 2>&1 ) || true
( MARINA_DRY_RUN=1 bash "$real" stop >/dev/null 2>&1 ) || true
[[ ! -e "$MARK" ]] || fail "기동 스크립트 직접 호출이 표시를 만들었다(표시는 marina dashboard off 만)"
grep -q "dashboard-off" "$real" && fail "marina-dashboard.sh 본문이 표시를 안다(표시는 entrypoint·remote CLI 몫)" || true

# 8) marina remote serve|funnel 의 사후 restart: 표시 있으면 건너뛰고 안내, 없으면 기존대로 부른다
export PYTHONPATH="$HERE/../scripts"
export MARINA_AUTH_DB="$TMP/auth.db"
remote_run() {  # $1=표시 유무(yes|no)  $2=3900 리스너 유무(yes|no)
  python3 - "$1" "$TMP" "${2:-no}" <<'PY'
import os, sys, argparse
from pathlib import Path
import marina_remote_cli as rc
mark, tmp, listening = sys.argv[1], sys.argv[2], sys.argv[3]
home = Path(os.environ["MARINA_HOME"]); m = home / "dashboard-off"
if mark == "yes": m.write_text("")
elif m.exists(): m.unlink()
class FakeSvc:
    control_host, control_port = "127.0.0.1", 59999
    def activate(self, mode, principal, password=""): return {"state": "ok", "mode": mode, "restartRequired": True}
rc._service = lambda store, home: FakeSvc()
rc._principal = lambda store: None
calls = []
rc._dashboard_listening = lambda host, port: listening == "yes"
rc.subprocess.run = lambda *a, **k: calls.append(a[0])
rc.run(argparse.Namespace(command="serve", password_stdin=False))
print("CALLS=%d" % len(calls))
PY
}
out="$(remote_run yes 2>&1)" || fail "표시 있을 때 remote serve 실패: $out"
echo "$out" | grep -q "CALLS=0" || fail "표시 있는데 사후 restart 를 불렀다: $out"
echo "$out" | grep -q "대시보드는 꺼 둠 — 켜려면 marina dashboard start" || fail "remote 안내 한 줄 없음: $out"
out="$(remote_run yes yes 2>&1)" || fail "표시+리스너 있을 때 실패: $out"
echo "$out" | grep -q "CALLS=1" || fail "표시가 있어도 대시보드가 떠 있으면 평소대로 restart: $out"
out="$(remote_run no 2>&1)" || fail "표시 없을 때 remote serve 실패: $out"
echo "$out" | grep -q "CALLS=1" || fail "표시 없으면 기존대로 restart 를 불러야: $out"

echo "PASS test-dashboard-off-mark"
