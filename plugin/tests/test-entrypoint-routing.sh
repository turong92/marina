#!/usr/bin/env bash
# entrypoint(설치 shim 대상)가 marina.sh 그룹 명령을 라우팅하는지 — worktree/gateway/link 누락이
# "설치 shim 은 이 명령 없음" 증상을 만들었던 회귀(도그푸드 발견). 전역 usage 로 떨어지면 실패.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
EP="$HERE/../scripts/marina-entrypoint.sh"

# worktree: 무인자 → marina.sh 의 worktree usage("usage: marina worktree create ...")가 와야 함
out=$(bash "$EP" worktree 2>&1 || true)
echo "$out" | grep -q "worktree create" || { echo "FAIL: worktree 미라우팅 — $out"; exit 1; }
echo "$out" | grep -q "전역 CLI" && { echo "FAIL: worktree 가 전역 usage 로 떨어짐"; exit 1; }

# session: Discord 세션 명령 — 빠져 있어 설치본에서 'unknown command: session' 이었다(2026-10-01)
out=$(bash "$EP" session --help 2>&1 || true)
echo "$out" | grep -q "Discord" || { echo "FAIL: session 미라우팅 — $out"; exit 1; }
echo "$out" | grep -q "unknown command" && { echo "FAIL: session 이 전역 usage 로 떨어짐"; exit 1; }

# gateway: status 는 running/stopped 중 하나
out=$(MARINA_HOME="$(mktemp -d)" bash "$EP" gateway status 2>&1 || true)
echo "$out" | grep -qE "running|stopped" || { echo "FAIL: gateway 미라우팅 — $out"; exit 1; }

# link: 등록 안 된 tmp cwd 에서도 전역 usage 가 아닌 marina.sh 응답(성공/무출력/자체 에러)이어야 함
out=$(cd "$(mktemp -d)" && MARINA_HOME="$(mktemp -d)" bash "$EP" link 2>&1 || true)
echo "$out" | grep -q "전역 CLI" && { echo "FAIL: link 가 전역 usage 로 떨어짐"; exit 1; }

# dashboard restart: entrypoint가 하위 dashboard 런처의 restart를 막지 않아야 함.
restart_home="$(mktemp -d)"
restart_fake="$restart_home/fakebin"
restart_launchctl_log="$restart_home/launchctl.log"
mkdir -p "$restart_fake"
printf '#!/usr/bin/env bash\necho Darwin\n' > "$restart_fake/uname"
cat > "$restart_fake/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MARINA_LAUNCHCTL_LOG"
exit 0
SH
chmod +x "$restart_fake/uname" "$restart_fake/launchctl"
# 실제 설치처럼 기존 supervisor 설정이 있어야 pre-fix restart 의 stop 단계가
# launchctl bootout 을 호출한다. dry-run 은 이 파일이 있어도 side effect 가 없어야 한다.
touch "$restart_home/marina.dashboard.plist"
out=$(PATH="$restart_fake:$PATH" MARINA_LAUNCHCTL_LOG="$restart_launchctl_log" \
  MARINA_HOME="$restart_home" MARINA_CONTROL_HOST=127.0.0.1 MARINA_CONTROL_PORT=0 \
  MARINA_DRY_RUN=1 bash "$EP" dashboard restart 2>&1 || true)
echo "$out" | grep -q "dry-run: wrote launcher" || { echo "FAIL: dashboard restart 미라우팅 — $out"; exit 1; }
if [[ -s "$restart_launchctl_log" ]]; then
  echo "FAIL: dashboard dry-run restart touched launchctl — $(cat "$restart_launchctl_log")"
  exit 1
fi
rm -rf "$restart_home"

# 분리 A: 플러그인 bin/marina(켜져 있으면 Claude 의 Bash PATH) = entrypoint, `marina runtimed` = 청소 상주 프로그램
BIN="$HERE/../bin/marina"
[[ -x "$BIN" ]] || { echo "FAIL: plugin/bin/marina 없음/실행 불가"; exit 1; }
rt_home="$(mktemp -d)"
out=$(MARINA_HOME="$rt_home" "$BIN" runtimed status 2>&1 || true)
echo "$out" | grep -q "runtimed stopped" || { echo "FAIL: bin/marina runtimed status 미라우팅 — $out"; exit 1; }
rm -rf "$rt_home"

# 분리 B: discord 명령은 marina-session(discord 플러그인 bin). runtime 의 `marina session …` 은 그쪽으로 넘겨줄 뿐
SBIN="$HERE/../../plugin-discord/bin/marina-session"
[[ -x "$SBIN" ]] || { echo "FAIL: plugin-discord/bin/marina-session 없음"; exit 1; }
fwd="$(mktemp -d)"; printf '#!/usr/bin/env bash\necho "FORWARDED $*"\n' > "$fwd/marina-session"; chmod +x "$fwd/marina-session"
out=$(MARINA_SESSION_BIN="$fwd/marina-session" MARINA_HOME="$fwd" bash "$EP" session ls 2>&1 || true)
echo "$out" | grep -q "FORWARDED ls" || { echo "FAIL: marina session 이 marina-session 으로 안 넘어감 — $out"; exit 1; }
out=$(MARINA_SESSION_BIN=none MARINA_HOME="$fwd" bash "$EP" session ls 2>&1 || true)
echo "$out" | grep -q "discord" || { echo "FAIL: discord 플러그인이 없을 때 안내 — $out"; exit 1; }
rm -rf "$fwd"

echo "PASS test-entrypoint-routing"
