#!/usr/bin/env bash
# 고아 백그라운드 프로세스 리퍼 — Claude Code 세션이 Bash 로 띄운 백그라운드 프로세스가 세션 종료 후
# ppid=1 고아로 남아 수 주 동안 살아 있었다(2026-09-14 실측: `python -` heredoc 5일 CPU 97%,
# http.server 779개, storybook 49일 ...). 강한 시그니처 둘로만 판정한다:
#   1) ppid==1 이고 fd1/fd2 가 /private/tmp/claude-<uid>/**/tasks/*.output (삭제된 파일 포함)
#   2) ppid==1 이고 cwd 디렉터리가 사라짐 (marina 데몬·caddy·시스템 경로 제외)
# 여기에 "시작 후 N시간" 을 넘긴 것만 SIGTERM→10s→SIGKILL. 세션 liveness 와 같은 규칙: argv 를
# 판정에 쓰지 않는다(ps comm + lsof cwd/fd 만). argv 는 로그에 남길 뿐이다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"

# e2e 용 실제 경로: 시그니처 1 은 /private/tmp/claude-<uid>/ 밑 고정 경로라 거기에 테스트 전용 하위 폴더를 쓴다.
TASKS_ROOT="/private/tmp/claude-$(id -u)/marina-test-reaper/$(basename -- "$0" .sh)"
rm -rf "$TASKS_ROOT"; mkdir -p "$TASKS_ROOT/sid1/tasks"
GONE_DIR="$MARINA_HOME/gone-cwd"; mkdir -p "$GONE_DIR"
cleanup() { pkill -f "sleep 7301" 2>/dev/null || true; pkill -f "sleep 7302" 2>/dev/null || true; rm -rf "$TASKS_ROOT"; }
trap cleanup EXIT

# 고아 1: stdout/stderr 가 tasks/*.output (그 뒤 파일은 삭제 — 실측 사례처럼)
( sleep 7301 >"$TASKS_ROOT/sid1/tasks/abc.output" 2>&1 & )
# 고아 2: cwd 가 곧 사라짐
( cd "$GONE_DIR"; sleep 7302 >/dev/null 2>&1 & )   # 리스트(cd && sleep &)면 bash 가 중간 셸을 남겨 ppid≠1
sleep 1.5   # ps etime 은 초 단위라 00:00(나이 0)이면 제외된다 — 1초는 넘겨야 한다
rm -f "$TASKS_ROOT/sid1/tasks/abc.output"
rmdir "$GONE_DIR"
P1="$(pgrep -f 'sleep 7301' | head -1)"; P2="$(pgrep -f 'sleep 7302' | head -1)"
[ -n "$P1" ] && [ -n "$P2" ] || { echo "FAIL: 고아 프로세스를 띄우지 못했다"; exit 1; }

python3 - "$SCRIPTS" "$P1" "$P2" "$TASKS_ROOT" <<'PY'
import os, subprocess, sys, time
from pathlib import Path
scripts = Path(sys.argv[1]); p1, p2 = int(sys.argv[2]), int(sys.argv[3]); tasks_root = sys.argv[4]
sys.path.insert(0, str(scripts))
import marina_reaper as mr

fails = []
def check(cond, msg):
    if not cond: fails.append(msg)

# ── 1) etime 파싱: ps 의 [[dd-]hh:]mm:ss ──────────────────────────────────────────────
check(mr.parse_etime("00:01") == 1, "etime mm:ss")
check(mr.parse_etime("1:02:03") == 3723, "etime hh:mm:ss")
check(mr.parse_etime("122-23:35:42") == 122*86400 + 23*3600 + 35*60 + 42, "etime dd-hh:mm:ss")
check(mr.parse_etime("garbage") == 0, "etime garbage → 0 (판정 보수적: 나이 0 이면 안 죽인다)")

