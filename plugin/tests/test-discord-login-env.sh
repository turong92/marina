#!/usr/bin/env bash
# 데몬(짧은 PATH)이 방을 깨울 때 쓸 환경의 출처 = 사용자의 로그인 셸. 가짜 SHELL 스크립트로 흉내 낸다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a >/dev/null 2>&1 || fail "new"

# 가짜 로그인 셸: `-l -i -c CMD` 를 받아 rc 가 적용된 척 환경을 바꾸고 CMD 를 돌린다. 호출 횟수를 센다.
export FAKE_COUNT="$TMPROOT/shell-count"
FAKE_TAIL="$TMPROOT/bin:$(dirname "$(command -v tmux)")"
# 로그인 셸은 HOME·USER·LOGNAME·SHELL·PATH·LANG·TMPDIR 만 받는다 — 시험용 값은 환경이 아니라 스크립트·파일로 건넨다
cat > "$TMPROOT/fakeshell" <<SH
#!/bin/bash
echo "\$*" >> "$TMPROOT/shell-count"
[ "\$1 \$2 \$3" = "-l -i -c" ] || exit 3
env > "$TMPROOT/shell-count.env"                           # 로그인 셸이 받은 환경(비밀이 새는지 본다)
[ -e "$TMPROOT/fake-fail" ] && exit 1
[ -e "$TMPROOT/fake-sleep" ] && sleep "\$(cat "$TMPROOT/fake-sleep")"
printf 'noise\033[2J prompt-plugin garbage\n'            # 프롬프트 플러그인이 표식 앞에 찍는 쓰레기
export PATH="/fake/.sdkman/candidates/java/current/bin:/opt/homebrew/opt/node@22/bin:/usr/bin:/bin:$FAKE_TAIL"
export JAVA_HOME=/fake/.sdkman/java SDKMAN_DIR=/fake/.sdkman LANG=ko_KR.UTF-8
export SECRET_TOKEN=must-not-leak AWS_SECRET_ACCESS_KEY=nope
exec /bin/bash -c "\$4"
SH
chmod +x "$TMPROOT/fakeshell"
export MARINA_LOGIN_SHELL="$TMPROOT/fakeshell"
export HOME_FAKE="$TMPROOT/home"; mkdir -p "$HOME_FAKE"
export FAKE_COUNT FAKE_TAIL
cat > "$TMPROOT/prelude.py" <<'PY'
import json, os, sys, time
from pathlib import Path
import marina_session as ms
fails = []
def check(c, m):
    if not c: fails.append(m)
def finish():
    if fails:
        print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
os.environ["HOME"] = os.environ["HOME_FAKE"]
COUNT = Path(os.environ["FAKE_COUNT"])
def calls(): return len(COUNT.read_text().splitlines()) if COUNT.exists() else 0
LE = ms.marina_home() / "login-env.json"
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"])
PY
run() { PYTHONPATH="$DSCRIPTS:$SCRIPTS" TMPROOT="$TMPROOT" python3 - ; }

# 1) 캐시 없음 → 로그인 셸 한 번 · 그 PATH · 5개 키만 캐시 · 쓰레기·비밀 없음
{ cat "$TMPROOT/prelude.py"; cat <<'PY'
env = ms.login_env()
check(env and env["PATH"].startswith("/fake/.sdkman/candidates/java"), f"로그인 셸의 PATH: {env}")
check(calls() == 1, f"로그인 셸을 한 번 부른다: {calls()}")
check(LE.exists() and set(json.loads(LE.read_text())) <= {"PATH", "LANG", "LC_ALL", "JAVA_HOME", "SDKMAN_DIR"}, f"캐시에 허용 키만: {LE.read_text() if LE.exists() else None}")
check("must-not-leak" not in LE.read_text() and "noise" not in LE.read_text(), "비밀·쓰레기는 캐시에 없다")
check(json.loads(LE.read_text()).get("JAVA_HOME") == "/fake/.sdkman/java", "JAVA_HOME 도 담는다")
# 2) 캐시 있음 → 안 부른다
ms.login_env(); check(calls() == 1, f"캐시가 유효하면 안 부른다: {calls()}")
# 3) rc 가 캐시보다 새로우면 다시
rc = Path(os.environ["HOME"]) / ".zshrc"; rc.write_text("x")
os.utime(rc, (time.time() + 5, time.time() + 5))
ms.login_env(); check(calls() == 2, f"rc 가 새로워지면 다시 부른다: {calls()}")
# 4) 6시간 지나면 다시
old = time.time() - 7 * 3600
os.utime(LE, (old, old)); os.utime(rc, (old - 10, old - 10))
n = calls(); ms.login_env(); check(calls() == n + 1, "6시간 넘으면 다시")
finish()
PY
} | run

