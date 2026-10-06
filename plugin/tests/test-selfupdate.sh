#!/usr/bin/env bash
# runtimed 가 marina 새 버전을 받는다(2026-10-06) — 대시보드를 내려도 최신으로 유지되게.
#  - 받아서 검증하고 설치만. 재시작은 안 한다(runtimed 는 설치 경로가 바뀌면 스스로 다시 뜬다)
#  - 설치 전 사전 검증에 떨어지면 설치하지 않고 그 버전을 기록한다 · 격리 홈·Claude 설치 기록이 없는 맥은 받지 않는다
#  - 검증을 못 돌린 것(타임아웃 등)은 코드 탓이 아니다 — 버전을 막지 않고 다음 주기에 다시
#  - 대시보드 틱(marina_autoupdate)의 상태 파일을 안 건드린다 — 주기를 뺏으면 대시보드가 stale 재시작을 못 한다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"
# harness 는 MARINA_HOME 만 격리한다 — 이 테스트는 설치 기록·마켓 사본을 직접 쓰므로 Claude·Codex 홈도 임시로.
# (2026-10-06: 격리 없이 돌려 실제 ~/.claude/plugins/installed_plugins.json 을 덮어쓴 사고)
export CLAUDE_CONFIG_DIR="$MARINA_HOME/claude" CODEX_HOME="$MARINA_HOME/codex"

PYTHONPATH="$SCR" python3 - <<'PY'
import os
import marina_selfupdate as su
import marina_autoupdate as au
# 인계철선: 격리 안 된 Claude 홈이면 아무것도 하기 전에 멈춘다(2026-10-06 실제 설치 기록을 덮어쓴 사고)
assert str(su.CLAUDE_CONFIG_DIR).startswith(os.environ["MARINA_HOME"] + "/"), f"격리 안 된 Claude 홈: {su.CLAUDE_CONFIG_DIR}"
NOW = 1_790_000_000.0
cmds = []
def run_fn(argv):
    cmds.append(argv[1:] if argv and argv[0].endswith("claude") else argv); return 0, "ok"
ok_pre = lambda d: (True, "")
def tick(primary=True, now=NOW, installed="aaa111aaa111", new="bbb222bbb222", pre=ok_pre, run=run_fn, applied=True):
    # 설치본은 `plugin update` 가 성공한 뒤에야 새 버전으로 바뀐다(applied=False: 명령은 성공했는데 안 바뀜)
    def installed_fn():
        done = ["plugin", "update", "marina@marina-dev"] in cmds and applied
        return new if done and installed else installed
    return su.tick(primary, now=now, run_fn=run, preflight_fn=pre, installed_fn=installed_fn, new_fn=lambda: new)
def reset():
    cmds.clear()
    if su.STATE_FILE.exists(): su.STATE_FILE.unlink()

os.environ["MARINA_AUTO_UPDATE"] = "0"; assert tick() == "skipped:off"; del os.environ["MARINA_AUTO_UPDATE"]
assert tick(primary=False) == "skipped:not-primary" and not cmds, "격리 홈은 받지 않는다"
assert tick(installed=None) == "noop:unknown" and not cmds, "Claude 설치 기록이 없으면 받지 않는다"

# 새 버전: 마켓 갱신 → 검증 → 설치. 재시작 명령은 없다
reset()
assert tick() == "installed", su.LOG_FILE.read_text() if su.LOG_FILE.exists() else ""
assert cmds == [["plugin", "marketplace", "update", "marina-dev"], ["plugin", "update", "marina@marina-dev"]], cmds
assert "INSTALLED aaa111aaa111 → bbb222bbb222 (runtimed)" in su.LOG_FILE.read_text().splitlines()[-1]
assert su.STATE_FILE != au.STATE_FILE and not au.STATE_FILE.exists(), "대시보드 틱의 상태 파일은 안 건드린다"
# 주기 안이면 다시 안 본다 — 지나면 본다
cmds.clear()
assert tick(now=NOW + 60) == "skipped:not-due" and not cmds
# 이미 최신
assert tick(now=NOW + 7200, installed="bbb222bbb222") == "noop:current"
assert cmds == [["plugin", "marketplace", "update", "marina-dev"]], f"최신이면 갱신만 하고 설치 안 함: {cmds}"
# 검증 실패 → 설치 안 함 + 그 버전은 다시 안 받는다. 새 버전이 나오면 다시 받는다
reset()
assert tick(pre=lambda d: (False, "TypeError: unsupported operand")) == "rejected:preflight"
assert ["plugin", "update", "marina@marina-dev"] not in cmds
assert "REJECTED bbb222bbb222" in su.LOG_FILE.read_text().splitlines()[-1]
cmds.clear()
assert tick(now=NOW + 7200) == "skipped:bad-sha" and ["plugin", "update", "marina@marina-dev"] not in cmds
assert tick(now=NOW + 14400, new="ccc333ccc333") == "installed"
# 검증을 못 돌린 것(타임아웃·인터프리터 실행 실패)은 버전을 막지 않는다 — 다음 주기에 같은 버전을 다시 받는다
reset()
assert tick(pre=lambda d: (False, su.UNAVAILABLE + "timed out")) == "failed:preflight-unavailable"
assert ["plugin", "update", "marina@marina-dev"] not in cmds and "badSha" not in su._load()
assert tick(now=NOW + 7200) == "installed", "다음 주기엔 받는다"
# 명령 실패 — 기록을 남기고 이번 주기는 소모한다(매 틱 재시도하지 않는다)
reset()
assert tick(run=lambda argv: (1, "network down")) == "failed:marketplace"
assert "FAILED marketplace update" in su.LOG_FILE.read_text().splitlines()[-1]
assert tick(now=NOW + 600) == "skipped:not-due", "실패해도 주기는 소모"
reset()
def half(argv):
    return (1, "boom") if argv[1:3] == ["plugin", "update"] else (0, "ok")