# ── 2) ps 파싱: comm 에 공백이 있어도(앱 번들 경로·"redis-server *:6379") 깨지지 않는다 ─────
ps_out = "\n".join([
    "  139     1 122-23:35:42 autofsd",
    " 4239     1  13-02:11:00 /Users/x/.venv/bin/python",
    "53536     1  88-20:00:01 /Users/x/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient",
    "44031     1  95-05:20:02 /opt/homebrew/bin/redis-server *:6379",
    "  777   555       00:03 sleep",
    "bad line",
])
table = mr.parse_ps(ps_out)
check(table[53536] == (1, 88*86400 + 20*3600 + 1, "/Users/x/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient"),
      f"ps comm with spaces: {table.get(53536)}")
check(table[44031][2] == "/opt/homebrew/bin/redis-server *:6379", "ps comm with trailing args-like text")
check(table[777] == (555, 3, "sleep"), f"ps plain: {table.get(777)}")
check(set(table) == {139, 4239, 53536, 44031, 777}, f"ps bad line skipped: {set(table)}")

# ── 3) lsof -Fpfn 파싱: pid → cwd, fd1, fd2 ─────────────────────────────────────────────
lsof_out = "\n".join(["p10", "fcwd", "n/a/b", "f1", "n/dev/null", "f2", "n/x/tasks/q.output",
                      "p11", "fcwd", "n/gone", "f1", "n", "f2", "n"])
fds = mr.parse_lsof(lsof_out)
check(fds[10] == {"cwd": "/a/b", "1": "/dev/null", "2": "/x/tasks/q.output"}, f"lsof pid 10: {fds.get(10)}")
check(fds[11] == {"cwd": "/gone", "1": "", "2": ""}, f"lsof pid 11 empty names: {fds.get(11)}")

# ── 4) 판정(순수): reason 문자열 또는 None ───────────────────────────────────────────────
ROOT = f"/private/tmp/claude-{os.getuid()}"
OUT = f"{ROOT}/-Users-x-proj/0123-sid/tasks/bw2vtkx6s.output"     # 실측 형태
existing_cwd = str(scripts)                                       # 실제로 존재하는 디렉터리
gone_cwd = str(Path(os.environ["MARINA_HOME"]) / "definitely-gone")
H = 6 * 3600
def cls(ppid=1, age=H + 1, comm="/usr/local/bin/python3", cwd=existing_cwd, fd1="/dev/null", fd2="/dev/null", pid=4242):
    return mr.classify(pid, ppid, age, comm, {"cwd": cwd, "1": fd1, "2": fd2}, min_age_s=H, protected={1})

check(cls(fd1=OUT) == "claude-task-output", f"sig1 fd1 → {cls(fd1=OUT)}")
check(cls(fd2=OUT) == "claude-task-output", "sig1 fd2")
check(cls(fd1=OUT, cwd=gone_cwd) == "claude-task-output", "sig1 wins over sig2 when both (more specific)")
check(cls(cwd=gone_cwd) == "cwd-gone", f"sig2 → {cls(cwd=gone_cwd)}")
check(cls() is None, "healthy orphan (cwd exists, no task output) untouched")
check(cls(ppid=555, fd1=OUT) is None, "ppid != 1 never reaped (parent still owns it)")
check(cls(fd1=OUT, age=H - 1) is None, "younger than min age untouched")
check(cls(fd1=OUT, age=0) is None, "age 0 (etime unparsable) untouched")
check(cls(fd1=f"{ROOT}/x/tasks/notes.txt") is None, "tasks/ but not .output → not a task output")
check(cls(fd1=f"{ROOT}/x/other/a.output") is None, "*.output outside tasks/ → no")
check(cls(fd1="/tmp/elsewhere/tasks/a.output") is None, "tasks/*.output outside claude tmp root → no")
check(cls(fd1=f"/private/tmp/claude-{os.getuid() + 1}/x/tasks/a.output") is None, "other uid's claude tmp → no")
# 제외: marina 데몬 자신·게이트웨이(caddy)·시스템 경로
check(cls(pid=1, cwd=gone_cwd) is None, "protected pid (self/daemon) excluded")
check(cls(comm="/opt/homebrew/bin/caddy", cwd=gone_cwd) is None, "caddy excluded")
check(cls(comm="caddy", cwd=gone_cwd) is None, "caddy (bare comm) excluded")
for sysc in ("/System/Library/x/y", "/usr/libexec/z", "/Applications/Foo.app/Contents/MacOS/Foo"):
    check(cls(comm=sysc, cwd=gone_cwd) is None, f"system comm excluded: {sysc}")