# 5) 실패·타임아웃·빈 PATH → None (막지 않는다), 이전 캐시가 없으면 캐시도 안 만든다
rm -f "$MARINA_HOME/login-env.json" "$MARINA_HOME/login-env.fail"
{ cat "$TMPROOT/prelude.py"; cat <<'PY'
FAIL = ms.marina_home() / "login-env.fail"
(Path(os.environ["TMPROOT"]) / "fake-fail").write_text("1")
check(ms.login_env() is None and not LE.exists(), "로그인 셸 실패 → None")
check(FAIL.exists(), "실패 시각을 적는다")
(Path(os.environ["TMPROOT"]) / "fake-fail").unlink()
n = calls(); check(ms.login_env() is None and calls() == n, f"실패 뒤 10분은 다시 안 부른다: {calls() - n}")
FAIL.unlink()
ms.LOGIN_ENV_TIMEOUT = 1.0; (Path(os.environ["TMPROOT"]) / "fake-sleep").write_text("5")
t = time.time(); r = ms.login_env()
check(r is None and time.time() - t < 6, f"타임아웃 → None, 오래 안 기다림: {time.time() - t:.1f}s")
(Path(os.environ["TMPROOT"]) / "fake-sleep").unlink()
FAIL.unlink(missing_ok=True)
os.environ["MARINA_LOGIN_SHELL"] = "/nonexistent/shell"
check(ms.login_env() is None, "셸이 없으면 None")
FAIL.unlink(missing_ok=True)
finish()
PY
} | run

# 5-b) 실패하면 이전 캐시(낡았어도)를 쓰고, 10분 뒤에야 다시 시도한다
rm -f "$MARINA_HOME/login-env.json" "$MARINA_HOME/login-env.fail"
{ cat "$TMPROOT/prelude.py"; cat <<'PY'
FAIL = ms.marina_home() / "login-env.fail"
good = ms.login_env(); check(good is not None, "먼저 성공")
old = time.time() - 7 * 3600; os.utime(LE, (old, old))           # 캐시를 낡게
(Path(os.environ["TMPROOT"]) / "fake-fail").write_text("1"); n = calls()
got = ms.login_env()
check(got == good and calls() == n + 1, f"조회가 실패하면 낡은 캐시를 그대로 쓴다: {got} {calls() - n}")
check(FAIL.exists(), "실패 시각 기록")
n = calls(); got = ms.login_env()
check(got == good and calls() == n, "10분 안엔 재시도하지 않는다(캐시는 계속 씀)")
old = time.time() - 11 * 60; os.utime(FAIL, (old, old))
(Path(os.environ["TMPROOT"]) / "fake-fail").unlink(); n = calls(); got = ms.login_env()
check(calls() == n + 1 and got and not FAIL.exists(), f"10분 뒤 재시도 → 성공하면 실패 기록 지움: {calls() - n}")
finish()
PY
} | run

# 5-c) 타임아웃 뒤 communicate 에 제한 · 끝 표식이 있으면 EOF 없이도 완결
rm -f "$MARINA_HOME/login-env.json" "$MARINA_HOME/login-env.fail"
cat > "$TMPROOT/hangshell" <<'SH'
#!/bin/bash
# 환경과 끝 표식까지 찍고 EOF 를 안 준다(손자가 stdout 을 쥔 채 새 세션으로 도망 — 그룹 kill 이 안 닿는다)
[ "$1 $2 $3" = "-l -i -c" ] || exit 3
export PATH="/hang/bin:/usr/bin:/bin"
/bin/bash -c "$4"
python3 - <<'PYX' &
import os, time
os.setsid(); time.sleep(8)
PYX
sleep 8
SH
chmod +x "$TMPROOT/hangshell"
{ cat "$TMPROOT/prelude.py"; cat <<'PY'
os.environ["MARINA_LOGIN_SHELL"] = os.environ["TMPROOT"] + "/hangshell"
ms.LOGIN_ENV_TIMEOUT = 1.5
t = time.time(); env = ms.login_env()
check(env and env["PATH"].startswith("/hang/bin"), f"끝 표식까지 읽었으면 EOF 없이도 쓴다: {env}")
check(time.time() - t < 6, f"communicate 뒤처리에 제한: {time.time() - t:.1f}s")
finish()
PY
} | run

