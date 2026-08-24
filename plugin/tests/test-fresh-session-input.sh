#!/usr/bin/env bash
# 갓 띄운 세션에 첫 메시지를 넣을 때 **TUI 가 준비될 때까지 기다려야** 한다 — 형: "지금
# 로그인하고 새 대화 쳤는데 왜 반응이 없지?" (멤버 daeun 첫 사용, 2026-08-24).
#
# **실측.** 방을 열고(+ Claude) 바로 메시지를 보냈더니: launch 200, send 200 인데 아무 반응이
# 없었다. PTY 는 살아 있고(claude, cwd=~/.marina/chat) 트랜스크립트는 아예 안 생겼다.
# CLI 가 뜨는 데 몇 초 걸리는데 그 사이에 키를 밀어 넣어 통째로 사라진 것이다.
# 게다가 도착 확인 로직은 **트랜스크립트가 이미 있을 때만** 돌아서, 새 세션에서는 확인 없이
# "보냈다"고 답했다 — 조용히 틀리는 종류다.
#
# 규칙: 새 세션(트랜스크립트 없음)에 넣기 전에 화면이 잠잠해질 때까지 기다린다. 못 기다렸으면
# 성공을 지어내지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import marina_mobile as mm

기록 = []
mm.term_input = lambda tid, data: 기록.append(("입력", data))
mm._agent_input_pause = lambda: None

# 화면이 아직 안 잠잠한 척 → 두 번째 확인에서 준비됨
상태 = {"n": 0}
def 마크(tid):
    상태["n"] += 1
    return 상태["n"]
def 기다림(tid, since, quiet=0.12, timeout=2.0):
    기록.append(("대기", since))
    return True
mm.term_output_mark = 마크
mm.term_await_redraw = 기다림

mm._deliver_agent_input("tid-1", "claude", "안녕", fresh=True)
종류 = [k for k, _ in 기록]
assert "대기" in 종류, f"준비를 안 기다리고 바로 친다: {기록}"
assert 종류.index("대기") < 종류.index("입력"), f"치고 나서 기다린다: {기록}"

# 이미 쓰던 세션(fresh 아님)은 예전 그대로 — 기다림 없이 바로.
기록.clear()
mm._deliver_agent_input("tid-1", "claude", "안녕")
assert [k for k, _ in 기록] == ["입력", "입력"], f"쓰던 세션에 군더더기 대기가 붙었다: {기록}"
print("ok 새 세션엔 준비를 기다렸다 친다 · 쓰던 세션은 그대로")
PY

# 새 세션 전달은 **확인 없이 성공이라 답하지 않는다**.
PYTHONPATH="$SCR" python3 - <<'PY2'
import inspect

import marina_mobile as mm

원본 = inspect.getsource(mm._deliver_to_live_agent)
assert "fresh" in 원본, "새 세션 여부를 전달 경로가 모른다"
assert "_confirm_screen_echo" in 원본 or "echo" in 원본, \
    "새 세션에서 도착을 확인하지 않는다 — 조용히 사라져도 '보냈다'가 된다"
print("ok 새 세션도 도착을 확인한다")
PY2

echo "PASS test-fresh-session-input"
