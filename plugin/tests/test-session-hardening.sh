#!/usr/bin/env bash
# marina session — 최종 리뷰가 잡은 결함 재발 방지.
#  C1 데몬 PATH(/usr/bin:/bin)에도 tmux 를 찾는다(못 찾으면 워크트리를 지워도 claude 가 계속 돈다)
#  I1 DM 허용 목록은 비운다(같은 봇을 쓰는 모든 세션이 DM 을 동시에 받는다)
#  I2 Stop 훅은 실패해도 exit 0(버전 캐시가 지워지면 exit 2 로 claude 종료를 막는다), start 가 설정을 다시 쓴다
#  I3 Discord 응답 대기 중 타임아웃도 SessionError, 정리는 끝까지 간다
#  I4 첫 실행(카테고리 없음)에도 토큰을 워크트리 만들기 전에 확인한다
#  I5 SSH_AUTH_SOCK 은 넘긴다(채널 세션에서 git push)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }

# I4 — 잘못된 토큰이면 워크트리도 안 만든다(카테고리 ID 가 아직 없는 첫 실행)
cp "$MARINA_HOME/token.env" "$TMPROOT/token.bak"; printf 'DISCORD_BOT_TOKEN=wrong\n' > "$MARINA_HOME/token.env"
out="$(msess new proj feat/early --no-start 2>&1)" && fail "잘못된 토큰이 성공함"
echo "$out" | grep -q "401" || fail "401 안내 없음: $out"
[ ! -e "$SRC/.claude/worktrees/feat-early" ] || fail "토큰 확인 전에 워크트리를 만듦"
cp "$TMPROOT/token.bak" "$MARINA_HOME/token.env"

export SSH_AUTH_SOCK="$TMPROOT/agent.sock"
msess new proj feat/one --no-start >/dev/null 2>&1 || fail "new"
for _ in $(seq 50); do ls "$FAKE_OUT"/*/argv >/dev/null 2>&1 && break; sleep 0.1; done

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FAKE_OUT" "$TMPROOT" <<'PY'
import json, os, socket, subprocess, sys, threading
from pathlib import Path
import marina_session as ms
out, tmp = Path(sys.argv[1]), Path(sys.argv[2])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
rec = ms.find_session("proj/feat/one")
sd = Path(rec["stateDir"])

# I1
acc = json.loads((sd / "access.json").read_text())
check(acc["allowFrom"] == [], f"DM 허용 목록은 비어야 함: {acc['allowFrom']}")
check(acc["groups"][rec["channelId"]]["allowFrom"] == ["U1"], "채널 허용자는 유지")

# I5
call = sorted((p for p in out.iterdir() if (p / "env").exists()), key=lambda p: p.stat().st_mtime)[-1]
env = dict(l.split("=", 1) for l in (call / "env").read_text().splitlines() if "=" in l)
check(env.get("SSH_AUTH_SOCK") == str(tmp / "agent.sock"), "SSH_AUTH_SOCK 전달")

# I2 — 훅 명령은 실패해도 0, start 가 설정을 다시 쓴다
cmd = json.loads((sd / "settings.json").read_text())["hooks"]["Stop"][0]["hooks"][0]["command"]
broken = cmd.replace("marina_session.py", "no_such_file.py")
check(subprocess.run(["/bin/sh", "-c", broken], input="{}", text=True, capture_output=True).returncode == 0,
      f"훅 대상 파일이 사라져도 exit 0 이어야 함: {cmd}")
ms.tmux_stop(rec["tmux"]); (sd / "settings.json").unlink()
started, failed = ms.cmd_start("proj/feat/one")
check(started and (sd / "settings.json").exists(), f"start 가 settings.json 을 다시 씀: {started} {failed}")

# C1 — 데몬 PATH 에서도 tmux 를 찾는다
real_path = os.environ["PATH"]
os.environ["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
check(ms.tmux_alive(rec["tmux"]), "데몬 PATH 에서 살아 있는 세션을 못 봄")
check(ms.has_live_session(Path(rec["root"])), "데몬 PATH 에서 has_live_session False")
ms.tmux_stop(rec["tmux"])
os.environ["PATH"] = real_path
check(not ms.tmux_alive(rec["tmux"]), "데몬 PATH 에서 tmux_stop 이 못 끔")

# I3 — 연결은 받지만 응답이 없는 서버: 타임아웃도 SessionError, teardown 은 끝까지
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(5)
os.environ["MARINA_DISCORD_API"] = f"http://127.0.0.1:{srv.getsockname()[1]}"
os.environ["MARINA_DISCORD_TIMEOUT"] = "0.5"
try:
    ms.Discord("test-token").list_channels("G1"); check(False, "응답 없음이 성공함")
except ms.SessionError as exc:
    check("Discord" in str(exc), f"타임아웃 안내: {exc}")
except Exception as exc:
    check(False, f"타임아웃이 SessionError 가 아님: {type(exc).__name__}: {exc}")
warnings = ms.teardown(rec)
check(any("채널 삭제 실패" in w for w in warnings), f"채널 삭제 실패가 경고로: {warnings}")
check(not sd.exists(), "Discord 가 죽어도 상태 폴더는 지움")
check(ms.load_sessions() == [], "Discord 가 죽어도 기록은 지움")
srv.close()

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-hardening"
