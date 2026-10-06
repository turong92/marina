#!/usr/bin/env bash
# 뒤에서 도는 서브에이전트가 지금 뭘 하는지 — 지시 스레드에 한 줄씩 쌓는다(형 2026-10-06 "작업중인거 안 보이니까 답답").
#  - 시작·끝 줄(role-events)만으론 40분 동안 스레드가 조용했다. 하는 일이 바뀐 에이전트만, 에이전트마다 2분에 한 번
#  - 고쳐 쓰지 않고 쌓는다(이력) · 알림 없이 · 명령 원문은 안 보낸다(설명만) · 지시 메시지 없는 세션은 건너뜀
#  - 채널의 '입력 중…' 은 뒤에서 도는 동안에도 켠다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"
export ROLE_EVENTS="$TMPROOT/role-events.jsonl"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" "$TMPROOT" <<'PY'
import calendar, json, os, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fd, tmp = Path(sys.argv[1]), Path(sys.argv[2])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()] if (fd / "log.jsonl").exists() else []
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
def thread_posts(n=0):
    return [x["b"] for x in log()[n:] if x["m"] == "POST" and x["p"].startswith("/channels/")
            and x["p"].endswith("/messages") and x["p"] != f"/channels/{ch}/messages"]

T0 = "2026-10-06T06:27:00.000Z"
def row(kind, content, ts=T0):
    return json.dumps({"type": kind, "timestamp": ts, "message": {"role": kind, "content": content}}, ensure_ascii=False)
qa = tmp / "agent-qa.jsonl"; cve = tmp / "agent-cve.jsonl"
qa.write_text("\n".join([
    row("user", "ovation 을 눌러 본다"),
    row("assistant", [{"type": "text", "text": "만들기 화면부터 본다.\n둘째 줄은 안 나온다"}]),
    row("user", [{"type": "tool_result", "content": "ok"}]),
]) + "\n")
cve.write_text("\n".join([
    row("user", "취약점 점검"),
    row("assistant", [{"type": "text", "text": "의존성 목록을 읽는다"},
                      {"type": "tool_use", "name": "Bash", "input": {"command": "cat secret --token=abc", "description": "의존성 목록 뽑기"}}]),
]) + "\n")
agents = [{"id": "qa1", "desc": "한 바퀴 눌러 보기", "path": qa, "role": "qa", "model": "sonnet 5.5", "name": "w12-qa"},
          {"id": "a84559d9f6eba0085", "desc": "취약점 점검", "path": cve, "role": "researcher"}]
real_running = mb._agents_running
mb._agents_running = lambda r: agents if r.get("stateDir") == str(sd) else []
# effort 는 기록에 없다 — role-hook 시작 이벤트에서(역할 에이전트만 남는다)
Path(os.environ["ROLE_EVENTS"]).write_text(json.dumps({"ev": "start", "agent": "qa1", "role": "qa", "model": "sonnet", "effort": "medium"}) + "\n"
                                           + "{깨진 줄\n" + json.dumps({"ev": "start", "agent": "a84559d9f6eba0085", "role": "-", "model": "inherit", "effort": ""}) + "\n")
base = calendar.timegm(time.strptime("2026-10-06 06:27:00", "%Y-%m-%d %H:%M:%S"))   # T0 의 epoch

# 지시 메시지 없음 → 안 올린다
st = {}
mb.agent_words_tick(st, now=base + 600)
check(thread_posts() == [], "지시 메시지 없으면 게시 안 함")

(sd / "activity.json").write_text(json.dumps({"mid": "9001"}))
st = {}
n = len(log()); live = mb.agent_words_tick(st, now=base + 600)
check(live == {ch}, f"에이전트가 도는 채널을 돌려준다: {live}")
got = thread_posts(n)
check(len(got) == 1, f"한 판은 메시지 하나로: {got}")
body = got[0]["content"] if got else ""
lines = body.split("\n")
check(lines == ["🤖 `qa#w12-qa · sonnet 5.5/medium` 한 바퀴 눌러 보기 · 10분 — 만들기 화면부터 본다.", "🤖 `researcher#0085` 취약점 점검 · 10분 — 의존성 목록 뽑기"],
      f"줄 모양 — 역할·모델/effort 를 알면 앞에: {lines}")