# 5-d) 로그인 셸에 넘기는 환경은 HOME·USER·LOGNAME·SHELL·PATH·LANG·TMPDIR 만, 얻은 PATH 뒤에 daemon_path 의 빠진 항목
rm -f "$MARINA_HOME/login-env.json" "$MARINA_HOME/login-env.fail" "$TMPROOT/shell-count.env"
{ cat "$TMPROOT/prelude.py"; cat <<'PY'
os.environ.update(DISCORD_BOT_TOKEN="tok-secret", MARINA_GUILD="g", MARINA_X="y", AWS_SECRET_ACCESS_KEY="aws", USER="u1", LOGNAME="u1", LANG="C", TMPDIR="/tmp")
env = ms.login_env()
seen = dict(l.split("=", 1) for l in (Path(os.environ["TMPROOT"]) / "shell-count.env").read_text().splitlines() if "=" in l)
leaked = [k for k in seen if k.startswith(("MARINA_", "DISCORD_")) or k in ("AWS_SECRET_ACCESS_KEY", "SECRET_TOKEN")]
check(not leaked, f"비밀·MARINA_* 를 로그인 셸에 넘기지 않는다: {leaked}")
check({"HOME", "USER", "LOGNAME", "SHELL", "PATH", "LANG", "TMPDIR"} <= set(seen) and seen["USER"] == "u1", f"쓰는 키는 넘긴다: {sorted(seen)}")
parts = env["PATH"].split(":")
dp = ms.daemon_path().split(":")
check(all(x in parts for x in dp), f"daemon_path 의 빠진 항목을 덧붙인다: {parts}")
check(parts.index("/fake/.sdkman/candidates/java/current/bin") < parts.index(dp[0]), "얻은 PATH 가 앞, 덧붙인 것은 뒤")
check(len(parts) == len(set(parts)), "중복 없음")
# 셸 고르는 순서
import pwd
os.environ["MARINA_LOGIN_SHELL"] = "/a/shell"; check(ms._login_shell() == "/a/shell", "MARINA_LOGIN_SHELL 이 먼저")
del os.environ["MARINA_LOGIN_SHELL"]
real = pwd.getpwuid
class P: pw_shell = "/pw/shell"
pwd.getpwuid = lambda uid: P(); os.environ["SHELL"] = "/env/shell"
check(ms._login_shell() == "/pw/shell", "계정의 셸이 $SHELL 보다 먼저")
P.pw_shell = ""; check(ms._login_shell() == "/env/shell", "계정 셸이 없으면 $SHELL")
del os.environ["SHELL"]; check(ms._login_shell() == "/bin/zsh", "마지막은 /bin/zsh")
pwd.getpwuid = real
finish()
PY
} | run