check(cls(comm="/usr/libexec/z", fd1=OUT) == "claude-task-output", "sig1 is not subject to the system-path exclusion (a claude task is a claude task)")
check(cls(comm="/usr/local/bin/node", cwd=gone_cwd) == "cwd-gone", "/usr/local is user-installed, not system")
check(cls(cwd="") is None, "empty cwd (lsof gave nothing) → no judgement")

# ── 5) e2e: scan 이 실제 고아 둘을 찾고, dry-run 은 안 죽이고, reap 은 죽이고 로그를 남긴다 ─
cands = {c.pid: c for c in mr.scan(min_age_s=0)}
check(p1 in cands and cands[p1].reason == "claude-task-output", f"live orphan with deleted task output found: {cands.get(p1)}")
check(p2 in cands and cands[p2].reason == "cwd-gone", f"live orphan with deleted cwd found: {cands.get(p2)}")
if p1 in cands:
    check("sleep 7301" in cands[p1].argv, f"argv captured for log: {cands[p1].argv!r}")
    check(cands[p1].fd_path.endswith("/tasks/abc.output"), f"fd path captured: {cands[p1].fd_path}")
check(os.getpid() not in cands, "the scanning process itself is never a candidate")

# 데몬 보호: `marina reap` CLI 는 데몬과 다른 프로세스라 os.getpid() 로는 데몬을 못 알아본다.
# 데몬 pid 는 $MARINA_HOME/dashboard.pid(marina-dashboard.sh 가 쓴다) — 그 pid 는 무슨 시그니처든 건드리지 않는다.
pidfile = Path(os.environ["MARINA_HOME"]) / "dashboard.pid"
pidfile.write_text(f"{p2}\n")
check(p2 not in {c.pid for c in mr.scan(min_age_s=0)}, "pid in dashboard.pid (the daemon) must never be a candidate, even with cwd gone")
check(p1 in {c.pid for c in mr.scan(min_age_s=0)}, "other candidates unaffected by the pidfile")
pidfile.write_text("not-a-pid\n")
check(p2 in {c.pid for c in mr.scan(min_age_s=0)}, "garbage pidfile protects nothing (and does not crash)")
pidfile.unlink()

log = Path(os.environ["MARINA_HOME"]) / "reaper.log"
done = mr.reap(min_age_s=0, dry_run=True, only={p1, p2})
check({c.pid for c in done} == {p1, p2}, f"dry-run reports both: {[c.pid for c in done]}")
time.sleep(0.2)
check(os.kill(p1, 0) is None and os.kill(p2, 0) is None, "dry-run must not kill")
text = log.read_text() if log.exists() else ""
check("dry-run" in text and str(p1) in text and "claude-task-output" in text and "sleep 7301" in text,
      f"dry-run logged with pid/argv/reason: {text!r}")

done = mr.reap(min_age_s=0, dry_run=False, only={p1, p2})
check({c.pid for c in done} == {p1, p2}, f"reap reports both: {[c.pid for c in done]}")
deadline = time.time() + 3
while time.time() < deadline:
    try:
        os.kill(p1, 0); os.kill(p2, 0); time.sleep(0.1)
    except ProcessLookupError:
        break
alive = []
for p in (p1, p2):
    try:
        os.kill(p, 0); alive.append(p)
    except ProcessLookupError:
        pass