check("abc" not in body and "cat secret" not in body, "명령 원문은 안 보낸다")
check(got and got[0].get("flags") == 4096, "알림 없이")

# 바뀐 게 없으면 안 올린다(시간이 지나도)
n = len(log()); mb.agent_words_tick(st, now=base + 900)
check(thread_posts(n) == [], f"그대로면 조용: {thread_posts(n)}")

# 하는 일이 바뀌어도 2분 안엔 안 올린다 — 지나면 바뀐 에이전트만
with open(qa, "a") as fh:
    fh.write(row("assistant", [{"type": "tool_use", "name": "Read", "input": {"file_path": "/x/y/approve.tsx"}}]) + "\n")
st2 = dict(st); st2["qa1"] = (st["qa1"][0], base + 900)
n = len(log()); mb.agent_words_tick(st2, now=base + 960)
check(thread_posts(n) == [], "2분 안엔 다시 안 올린다")
n = len(log()); mb.agent_words_tick(st2, now=base + 1080)
got = thread_posts(n)
check(len(got) == 1 and got[0]["content"] == "🤖 `qa#w12-qa · sonnet 5.5/medium` 한 바퀴 눌러 보기 · 18분 — 만들기 화면부터 본다. (파일 읽는 중 approve.tsx)"
      and "취약점" not in got[0]["content"], f"바뀐 에이전트만, 쌓아서: {got}")

# 긴 말은 자른다 · 기록을 못 읽는 에이전트는 건너뛴다 · 사라진 에이전트의 상태는 치운다
with open(cve, "a") as fh:
    fh.write(row("assistant", [{"type": "text", "text": "가" * 500}]) + "\n")
agents.append({"id": "gone", "desc": "없는 것", "path": tmp / "nope.jsonl"})
n = len(log()); mb.agent_words_tick(st2, now=base + 2000)
got = thread_posts(n)
check(len(got) == 1 and len(got[0]["content"]) < 260 and "없는 것" not in got[0]["content"], f"자르기·건너뛰기: {got}")
del agents[:]
mb.agent_words_tick(st2, now=base + 3000)
check(st2 == {}, f"끝난 에이전트 상태 정리: {st2}")

# 묶음을 깨는 코드 펜스 · 설명이 본문인 도구 · 한 판 줄 수 제한
with open(qa, "a") as fh:
    fh.write(row("assistant", [{"type": "text", "text": "```bash"}]) + "\n")
    fh.write(row("assistant", [{"type": "tool_use", "name": "TaskCreate", "input": {"description": "본문 첫 줄\n본문 둘째 줄"}}]) + "\n")
check("```" not in mb._agent_now(qa)[0] and "본문" not in mb._agent_now(qa)[0], f"펜스·본문 설명: {mb._agent_now(qa)[0]}")
many = []
for k in range(9):
    f = tmp / f"agent-m{k}.jsonl"; f.write_text(row("assistant", [{"type": "text", "text": f"일 {k}"}]) + "\n")
    many.append({"id": f"m{k}", "desc": f"작업 {k}", "path": f})
agents.extend(many); st3 = {}
n = len(log()); mb.agent_words_tick(st3, now=base + 5000)
got = thread_posts(n)
check(len(got) == 1 and len(got[0]["content"].split("\n")) == mb.AGENT_WORDS_MAX and len(st3) == mb.AGENT_WORDS_MAX,
      f"한 판 줄 수 제한 — 넘친 건 기록 안 하고 다음 판에: {got} {len(st3)}")
n = len(log()); mb.agent_words_tick(st3, now=base + 5030)
check(len(thread_posts(n)) == 1 and len(st3) == 9, "넘친 줄은 다음 판에 올라온다")
# 한 세션을 못 읽은 판에는 상태를 지우지 않는다(다음 판 중복 방지)
def boom(r): raise RuntimeError("x")
mb._agents_running = boom
mb.agent_words_tick(st3, now=base + 5060)
check(len(st3) == 9, "읽기 실패한 판은 상태 유지")