# 6) 우선순위·by 판정·오염 방지·되돌리기
rm -f "$MARINA_HOME/login-env.json"
{ cat "$TMPROOT/prelude.py"; cat <<'PY'
LF = sd / "launch-env.json"
human = {"PATH": "/h/.sdkman/candidates/java/current/bin:/usr/bin", "by": "human"}
LF.write_text(json.dumps(human)); n = calls()
check(ms.apply_launch_env(sd) is True and os.environ["PATH"] == human["PATH"] and calls() == n, "by:human 기록이 우선(로그인 셸 안 부름)")
LF.write_text(json.dumps({"PATH": "/d/.sdkman/x:/usr/bin", "by": "daemon"}))
ms.apply_launch_env(sd)
check(os.environ["PATH"].startswith("/fake/.sdkman"), f"by:daemon 기록은 무시하고 로그인 환경: {os.environ['PATH']}")
LF.write_text(json.dumps({"PATH": ms.daemon_path()}))
ms.apply_launch_env(sd)
check(os.environ["PATH"].startswith("/fake/.sdkman"), "by 없고 데몬 PATH 와 같은 옛 기록은 daemon 으로 간주")
os.environ["HOME"] = "/Users/sumin"                  # daemon_path() 의 ~/.local/bin 이 실제 값과 같게
REAL = "/Users/sumin/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/bin:/bin"
LF.write_text(json.dumps({"PATH": REAL}))
ms.apply_launch_env(sd)
check(os.environ["PATH"].startswith("/fake/.sdkman"), "(C1) 실제 데몬이 굳힌 PATH(daemon_path + 봇 PATH)도 daemon 으로 간주")
os.environ["HOME"] = "/Users/sumin"
check(not ms._launch_record_is_human({"PATH": REAL}) and ms._launch_record_is_human({"PATH": REAL + ":/Users/sumin/.nvm/bin"}), "(C1) 사용자 항목이 하나라도 있으면 사람 것")
os.environ["HOME"] = os.environ["HOME_FAKE"]
check(not ms._launch_record_is_human({"PATH": "/usr/bin:/bin", "by": "session"}) and not ms._launch_record_is_human({"PATH": "/x/.sdkman/bin", "by": "daemon"}), "by:session·daemon 은 환경 출처로 안 쓴다")
LF.write_text(json.dumps({"PATH": "/Users/x/.sdkman/candidates/java/current/bin:/usr/bin"}))
ms.apply_launch_env(sd)
check(os.environ["PATH"].startswith("/Users/x/.sdkman"), "by 없어도 사용자 항목이 있으면 사람 것")
# 로그인 셸 실패 + daemon 기록 → 지금 환경 그대로(False)
LE.unlink(missing_ok=True)
os.environ["MARINA_LOGIN_SHELL"] = "/nonexistent/shell"
os.environ["PATH"] = "/usr/bin:/bin"
LF.write_text(json.dumps({"PATH": ms.daemon_path(), "by": "daemon"}))
check(ms.apply_launch_env(sd) is False and os.environ["PATH"] == "/usr/bin:/bin", "로그인 셸 실패 → 기존 동작(입히지 않음)")
(ms.marina_home() / "login-env.fail").unlink(missing_ok=True)      # 위의 일부러 실패한 조회가 남긴 재시도 금지 기록
# 기록: 사람이 켜면 human, 데몬 맥락이면 daemon, 데몬이 사람 기록을 덮지 않는다
os.environ["MARINA_LOGIN_SHELL"] = os.environ["TMPROOT"] + "/fakeshell"
os.environ["PATH"] = os.environ["FAKE_TAIL"] + ":/usr/bin:/bin"
os.environ["JAVA_HOME"] = "/orig/java"; os.environ.pop("SDKMAN_DIR", None); orig = dict(os.environ)
ms.tmux_stop(rec["tmux"]); LF.unlink(missing_ok=True)
import marina_discord_wake as mw
started, failed = mw._start_with_launch_env("proj/feat/a", sd, "go")
check(started and not LF.exists(), f"데몬 경로로 띄우면 기록을 안 적는다(by:daemon 은 죽은 데이터): {LF.exists()}")
check(os.environ["PATH"] == orig["PATH"] and os.environ["JAVA_HOME"] == "/orig/java" and "SDKMAN_DIR" not in os.environ, "띄운 뒤 데몬 환경(PATH·JAVA_HOME·SDKMAN_DIR)이 원래대로")
cmd = ms._tmux("display-message", "-p", "-t", f"={rec['tmux']}:", "#{pane_start_command}").stdout
check("/fake/.sdkman/java" in cmd and "/opt/homebrew/opt/node@22" in cmd, "세션이 로그인 환경의 PATH·JAVA_HOME 으로 떴다")
ms.tmux_stop(rec["tmux"])
LF.write_text(json.dumps({"PATH": "/h/.sdkman/bin:/usr/bin", "by": "human"}))
mw._start_with_launch_env("proj/feat/a", sd, "go")
check(json.loads(LF.read_text()).get("by") == "human", "데몬이 띄워도 사람 기록은 덮지 않는다")
ms.tmux_stop(rec["tmux"])
LF.unlink()
os.environ["PATH"] = orig["PATH"]
os.environ["MARINA_DISCORD_SUPERVISED"] = "launchd"
ms.cmd_start("proj/feat/a")
check(not LF.exists(), "SUPERVISED 표식이 있는 프로세스에서 띄우면 기록 안 적음")
del os.environ["MARINA_DISCORD_SUPERVISED"]
ms.tmux_stop(rec["tmux"])
os.environ["MARINA_DISCORD_BOTPROC"] = "1"          # nohup 데몬·봇 자식 표식(launchd 가 아니어도)
check(ms.launched_by() == "daemon", "봇 프로세스 표식이 있으면 daemon(nohup 감독도)")
ms.cmd_start("proj/feat/a"); check(not LF.exists(), "nohup 데몬이 by:human 으로 적는 구멍 닫힘")
ms.tmux_stop(rec["tmux"])
os.environ["DISCORD_STATE_DIR"] = str(sd)            # 세션 안에서 부른 restart·start
check(ms.launched_by() == "session", "DISCORD_STATE_DIR 이 있으면 session(봇 표식보다 먼저)")
LF.write_text(json.dumps({"PATH": "/h/.sdkman/bin:/usr/bin", "by": "human"}))
ms.cmd_start("proj/feat/a")
check(json.loads(LF.read_text()) == {"PATH": "/h/.sdkman/bin:/usr/bin", "by": "human"}, "session 이 띄워도 human 기록을 덮지 않는다")
ms.tmux_stop(rec["tmux"]); LF.unlink()
ms.cmd_start("proj/feat/a")
check(not LF.exists(), "session 은 기록을 적지 않는다(환경 출처로 쓰이지 않게)")
del os.environ["DISCORD_STATE_DIR"], os.environ["MARINA_DISCORD_BOTPROC"]
ms.tmux_stop(rec["tmux"]); LF.unlink(missing_ok=True)
ms.cmd_start("proj/feat/a")
check(json.loads(LF.read_text()).get("by") == "human", "손으로 띄우면 human")
finish()
PY
} | run

