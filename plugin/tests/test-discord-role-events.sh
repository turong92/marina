#!/usr/bin/env bash
# 역할 에이전트(2026-10-04): role-hook 이 남긴 서브에이전트 시작·끝 이벤트를 봇이 읽어 지시 스레드에 한 줄씩 —
#  형이 '무엇이 어떤 모델로 돌았나'를 본다. 봇은 이벤트 파일만 읽는다(역할 코드 import 없음)
#  - 그 세션(sessionId)이 Discord 세션이고 지시 메시지(activity mid)가 있을 때만 · 오프셋으로 한 번씩 · 깨진 줄 무시
#  - 줄은 에이전트가 처음 시작된 때의 지시 스레드로(자식은 부모 것) · 끝 줄은 이어 쓰기/자식이 도는 동안 붙잡는다(아래 구획)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"
export ROLE_EVENTS="$TMPROOT/role-events.jsonl"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()] if (fd / "log.jsonl").exists() else []
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
ms.save_sessions([dict(x, sessionId="S1") if x.get("stateDir") == str(sd) else x for x in ms.load_sessions()])
ev = Path(os.environ["ROLE_EVENTS"])
mb.ROLE_STOP_HOLD = 0          # 0 = 붙잡지 않고 stop 즉시 게시(테스트 전용 분기) — 기존 형식·순서 검증용. 붙잡기 검증은 아래 새 구획에서
def put(*rows):
    with open(ev, "a") as fh:
        for r in rows: fh.write((r if isinstance(r, str) else json.dumps(r, ensure_ascii=False)) + "\n")
def thread_posts():
    return [x["b"]["content"] for x in log() if x["m"] == "POST" and x["p"].startswith("/channels/")
            and x["p"].endswith("/messages") and x["p"] != f"/channels/{ch}/messages"]

# (리뷰 I4) 오프셋이 없으면(처음·지워짐) 지난 이벤트를 재생하지 않고 지금 끝에서 시작
(sd / "activity.json").write_text(json.dumps({"mid": "9000"}))
put({"ev": "start", "ts": 0, "session": "S1", "agent": "old", "role": "qa", "model": "haiku", "effort": "low", "skills": [], "desc": "옛날 일"})
mb.role_events_tick()
check(thread_posts() == [], f"옛 이벤트 재생 안 함: {thread_posts()}")
(sd / "activity.json").unlink()
# 지시 메시지 없음 → 게시 안 하고 오프셋만 전진
put({"ev": "start", "ts": 1, "session": "S1", "agent": "a0", "role": "developer", "model": "sonnet", "effort": "medium",
     "skills": ["superpowers:test-driven-development"], "desc": "이전 일"})
mb.role_events_tick()
check(thread_posts() == [], "지시 메시지 없으면 게시 안 함")
(sd / "activity.json").write_text(json.dumps({"mid": "9001"}))
put({"ev": "override_blocked", "ts": 2, "session": "S1", "agent": "", "role": "developer", "asked": "opus", "model": "sonnet",
     "effort": "medium", "skills": [], "desc": "결제 버그 Task 3"},
    {"ev": "start", "ts": 3, "session": "S1", "agent": "a1", "role": "developer", "model": "sonnet", "effort": "medium",
     "skills": ["superpowers:test-driven-development"], "desc": "결제 버그 Task 3"},
    "{깨진 줄",
    {"ev": "start", "ts": 3, "session": "OTHER", "agent": "a9", "role": "qa", "model": "haiku", "effort": "low", "skills": [], "desc": "남의 것"},
    {"ev": "stop", "ts": 243, "session": "S1", "agent": "a1", "role": "developer", "model": "sonnet", "effort": "medium", "skills": [],
     "desc": "결제 버그 Task 3", "secs": 240.0, "tokens": {"in": 2000, "out": 30000, "cache_read": 900000, "cache_write": 20000},
     "models": ["claude-sonnet-5-5"]},
    {"ev": "start", "ts": 4, "session": "S1", "agent": "a2", "role": "-", "model": "inherit", "effort": "", "skills": [], "desc": "코드 찾기"})
