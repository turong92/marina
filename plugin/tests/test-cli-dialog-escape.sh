#!/usr/bin/env bash
# CLI 가 **선택창을 띄운 채 멈춘 것**을 마리나가 알아보고, 폰에서 풀 수 있어야 한다.
#
# 실측 사고(2026-09-09): `/resume` 이 세션 선택 다이얼로그를 열어 CLI 가 멈췄고, 그 세션이
# 클라우드 브리지까지 붙들어 데스크탑 앱이 47분간 스피너였다. 마리나 화면은 그냥 "대기 중"
# 이라고만 했고, 폰에는 Esc 를 보낼 수단이 아예 없어 맥 앞에 갈 때까지 못 풀었다.
#
# Claude Code 는 `~/.claude/sessions/<pid>.json` 에 자기 상태를 적는다
# (`status: "waiting"`, `waitingFor: "dialog open"`). 마리나는 PTY 의 pid 를 아니까 읽을 수 있다.
# **모든 읽기는 fail-open** — 이 파일은 CLI 내부 계약이라 포맷이 바뀌면 표시가 안 뜰 뿐,
# 기존 동작은 그대로여야 한다.
#
# 계약: ① waiting+waitingFor 면 알린다 ② 그 외/없음/깨짐은 조용히 없음 ③ pid 재사용을
# procStart 로 막는다 ④ Esc 는 살아있는 PTY 에만 가고, 없으면 정직하게 실패한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" "$HERE" <<'PY'
import json
import sys
from pathlib import Path

import marina_mobile as mm

tmp, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
mm.CLAUDE_HOME = tmp / "claude"
(tmp / "claude" / "sessions").mkdir(parents=True)
mm.safe_root = lambda value: Path(str(value)).resolve()

def 적기(pid, **fields):
    (mm.CLAUDE_HOME / "sessions" / f"{pid}.json").write_text(
        json.dumps({"pid": pid, **fields}), encoding="utf-8")

# ① 선택창에 갇힌 상태를 알아본다.
적기(111, status="waiting", waitingFor="dialog open", procStart="Wed Sep  9 04:41:45 2026")
갇힘 = mm.cli_dialog_state(111, "Wed Sep  9 04:41:45 2026")
assert 갇힘 and 갇힘.get("waitingFor") == "dialog open", 갇힘

# ② 그 외는 조용히 없음 — 일하는 중·유휴·파일 없음·깨진 JSON 모두.
적기(222, status="busy")
assert mm.cli_dialog_state(222, "") == {}, "작업 중인데 선택창이라고 했다"
적기(223, status="waiting")                      # waitingFor 가 비었다 = 무엇을 기다리는지 모름
assert mm.cli_dialog_state(223, "") == {}, "이유를 모르는데 선택창이라고 했다"
assert mm.cli_dialog_state(999, "") == {}, "없는 파일에 반응했다"
(mm.CLAUDE_HOME / "sessions" / "224.json").write_text("{깨짐", encoding="utf-8")
assert mm.cli_dialog_state(224, "") == {}, "깨진 파일에 터졌다"   # fail-open

# ③ pid 재사용 방어 — 지문이 다르면 남의 프로세스다.
적기(333, status="waiting", waitingFor="dialog open", procStart="Wed Sep  9 04:41:45 2026")
assert mm.cli_dialog_state(333, "Tue Sep  8 01:02:03 2026") == {}, "pid 재사용을 안 걸렀다"
# 지문을 모를 때는 막지 않는다(fail-open) — 모르는 것과 틀린 것은 다르다.
assert mm.cli_dialog_state(333, "").get("waitingFor") == "dialog open"

# ④ Esc 는 살아있는 PTY 로 간다.
보낸키 = []
mm.term_input = lambda tid, data: 보낸키.append((tid, data))
mm._live_agent_tid = lambda r, s, i: "tid-1"
out = mm.mobile_escape({"root": str(root), "source": "claude", "sid": "sid-1"})
assert out.get("ok") and 보낸키 == [("tid-1", "\x1b")], 보낸키

# PTY 가 없으면 **정직하게 실패한다** — 눌렀는데 아무 일도 안 나면 고장으로 보인다.
mm._live_agent_tid = lambda r, s, i: ""
보낸키.clear()
try:
    mm.mobile_escape({"root": str(root), "source": "claude", "sid": "sid-1"})
except ValueError as exc:
    assert str(exc), "이유 없는 실패"
else:
    raise AssertionError("PTY 가 없는데 성공이라 답했다")
assert 보낸키 == []

print("ok")
PY
echo "PASS: 선택창에 갇힌 CLI 를 알아보고 폰에서 Esc 로 푼다"
