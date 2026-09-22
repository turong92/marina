#!/usr/bin/env bash
# 강제 자동 업데이트 — 형(2026-09-22): "업데이트 하라고 하면 말 안 들으니까 강제로 한 번에".
# 핵심 안전장치: 설치 **전에** 새 코드를 데몬 인터프리터로 import 해 보고, 실패하면 설치하지 않는다
# (2026-09-17 `str | None` 한 줄이 3.9 데몬을 죽인 사고가 팀 전체로 퍼지는 걸 막는다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import os
from pathlib import Path
import marina_autoupdate as au

NOW = 1_790_000_000.0
cmds, restarts = [], []
def run_fn(argv):
    cmds.append(argv[1:] if argv and argv[0].endswith("claude") else argv); return 0, "ok"
def restart_fn():
    restarts.append(1); return 0, "dashboard restart scheduled"
ok_pre = lambda d: (True, "")
bad_pre = lambda d: (False, "TypeError: unsupported operand type(s) for |")
def status(kind, serving="aaa111", installed="aaa111", origin="bbb222"):
    return lambda: {"state": kind, "serving": serving, "installed": installed, "origin": origin}
def tick(**kw):
    base = dict(port=3900, now=NOW, primary=True, run_fn=run_fn, restart_fn=restart_fn, busy_fn=lambda: False, preflight_fn=ok_pre,
                clients_fn=lambda: False, installed_dir_fn=lambda: Path("/installed/scripts"))
    base.update(kw); return au.auto_update_tick(**base)
def reset():
    cmds.clear(); restarts.clear()
    if au.STATE_FILE.exists(): au.STATE_FILE.unlink()

# 끄기 / 기록된 데몬 아님
os.environ["MARINA_AUTO_UPDATE"] = "0"; assert tick(status_fn=status("new")) == "skipped:off"; del os.environ["MARINA_AUTO_UPDATE"]
assert tick(status_fn=status("new"), primary=False) == "skipped:not-primary" and not cmds

# new: 마켓 갱신 → 검증 → 설치 → 재시작
reset()
assert tick(status_fn=status("new")) == "updated", au.LOG_FILE.read_text()
assert cmds == [["plugin", "marketplace", "update", "marina-dev"], ["plugin", "update", "marina@marina-dev"]], cmds
assert restarts == [1]
st = au.load_state(); assert st["updatedTo"] == "bbb222" and st["updatedFrom"] == "aaa111", st
assert "UPDATED aaa111 → bbb222 (restarted)" in au.LOG_FILE.read_text().splitlines()[-1]

# 주기 안이면 다시 안 본다
assert tick(status_fn=status("new"), now=NOW + 600) == "skipped:not-due"

# 검증 실패 → 설치·재시작 안 함, 그 SHA 는 다시 시도 안 함, 새 SHA 가 나오면 다시 시도
reset()
assert tick(status_fn=status("new"), preflight_fn=bad_pre) == "rejected:preflight"
assert cmds == [["plugin", "marketplace", "update", "marina-dev"]] and not restarts, (cmds, restarts)
assert au.load_state()["badSha"] == "bbb222" and "REJECTED bbb222" in au.LOG_FILE.read_text().splitlines()[-1]
cmds.clear()
assert tick(status_fn=status("new"), now=NOW + 7200) == "skipped:bad-sha" and not cmds
assert tick(status_fn=status("new", origin="ccc333"), now=NOW + 3 * 3600) == "updated"

# 기동 중이면 미룬다(주기를 소모하지 않아 다음 틱에 바로 다시)
reset()
assert tick(status_fn=status("new"), busy_fn=lambda: True) == "deferred:busy" and not cmds
assert tick(status_fn=status("new"), now=NOW + 600) == "updated"

# 설치하는 몇 분 사이에 기동이 시작되면 재시작 직전 게이트가 잡는다 → 설치만 하고 다음 틱(stale)에 재시작
reset()
seq = iter([False, True])                                        # 설치 전엔 한가, 재시작 직전엔 바쁨
assert tick(status_fn=status("new"), busy_fn=lambda: next(seq)) == "installed:deferred:busy" and not restarts
assert tick(status_fn=status("stale", installed="bbb222"), now=NOW + 600) == "restarted" and restarts == [1]