# 7) I1 — [새 작업 열기] 도 사람의 환경으로 뜬다. 표식은 봇 프로세스(nohup·launchd 둘 다)가 자식에게 준다
rm -f "$MARINA_HOME/login-env.json" "$MARINA_HOME/login-env.fail"
{ cat "$TMPROOT/prelude.py"; cat <<'PY'
import marina_discord_bot as mb
cfgd = ms.load_config()
check(mb.bot_command(cfgd)["env"].get("MARINA_DISCORD_BOTPROC") == "1" if mb.bot_command(cfgd) else True, "봇 자식 환경에 표식")
check(ms._daemon_env().get("MARINA_DISCORD_BOTPROC") == "1", "nohup 데몬 환경에 표식")
os.environ["MARINA_DISCORD_BOTPROC"] = "1"
os.environ["PATH"] = "/usr/bin:/bin"
ms.load_sessions_orig = ms.load_sessions
ms.load_sessions = lambda: [{"project": "proj", "kind": "dev-lobby", "channelId": "C1", "task": "lobby"}]
mb._allowed = lambda *a, **k: True; mb._dc = lambda cfg: None
ms.unique_slug = lambda p, s_: "s1"; ms.suggest_slug = lambda t: "s1"; ms.extract_base = lambda p, t: ""; ms.task_title = lambda t: "t"
seen = {}
def fake_new(project, slug, base="", start=False, title="", first=None):
    seen.update(path=os.environ.get("PATH"), by=ms.launched_by(), java=os.environ.get("JAVA_HOME")); return {"channelId": "9"}
ms.cmd_new = fake_new
out = mb.new_from_text("proj", "U1", "무언가", "C1")
check(out.startswith("열었어") and seen.get("path", "").startswith("/fake/.sdkman") and seen.get("java") == "/fake/.sdkman/java" and seen.get("by") == "daemon", f"새 작업은 로그인 환경으로: {seen} {out}")
check(os.environ["PATH"] == "/usr/bin:/bin" and "JAVA_HOME" not in os.environ, "끝나면 환경을 되돌린다")
finish()
PY
} | run
echo PASS