mb.role_events_tick()
got = thread_posts()
check(len(got) == 1, f"(리뷰 M3) 한 판의 줄들은 메시지 하나로 — 서브에이전트가 몰려도 도배 안 함: {got}")
got = got[0].split("\n") if got else []
want = ["⚠️ developer 모델 지정(opus) 무시 — 역할표대로 sonnet",
        "🤖 developer#a1 시작 · sonnet/medium · test-driven-development · 결제 버그 Task 3",
        "✅ developer#a1 끝 · 4분 · 52k",
        "🤖 서브에이전트#a2 시작 · 코드 찾기"]
check(got == want, f"줄 형식: {got}")
mb.role_events_tick()
check(len(thread_posts()) == 1, "오프셋 — 같은 줄 두 번 안 올림")
# (리뷰 I5) 게시 중 예상 밖 예외(네트워크 등)여도 오프셋은 저장 — 같은 줄 반복 게시 없음
real = ms._progress
calls = []
def boom(rec, args):
    calls.append(args["text"])
    if len(calls) == 1: raise OSError("network down")
    return real(rec, args)
ms._progress = boom
n0 = len(thread_posts())
put({"ev": "start", "ts": 6, "session": "S1", "agent": "x1", "role": "-", "model": "inherit", "effort": "", "skills": [], "desc": "하나"},
    {"ev": "start", "ts": 7, "session": "S1", "agent": "x2", "role": "-", "model": "inherit", "effort": "", "skills": [], "desc": "둘"},
    {"ev": "start", "ts": 8, "session": "S1", "agent": "x3", "role": "-", "model": "inherit", "effort": "", "skills": [], "desc": "셋"})
try:
    mb.role_events_tick()
except Exception:
    pass
mb.role_events_tick(); mb.role_events_tick()
ms._progress = real
check(sum("하나" in c for c in calls) == 1, f"반복 게시 없음: {calls}")
# (리뷰 I1) 한 판에 줄이 많아 1900자를 넘으면 잘리지 않고 여러 메시지로
n1 = len(thread_posts())
put(*[{"ev": "start", "ts": 9, "session": "S1", "agent": f"m{i}", "role": "-", "model": "inherit", "effort": "", "skills": [],
       "desc": f"{i:02d} " + "가" * 78} for i in range(20)])
for _ in range(3):
    mb.role_events_tick()
new_posts = thread_posts()[n1:]
check(all(len(p) <= 1900 and not p.endswith("가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가가")
          or p.endswith("가" * 78) for p in new_posts), f"줄 중간에서 안 잘림: {[len(p) for p in new_posts]}")
check(all(l.startswith("🤖") for p in new_posts for l in p.split("\n")), f"모든 줄이 온전: {[p[-20:] for p in new_posts]}")
check(sum(len(__import__("re").findall(r"🤖 서브에이전트#m\d+ 시작", p)) for p in new_posts) == 20, "20줄 다 감")
# 회전(파일이 줄어듦) → 처음부터
ev.write_text(json.dumps({"ev": "stop", "ts": 5, "session": "S1", "agent": "a2", "role": "-", "model": "inherit", "effort": "",
                          "skills": [], "desc": "코드 찾기", "secs": 12.0, "tokens": {"in": 1, "out": 2, "cache_read": 0, "cache_write": 0},
                          "models": []}) + "\n")
mb.role_events_tick()
check(thread_posts()[-1] == "✅ 서브에이전트#a2 끝 · 12초 · 3", f"회전 후 · 짧은 시간·작은 토큰: {thread_posts()[-1:]}")

# ── 스레드 고정 · 끝/시작 붙잡기 · 접기 보호 (2026-10-09) ──────────────────────────────────────
import time as _t
proj = Path(os.environ["ROLE_EVENTS"]).parent / "claude-projects" / "p"; (proj / "S1" / "subagents").mkdir(parents=True)
(proj / "S1.jsonl").write_text("")
os.environ["MARINA_CLAUDE_PROJECTS"] = str(proj.parent)
mb.ROLE_STOP_HOLD = 20.0
T = [10_000.0]
mb._now = lambda: T[0]
def tid_of(mid):
    return json.loads((sd / "threads.json").read_text()).get(mid)