# 대시보드·폰이 붙어 있으면 최대 6시간 미룬다
reset()
assert tick(status_fn=status("stale", installed="bbb222"), clients_fn=lambda: True) == "deferred:clients" and not restarts
assert tick(status_fn=status("stale", installed="bbb222"), clients_fn=lambda: True, now=NOW + 3 * 3600) == "deferred:clients"
assert tick(status_fn=status("stale", installed="bbb222"), clients_fn=lambda: True, now=NOW + 7 * 3600) == "restarted", "6시간 넘으면 한다"

# 재시작해도 안 바뀌면 3번에서 멈춘다(매시간 재시작 루프 방지)
reset()
for i in range(3):
    assert tick(status_fn=status("stale", installed="bbb222"), now=NOW + i * 7200) == "restarted"
assert tick(status_fn=status("stale", installed="bbb222"), now=NOW + 4 * 7200) == "gave-up" and restarts == [1, 1, 1]
assert tick(status_fn=status("stale", installed="ddd444"), now=NOW + 5 * 7200) == "restarted", "새 버전이면 다시 시도"

# 설치된 코드 자체가 안 뜨면(검증~설치 사이 경합 등) 재시작하지 않고 옛 데몬 유지
reset()
pre_calls = []
def pre_seq(d):
    pre_calls.append(str(d)); return (True, "") if len(pre_calls) == 1 else (False, "SyntaxError")
assert tick(status_fn=status("new"), preflight_fn=pre_seq) == "installed:rejected:installed" and not restarts
assert pre_calls == [str(au.marketplace_scripts_dir()), "/installed/scripts"], pre_calls
assert au.load_state()["badSha"] == "bbb222"
assert tick(status_fn=status("stale", installed="bbb222"), now=NOW + 7200) == "skipped:bad-sha" and not restarts

# stale: 재시작만 / current·unknown: 아무것도
reset()
assert tick(status_fn=status("stale", installed="bbb222")) == "restarted" and restarts == [1] and not cmds
reset()
assert tick(status_fn=status("current", serving="bbb222")) == "noop:current" and not cmds and not restarts
reset()
assert tick(status_fn=status("unknown", serving=None)) == "noop:unknown" and not cmds

# 실패 경로
reset()
assert tick(status_fn=status("new"), run_fn=lambda a: (1, "network down")) == "failed:marketplace" and not restarts
def boom(): raise RuntimeError("status broke")
reset()
assert tick(status_fn=boom).startswith("failed:") and "FAILED status broke" in au.LOG_FILE.read_text().splitlines()[-1]
print("ok")
PY

# ── 실제 사전 검증: 지금 코드는 통과, 3.9 에서 안 뜨는 코드는 거부 ──
PY39=""
for c in /Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3 /usr/bin/python3; do
  if [ -x "$c" ] && "$c" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 9) else 1)' 2>/dev/null; then PY39="$c"; break; fi
done
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp -R "$SCR" "$T/good"; cp -R "$SCR" "$T/bad"
printf '\ndef _broken(x: str | None = None):\n    return x\n' >> "$T/bad/marina-compose.py"
PYTHONPATH="$SCR" python3 - "$T" "${PY39:-}" <<'PY'
import sys
from pathlib import Path
import marina_autoupdate as au
T, py39 = Path(sys.argv[1]), sys.argv[2] or None
ok, err = au.preflight(T / "good", python=py39)
assert ok, ("지금 코드는 통과해야", err)
if py39:
    ok, err = au.preflight(T / "bad", python=py39)
    assert not ok and "unsupported operand" in err, ("3.9 에서 안 뜨는 코드는 거부", ok, err)
    print("ok preflight (3.9)")
else:
    print("ok preflight (3.9 없음 — 거부 경로 생략)")
PY
echo "PASS test-auto-update"
