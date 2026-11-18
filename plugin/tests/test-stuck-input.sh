#!/usr/bin/env bash
# 마리나가 친 글이 보내지지 않고 쉬는 방 입력창에 남으면, 그 뒤 글이 전부 '못 침(쉬는 순간이 안 옴)'으로 막힌다
# (2026-11-18 ppojji-launch-dev: 13:58 글이 입력창에 남아 1시간 넘게 다른 방 글·지시가 못 들어감) — 남은 마리나 글은 Enter 로 보낸다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import marina_session as ms
import marina_discord_bot as mb
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)

SEP = "─" * 40
def screen(box, dim=False, more=True):
    body = f"\x1b[2m{box}\x1b[22m" if dim else box
    return "\n".join(["⏺ 끝났어", SEP, f"❯ {body}"] + (["  이어지는 줄"] if more else []) + [SEP, "  ⏵⏵ bypass permissions on"])

STUCK = screen("[마리나 · story-chat/glamchat 방에서] 받았습니다: 094d936db")
check(mb.input_box_text(STUCK).startswith("[마리나"), f"입력창 글 읽기: {mb.input_box_text(STUCK)!r}")
check(mb.input_box_text(screen("", more=False)) == "", "빈 입력창")
check(mb.input_box_text(screen("다음 할 일 추천", dim=True, more=False)) == "", "흐린 추천은 글 아님")
check(mb.input_box_text("아무것도 없음") is None, "입력창 못 찾음")

entered = []
state = {"scr": STUCK, "busy": False, "alive": True, "human": False}
def tick(now):
    return mb.stuck_input_tick(now, screen=lambda r: state["scr"], busy=lambda r: (state["alive"], state["busy"]),
                               enter=lambda r: entered.append(r["task"]), human=lambda r: state["human"])
T = 1000.0
check(tick(T) == [] and not entered, "처음 본 건 기다림")
check(tick(T + 30) == [] and not entered, "60초 안엔 기다림")
check(tick(T + 61) == ["proj/feat/a"] and entered == ["feat/a"], f"남은 마리나 글 보냄: {entered}")
entered.clear()
check(tick(T + 62) == [] and not entered, "보낸 뒤 바로 또 안 침")
# 사람이 쓰던 초안은 건드리지 않는다
state["scr"] = screen("형이 쓰던 글")
check(tick(T + 100) == [] and tick(T + 200) == [] and not entered, "사람 초안은 안 보냄")
# 일하는 중·꺼진 방은 건드리지 않는다(일하는 중엔 클로드가 대기열로 받는다)
state["scr"] = STUCK; state["busy"] = True
check(tick(T + 300) == [] and tick(T + 400) == [] and not entered, "일하는 방은 안 침")
state["busy"] = False; state["alive"] = False
check(tick(T + 500) == [] and tick(T + 600) == [] and not entered, "꺼진 방은 안 침")
# 글이 바뀌면(새로 친 중) 처음부터 다시 잰다
state["alive"] = True
tick(T + 700)
state["scr"] = screen("[마리나 · 다른 방에서] 새 글")
check(tick(T + 770) == [] and not entered, "글이 바뀌면 다시 잼")
check(tick(T + 840) == ["proj/feat/a"], "바뀐 글도 60초 지나면 보냄")
entered.clear()
# 권한·선택 창(❯ 1. Yes)에선 Enter 가 승인이 된다 — 안 친다
state["scr"] = "\n".join(["Do you want to proceed?", "❯ 1. Yes", "  2. No", SEP])
check(tick(T + 900) == [] and tick(T + 1000) == [] and not entered, "선택 창은 안 침")
# 사람이 터미널에서 만지는 중이면(키 친 지 60초 안·보기 모드) 기다린다(리뷰 I2·S2)
state["scr"] = STUCK; state["human"] = True
check(tick(T + 1100) == [] and tick(T + 1200) == [] and not entered, "사람이 만지는 중엔 안 침")
state["human"] = False
check(tick(T + 1300) == ["proj/feat/a"], "사람이 손 뗀 뒤 60초 지나면 보냄")
entered.clear()
# /stop 으로 멈춰서 되돌아온 글은 형이 멈춘 것 — 안 보낸다(리뷰 I1)
import time as _t
from pathlib import Path
sd = Path(ms.find_session("proj/feat/a")["stateDir"])
(sd / "interrupted").write_text(f"m1 {_t.time() - 30}\n")
state["scr"] = screen("[마리나 · 멈춘 뒤 돌아온 글]")
check(mb.stuck_input_tick(None, screen=lambda r: state["scr"], busy=lambda r: (True, False),
                          enter=lambda r: entered.append(1), human=lambda r: False) == [], "멈춘 직후 첫 tick")
check(mb.stuck_input_tick(_t.time() + 120, screen=lambda r: state["scr"], busy=lambda r: (True, False),
                          enter=lambda r: entered.append(1), human=lambda r: False) == [] and not entered, "/stop 뒤 돌아온 글은 안 보냄")

if fails:
    print("FAIL:", *fails, sep="\n  "); raise SystemExit(1)
print("PASS")
PY
