#!/usr/bin/env bash
# LaunchAgent(marina.discord): 로그인하면 봇 데몬이 뜨고 죽으면 다시 뜬다. 맥 기본 홈에서만 launchd 가 주인이고,
# 테스트·격리 홈은 실제 launchctl 을 절대 부르지 않는다(가짜만).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
fail() { echo "FAIL: $*"; exit 1; }
REAL_SUM_BEFORE="$(cksum "$HOME/Library/LaunchAgents/marina.discord.plist" 2>/dev/null || echo none)"   # 실제 로그인 항목은 있든 없든 그대로여야 한다
LC="$TMPROOT/lc"; mkdir -p "$LC" "$TMPROOT/bin"
cat > "$TMPROOT/bin/fake-launchctl" <<SH
#!/bin/sh
echo "\$*" >> "$LC/log"
case "\$1" in
  print) [ -e "$LC/slow" ] && exec sleep 8
         [ -f "$LC/loaded" ] || exit 113; echo "state = \$(cat "$LC/state" 2>/dev/null || echo running)" ;;
  bootstrap) [ -e "$LC/fail_bootstrap" ] && { echo "Bootstrap failed: 5"; exit 5; }
             if [ -s "$LC/fail_n" ]; then n=\$(cat "$LC/fail_n"); if [ "\$n" -gt 0 ]; then echo \$((n-1)) > "$LC/fail_n"; echo "Bootstrap failed: 5"; exit 5; fi; fi
             touch "$LC/loaded" ;;
  bootout) rm -f "$LC/loaded" ;;
  kickstart) echo running > "$LC/state" ;;
esac
SH
chmod +x "$TMPROOT/bin/fake-launchctl"
export MARINA_LAUNCH_AGENTS_DIR="$MARINA_HOME/LaunchAgents" LC
PYTHONPATH="$DSCRIPTS:$SCRIPTS" FAKE="$TMPROOT/bin/fake-launchctl" TMPROOT_PY="$TMPROOT" python3 - <<'PY'
import os, plistlib, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_launchd as ld
fails = []
def check(c, m):
    if not c: fails.append(m)
LC = Path(os.environ["LC"]); log = LC / "log"
def calls(): return log.read_text().splitlines() if log.exists() else []
prog = [str(ms.marina_home() / "bin" / "marina-session-hook"), "daemon"]
# 내용
d = plistlib.loads(ld.plist_text(prog).encode())
check(d["Label"] == "marina.discord" and d["ProgramArguments"] == prog, f"라벨·실행 인자: {d}")
check(d["RunAtLoad"] is True and d["KeepAlive"] is True and d["AbandonProcessGroup"] is True, "로그인 때 뜨고·죽으면 다시·자식은 안 죽임")
env = d["EnvironmentVariables"]
check(env["LANG"] == "en_US.UTF-8" and env["MARINA_DISCORD_SUPERVISED"] == "launchd" and env["PATH"] == ms.daemon_path()
      and env["MARINA_HOME"] == str(ms.marina_home()), f"환경: {env}")
check(d["WorkingDirectory"] == str(ms.marina_home()) and d["StandardOutPath"].endswith("discord-daemon.log"), "cwd·로그")
check(ld.plist_text(prog) == ld.plist_text(prog), "같은 입력이면 같은 내용(누가 써도 안 흔들린다)")
# 주인: 격리 홈은 nohup — 가짜가 없으면 강제해도 nohup(실제 launchctl 을 안 부른다)
check(ld.is_primary() is False and ld.supervisor() == "nohup", "격리 홈은 nohup")
os.environ["MARINA_DISCORD_SUPERVISOR"] = "launchd"
check(ld.supervisor() == "nohup", "가짜 launchctl 없이 강제해도 격리 홈은 nohup")
check(ld.status() == "absent" and calls() == [], f"격리 홈은 launchctl 을 부르지 않는다: {calls()}")
os.environ["MARINA_DISCORD_LAUNCHCTL"] = os.environ["FAKE"]
check(ld.supervisor() == "launchd", "가짜가 있으면 강제대로")
# 없으면 등록
check(ld.ensure(prog) == "installed" and ld.plist_path().is_file(), "없으면 plist 쓰고 bootstrap")
check(any(c.startswith("bootstrap gui/") and c.endswith(str(ld.plist_path())) for c in calls()), f"bootstrap 호출: {calls()}")
check(ld.status() == "running" and ld.ensure(prog) == "running", "떠 있으면 그대로")
# 올라가 있는데 죽어 있으면 kickstart
(LC / "state").write_text("not running"); log.unlink()
check(ld.status() == "loaded" and ld.ensure(prog) == "kicked", "죽어 있으면 kickstart")
check(not any(c.startswith("bootstrap") for c in calls()), f"이미 올라가 있으면 bootstrap 안 함: {calls()}")
# 내용이 다르면 다시 올린다(떼어 낸 도우미: bootout → bootstrap)
log.unlink(); ld.plist_path().write_text("old")
check(ld.ensure(prog) == "reloaded", "내용이 다르면 다시 올림")
for _ in range(40):
    if any(c.startswith("bootstrap") for c in calls()): break
    time.sleep(0.1)
cs = calls()
check([c.split()[0] for c in cs if c.split()[0] in ("bootout", "bootstrap")] == ["bootout", "bootstrap"], f"bootout 다음 bootstrap: {cs}")
check(plistlib.loads(ld.plist_path().read_bytes())["Label"] == "marina.discord", "파일은 새 내용")
# 다시 올리다 bootstrap 이 일시 실패해도(bootout 직후 아직 정리 중) 두 번 더 시도한다
log.unlink(); ld.plist_path().write_text("old"); (LC / "fail_n").write_text("2")
check(ld.ensure(prog) == "reloaded", "재시도 시험 준비")
for _ in range(100):
    if len([c for c in calls() if c.startswith("bootstrap")]) >= 3: break
    time.sleep(0.1)
