#!/usr/bin/env bash
# (형 2026-10-29) "상태 채널이 부실해 — 계속 하고 있냐고 물어보게 돼"
#  ① 작업 중 줄에 무슨 지시를 몇 분째 하는지·지금 하는 일·오래 조용하면 ⚠
#  ② 잠든 방은 방마다 한 줄이 아니라 링크 한 줄로(24줄이 화면을 덮었다)
#  ③ 일하던 방이 갑자기 꺼지면(16:11 tmux 서버 종료로 ovation 이 3시간 꺼져 있었는데 아무도 몰랐다) 방에 알리고 다시 켜서 잇게
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
msess new proj feat/a --no-start >/dev/null 2>&1 || { echo "FAIL: new"; exit 1; }

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
import marina_discord_wake as mw
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = str(rec["channelId"])
os.environ["DISCORD_STATE_DIR"] = str(sd)
tr = sd / "t.jsonl"; tr.write_text("")

# ① 받은 지시의 첫 줄을 적어 두고, 도구를 쓸 때마다 지금 하는 일을 적는다
tag = (f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="7001" user="u" ts="x">\n'
       f'\n  ovation 설명글 규칙 1차 작업 이어서 해줘. 끝나면 dev 화면 찍어서 보여줘 그리고 전체 시험도 다시 돌려\n둘째 줄\n</channel>')
ms.hook_activity({"hook_event_name": "UserPromptSubmit", "prompt": tag, "transcript_path": str(tr)}, min_gap=0)
st = ms._activity_state(sd)
check(st.get("ask", "").startswith("ovation 설명글 규칙 1차 작업") and len(st["ask"]) <= 60 and "둘째" not in st["ask"],
      f"지시 첫 줄(60자 안): {st.get('ask')!r}")
tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": tag}}) + "\n")
ms.hook_activity({"tool_name": "Bash", "tool_input": {"command": "pytest -q", "description": "영향 테스트"},
                  "transcript_path": str(tr)}, min_gap=0)
st = ms._activity_state(sd)
check("테스트 중" in st.get("doing", ""), f"지금 하는 일: {st.get('doing')!r}")
check(st.get("ask", "").startswith("ovation"), "도구 훅이 지시 요약을 지우지 않는다")

def busy_row(**kw):
    r = {"ref": "proj/feat/a", "channelId": ch, "alive": True, "busy": True, "emoji": "🧪", "ctx": 30.0}
    r.update(kw); return r
def texts(comps):
    out = []
    for c in comps:
        if c.get("type") == 10: out.append(c["content"])
        for x in c.get("components") or []:
            if x.get("type") == 10: out.append(x["content"])
    return "\n".join(out)
now = time.time()
t = texts(mb.render({"usage": [], "sessions": [busy_row(ask="설명글 규칙 1차", since=now - 25 * 60, doing="🧪 테스트 중 — 영향 테스트", quiet=30)]}))
check("설명글 규칙 1차" in t and "25분째" in t and "테스트 중" in t, f"작업 중 줄에 지시·경과·지금 하는 일: {t}")
check("조용" not in t, f"방금 움직였으면 조용 표시 없음: {t}")
t = texts(mb.render({"usage": [], "sessions": [busy_row(ask="x", since=now - 3 * 3600, doing="🔧 명령 실행 중", quiet=17 * 60)]}))
check("⚠ 17분째 조용" in t and "3시간째" in t, f"오래 조용하면 ⚠ · 시간 단위: {t}")
t = texts(mb.render({"usage": [], "sessions": [busy_row()]}))
check("📝" not in t, f"모르면 안 그린다: {t}")

# ② 잠든 방은 링크 한 줄
def srow(ref, chn): return {"ref": ref, "channelId": chn, "alive": False, "busy": False, "emoji": "", "ctx": None,
                            "asking": False, "permission": False, "wakeable": True}
t = texts(mb.render({"usage": [], "sessions": [srow(f"p{i}/x", str(100 + i)) for i in range(20)]}))
sleep = t[t.index("🌙"):]
check("🌙 잠듦 20" in sleep and "<#100>" in sleep and "<#119>" in sleep, f"잠든 방 수와 링크: {sleep}")
check(sleep.count("\n") <= 3, f"방마다 한 줄이 아니라 링크 한 줄: {sleep!r}")

# ③ 일하던 방이 marina 가 내리지 않았는데 꺼지면 → 방에 알리고 다시 켠다
resumed = []
mb._spawn_bg = lambda f: f()
ms.tmux_alive = lambda name: False         # 픽스처 방의 실제 tmux 와 무관하게 '꺼짐'으로

