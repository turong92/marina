#!/usr/bin/env bash
# (형 2026-10-23) 멈춘 서브에이전트(8시간 무기록)·남은 셸이 '일하는 중'으로 잡혀 방이 며칠씩 안 잠들었다
#  → 대화·서브에이전트 기록이 2시간 넘게 안 움직였으면 백그라운드 이유는 잠재우기를 막지 않는다. 그 밖의 이유(질문 등)는 그대로 막는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$MARINA_HOME" <<'PY'
import os, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
import marina_discord_idle as mi
import marina_discord_wake as mw
fails = []
def check(c, m):
    if not c: fails.append(m)
home = Path(sys.argv[1])
tr = home / "conv" / "s1.jsonl"; tr.parent.mkdir(parents=True); tr.write_text("{}\n")
sub = home / "conv" / "s1" / "subagents"; sub.mkdir(parents=True); agent = sub / "agent-x.jsonl"; agent.write_text("{}\n")
now = time.time()
def age(p, sec): os.utime(p, (now - sec, now - sec))
rec = {"tmux": "t", "root": str(home), "project": "p", "task": "t"}
ms.tmux_alive = lambda n: True
mi._eligible = lambda r: True
mi.last_activity = lambda r: now - 5 * 3600
mb._session_transcript = lambda r: tr
mw.allow_list = lambda r: []
mi._attached = lambda n: False
mb._input_empty = lambda n: True
mi._selecting = lambda n: False
BG = ["백그라운드 1", "백그라운드 셸 1", "팀 에이전트 일하는 중", "에이전트 2개 일하는 중"]
blk = list(BG)
real_rb = mb.restart_blockers
mb.restart_blockers = lambda r: list(blk)

age(tr, 9 * 3600); age(agent, 8 * 3600)
check(mi._verdict(rec, 2 * 3600, now) == [], f"모든 기록이 2시간 넘게 멈췄으면 백그라운드는 안 막는다: {mi._verdict(rec, 2 * 3600, now)}")
age(agent, 30 * 60)
check(mi._verdict(rec, 2 * 3600, now) == BG, "서브에이전트가 최근에 썼으면 그대로 막는다")
age(agent, 8 * 3600); age(tr, 10 * 60)
check(mi._verdict(rec, 2 * 3600, now) == BG, "대화 기록이 최근이면 그대로 막는다")
OTHER = ["질문 답 기다림", "감시 중(Monitor)", "예약 기다림", "예약 기다림(cron)", "턴 진행 중", "작업 중", "판정 실패(OSError: x)"]
age(tr, 9 * 3600); blk[:] = BG + OTHER
check(mi._verdict(rec, 2 * 3600, now) == OTHER, f"백그라운드 말고 다른 이유는 그대로: {mi._verdict(rec, 2 * 3600, now)}")
blk[:] = list(BG)
# 셸이 출력을 내고 있으면(빌드·서버 로그) 살아 있는 것(리뷰 I2)
tmpd = home / "ctmp"; os.environ["MARINA_CLAUDE_TMP"] = str(tmpd)
out = tmpd / "claude-501" / tr.parent.name / tr.stem / "tasks" / "b1.output"; out.parent.mkdir(parents=True); out.write_text("x")
check(mi._verdict(rec, 2 * 3600, now) == BG, "셸 출력이 최근이면 막는다")
age(out, 5 * 3600)
check(mi._verdict(rec, 2 * 3600, now) == [], "셸 출력도 멈췄으면 안 막는다")
# 기준을 6시간으로 올리면 멈춤 판정도 6시간(리뷰 S7)
mi.last_activity = lambda r: now - 10 * 3600
check(mi._verdict(rec, 6 * 3600, now) == BG, "기준이 더 길면 그 기준으로")
# 문구가 바뀌어 정규식이 빗나가지 않게 — 진짜 restart_blockers 의 셸 문구로(리뷰 S4)
mb.restart_blockers = real_rb
mb._pane_shells = lambda name: 1
mb._room_busy = lambda r: (True, False)
mb._turn_in_progress = lambda *a: False
mb.live_tasks = lambda r: []
mb._agents_running = lambda *a: []
mb._pending_wakeup = lambda *a: 0
mb._pending_crons = lambda *a: False
mb._live_monitors = lambda *a: False
mb._session_born = lambda n: 0.0
mb._pane_permission = lambda n: False
ms._tmux = lambda *a: type("R", (), {"stdout": "", "returncode": 0})()
rec["stateDir"] = str(home / "sd"); (home / "sd").mkdir()
check(mi._verdict(rec, 2 * 3600, now) == [], f"실제 문구 '백그라운드 셸 1' 도 빠진다: {mi._verdict(rec, 2 * 3600, now)}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-idle-stale"