assert tick(run=half) == "failed:plugin-update"
# 사본의 HEAD 를 못 읽으면 조용히 '최신'이라 하지 않는다
reset()
assert tick(new=None) == "failed:marketplace-sha" and "HEAD" in su.LOG_FILE.read_text().splitlines()[-1]
# 명령은 성공했는데 설치본이 안 바뀌면 설치했다고 적지 않는다
reset()
assert tick(applied=False) == "failed:not-applied"
assert "INSTALLED" not in su.LOG_FILE.read_text().splitlines()[-1]
# 예외가 나도 밖으로 안 내고 주기는 소모한다
reset()
def boom(d): raise OSError("disk full")
assert tick(pre=boom).startswith("failed:") and tick(now=NOW + 600) == "skipped:not-due"
# 다른 업데이트(대시보드·discord)가 잠금을 쥐고 있으면 미루고 주기를 소모하지 않는다
reset()
lock = su._update_lock(); assert lock is not None
assert tick() == "deferred:lock" and not su.STATE_FILE.exists()
lock.close()
assert tick() == "installed"
# 실구현: 설치본 SHA(설치 기록의 폴더 이름) · 사본 HEAD(git) · 검증은 새 코드에 없는 모듈을 건너뛴다
import json, subprocess, tempfile
from pathlib import Path
cfg = su.CLAUDE_CONFIG_DIR
(cfg / "plugins").mkdir(parents=True, exist_ok=True)
def manifest(path):
    (cfg / "plugins" / "installed_plugins.json").write_text(json.dumps({"plugins": {"marina@marina-dev": [{"installPath": path}]}}))
manifest("/x/cache/marina-dev/marina/abcdef123456"); assert su.installed_sha() == "abcdef123456"
manifest("/x/dev/marina/plugin"); assert su.installed_sha() is None, "SHA 폴더가 아니면 받지 않는다"
repo = su.marketplace_scripts_dir().parent.parent; (repo / "plugin" / "scripts").mkdir(parents=True, exist_ok=True)
assert su.marketplace_sha() is None, "git 사본이 아니면 None"
g = lambda *a: subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *a], check=True, capture_output=True)
g("init", "-q"); (repo / "f").write_text("x"); g("add", "f"); g("commit", "-qm", "c")
head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
assert su.marketplace_sha() == head[:12], (su.marketplace_sha(), head)
with tempfile.TemporaryDirectory() as d:
    (Path(d) / "marina_state.py").write_text("X = 1\n")              # 목록의 나머지 모듈·파일은 이 버전에 없다
    assert su.preflight(Path(d)) == (True, ""), "없는 모듈은 건너뛴다 — 옛 목록이 새 릴리스를 막지 않게"
    (Path(d) / "marina_runtimed.py").write_text("def f(:\n")
    ok, err = su.preflight(Path(d)); assert not ok and err and not su.unavailable(err), "있는 모듈이 안 뜨면 거부(코드 탓)"
    ok, err = su.preflight(Path(d), python="/nonexistent/python3"); assert not ok and su.unavailable(err), "인터프리터를 못 돌리면 '검증 불가'"
ok, err = su.preflight(Path("/nonexistent/scripts")); assert not ok and not su.unavailable(err), "검사할 폴더가 없으면 통과시키지 않는다"
# 시스템 파이썬은 쓸 수 있을 때만 후보 — 못 돌리는 것·이 프로세스와 같은 것은 뺀다
import sys
assert su.preflight_pythons("/nonexistent/python3") == [sys.executable]
assert su.preflight_pythons(sys.executable) == [sys.executable], "같은 인터프리터를 두 번 돌리지 않는다"
assert su._probe(sys.executable) == (tuple(sys.version_info[:2]), os.path.realpath(sys.executable))
# 공용 부품은 한 벌 — 대시보드 틱도 같은 것을 쓴다
assert au.preflight is su.preflight and au._update_lock is su._update_lock and au.enabled is su.enabled
print("ok")
PY
echo "PASS test-selfupdate"