mw._resume_interrupted = lambda r, now, text=ms.RESUME_TEXT: resumed.append((r["channelId"], text)) or True
mem = {}
alive_row = {"ref": "proj/feat/a", "channelId": ch, "alive": True, "busy": False, "bg": True}
dead_row = dict(alive_row, alive=False, bg=False)
mb.crash_tick([alive_row], mem, now)
n = len(log())
mb.crash_tick([dead_row], mem, now + 5)
check(not resumed, "잠깐(유예 안) 꺼진 건 아직 판단하지 않는다")
mb.crash_tick([dead_row], mem, now + 30)
check(resumed and resumed[0][0] == ch and "갑자기 꺼졌" in resumed[0][1], f"다시 켜서 이어서 하게: {resumed}")
posts = [x for x in log()[n:] if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages"]
check(posts and "갑자기 꺼졌" in posts[-1]["b"]["content"], f"방에 알림: {[p['b'] for p in posts]}")
mb.crash_tick([dead_row], mem, now + 120)
check(len(resumed) == 1, "한 번만")

# marina 가 내린 방(멈춤·재시작·쉼)은 건드리지 않는다
resumed.clear(); mem.clear()
mb.crash_tick([alive_row], mem, now)
ms.tmux_stop(str(rec["tmux"]))            # 떠 있지 않아도 내린 기록은 남는다
mb.crash_tick([dead_row], mem, now + 5); mb.crash_tick([dead_row], mem, now + 60)
check(not resumed, f"marina 가 내린 방은 그대로: {resumed}")
# 쉬던 방이 꺼진 건 알리지 않는다(글이 오면 깨어난다)
resumed.clear(); mem.clear(); n = len(log())
mb.crash_tick([dict(alive_row, bg=False)], mem, time.time() + 1000)
mb.crash_tick([dead_row], mem, time.time() + 2000); mb.crash_tick([dead_row], mem, time.time() + 2100)
check(not resumed and not [x for x in log()[n:] if x["m"] == "POST"], "쉬던 방은 조용히")
# (리뷰 I1) 디스코드에서 오지 않은 턴(이어받기·터미널)은 지난 지시를 보여 주지 않고, 조용함은 이번 턴 시작부터 잰다
(sd / "turn-at").write_text(str(time.time() - 120))
st = ms._activity_state(sd); st["since"] = time.time() - 3 * 3600; ms._write_json(sd / "activity.json", st)
os.utime(sd / "activity-at", (time.time() - 3 * 3600, time.time() - 3 * 3600))
info = mb._turn_info(ms._activity_state(sd), sd)
check(not info["ask"] and not info["doing"] and abs(time.time() - info["since"] - 120) < 5, f"지난 지시 버림·이번 턴 시작: {info}")
check(info["quiet"] < 200, f"조용함은 이번 턴부터: {info['quiet']}")
# (리뷰 I2) 작업 줄이 많고 길어도 한 메시지 4000자 안
long = [busy_row(ref=f"p{i}/x", channelId=str(500 + i), ask="가" * 60, since=now - 600, doing="🔧 " + "나" * 60, quiet=900,
                 tasks=[{"kind": "agent", "id": f"a{j}", "name": "n", "desc": "다" * 50, "state": "run"} for j in range(4)]) for i in range(12)]
long += [srow(f"s{i}/x", str(900000000000000000 + i)) for i in range(30)]
comps = mb.render({"usage": [], "sessions": long})
check(mb._chars(comps) + 200 <= 4000, f"글자 수 한도: {mb._chars(comps)}")
# (리뷰 M1·I3) 유예는 처음 꺼진 걸 본 때부터 · 다시 켜기는 루프 밖에서(spawn)
resumed.clear(); mem.clear(); spawned = []
mb._spawn_bg = lambda f: spawned.append(f)
t0 = time.time() + 5000
mb.crash_tick([alive_row], mem, t0)
mb.crash_tick([dead_row], mem, t0 + 100)
check(not spawned, "루프가 오래 멈춘 뒤 처음 본 꺼짐은 바로 판단하지 않는다")
mb.crash_tick([dead_row], mem, t0 + 130)
check(len(spawned) == 1 and not resumed, f"다시 켜기는 루프 밖으로: {spawned}")
spawned[0](); check(len(resumed) == 1, "넘긴 일이 다시 켠다")
ms.tmux_alive = lambda name: True; resumed.clear(); mem.clear(); spawned.clear()
mb.crash_tick([alive_row], mem, t0); mb.crash_tick([dead_row], mem, t0 + 1); mb.crash_tick([dead_row], mem, t0 + 30)
n = len(log()); spawned[0]()
check(not resumed and not [x for x in log()[n:] if x["m"] == "POST"], "그사이 다시 떴으면 켜지도 알리지도 않는다(리뷰 M2)")
# (리뷰 M4) 목록에서 빠진 방은 잊는다
mb.crash_tick([], mem, t0 + 200); check(not mem, f"빠진 방 정리: {mem}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-status-board"