check((LC / "loaded").exists() and len([c for c in calls() if c.startswith("bootstrap")]) == 3, f"bootstrap 이 두 번 실패해도 세 번째에 올라간다: {calls()}")
(LC / "fail_n").write_text("0")
# launchctl 한 번은 5초 안에 끝낸다(데몬 틱을 20초씩 붙잡지 않게)
import inspect
(LC / "slow").touch(); t0 = time.time(); st_slow = ld.status(); took = time.time() - t0; (LC / "slow").unlink()
check(took < 6.5 and st_slow == "absent", f"느린 launchctl 은 5초 안에 포기(소스 글자가 아니라 반환 시간으로): {took:.1f}s {st_slow}")
# 등록 실패는 failed:
ld.uninstall(); (LC / "fail_bootstrap").touch()
check(ld.ensure(prog).startswith("failed:"), "bootstrap 실패를 성공으로 적지 않는다")
(LC / "fail_bootstrap").unlink()
# 제거
ld.ensure(prog)
check(ld.uninstall() == "removed" and not ld.plist_path().exists() and ld.status() == "absent", "제거")
check(ld.uninstall() == "absent", "없으면 absent")
# 격리 홈 + 실제 LaunchAgents 경로: 아무것도 지우거나 쓰지 않는다(MARINA_LAUNCH_AGENTS_DIR 도 없을 때)
fakehome = Path(os.environ["TMPROOT_PY"]) / "fakehome"; (fakehome / "Library" / "LaunchAgents").mkdir(parents=True)
real_plist = fakehome / "Library" / "LaunchAgents" / "marina.discord.plist"; real_plist.write_text("실제 로그인 항목")
saved = {k: os.environ.pop(k, None) for k in ("MARINA_LAUNCH_AGENTS_DIR",)}
os.environ["HOME"] = str(fakehome)
check(ld.uninstall() == "absent" and real_plist.read_text() == "실제 로그인 항목", "격리 홈의 uninstall 은 실제 plist 를 안 지운다")
check(ld.ensure(prog).startswith("failed:") and real_plist.read_text() == "실제 로그인 항목", "격리 홈의 ensure 는 실제 plist 를 안 쓴다")
check(ld.uninstall(permanent=True) == "absent" and not (ms.marina_home() / "discord-daemon.off").exists(), "격리 홈은 끔 표식도 안 남긴다")
os.environ["MARINA_LAUNCH_AGENTS_DIR"] = saved["MARINA_LAUNCH_AGENTS_DIR"]
# 끔 표식: uninstall 이 남기고 ensure 가 해제하지 않는다(ensure_daemon 이 존중)
ld.ensure(prog)
check(ld.uninstall(permanent=True) == "removed" and ld.off_mark().exists(), "daemon-uninstall 은 끔 표식을 남긴다")
check(ms.ensure_daemon([str(ms.marina_home() / "bin" / "marina-session-hook")]) == "off", "끔 표식이 있으면 ensure_daemon 이 다시 등록하지 않는다")
check(not ld.plist_path().exists(), "다시 등록되지 않았다")
ld.clear_off()
check(not ld.off_mark().exists(), "daemon-install 이 표식을 푼다")
# daemon-uninstall 은 떼어 띄운 데몬(pid 파일)도 멈춘다
import subprocess
fake_d = Path(os.environ["TMPROOT_PY"]) / "marina_session.py"; fake_d.write_text("import time; time.sleep(100)\n")
proc = subprocess.Popen([sys.executable, str(fake_d), "daemon"]); ms.daemon_pid_path().write_text(f"{proc.pid}\n")
time.sleep(0.3)
ms.main(["daemon-uninstall"])
for _ in range(30):
    if proc.poll() is not None: break
    time.sleep(0.1)
check(proc.poll() is not None, "떼어 띄운 데몬에 SIGTERM")
check(ld.off_mark().exists(), "표식도 남는다")
# 끔 상태면 ls·start 가 알린다(--json 은 JSON 을 해치지 않게 건드리지 않는다)
import contextlib, io
def run_cli(argv):
    o, e = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
        try: ms.main(argv)
        except SystemExit: pass
    return o.getvalue(), e.getvalue()
o, e = run_cli(["ls"])
check("daemon-install" in o + e, f"ls 에 안내: {o + e!r}")
o, e = run_cli(["ls", "--json"])
check("daemon-install" not in o and o.strip().startswith("["), f"--json 은 그대로: {o[:80]!r}")
o, e = run_cli(["start"])
check("daemon-install" in o + e, "start 에 안내")
ld.clear_off()
o, e = run_cli(["ls"])
check("daemon-install" not in o + e, "켜져 있으면 안내 없음")
# 표식
os.environ.pop("MARINA_DISCORD_SUPERVISED", None)
check(ld.supervised() is False, "표식 없으면 아님")
os.environ["MARINA_DISCORD_SUPERVISED"] = "launchd"
check(ld.supervised() is True, "표식 있으면 launchd 자식")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
REAL="$HOME/Library/LaunchAgents/marina.discord.plist"
REAL_SUM_AFTER="$(cksum "$REAL" 2>/dev/null || echo none)"
[ "$REAL_SUM_AFTER" = "$REAL_SUM_BEFORE" ] || fail "테스트가 실제 로그인 항목을 건드렸다(전 $REAL_SUM_BEFORE · 후 $REAL_SUM_AFTER)"
echo "PASS test-discord-launchd"