check(not alive, f"reap must kill both, still alive: {alive}")
text = log.read_text()
check("cwd-gone" in text and str(p2) in text and "SIGTERM" in text, f"reap logged pid/cwd/reason/signal: {text!r}")
check(mr.reap(min_age_s=0, dry_run=False, only={p1, p2}) == [], "second pass finds nothing (they are gone)")

# ── 6) 옵트아웃·설정 ──────────────────────────────────────────────────────────────────
os.environ["MARINA_REAPER"] = "0"; check(mr.enabled() is False, "MARINA_REAPER=0 disables")
os.environ["MARINA_REAPER"] = "off"; check(mr.enabled() is False, "MARINA_REAPER=off disables")
os.environ.pop("MARINA_REAPER"); check(mr.enabled() is True, "default enabled")
os.environ.pop("MARINA_REAPER_MIN_AGE_H", None); check(mr.min_age_s() == 6 * 3600, "default min age 6h")
os.environ["MARINA_REAPER_MIN_AGE_H"] = "1.5"; check(mr.min_age_s() == 5400, "min age configurable (hours, fractional ok)")
os.environ["MARINA_REAPER_MIN_AGE_H"] = "bogus"; check(mr.min_age_s() == 6 * 3600, "bogus min age → default")

if fails:
    print("FAIL")
    for f in fails: print("  -", f)
    sys.exit(1)
print("PASS: reaper classifies by ppid/lsof only, reaps both signatures, logs, opt-out")
PY

# ── 7) CLI: marina.sh reap --dry-run (데몬 없이, 격리 MARINA_HOME) ───────────────────────
# **dry-run 만 돌린다.** 실제 reap 은 이 머신의 진짜 고아까지 죽인다 — 테스트가 형의 프로세스를 건드리면 안 된다.
# 죽이는 경로는 위 python 구간에서 `only=` 로 범위를 묶어 검증했다. main() 은 reap() 에 인자만 넘긴다.
( sleep 7301 >"$TASKS_ROOT/sid1/tasks/def.output" 2>&1 & ); sleep 1.5
P3="$(pgrep -f 'sleep 7301' | head -1)"
out="$(bash "$SCRIPTS/marina.sh" reap --dry-run --min-age-hours 0 2>&1)" || { echo "FAIL: marina.sh reap --dry-run exit $?: $out"; exit 1; }
echo "$out" | grep -q "pid=$P3 reason=claude-task-output" || { echo "FAIL: CLI dry-run should list pid $P3 with reason: $out"; exit 1; }
kill -0 "$P3" 2>/dev/null || { echo "FAIL: CLI dry-run killed the process"; exit 1; }
grep -q "dry-run pid=$P3" "$MARINA_HOME/reaper.log" || { echo "FAIL: CLI dry-run should log to \$MARINA_HOME/reaper.log"; exit 1; }
echo "PASS: marina reap --dry-run CLI lists candidates without killing"

# ── 8) 설치 shim 경로(marina-entrypoint.sh) 로도 닿는다 — 배포 첫날 `marina reap` 이 usage 만 찍던 회귀 방지 ──
# entrypoint 는 그룹 명령을 marina.sh 에 위임하는 허용 목록을 갖고 있어, 새 명령은 여기 빠지면 shim 에서 사라진다.
out="$(bash "$SCRIPTS/marina-entrypoint.sh" reap --dry-run --min-age-hours 0 2>&1)" || { echo "FAIL: entrypoint reap --dry-run exit $?: $out"; exit 1; }
echo "$out" | grep -q "pid=$P3 reason=claude-task-output" || { echo "FAIL: entrypoint should route reap to marina.sh (got usage?): $out"; exit 1; }
kill -0 "$P3" 2>/dev/null || { echo "FAIL: entrypoint dry-run killed the process"; exit 1; }
kill "$P3" 2>/dev/null || true
echo "PASS: marina-entrypoint.sh routes reap"
