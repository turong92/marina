#!/usr/bin/env bash
# 질문이 여러 개인 폼은 **시계가 아니라 화면을 보고** 넘어간다.
#
# 형: "질문을 시간으로 나누는게 맞아? 각각 따로따로 병렬로 해서 조립하면 되는거 아니야?"
#
# 병렬은 불가능하다 — 그 폼은 CLI 안의 마법사라 질문 하나만 그려지고, 답을 확정해야 다음이
# 그려지며, 입력 통로도 키보드 하나뿐이다. 미리 답할 대상 자체가 화면에 없다.
#
# 그러나 지적의 핵심은 맞다: **고정 시간은 추측이다.** 느리면 그리기 전에 키가 들어가 어긋나고
# (실측 2026-08-17: 3개짜리 폼이 첫 시도에 settled=False), 빠르면 쓸데없이 기다린다.
# 출력이 오는 것이 곧 "그렸다"는 증거다 — /model 을 트랜스크립트 행으로 확인한 것과 같은 원리.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ① 진짜 PTY 로 재본다 — 화면이 늦게 그려져도 기다리고, 빨리 그려지면 빨리 넘어가야 한다.
PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import sys
import time
from pathlib import Path

import marina_term as mt

tmp = Path(sys.argv[1])


def wait_ready(tid):
    """가짜 TUI 가 시작 배너를 찍을 때까지 — 인터프리터 기동 시간이 측정에 섞이지 않게."""
    assert mt.term_await_redraw(tid, 0, timeout=10.0), "가짜 TUI 가 시작을 안 알렸다"

# 입력을 받으면 **일부러 늦게** 화면을 그리는 가짜 TUI. 다음 질문이 뜨기까지 0.8초 걸린다.
slow = tmp / "slow_tui.py"
slow.write_text(
    "import sys, time\n"
    "sys.stdout.write('READY ' + 'r' * 200 + '\\n'); sys.stdout.flush()\n"
    "for _ in range(3):\n"
    "    sys.stdin.readline()\n"
    "    time.sleep(0.8)\n"          # 사람이 답한 뒤 다음 질문을 그리기까지의 지연
    "    sys.stdout.write('QUESTION ' + 'x' * 200 + '\\n'); sys.stdout.flush()\n",
    encoding="utf-8")
mt._AGENT_CLIS["fake"] = lambda sid, prompt="", model="", effort="": [
    sys.executable, str(slow)]

opened = mt.term_open(tmp, 80, 24, agent_source="fake", agent_sid="redraw-0001")
tid = opened["tid"]
try:
    wait_ready(tid)
    mark = mt.term_output_mark(tid)
    started = time.time()
    mt.term_input(tid, "\r")
    # 화면이 그려질 때까지 기다린다 — 0.8초 지연을 넘겨야 True 다.
    assert mt.term_await_redraw(tid, mark, timeout=4.0) is True, "늦게 그려지는 화면을 못 기다렸다"
    waited = time.time() - started
    assert waited >= 0.7, f"그리기 전에 넘어갔다({waited:.2f}s) — 다음 키가 허공으로 간다"
    assert waited < 3.5, f"너무 오래 붙잡았다({waited:.2f}s)"

    # 두 번째: 같은 방식으로 또 기다린다(폼이 여러 개여도 매번 증거를 본다).
    mark = mt.term_output_mark(tid)
    mt.term_input(tid, "\r")
    assert mt.term_await_redraw(tid, mark, timeout=4.0) is True

    # ①-1 **에코는 다시 그리기가 아니다.** PTY 는 넣은 키를 되돌려주는데, 그걸 화면 갱신으로
    #      세면 다음 키가 그리기 전에 들어간다(실측: Enter 에코가 0.22초 만에 왔다).
    mark = mt.term_output_mark(tid)
    mt.term_input(tid, "\x1b[B")           # 화살표 — 앱은 응답하지 않고 에코만 돌아온다
    assert mt.term_await_redraw(tid, mark, timeout=0.5) is False, "에코를 다시 그리기로 셌다"

    # ② 아무 출력도 안 오면 상한까지만 기다리고 **정직하게 False** 를 준다(무한 대기 금지).
    mark = mt.term_output_mark(tid)
    started = time.time()
    assert mt.term_await_redraw(tid, mark, timeout=0.6) is False, "안 그려졌는데 그려졌다고 했다"
    spent = time.time() - started
    assert 0.5 <= spent < 1.6, f"상한을 안 지켰다({spent:.2f}s)"
