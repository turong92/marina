#!/usr/bin/env bash
# ＋Claude 로 띄운 **자리표시자의 첫 메시지**는 아직 sid 가 없어 `term` 타겟으로 나간다.
# 그 길은 준비 대기도 도착 확인도 없이 그냥 타이핑해서, 부팅 중인 TUI 가 키를 통째로 삼켰다.
# 실측(2026-09-03, 같은 워크트리·같은 문장): launch 0.3초 뒤 타이핑 = 트랜스크립트조차 안
# 생김(메시지 소멸), 12초 뒤 = 정상 도착. 그동안 marina 는 "보냄"이라 답했다.
# 부팅 출력은 t+0·t+7·t+10초로 중간에 쉬기까지 해서, "출력이 멎으면 준비됨"으로도 못 맞힌다.
#
# 계약: ① 자리표시자의 첫 메시지는 타이핑이 아니라 **CLI 인자**로 실어 다시 띄운다(부팅 경쟁
# 자체를 없앤다) ② 이미 프롬프트를 싣고 뜬 PTY 는 접지 않는다 — 방금 시킨 일이 사라진다
# ③ 입양된(sid 있는) 에이전트 term 은 에이전트 타겟과 **같은** 전달 경로를 탄다(길이 하나)
# ④ 일반 셸 term 은 종전대로 즉시 친다.
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
mm.safe_root = lambda value: Path(str(value)).resolve()
mm.OUTBOX_DIR = tmp / "outbox"
mm._agent_input_pause = lambda: None
mm._native_agent_active = lambda r, s, i: False

일지: list[tuple[str, object]] = []
세션 = {
    # ＋Claude 자리표시자 — 에이전트로 띄웠지만 프롬프트도 sid 도 없다.
    "tid-placeholder": {"source": "claude", "sid": "", "prompted": False},
    # 바로 앞 메시지를 argv 로 싣고 막 시작된 PTY — 아직 입양 전이지만 접으면 안 된다.
    "tid-starting": {"source": "claude", "sid": "", "prompted": True},
    # 입양이 끝난 대화.
    "tid-adopted": {"source": "claude", "sid": "sid-1", "prompted": True},
    "tid-shell": None,
}
mm.term_list = lambda: {"sessions": [{"tid": tid, "root": str(root), "agent": agent}
                                     for tid, agent in 세션.items()]}
mm.term_input = lambda tid, text: 일지.append(("input", (tid, text)))
mm.term_kill = lambda tid: 일지.append(("kill", tid))
def 열기(root_, cols=80, rows=24, **kw):
    일지.append(("open", kw))
    return {"tid": "tid-new"}
mm.term_open = 열기
mm.term_output_mark = lambda tid: 100
mm.term_await_redraw = lambda tid, since, **kw: 일지.append(("wait", tid)) or True
mm.term_tail = lambda tid, limit=1800: "❯ 야 이거 확인해줘"

def 보내기(tid, text="야 이거 확인해줘"):
    일지.clear()
    return mm.mobile_send({"root": str(root), "text": text, "target": {"type": "term", "tid": tid}})

# ① 자리표시자: 타이핑하지 않는다. 접고 프롬프트를 argv 로 실어 다시 띄운다.
out = 보내기("tid-placeholder")
assert out["ok"] and out.get("started") and out["tid"] == "tid-new", out
assert not any(kind == "input" for kind, _ in 일지), f"부팅 중인 TUI 에 타이핑했다: {일지}"
assert ("kill", "tid-placeholder") in 일지, 일지
# 실패가 아무것도 잃지 않도록 **띄우고 나서 접는다** — 반대면 open 이 실패했을 때 겨눌 PTY 가 없다.
assert [k for k, _ in 일지].index("open") < [k for k, _ in 일지].index("kill"), 일지
열린것 = [payload for kind, payload in 일지 if kind == "open"]
assert len(열린것) == 1 and 열린것[0]["agent_prompt"] == "야 이거 확인해줘", 열린것
assert 열린것[0]["agent_source"] == "claude" and 열린것[0]["agent_sid"] == "", 열린것

# ①-1 다시 띄우기가 실패하면 자리표시자는 **그대로 남는다**(형이 다시 보내기를 누를 곳).
def 터지는열기(root_, cols=80, rows=24, **kw):
    raise ValueError("자원 부족")
열던것, mm.term_open = mm.term_open, 터지는열기
try:
    보내기("tid-placeholder")
except ValueError:
    pass
else:
    raise AssertionError("open 실패를 삼켰다")
assert not any(kind == "kill" for kind, _ in 일지), f"실패했는데 자리표시자를 접었다: {일지}"
mm.term_open = 열던것

# ② 이미 프롬프트를 싣고 뜬 PTY 는 **접지 않는다** — 방금 시킨 일이 사라진다.
mm.agent_transcript_path = lambda r, s, i: tmp / "none.jsonl"     # 아직 트랜스크립트 없음
out = 보내기("tid-starting")
assert not any(kind == "kill" for kind, _ in 일지), f"막 시작된 대화를 접었다: {일지}"
assert not any(kind == "open" for kind, _ in 일지), 일지
assert out["ok"], out
assert [p for k, p in 일지 if k == "input"] == [("tid-starting", "야 이거 확인해줘"),
                                                ("tid-starting", "\r")], 일지

# ②-1 화면에 흔적이 없으면 성공을 지어내지 않는다.
mm.term_tail = lambda tid, limit=1800: "다른 글자만 잔뜩 그려져 있다"
mm._confirm_screen_echo.__defaults__ = (0.3,)      # 테스트에서 4초씩 기다리지 않는다
out = 보내기("tid-starting")
assert out["ok"] is False and out.get("error"), out
mm.term_tail = lambda tid, limit=1800: "❯ 야 이거 확인해줘"

# ③ 입양된 대화는 에이전트 타겟과 같은 길 — 트랜스크립트로 도착을 확인한다(= accepted).
transcript = tmp / "session.jsonl"
transcript.write_text("{}\n", encoding="utf-8")
mm.agent_transcript_path = lambda r, s, i: transcript
mm._DELIVERY_CONFIRM_TIMEOUT_S = 0.3
def 확인되는입력(tid, text):
    일지.append(("input", (tid, text)))
    if text not in ("\r", "\t"):
        with transcript.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"type": "user", "message": {"content": text}}, ensure_ascii=False) + "\n")
mm.term_input = 확인되는입력
out = 보내기("tid-adopted")
assert out["ok"] and out["delivery"] == "accepted", out
assert not any(kind in ("kill", "open") for kind, _ in 일지), 일지

# ④ 일반 셸은 종전대로 — 기다리지도 접지도 않고 곧장 친다(회귀 방지).
mm.term_input = lambda tid, text: 일지.append(("input", (tid, text)))
out = 보내기("tid-shell", "ls")
assert out["ok"] and [k for k, _ in 일지] == ["input"], 일지
assert [p for _, p in 일지] == [("tid-shell", "ls\r")], 일지

print("ok")
PY
echo "PASS: 자리표시자의 첫 메시지는 argv 로 시작되고, 시작된 대화는 접히지 않는다"
