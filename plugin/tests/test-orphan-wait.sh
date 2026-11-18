#!/usr/bin/env bash
# 하위 에이전트가 끝났는데 그걸 맡긴 부모(리드)가 완료 알림을 못 받아 안 깨어나면, 방을 깨워 이어 가게 한다
# (형 2026-11-18 "넣어야지" — mdc 방: 리드가 시킨 개발자가 21시에 끝났는데 리드가 안 깨어나 방·리드 둘 다 아침까지 섰다)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)

rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"])
tr = Path(os.environ["MARINA_HOME"]) / "tr" / "s1.jsonl"
sub = tr.parent / "s1" / "subagents"; sub.mkdir(parents=True)
tr.write_text("{}\n")
END = json.dumps({"type": "assistant", "message": {"role": "assistant", "stop_reason": "end_turn",
                                                   "content": [{"type": "text", "text": "완료 알림이 오면 이어 갈게"}]}}) + "\n"
TOOL = json.dumps({"type": "assistant", "message": {"role": "assistant", "stop_reason": "tool_use", "content": []}}) + "\n"
def agent(aid, meta, body, at):
    (sub / f"agent-{aid}.meta.json").write_text(json.dumps(meta))
    p = sub / f"agent-{aid}.jsonl"; p.write_text(body); os.utime(p, (at, at))
NOW = 1_000_000.0
agent("alead-x-1", {"name": "lead-x", "description": "X 리드"}, END, NOW - 3600)
agent("adev1", {"description": "X 구현", "parentAgentId": "alead-x-1", "finished": True}, "{}\n", NOW - 1800)

got = mb.orphan_waits(tr, NOW)
check([(w["parent"], w["child"]) for w in got] == [("alead-x-1", "adev1")], f"부모가 끝난 뒤 못 깸: {got}")
check(got and got[0]["parentName"] == "lead-x" and got[0]["childDesc"] == "X 구현", f"이름: {got}")

# 끝난 지 10분이 안 됐으면 아직(알림이 오는 중일 수 있다)
check(mb.orphan_waits(tr, NOW - 1800 + 300) == [], "10분 안엔 기다린다")
# 부모가 자식보다 뒤에 움직였으면(알림 받고 이어 감) 아님
os.utime(sub / "agent-alead-x-1.jsonl", (NOW - 60, NOW - 60))
check(mb.orphan_waits(tr, NOW) == [], "부모가 뒤에 움직였으면 아님")
os.utime(sub / "agent-alead-x-1.jsonl", (NOW - 3600, NOW - 3600))
# 부모가 턴을 끝내지 않았으면(도구 기다리는 중 = 전경 자식) 아님
(sub / "agent-alead-x-1.jsonl").write_text(TOOL); os.utime(sub / "agent-alead-x-1.jsonl", (NOW - 3600, NOW - 3600))
check(mb.orphan_waits(tr, NOW) == [], "부모가 턴 중이면 아님")
(sub / "agent-alead-x-1.jsonl").write_text(END); os.utime(sub / "agent-alead-x-1.jsonl", (NOW - 3600, NOW - 3600))
# 자식이 안 끝났으면 아님
agent("adev2", {"description": "Y", "parentAgentId": "alead-x-1"}, "{}\n", NOW - 1800)
check([w["child"] for w in mb.orphan_waits(tr, NOW)] == ["adev1"], "안 끝난 자식은 아님")
# 부모가 없는 자식(방이 직접 띄움)·하루 지난 것은 아님
agent("adev3", {"description": "Z", "finished": True}, "{}\n", NOW - 1800)
agent("adev4", {"description": "W", "parentAgentId": "alead-x-1", "finished": True}, "{}\n", NOW - 2 * 86400)
check([w["child"] for w in mb.orphan_waits(tr, NOW)] == ["adev1"], "부모 없음·오래된 것 제외")

# tick: 쉬는 방에 한 번만 깨우기 글 · 일하는 방은 다음에
sent = []
def tick(now, busy=False, alive=True, born=NOW - 86400):
    return mb.orphan_wait_tick(now, transcript=lambda r: tr, busy=lambda r: (alive, busy),
                               send=lambda r, t: sent.append((r["task"], t)), started=lambda r: born)
check(tick(NOW, busy=True) == [] and not sent, "일하는 방은 안 깨움")
check(tick(NOW, alive=False) == [] and not sent, "꺼진 방은 안 깨움")
# 한도로 멈춘 방은 limit_revive 몫(이 글이 한도 표시를 지우지 않게, 리뷰 I3)
(sd / mb.LIMIT_STALLED).write_text("{}")
check(tick(NOW) == [] and not sent, "한도 표시 있는 방은 건너뜀")
(sd / mb.LIMIT_STALLED).unlink()
# 다른 리드도 같이 걸리면 한 글에 둘 다(리뷰 I2)
agent("alead-y-1", {"name": "lead-y"}, END, NOW - 3000)
agent("adev5", {"description": "Y 구현", "parentAgentId": "alead-y-1", "finished": True}, "{}\n", NOW - 1500)
check(tick(NOW) == ["proj/feat/a"] and len(sent) == 1, f"깨움: {sent}")
check(all(s in sent[0][1] for s in ("lead-x", "X 구현", "lead-y", "Y 구현", "SendMessage")), f"글: {sent}")
check(tick(NOW + 60) == [] and len(sent) == 1, "같은 자식은 한 번만")
# 방이 부모가 멈춘 뒤에 다시 떴으면(팀원이 이미 없음) 안 깨우고 본 걸로만(리뷰 I1)
(sd / mb.ORPHAN_SEEN).unlink(); sent.clear()
check(tick(NOW, born=NOW - 600) == [] and not sent, "다시 뜬 방은 지난 짝으로 안 깨움")
check(tick(NOW + 60) == [] and not sent, "다시 뜬 방 짝은 본 걸로 남김")

if fails:
    print("FAIL:", *fails, sep="\n  "); raise SystemExit(1)
print("PASS")
PY