finally:
    mt.term_kill(tid)

# ③ 빠른 화면은 **빨리** 넘어간다 — 고정 시간이었다면 여기서도 그만큼 잤을 자리다.
fast = tmp / "fast_tui.py"
fast.write_text(
    "import sys\n"
    "sys.stdout.write('READY ' + 'r' * 200 + '\\n'); sys.stdout.flush()\n"
    "for _ in range(3):\n"
    "    sys.stdin.readline()\n"
    "    sys.stdout.write('QUESTION ' + 'x' * 200 + '\\n'); sys.stdout.flush()\n",
    encoding="utf-8")
mt._AGENT_CLIS["fake"] = lambda sid, prompt="", model="", effort="": [sys.executable, str(fast)]
opened = mt.term_open(tmp, 80, 24, agent_source="fake", agent_sid="redraw-0002")
tid = opened["tid"]
try:
    wait_ready(tid)
    mark = mt.term_output_mark(tid)
    started = time.time()
    mt.term_input(tid, "\r")
    assert mt.term_await_redraw(tid, mark, timeout=4.0) is True
    quick = time.time() - started
    assert quick < 0.6, f"빨리 그려졌는데 오래 기다렸다({quick:.2f}s) — 고정 시간과 다를 게 없다"
finally:
    mt.term_kill(tid)

print("ok 화면이 그려지는 것을 보고 넘어간다(느리면 기다리고, 빠르면 즉시)")
PY

# ④ 답 구동이 실제로 그 기다림을 쓰는지 — 고정 sleep 으로 돌아가면 안 된다.
PYTHONPATH="$SCR" python3 - "$HERE" <<'PY'
import sys
from pathlib import Path

import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
calls = []
mm.term_output_mark = lambda tid: len(calls)
mm.term_await_redraw = lambda tid, since, timeout=0: calls.append(("wait", since)) or True
mm.term_input = lambda tid, text: calls.append(("input", text))
mm._agent_input_pause = lambda: None

# 질문 3개를 몰아 확정한다.
mm._drive_selector = mm._drive_selector       # 원본 사용
mm._question_state_token = lambda sid: ""     # settled 판정은 여기서 관심 밖
mm._await_answer_settled = lambda sid, before, questions=1: True
mm.mobile_pending_question = lambda source, sid: {"questions": [
    {"question": "a", "options": [{"label": "1"}]},
    {"question": "b", "options": [{"label": "1"}]},
    {"question": "c", "options": [{"label": "1"}]},
]}
mm._live_agent_tid = lambda r, s, i: "tid-1"
mm.safe_root = lambda value: root
mm._parse_answers = lambda body: [[0], [0], [0]]

mm.mobile_answer({"root": str(root), "target": {"type": "agent", "source": "claude", "sid": "s1"},
                  "answers": [[0], [0], [0]]})

waits = [c for c in calls if c[0] == "wait"]
# 질문 사이 2번 + 제출 화면이 그려지길 기다리는 1번 = 3번.
assert len(waits) == 3, f"질문 3개인데 기다림이 {len(waits)}번 — 사이마다, 그리고 제출 전에 본다"
# 기다림은 **입력 사이**에 와야 한다(입력 전부 몰아친 뒤 기다리면 의미가 없다).
order = [c[0] for c in calls]
assert order.index("wait") < len(order) - 1, order
print("ok 답 구동이 질문 사이마다 화면을 기다린다")
PY