# 실제 _agents_running — 끝난 에이전트(기록이 end_turn 으로 끝남)·끝남 알림 온 것·채팅방 세션은 뺀다
mb._agents_running = real_running
proj = tmp / "projects" / "p"; sub = proj / "S1" / "subagents"; sub.mkdir(parents=True)
tr = proj / "S1.jsonl"; tr.write_text(row("user", "hi") + "\n")
(sub / "agent-run1.jsonl").write_text(json.dumps({"type": "assistant", "timestamp": T0, "message": {"role": "assistant",
    "model": "claude-haiku-4-5-20251001", "content": [{"type": "tool_use", "name": "Bash", "input": {"description": "도는 중"}}]}}) + "\n")
(sub / "agent-run1.meta.json").write_text(json.dumps({"description": "도는 일", "agentType": "flaky-public", "name": "flaky-public",
                                                      "customAgentType": "developer", "model": "claude-sonnet-5-5"}))
(sub / "agent-gp1.jsonl").write_text(json.dumps({"type": "assistant", "timestamp": T0,
    "message": {"role": "assistant", "model": "claude-opus-5-5", "content": [{"type": "text", "text": "찾는 중"}]}}) + "\n")
(sub / "agent-gp1.meta.json").write_text(json.dumps({"description": "코드 찾기", "agentType": "general-purpose"}))
(sub / "agent-w12-qa-abc.jsonl").write_text(json.dumps({"type": "assistant", "timestamp": T0,
    "message": {"role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": "최종 보고"}]}}) + "\n")
ms.tmux_alive = lambda name: True
mb._session_transcript = lambda r: tr
mb._session_born = lambda name: 0.0
got = mb._agents_running(dict(rec, tmux="t"))
got = sorted(got, key=lambda a: a["id"])
check([a["id"] for a in got] == ["gp1", "run1"] and got[1]["desc"] == "도는 일" and got[1]["path"] == sub / "agent-run1.jsonl",
      f"끝난(end_turn) 팀 에이전트는 빼고 도는 것만: {got}")
check(got[1].get("name") == "flaky-public" and mb._agent_tag("a84559d9f6eba0085") == "0085" and mb._agent_tag("x", "w12-qa") == "w12-qa",
      f"꼬리표 — 붙인 이름, 없으면 id 끝 4자: {got[1]}")
check((got[1].get("role"), got[1].get("model")) == ("developer", "haiku 4.5"),
      f"팀 에이전트는 이름이 아니라 역할 · 모델은 meta 의 지정값이 아니라 기록에 찍힌 실제 모델(버전까지): {got[1]}")
check((got[0].get("role"), got[0].get("model")) == ("general-purpose", "opus 5.5"), f"모델 버전: {got[0]}")
check([mb._short_model(x) for x in ("claude-sonnet-5-5", "claude-fable-5-1", "sonnet", "inherit", "")] ==
      ["sonnet 5.5", "fable 5.1", "sonnet", "inherit", ""], "모델 이름 줄이기")
check(mb._agents_running(dict(rec, tmux="t", kind=sorted(ms.CHAT_KINDS)[0])) == [], "채팅방 세션은 안 본다")
ms.tmux_alive = lambda name: False
check(mb._agents_running(dict(rec, tmux="t")) == [], "꺼진 세션은 안 본다")

# '입력 중…' — 작업 중인 채널 + 에이전트가 도는 채널. 뒤에 셸만 떠 있는 채널(bg)은 아니다
ty = {}
snap = {"sessions": [{"channelId": "1", "busy": False, "bg": True}, {"channelId": "2", "busy": False, "bg": True},
                     {"channelId": "3", "busy": True, "bg": False}]}
n = len(log()); mb.typing_tick(snap, ty, now=1000, agents={"1"})
typ = sorted(x["p"] for x in log()[n:] if x["m"] == "POST" and x["p"].endswith("/typing"))
check(typ == ["/channels/1/typing", "/channels/3/typing"], f"작업 중 + 에이전트 도는 채널만: {typ}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-agent-words"
