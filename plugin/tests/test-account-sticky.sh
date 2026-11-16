#!/usr/bin/env bash
# 계정을 따로 안 정한 방은 깰 때 내리기 전에 쓰던 계정으로 다시 뜬다(형 2026-11-16: 밤글 방이 A 로 돌다 쉬어 내린 뒤
# 깰 때 프로젝트 기본 B 로 떴다). 단 그 뒤에 사람이 프로젝트·기본 계정을 바꿨거나, 한도로 잠시 옮겼다 되돌린 거면 설정을 따른다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"
mkdir -p "$MARINA_HOME/accounts"; printf 'sk-ant-oat-TEST-B\n' > "$MARINA_HOME/accounts/b.token"; chmod 600 "$MARINA_HOME/accounts/b.token"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import os, time
from pathlib import Path
import marina_session as ms
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def age(p, t):
    os.utime(p, (t, t))
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"])
now = time.time()
ms.set_project_account("proj", "b"); age(ms.accounts_dir() / "projects.json", now - 1000)

# 고정 없는 방이 a 로 돌았다 → 깰 때도 a(프로젝트 기본 b 가 아니라)
(sd / "account-last").write_text("a\n"); age(sd / "account-last", now - 100)
check(ms.account_of(sd) == "a", f"쓰던 계정 a 로: {ms.account_of(sd)}")
check(ms.ACCOUNT_TOKEN_ENV not in ms.session_env(sd), "띄울 때도 a(토큰 없음)")

# 기록이 아직 없는 방(이번 배포 전에 뜬 방)은 account-running 을 쓴다
(sd / "account-last").unlink()
(sd / "account-running").write_text("a\n"); age(sd / "account-running", now - 100)
check(ms.account_of(sd) == "a", f"account-running 으로 대신: {ms.account_of(sd)}")
# 단 배포 전에 한도로 옮겼던 방은 account-running 이 옮긴 계정일 수 있어 안 믿는다(리뷰 I1)
(sd / "account-failover-at").write_text("1\n")
check(ms.account_of(sd) == "b", f"한도로 옮겼던 방은 대신 안 씀: {ms.account_of(sd)}")
(sd / "account-failover-at").unlink()

# 그 뒤에 사람이 프로젝트 계정을 바꿨으면 설정을 따른다
(sd / "account-last").write_text("a\n"); age(sd / "account-last", now - 100)
ms.set_project_account("proj", "b")
check(ms.account_of(sd) == "b", f"프로젝트 계정을 새로 정하면 그쪽: {ms.account_of(sd)}")
age(ms.accounts_dir() / "projects.json", now - 1000)
ms.set_default_account("b")
check(ms.account_of(sd) == "b", f"기본 계정을 새로 정해도 그쪽: {ms.account_of(sd)}")
(ms.accounts_dir() / "default").unlink()

# 사람이 방 고정을 지우면 설정을 따른다
ms.set_account(sd, "a"); ms.clear_account(sd)
check(ms.account_of(sd) == "b", f"고정 지우면 설정: {ms.account_of(sd)}")

# 한도로 잠시 옮겼다(고정 없던 방 → a) 되돌리면 옮긴 계정에 남지 않는다
ms.clear_account(sd)
ms.fallback_account(sd, "a")
(sd / "account-last").write_text("a\n"); (sd / "account-running").write_text("a\n")   # a 로 다시 떴다
ms.restore_account(sd)
check(ms.account_of(sd) == "b", f"되돌리면 프로젝트 기본 b: {ms.account_of(sd)}")

# 방 고정이 있으면 고정이 이긴다
ms.set_account(sd, "b"); (sd / "account-last").write_text("a\n")
check(ms.account_of(sd) == "b", "방 고정이 이긴다")
ms.clear_account(sd)

# 없는 계정 이름이 남아 있으면 무시
(sd / "account-last").write_text("zz\n"); age(sd / "account-last", now)
check(ms.account_of(sd) == "b", f"없는 계정은 무시: {ms.account_of(sd)}")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
print("PASS test-account-sticky")
PY