# ⑤ 진단용 화면 캡처가 **실제로 동작**해야 한다. 실측(2026-08-17): 이 파일 아래쪽에 이미
# `_ANSI_RE`(문자열 패턴)가 있어서 새로 만든 바이트 패턴을 덮었고, term_tail 이 TypeError 로
# 죽으면서 답 응답까지 깨졌다. 진단이 본체를 망가뜨리면 안 된다.
PYTHONPATH="$SCR" python3 - "$TMP" <<'PY2'
import sys
import time
from pathlib import Path

import marina_term as mt

tmp = Path(sys.argv[1])
mt._AGENT_CLIS["fake"] = lambda sid, prompt="", model="", effort="": [
    sys.executable, "-c",
    "import sys,time; sys.stdout.write('\\x1b[32m선택하세요\\x1b[0m\\r\\n  1) 예\\n'); "
    "sys.stdout.flush(); time.sleep(5)"]
opened = mt.term_open(tmp, 80, 24, agent_source="fake", agent_sid="tail-0001")
tid = opened["tid"]
try:
    assert mt.term_await_redraw(tid, 0, timeout=8.0), "가짜 TUI 출력이 안 왔다"
    text = mt.term_tail(tid)
    assert "선택하세요" in text, f"화면 글자가 안 남았다: {text!r}"
    assert "\x1b" not in text and "[32m" not in text, f"색 코드가 안 걷혔다: {text!r}"
finally:
    mt.term_kill(tid)

# 없는 세션이면 빈 문자열 — **예외를 던지면 안 된다**(진단이 답 전송을 깨뜨린 실제 사고).
assert mt.term_tail("없는tid") == ""
print("ok 화면 캡처: 색 코드 제거 + 관찰 실패해도 안 터진다")
PY2

# ⑥ **여러 질문 폼은 마지막에 Submit 을 누른다.** 실측한 화면(2026-08-17):
#     ← ☒방향 ☒범위 ✔ Submit →   Review your answers …   ❯ 1. Submit answers
# 질문은 탭이고 끝에 Submit 탭이 따로 있다. 질문마다 답만 넣고 끝내면 제출이 안 돼 영영 안
# 먹는다 — "질문 2~3개짜리만 실패, 재시도는 1초 만에 성공"의 정체였다(그 Enter 가 Submit).
# 단일 질문은 Enter 하나로 선택+제출이라 이 단계가 **없어야** 한다.
PYTHONPATH="$SCR" python3 - "$HERE" <<'PY2'
import sys
from pathlib import Path

import marina_mobile as mm

root = Path(sys.argv[1]).resolve()

def drive(question_count):
    keys = []
    mm.term_output_mark = lambda tid: 0
    mm.term_await_redraw = lambda tid, since, timeout=0: True
    mm.term_input = lambda tid, text: keys.append(text)
    mm._agent_input_pause = lambda: None
    mm._question_state_token = lambda sid: ""
    mm._await_answer_settled = lambda sid, before, questions=1: True
    mm._live_agent_tid = lambda r, s, i: "tid-1"
    mm.safe_root = lambda value: root
    picks = [[0]] * question_count
    mm.mobile_pending_question = lambda source, sid: {"questions": [
        {"question": f"q{i}", "options": [{"label": "a"}]} for i in range(question_count)]}
    mm._parse_answers = lambda body: picks
    mm.mobile_answer({"root": str(root), "answers": picks,
                      "target": {"type": "agent", "source": "claude", "sid": "s1"}})
    return keys

one = drive(1)
assert one.count("\r") == 1, f"단일 질문에 Enter 가 {one.count(chr(13))}번 — 제출 화면이 없는데 더 쳤다"

two = drive(2)
assert two.count("\r") == 3, f"질문 2개면 확정 2번 + Submit 1번이어야 하는데 {two.count(chr(13))}번: {two}"

three = drive(3)
assert three.count("\r") == 4, f"질문 3개면 4번이어야 하는데 {three.count(chr(13))}번: {three}"
print("ok 여러 질문 폼은 마지막에 Submit 을 누른다(단일 질문은 안 누른다)")
PY2

echo "PASS test-answer-redraw-wait"