def at(mid):
    t = tid_of(mid)
    return [x["b"]["content"] for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{t}/messages"] if t else []
def st(agent, ts, **kw):
    return dict({"ev": "start", "ts": ts, "session": "S1", "agent": agent, "role": "developer", "model": "sonnet", "effort": "medium",
                 "skills": [], "desc": "d-" + agent}, **kw)
def sp(agent, ts, **kw):
    return dict({"ev": "stop", "ts": ts, "session": "S1", "agent": agent, "role": "developer", "model": "sonnet", "effort": "medium",
                 "skills": [], "desc": "d-" + agent, "secs": 30.0, "tokens": {"in": 1000, "out": 1000, "cache_write": 0}, "models": []}, **kw)
def act(mid): (sd / "activity.json").write_text(json.dumps({"mid": mid}))

# (a) 지시 mid 가 바뀐 뒤에도 먼저 시작한 에이전트의 줄은 처음 mid 로
act("7001")
put(st("pa", 1)); mb.role_events_tick()
act("7002")
put(st("pa2", 2, parent="")); mb.role_events_tick()              # 새 지시 뒤에 뜬 다른 에이전트는 새 mid
check(any("developer#pa 시작" in l for l in at("7001")), f"(a) 첫 시작은 7001: {at('7001')}")
check(any("developer#pa2 시작" in l for l in at("7002")) and not any("pa2" in l for l in at("7001")), f"(a) 새 에이전트는 7002: {at('7002')}")
put(sp("pa", 3)); mb.role_events_tick()
T[0] += 25; mb.role_events_tick()                                   # 20초 지나 stop 이 나간다
check(any("developer#pa 끝" in l for l in at("7001")), f"(a) 먼저 시작한 에이전트의 끝은 7001: {at('7001')} / {at('7002')}")
check(not any("developer#pa 끝" in l for l in at("7002")), "(a) 새 지시 스레드엔 안 감")

# (b) 자식은 부모 mid 로 — start 줄엔 parent 가 없어 하네스 meta 의 parentAgentId 로
act("7003")
put(st("lead", 10)); mb.role_events_tick()                          # 리드가 7003 에서 시작
act("7004")
(proj / "S1" / "subagents" / "agent-kid.meta.json").write_text(json.dumps({"description": "x", "parentAgentId": "lead"}))
put(st("kid", 11, parent="", depth=None)); mb.role_events_tick()
check(any("developer#kid 시작" in l for l in at("7003")) and not any("#kid" in l for l in at("7004")), f"(b) meta 부모 → 7003: {at('7003')} / {at('7004')}")
put(st("kid2", 12, parent="")); mb.role_events_tick()              # meta 없음 → 부모 모름 → 현재 mid
check(any("#kid2 시작" in l for l in at("7004")), f"(b) meta 없으면 현재 mid: {at('7004')}")
put(sp("kid3", 14, parent="lead")); mb.role_events_tick()   # 시작을 못 본 에이전트   # stop 줄의 parent 칸
T[0] += 25; mb.role_events_tick()
check(any("#kid3 끝" in l for l in at("7003")), f"(b) stop 줄 parent 칸도 쓴다: {at('7003')}")

# (c) stop → 20초 안 start 는 둘 다 안 씀 / 창이 지나면 stop 씀 / 창 밖 start 는 '이어 씀'
act("7005")
put(st("rl", 20)); mb.role_events_tick()
n = len(at("7005"))
put(sp("rl", 21)); mb.role_events_tick()
T[0] += 10
put(st("rl", 22)); mb.role_events_tick()
T[0] += 30; mb.role_events_tick()
check(len(at("7005")) == n, f"(c) 20초 안 stop→start 는 둘 다 안 씀: {at('7005')[n:]}")
put(sp("rl", 23)); mb.role_events_tick()
T[0] += 5; mb.role_events_tick()
check(len(at("7005")) == n, "(c) 아직 창 안이면 stop 안 씀")
T[0] += 20; mb.role_events_tick()
check(at("7005")[n:] == ["✅ developer#rl 끝 · 30초 · 2k"], f"(c) 창이 지나면 stop 씀: {at('7005')[n:]}")
put(st("rl", 24)); mb.role_events_tick()
check(at("7005")[-1].startswith("🤖 developer#rl 이어 씀"), f"(c) 창 밖 start 는 이어 씀: {at('7005')[-1]}")
# 붙잡은 stop 은 봇이 재시작해도(상태 파일) 잃지 않는다
put(sp("rl", 25)); mb.role_events_tick()
check((sd / "role-held.json").exists(), "(c) 붙잡은 것이 상태 파일에 남음")
n = len(at("7005"))
T[0] += 25; mb.role_events_tick()
check(len(at("7005")) == n + 1 and at("7005")[-1].startswith("✅ developer#rl 끝"), "(c) 다음 틱에 나감")

# (d) 접기 보호 — 살아 있는(30분 안) 에이전트의 mid 도 keep
pins = json.loads((sd / "agent-threads.json").read_text())
check(pins["lead"]["mid"] == "7003", f"(d) 고정 기록: {pins.get('lead')}")
now = mb._now()
check({"7003", "7005"} <= ms._live_pinned_mids(sd, now), f"(d) 살아 있는 에이전트 mid: {ms._live_pinned_mids(sd, now)}")
check("7003" not in ms._live_pinned_mids(sd, now + 3600 * 2), "(d) 30분 넘게 조용하면 keep 에서 빠짐")
class DC:
    def __init__(self): self.calls = []
    def _req(self, m, p, b=None): self.calls.append((m, p, b))
(sd / "threads.json").write_text(json.dumps({"1": "T1", "2": "T2", "3": "T3"}))
if (sd / "threads-archived.json").exists(): (sd / "threads-archived.json").unlink()
dc = DC(); ms._archive_threads({"stateDir": str(sd)}, dc, keep={"1", "3"})
check([c[1] for c in dc.calls] == ["/channels/T2"], f"(d) keep 집합은 접지 않음: {dc.calls}")
dc = DC(); ms._archive_threads({"stateDir": str(sd)}, dc, keep="2")
check(all(c[1] != "/channels/T2" for c in dc.calls), "(d) keep 문자열도 그대로")

# (e) 상태 파일이 깨져도 안 죽음
(sd / "agent-threads.json").write_text("{깨짐"); (sd / "role-held.json").write_text("[1,")
act("7009")
put(st("zz", 40)); mb.role_events_tick()
check(any("developer#zz 시작" in l for l in at("7009")), f"(e) 깨진 고정 기록 → 빈 것으로: {at('7009')}")
(sd / "agent-threads.json").write_text("{깨짐")
check(ms._live_pinned_mids(sd, mb._now()) == set(), f"(e) keep 계산도 안 죽음 — 깨진 기록은 빈 것: {ms._live_pinned_mids(sd, mb._now())}")
(sd / "agent-threads.json").write_text("{깨짐")
put(sp("zz", 41)); mb.role_events_tick(); T[0] += 25; mb.role_events_tick()
check(any("#zz 끝" in l for l in at("7009")), f"(e) 깨진 뒤에도 stop 게시: {at('7009')}")
# 24시간 지난 고정 기록은 정리
(sd / "agent-threads.json").write_text(json.dumps({"old": {"mid": "1", "ts": mb._now() - 90000}}))
put(st("yy", 50)); mb.role_events_tick()
check("old" not in json.loads((sd / "agent-threads.json").read_text()), "고정 기록 24시간 뒤 정리")
# (c2) 리드: stop → 자식 start → 자식 stop → 리드 start — 시간이 아니라 구조로 둘 다 지운다(자식이 도는 동안은 20초가 지나도 붙잡음)
act("7010")
(proj / "S1" / "subagents" / "agent-ch1.meta.json").write_text(json.dumps({"parentAgentId": "ld"}))
put(st("ld", 100)); mb.role_events_tick()
n = len(at("7010"))
put(sp("ld", 101)); mb.role_events_tick()
T[0] += 5; put(st("ch1", 102, parent="")); mb.role_events_tick()
T[0] += 300; mb.role_events_tick()
check(len(at("7010")) == n + 1 and "#ch1 시작" in at("7010")[-1], f"(c2) 자식이 도는 동안 리드 끝 줄은 계속 붙잡음: {at('7010')[n:]}")
put(sp("ch1", 400)); mb.role_events_tick()
T[0] += 5; put(st("ld", 401)); mb.role_events_tick()
T[0] += 25; mb.role_events_tick()
got = at("7010")[n:]
check(not any("#ld 끝" in l or "#ld 이어 씀" in l or "#ld 시작" in l for l in got), f"(c2) 리드의 끝·시작은 둘 다 안 씀: {got}")
check(any("#ch1 끝" in l for l in got), f"(c2) 자식 끝 줄은 나감: {got}")
# (a) 구조 판정: ts 가 멀리 떨어진 stop/start 가 한 판에 와도 같은 에이전트면 둘 다 지운다. 끝 줄이 이미 나간 뒤의 start 만 '이어 씀'
put(sp("ld", 1000), st("ld", 9000)); mb.role_events_tick(); T[0] += 25; mb.role_events_tick()
check(not any("#ld" in l and ("끝" in l or "이어" in l) for l in at("7010")[n:]), f"(c2) 한 판의 먼 ts 쌍도 지움: {at('7010')[n:]}")
# 상한(N2): 자식이 start 만 있고 stop 이 없는 채 — 5시간엔 안 나가고 7시간에 한 번 나간다
(proj / "S1" / "subagents" / "agent-ch2.meta.json").write_text(json.dumps({"parentAgentId": "ld2"}))
put(st("ld2", 1), st("ch2", 2, parent="")); mb.role_events_tick()
put(sp("ld2", 3)); mb.role_events_tick()
T[0] += 3600 * 5; mb.role_events_tick()
check(not any("#ld2 끝" in l for l in at("7010")), f"(c2) 5시간엔 안 나감: {at('7010')[-2:]}")
T[0] += 3600 * 2; mb.role_events_tick(); mb.role_events_tick()
check(sum("#ld2 끝" in l for l in at("7010")) == 1, f"(c2) 7시간엔 한 번 나감: {at('7010')[-3:]}")
# 정상 종료: 자식 stop → 리드 stop → 더 없음 — 19초엔 안 나가고 20초 뒤 한 번, 다음 틱에 중복 없음
(proj / "S1" / "subagents" / "agent-ch3.meta.json").write_text(json.dumps({"parentAgentId": "ld3"}))
put(st("ld3", 1), st("ch3", 2, parent="")); mb.role_events_tick()
put(sp("ch3", 3)); mb.role_events_tick(); put(sp("ld3", 4)); mb.role_events_tick()
T[0] += 19; mb.role_events_tick()
check(not any("#ld3 끝" in l for l in at("7010")), "(c2) 19초엔 안 나감")
T[0] += 1; mb.role_events_tick(); mb.role_events_tick()
check(sum("#ld3 끝" in l for l in at("7010")) == 1 and sum("#ch3 끝" in l for l in at("7010")) == 1, f"(c2) 20초 뒤 한 번씩: {at('7010')[-3:]}")

# (S1) 지시 mid 가 없으면 고정을 만들지 않는다
(sd / "activity.json").unlink()
put(st("nomid", 1)); mb.role_events_tick()
check("nomid" not in ms._agent_pins(sd), "(S1) mid 없으면 고정 안 만듦")
act("7011")

# (I4) 접은 스레드에 늦게 나가는 끝 줄 — 올린 뒤 다시 접고 목록을 되돌린다
put(st("ar", 1)); mb.role_events_tick()
put(sp("ar", 2)); mb.role_events_tick()
(sd / "threads-archived.json").write_text(json.dumps(["7011"]))
T[0] += 25; mb.role_events_tick()
tid = tid_of("7011")
check(any("#ar 끝" in l for l in at("7011")), f"(I4) 접힌 스레드에도 끝 줄이 들어감: {at('7011')}")
check(any(x["m"] == "PATCH" and x["p"] == f"/channels/{tid}" and x["b"].get("archived") for x in log()), "(I4) 올린 뒤 다시 접음")
check("7011" in json.loads((sd / "threads-archived.json").read_text()), "(I4) 접힘 목록 되돌림")

# (I5) 모양이 틀린 상태 항목 하나가 다른 세션·이후 줄을 멈추지 않는다
(sd / "role-held.json").write_text(json.dumps({"x": {"at": 1}, "y": 5, "z": {"ev": "no", "at": 1}}))
(sd / "agent-threads.json").write_text(json.dumps({"p": {"mid": "1", "ts": "abc"}, "q": [1], "r": {"mid": "7011", "ts": mb._now()}}))
put(st("sane", 1)); mb.role_events_tick()
check(any("#sane 시작" in l for l in at("7011")), f"(I5) 모양 틀린 항목이 있어도 줄이 나감: {at('7011')[-2:]}")
check(ms._live_pinned_mids(sd, mb._now()) == {"7011"}, f"(I5) keep 계산: {ms._live_pinned_mids(sd, mb._now())}")
off_before = (Path(os.environ["MARINA_HOME"]) / "role-events.offset").read_text()
check(off_before == str(ev.stat().st_size), "(I5) 오프셋 전진")

# (S2) 붙잡은 게 없고 새 줄도 없으면 세션 목록도 안 읽고 오프셋도 안 쓴다
for _ in range(2): T[0] += 25; mb.role_events_tick()          # 남은 붙잡기 정리
mb._held_dirs = None; real_ls = ms.load_sessions; cnt = [0]
def ls(*a, **k): cnt[0] += 1; return real_ls(*a, **k)
ms.load_sessions = ls
mb.role_events_tick(); c1 = cnt[0]; mb.role_events_tick(); mb.role_events_tick()
check(c1 >= 1 and cnt[0] == c1, f"(S2) 시작 때 한 번 훑고 이후엔 세션 목록 안 읽음: {c1} {cnt[0]}")
# 봇 재시작(메모리 집합 소실)에도 붙잡은 stop 은 상태 파일에서 살아남아 나간다
put(sp("rs", 5)); mb.role_events_tick()
mb._held_dirs = None
T[0] += 25; mb.role_events_tick()
ms.load_sessions = real_ls
check(any("#rs 끝" in l for l in at("7011")), f"(S2) 재시작 뒤에도 붙잡은 stop 이 나감: {at('7011')[-2:]}")

# (S1) 자식 start 때 meta 가 없어 부모가 빈 채 고정돼도, 붙잡기 판정 때 다시 읽어 채운다
put(st("ld4", 1)); mb.role_events_tick(); put(sp("ld4", 2)); mb.role_events_tick()
put(st("ch4", 3, parent="")); mb.role_events_tick()
(proj / "S1" / "subagents" / "agent-ch4.meta.json").write_text(json.dumps({"parentAgentId": "ld4"}))
T[0] += 60; mb.role_events_tick()
check(not any("#ld4 끝" in l for l in at("7010")) and ms._agent_pins(sd).get("ch4", {}).get("parent") == "ld4",
      f"(S1) meta 가 늦게 생겨도 자식이 도는 동안 붙잡음: {ms._agent_pins(sd).get('ch4')}")

# (N1) 재접기는 풀려난 끝 줄만으로 된 그룹에, 그 mid 에서 도는 에이전트가 없을 때만 — 다른 스레드는 안 건드림
act("7030")
put(st("xa", 1)); mb.role_events_tick()
T[0] += 1
def patches(n0): return [x["p"] for x in log()[n0:] if x["m"] == "PATCH"]
(sd / "threads-archived.json").write_text(json.dumps(["7030"]))
n0 = len(log()); put(st("xb", 2)); mb.role_events_tick()
check(patches(n0) == [] and any("#xb 시작" in l for l in at("7030")), f"(N1) 시작 줄은 올린 뒤 다시 접지 않음: {patches(n0)}")
put(sp("xb", 3)); mb.role_events_tick()
(sd / "threads-archived.json").write_text(json.dumps(["7030"]))
n0 = len(log()); T[0] += 25; mb.role_events_tick()
check(any("#xb 끝" in l for l in at("7030")) and patches(n0) == [], f"(N1) 같은 mid 에 도는 에이전트(xa)가 있으면 끝 줄도 안 접음: {patches(n0)}")
put(sp("xa", 4)); mb.role_events_tick()
(sd / "threads-archived.json").write_text(json.dumps(["7030"]))
n0 = len(log()); T[0] += 25; mb.role_events_tick()
check(patches(n0) == [f"/channels/{tid_of('7030')}"], f"(N1) 다 끝났으면 그 스레드 하나만 접음: {patches(n0)}")
# (S3) threads.json 을 못 읽으면 재접기를 안 한다(열린 스레드를 몽땅 접지 않게)
put(st("xq", 5)); mb.role_events_tick(); put(sp("xq", 6)); mb.role_events_tick()
(sd / "threads-archived.json").write_text(json.dumps(["7030"])); real_tj = (sd / "threads.json").read_text()
n0 = len(log()); ms_rearch = mb._rearchive
(sd / "threads.json").write_text("{깨짐")
try:
    ms_rearch({"stateDir": str(sd), "channelId": ch}, "7030")
finally:
    (sd / "threads.json").write_text(real_tj)
check(patches(n0) == [], f"(S3) 못 읽으면 안 접음: {patches(n0)}")

# (I3/S9) 턴 끝 접기 — 지금 도는 에이전트의 고정 mid 는 30분 넘게 조용해도 keep
(sd / "threads.json").write_text(json.dumps({"cur": "T1", "old": "T2", "other": "T3"}))
(sd / "threads-archived.json").unlink()
(sd / "agent-threads.json").write_text(json.dumps({"slow": {"mid": "old", "ts": mb._now() - 7200}}))
act("cur")
ms._running_agent_ids = lambda s: {"slow"}
dc = DC(); ms._turn_end_archive({"stateDir": str(sd)}, sd, dc)
check([c[1] for c in dc.calls] == ["/channels/T3"], f"(I3) 도는 에이전트의 mid(old)·최근(cur) 는 접지 않음: {dc.calls}")
(sd / "threads-archived.json").unlink()
ms._running_agent_ids = lambda s: set()
dc = DC(); ms._turn_end_archive({"stateDir": str(sd)}, sd, dc)
check(sorted(c[1] for c in dc.calls) == ["/channels/T1", "/channels/T2", "/channels/T3"], f"(I3) 도는 게 없으면 모두 접음: {dc.calls}")

# ── 스레드 이름: 종류 · 내용 (2026-10-09) ──────────────────────────────────────────────────────
def tname(mid):
    return next((x["b"]["name"] for x in log() if x["m"] == "POST" and x["p"].endswith(f"/messages/{mid}/threads")), None)
def renames(mid):
    t = tid_of(mid)
    return [x["b"]["name"] for x in log() if x["m"] == "PATCH" and x["p"] == f"/channels/{t}" and "name" in x["b"]]
def D(agent, ts, role, desc, **kw):
    return st(agent, ts, role=role, desc=desc, **kw)
# (b) developer 시작 줄로 열린 스레드 — 기계 글자(역할명·모델) 없이 설명만
act("8001"); put(D("n1", 1, "developer", "결제   버그 고치기")); mb.role_events_tick()
check(tname("8001") == "역할 · 결제 버그 고치기", f"(b) 역할 · 설명: {tname('8001')}")
# (c) researcher 만 → 조사
act("8002"); put(D("n2", 1, "researcher", "캐시 조사")); mb.role_events_tick()
check(tname("8002") == "조사 · 캐시 조사", f"(c) 조사 · 설명: {tname('8002')}")
# 역할 없는 서브에이전트(role '-')도 역할 종류
act("8010"); put(D("n10", 1, "-", "코드 찾기")); mb.role_events_tick()
check(tname("8010") == "역할 · 코드 찾기", f"(b2) 역할 없는 에이전트도 역할: {tname('8010')}")
# (d) 진행 스레드에 developer 가 붙으면 역할로 한 번, 같은 종류가 더 붙어도 그대로
ms._progress(rec, {"message_id": "8003", "text": "세션 혼자 한 줄"})
check(tname("8003") == "진행 · 세션 혼자 한 줄", f"(d) 처음은 진행: {tname('8003')}")
act("8003"); put(D("n3", 1, "developer", "첫 개발")); mb.role_events_tick()
check(renames("8003") == ["역할 · 첫 개발"], f"(d) 진행 → 역할 한 번: {renames('8003')}")
put(D("n3b", 2, "qa", "두번째")); mb.role_events_tick()
check(renames("8003") == ["역할 · 첫 개발"], f"(d) 같은 종류는 안 바꿈: {renames('8003')}")
# 조사 → 역할 올라감, 내려가지 않음
ms._progress(rec, {"message_id": "8011", "text": "x"})
act("8011"); put(D("n11", 1, "researcher", "조사부터")); mb.role_events_tick()
put(D("n11b", 2, "developer", "이어 구현")); mb.role_events_tick()
check(renames("8011") == ["조사 · 조사부터", "역할 · 이어 구현"] or renames("8011") == ["역할 · 이어 구현"], f"(d2) 조사 → 역할: {renames('8011')}")
put(D("n11c", 3, "researcher", "또 조사")); mb.role_events_tick()
check(renames("8011")[-1:] == ["역할 · 이어 구현"], f"(d2) 내려가지 않음: {renames('8011')}")
# (e) 리드가 붙으면 리드 · 리드 설명
ms._progress(rec, {"message_id": "8004", "text": "시작"})
act("8004"); put(D("n4", 1, "developer", "개발자 일")); mb.role_events_tick()
put(D("ld4", 2, "lead", "전체 굴리기")); mb.role_events_tick()
check(renames("8004")[-1:] == ["리드 · 전체 굴리기"], f"(e) 리드: {renames('8004')}")
# (f) 리드 스레드에 자식 developer 가 붙어도 이름 그대로
act("8006"); put(D("ld6", 1, "lead", "큰 작업")); mb.role_events_tick()
put(D("k6", 2, "developer", "자식 구현", parent="ld6")); mb.role_events_tick()
check(tname("8006") == "리드 · 큰 작업" and renames("8006") == [], f"(f) 리드 스레드 불변: {tname('8006')} {renames('8006')}")
# 90자 제한
act("8012"); put(D("n12", 1, "developer", "가" * 80)); mb.role_events_tick()
check(tname("8012") == ("역할 · " + "가" * 80)[:90], f"(b3) 90자: {tname('8012')}")
# (g) PATCH 실패 — 줄은 올라가고, 다음 틱에 바로 재시도하지 않는다
ms._progress(rec, {"message_id": "8007", "text": "g"})
(fd / "forbid").write_text(tid_of("8007"))
act("8007"); put(D("n7", 1, "developer", "실패 케이스")); mb.role_events_tick()
check(any("developer#n7 시작" in l for l in at("8007")), f"(g) 줄은 올라감: {at('8007')}")
check(len(renames("8007")) == 1, f"(g) PATCH 한 번 시도: {renames('8007')}")
put(D("n7b", 2, "developer", "더")); mb.role_events_tick()
check(len(renames("8007")) == 1, f"(g) 바로 재시도 안 함: {renames('8007')}")
(fd / "forbid").unlink()
kf = sd / "threads-kind.json"
kd = json.loads(kf.read_text()); kd["8007"]["retry"] = 0; kf.write_text(json.dumps(kd))
put(D("n7c", 3, "developer", "또")); mb.role_events_tick()
check(len(renames("8007")) == 2, f"(g) 재시도 시각이 지나면 다시: {renames('8007')}")
put(D("n7d", 4, "developer", "또또")); mb.role_events_tick()
check(len(renames("8007")) == 2, f"(g) 성공하면 더 안 함: {renames('8007')}")
# (h) 접힌 스레드는 이름을 안 바꾼다(다시 열지도 않음)
ms._progress(rec, {"message_id": "8008", "text": "h"})
(sd / "threads-archived.json").write_text(json.dumps(["8008"]))
n0 = len(log())
act("8008"); put(D("n8", 1, "developer", "접힌 케이스")); mb.role_events_tick()
check(renames("8008") == [], f"(h) 접힌 스레드는 이름 안 바꿈: {renames('8008')}")
check(not any(x["m"] == "PATCH" and x["b"].get("archived") is False for x in log()[n0:]), "(h) 다시 열지 않음")
# 상태 파일이 깨져도 안 죽음
kf.write_text("{깨짐")
act("8013"); put(D("n13", 1, "developer", "깨진 상태")); mb.role_events_tick()
check(tname("8013") == "역할 · 깨진 상태", f"(N) 깨진 종류 기록 → 빈 것: {tname('8013')}")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-role-events"
