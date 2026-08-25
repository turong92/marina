#!/usr/bin/env bash
# 인수인계는 **정말 넘겨받았는지 확인**해야 한다 — 형: "이런식으로 되는데 왜그래? 원래 안그랬는데"
# (같은 대화가 원격 사이드바에 두 개로 보임, 2026-08-25).
#
# **실측.** 폰에서 보내자 마리나가 `claude --resume <sid>` 를 새로 띄웠는데(pid 85133), 원래
# 그 대화를 쥐고 있던 **Claude 데스크톱 앱 프로세스(pid 9837)가 그대로 살아 있었다.**
# 같은 세션 파일을 둘이 붙잡고 있으면 사이드바에 두 번 뜨고, 답이 엇갈려 쓰인다.
#
# 원인: _takeover_agent 가 SIGTERM→SIGKILL 을 쏘고는 **결과를 안 보고 무조건 True** 를 냈다.
# 데스크톱 앱은 죽은 프로세스를 되살리므로 "끊었다"가 사실이 아니었다.
#
# 규칙: 죽은 걸 확인해야 True. 못 끊었으면 **새로 띄우지 않는다** — 보류함에 넣고 사실대로 말한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import os
import signal
import subprocess

import marina_mobile as mm

mm.TAKEOVER_TIMEOUT_S = 0.3

# 1) 안 죽는 프로세스 — 신호를 삼키는 상황을 실제 프로세스로 만든다(데스크톱 앱이 되살리는
#    것과 같은 결과: 쏘고 나서도 살아 있다). 확인 후 False 여야 한다(예전엔 무조건 True).
버티는놈 = subprocess.Popen(["sleep", "30"])
원래kill = os.kill
os.kill = lambda pid, sig=0: None if sig in (signal.SIGTERM, signal.SIGKILL) else 원래kill(pid, sig)
try:
    assert mm._takeover_agent("claude", "s1", 버티는놈.pid) is False, "안 죽었는데 넘겨받았다고 한다"
finally:
    os.kill = 원래kill
    버티는놈.kill()
    버티는놈.wait()

# 2) 진짜 죽는 프로세스 — True. 좀비(부모가 아직 안 거둔 상태)도 "죽음"으로 세야 한다.
죽는놈 = subprocess.Popen(["sleep", "30"])
assert mm._takeover_agent("claude", "s1", 죽는놈.pid) is True, "끊었는데 실패로 본다"
죽는놈.wait()
print("ok 인수인계: 죽은 걸 확인해야 성공이다(좀비는 죽음으로 센다)")
PY

# ③ 못 끊었으면 새로 띄우지 않는다 — 보류함으로 간다.
PYTHONPATH="$SCR" python3 - <<'PY2'
import inspect

import marina_mobile as mm

원본 = inspect.getsource(mm.mobile_send)
자리 = 원본[원본.find("took_over = _takeover_agent"):][:900]
assert "not took_over" in 자리 or "if took_over" in 자리, \
    f"인수인계 실패를 무시하고 그대로 진행한다: {자리[:300]}"
assert "outbox" in 자리 or "보류" in 자리, f"실패 시 보류함으로 안 간다: {자리[:300]}"
print("ok 못 끊었으면 새로 안 띄우고 보류한다")
PY2

echo "PASS test-takeover-verify"
