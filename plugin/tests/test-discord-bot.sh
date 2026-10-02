#!/usr/bin/env bash
# 마리나 Discord 봇 1단계 — 🛑 정지 · #상태 대시보드 · 사용량 숫자판(형만 보임).
#  - 로직은 파이썬(marina_discord_bot.py), 봇(bun)은 🛑 반응 이벤트만 받아 interrupt 를 부른다
#  - #상태·주간 채널은 만들 때부터 @everyone 을 막고 형(개발 프로젝트 allow)과 봇만 연다
#  - 대시보드는 메시지 하나를 고쳐 쓴다 — 내용이 같으면 안 건드린다
#  - 🛑: 작업이 시작되면 훅이 지시 메시지에 미리 달고, 턴이 끝나면 뗀다. 누르면 그 세션에 Esc
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$SCRIPTS" python3 - "$FD" "$MARINA_HOME" <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fd, mh = Path(sys.argv[1]), Path(sys.argv[2])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
cfg = ms.load_config()
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
mb.claude_usage = lambda: [{"key": "fiveHour", "label": "5시간", "usedPercent": 20.0},
                           {"key": "weekly", "label": "주간", "usedPercent": 6.0}]

check(mb.owner_ids(cfg) == ["U1"], f"형 = 개발 프로젝트 allow: {mb.owner_ids(cfg)}")

# ── #상태 대시보드 ──
st = {}
mb.dashboard_tick(st)
made = [x for x in log() if x["m"] == "POST" and x["p"] == "/guilds/G1/channels" and x["b"].get("name") == "상태"]
check(len(made) == 1, f"#상태 생성: {made}")
ow = {o["id"]: o for o in made[0]["b"]["permission_overwrites"]} if made else {}
check(int(ow.get("G1", {}).get("deny", 0)) & ms._VIEW, "@everyone 은 못 본다")
check(int(ow.get("U1", {}).get("allow", 0)) & ms._VIEW, "형은 본다")
check(int(ow.get("BOT1", {}).get("allow", 0)) & ms._VIEW, "봇도 본다(못 보면 고쳐 쓰지 못한다)")
posts = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{st.get('channelId')}/messages"]
check(len(posts) == 1, f"대시보드 메시지 하나: {posts}")
def txt(comps):
    out = []
    for c in comps or []:
        if c.get("content"): out.append(c["content"])
        out.append(txt(c.get("components")))
    return "\n".join(x for x in out if x)
body = txt(posts[0]["b"].get("components")) if posts else ""
check(posts and posts[0]["b"].get("flags") == 1 << 15, "Components V2 메시지")
check("5시간 `██░░░░░░░░` 20%" in body and "주간 `█░░░░░░░░░` 6%" in body, f"구독 사용량 막대: {body}")
check("### 🔧 작업 중 0" in body and f"### 💤 대기 1\n`   -  proj` <#{ch}>" in body, f"섹션 + 고정폭 칸 + 끝에 채널 링크: {body}")
check("디스크" in body and "갱신" in body.splitlines()[-1], "디스크·시각은 꼬리말")
check(posts and posts[0]["b"].get("allowed_mentions") == {"parse": []}, "멘션 알림 없음")
n = len(log()); mb.dashboard_tick(st)
check(not any(x["m"] in ("POST", "PATCH") for x in log()[n:]), "내용이 같으면 안 건드린다")
old = {"channelId": st["channelId"], "messageId": "old-text", "body": "x"}
n = len(log()); mb.dashboard_tick(old)
check(any(x["m"] == "DELETE" and x["p"].endswith("/messages/old-text") for x in log()[n:])
      and any(x["m"] == "POST" and x["b"].get("flags") == 1 << 15 for x in log()[n:]), "예전 글자 형식 메시지는 지우고 새로 올린다")

# 작업 중 세션: 입력창(❯) 위에 도는 표시 줄 → 🔧 표시, 다음 갱신은 메시지를 고쳐 쓴다
base = ms._tmux_base()
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)   # new 가 띄운 가짜 claude 대신
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", "printf 'esc to interrupt 는 대화 내용일 뿐\\n✢ Schlepping… (5m 41s · ↓ 3k tokens)\\n  ⎿  ☐ 1\\n     ☐ 2\\n     ☐ 3\\n     ☐ 4\\n     ☐ 5\\n     ☐ 6\\n     ☐ 7\\n     ☐ 8\\n\\n────\\n❯ \\n────\\n  [Opus]\\n'; exec cat -v"], check=True)
time.sleep(0.5)
snap = mb.snapshot()
me = next(s for s in snap["sessions"] if s["ref"] == "proj/feat/a")
check(me["busy"] is True, f"작업 중 판정: {me}")
# (실사용) 막 받은 Discord 메시지 알림 줄('← discord · …')이 표시 줄과 입력창 사이에 끼어도 작업 중
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                       "printf '✽ Forming… (7s · thinking)\\n← discord · u: 안녕\\n────\\n❯ \\n────\\n'; exec cat -v"], check=True)
time.sleep(0.5)
check(mb._pane_busy(rec["tmux"]) == (True, True), "알림 줄은 건너뛰고 표시 줄을 본다")
check(snap["anyBusy"] is True, "작업 중 세션 있음")
n = len(log()); mb.dashboard_tick(st)
patches = [x for x in log()[n:] if x["m"] == "PATCH" and x["p"] == f"/channels/{st['channelId']}/messages/{st['messageId']}"]
pc = patches[0]["b"]["components"] if patches else []
busy_sec = [c for c in pc if c.get("type") == 9]
check(busy_sec and f"🔧 `   -  proj` <#{ch}>" in busy_sec[0]["components"][0]["content"]
      and busy_sec[0]["accessory"]["custom_id"] == f"marina-stop:{ch}", f"작업 중 줄 + 정지 버튼: {pc}")
r2 = mb.render({"usage": [], "sessions": [
    {"ref": "a/x", "channelId": "1", "alive": True, "busy": False, "emoji": "", "ctx": 71.0},
    {"ref": "a/y", "channelId": "2", "alive": True, "busy": False, "emoji": "", "ctx": 10.0},
    {"ref": "b/z", "channelId": "3", "alive": True, "busy": True, "emoji": "🧪", "ctx": 30.0}]})
t2 = txt(r2)
check("🧪 ` 30%  b   ` <#3>" in t2 and "` 71%  a   ` <#1> ⚠\n` 10%  a   ` <#2>" in t2,
      f"프로젝트 너비 맞춤·프로젝트 순 정렬·70%↑ ⚠: {t2}")
check(sum(1 for c in r2 if c.get("type") == 9) == 1, "정지 버튼은 작업 중에만")
# '입력 중…' 은 10초면 꺼진다 — 작업 중인 세션 채널에 8초마다 다시 보낸다(쉬는 세션엔 안 보냄)
ty = {}
n = len(log()); mb.typing_tick(snap, ty, now=1000)
typ = [x["p"] for x in log()[n:] if x["m"] == "POST" and x["p"].endswith("/typing")]
check(typ == [f"/channels/{ch}/typing"], f"작업 중 채널에만 입력 중: {typ}")
n = len(log()); mb.typing_tick(snap, ty, now=1005)
check(not any(x["p"].endswith("/typing") for x in log()[n:]), "8초 안엔 다시 안 보낸다")
n = len(log()); mb.typing_tick(snap, ty, now=1009)
check(any(x["p"].endswith("/typing") for x in log()[n:]), "8초 지나면 다시")

# 언제 다시 그리나 — 신호(턴 시작·끝, 세션 켜짐·꺼짐)는 바로, 작업 중이면 30초마다, 쉬면 안 그린다
check(mb.should_render(now=100, last=90, dirty=95, busy=False) is True, "신호가 오면 바로")
check(mb.should_render(now=100, last=90, dirty=80, busy=False) is False, "쉬는 중엔 안 그린다")
check(mb.should_render(now=125, last=90, dirty=80, busy=True) is True, "작업 중 30초")
check(mb.should_render(now=110, last=90, dirty=80, busy=True) is False, "작업 중이어도 30초 안엔 안 그린다")
before = mb.dirty_mtime(); time.sleep(0.05)
mb.mark_dirty()
check(mb.dirty_mtime() > before, "신호 파일")

# ── 사용량 숫자판(형만 보이는 빈 카테고리 — 음성 채널은 서버 주인이 눌러서 들어가져 바꿈, 형 2026-10-02) ──
#  - 5시간·주간 각각 한 줄. 카테고리는 눌러도 접히기만 한다
mh_state = json.loads((mh / "discord-bot.json").read_text()) if (mh / "discord-bot.json").exists() else {}
mh_state["weekly"] = {"channelId": "OLDVOICE", "name": "📊 주간 5%", "renamedAt": 0}   # 예전 음성 숫자판
(mh / "discord-bot.json").write_text(json.dumps(mh_state))
meters = {}
n0 = len(log()); mb.meter_tick(meters)
check(any(x["m"] == "DELETE" and x["p"] == "/channels/OLDVOICE" for x in log()[n0:]), "예전 음성 숫자판은 지운다")
vc = [x for x in log()[n0:] if x["m"] == "POST" and x["p"] == "/guilds/G1/channels"]
names = [x["b"]["name"] for x in vc]
check(len(vc) == 2 and all(x["b"].get("type") == 4 for x in vc) and names == ["📊 5시간 20%", "📊 주간 6%"], f"숫자판 둘(카테고리): {names} {vc}")
vow = {o["id"]: o for o in vc[0]["b"]["permission_overwrites"]} if vc else {}
check(int(vow.get("G1", {}).get("deny", 0)) & ms._VIEW, "숫자판: @everyone 못 봄")
check(int(vow.get("U1", {}).get("allow", 0)) & ms._VIEW, "숫자판: 형은 봄")
check(int(vow.get("BOT1", {}).get("allow", 0)) & mb._MANAGE, "숫자판: 봇은 이름을 바꿀 수 있다")
wk = meters["weekly"]
n = len(log()); mb.meter_tick(meters)
check(not any(x["m"] in ("POST", "PATCH", "DELETE") for x in log()[n:]), "같은 숫자면 이름 안 바꿈(이름 변경은 10분 2회 제한)")
mb.claude_usage = lambda: [{"key": "fiveHour", "label": "5시간", "usedPercent": 20.0}, {"key": "weekly", "label": "주간", "usedPercent": 7.4}]
n = len(log()); mb.meter_tick(meters)
check(not any(x["m"] == "PATCH" for x in log()[n:]), "이름은 10분에 한 번만(재시작해도 기억, 리뷰 M5)")
wk["renamedAt"] = time.time() - 601; n = len(log()); mb.meter_tick(meters)
ren = [x for x in log()[n:] if x["m"] == "PATCH"]
check(len(ren) == 1 and ren[0]["p"] == f"/channels/{wk['channelId']}" and "주간 7%" in ren[0]["b"]["name"], f"바뀐 것만 이름 변경: {ren}")
# 봇이 못 만지는 채널(403 Missing Access)이 되면 새로 만든다
(fd / "forbid").write_text(wk["channelId"])
mb.claude_usage = lambda: [{"key": "fiveHour", "label": "5시간", "usedPercent": 20.0}, {"key": "weekly", "label": "주간", "usedPercent": 9.0}]
old_id = wk["channelId"]; wk["renamedAt"] = 0; n = len(log()); mb.meter_tick(meters)
check(wk["channelId"] != old_id and any(x["m"] == "POST" and x["b"].get("type") == 4 for x in log()[n:]), f"접근 불가면 다시 만듦: {wk}")
(fd / "forbid").unlink()
s2 = json.loads((mh / "discord-bot.json").read_text())
check(s2.get("dashboard", {}).get("channelId") == st["channelId"] and s2.get("weekly", {}).get("channelId") == wk["channelId"]
      and s2.get("fiveHour", {}).get("channelId") == meters["fiveHour"]["channelId"],
      f"채널 기억(재시작해도 새로 안 만든다): {s2}")

# ── 🛑 정지 ──
# 대상 = 그 세션이 지금 하고 있는 지시(기록의 마지막 형 메시지). 누른 메시지가 스레드 상태 줄이나 옛 메시지여도 같다(리뷰 I3)
sid = rec.get("sessionId") or "abcdabcd-0000-1111-2222-333344445555"
trp = ms.transcript_path(Path(rec["root"]), sid); trp.parent.mkdir(parents=True, exist_ok=True)
def say(mid):
    t = f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="{mid}" user="u">\nx\n</channel>'
    with open(trp, "a") as fh:
        fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": t}}) + "\n")
say("8999"); say("9001")
(sd / "acked").write_text("8999\n")
ms._write_json(sd / "activity.json", {"mid": "9001", "emoji": "🔧", "marked": {"9001": ["🛑", "🔧"], "8999": ["👀"]}})
out = mb.interrupt(ch, "U2", "9001")
check("권한" in out, f"허용 목록 밖 사람은 못 멈춘다: {out}")
check("권한" in mb.interrupt(ch, "BOT1", "9001"), "봇 자신(미리 단 🛑)은 멈추지 못한다(리뷰 M8)")
time.sleep(0.3)
pane = subprocess.run(base + ["capture-pane", "-p", "-t", rec["tmux"]], capture_output=True, text=True).stdout
check("^[" not in pane, "거절이면 키를 안 보낸다")
n = len(log())
out = mb.interrupt(ch, "U1", "T-status-line")     # 진행 스레드 상태 줄에서 누름
check("멈췄어" in out, f"정지: {out}")
out2 = mb.interrupt(ch, "U1", "9001")               # 연달아 또 눌림(두 사람·다시 누름) — Esc 두 번이면 되감기 창이 열린다(리뷰 I2)
check("이미" in out2, f"같은 지시는 한 번만 멈춘다: {out2}")
time.sleep(0.3)
pane = subprocess.run(base + ["capture-pane", "-p", "-t", rec["tmux"]], capture_output=True, text=True).stdout
check(pane.count("^[") == 1, f"Esc 를 한 번 보냈다: {pane!r}")
dels = [x["p"] for x in log()[n:] if x["m"] == "DELETE"]
check(any("/messages/9001/reactions/%F0%9F%94%A7" in p for p in dels) and any("/messages/9001/reactions/%F0%9F%9B%91" in p for p in dels),
      f"지금 지시(9001)의 진행 이모지·🛑 뗌: {dels}")
check(any("/messages/8999/reactions/%F0%9F%91%80" in p for p in dels), f"같이 읽은 앞 메시지의 👀 도 뗌(리뷰 B-I2): {dels}")
check(json.loads((sd / "activity.json").read_text()).get("marked") == {}, "달아 둔 표시 기록 비움")
check(any(x["m"] == "PUT" and "/messages/9001/reactions/%E2%8F%B9" in x["p"] for x in log()[n:]), "⏹️ 표시")
check(not any("T-status-line" in x["p"] for x in log()[n:]), "누른 상태 줄 메시지는 건드리지 않는다")
check((sd / "acked").read_text().strip() == "9001", "멈춘 지시엔 진행 이모지가 다시 붙지 않게")
check("모르는" in mb.interrupt("C-none", "U1", "1"), "세션 없는 채널")
subprocess.run(base + ["kill-session", "-t", rec["tmux"]])
check("쉬고" in mb.interrupt(ch, "U1", "9002"), "꺼진 세션엔 키를 안 보낸다")
subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c",
                        "printf '✢ Schlepping… (9s) 는 위쪽 대화 내용\\n1\\n2\\n3\\n4\\n5\\n6\\n7\\n✻ Worked for 3m\\n────\\n❯ \\n────\\n'; exec cat"], check=True)
time.sleep(0.5)
me = next(s for s in mb.snapshot(full=False)["sessions"] if s["ref"] == "proj/feat/a")
check(me["alive"] is True and me["busy"] is False, f"끝난 화면(입력창 위에 도는 표시 없음)은 대기: {me}")
check("쉬고" in mb.interrupt(ch, "U1", "9003"), "쉬는 세션엔 Esc 를 안 보낸다(입력 중인 글이 지워지지 않게)")
subprocess.run(base + ["kill-session", "-t", rec["tmux"]])

# ── 훅: 작업이 시작되면 🛑 를 미리 달고, 턴이 끝나면 뗀다 ──
os.environ["DISCORD_STATE_DIR"] = str(sd)
(sd / "acked").write_text(""); (sd / "activity.json").unlink()
tr = sd / "t.jsonl"
tag = f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="7001" user="u">\nfix\n</channel>'
tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": tag}}) + "\n")
d0 = mb.dirty_mtime(); time.sleep(0.05)
n = len(log())
ms.hook_activity({"tool_name": "Read", "tool_input": {"file_path": "/a"}, "transcript_path": str(tr)}, min_gap=0)
check(any(x["m"] == "PUT" and "/messages/7001/reactions/%F0%9F%9B%91" in x["p"] for x in log()[n:]), "🛑 미리 달기")
check(mb.dirty_mtime() > d0, "새 지시 시작 = 대시보드 신호")
n = len(log())
ms.hook_activity({"tool_name": "Edit", "tool_input": {"file_path": "/a"}, "transcript_path": str(tr)}, min_gap=0)
check(not any("%F0%9F%9B%91" in x["p"] for x in log()[n:]), "같은 지시면 🛑 를 다시 달지 않는다")
d1 = mb.dirty_mtime(); time.sleep(0.05)
n = len(log())
ms.hook_stop({"cwd": rec["root"], "transcript_path": str(tr)})
check(any(x["m"] == "DELETE" and "/messages/7001/reactions/%F0%9F%9B%91" in x["p"] for x in log()[n:]), "턴 끝에 🛑 뗌")
check(mb.dirty_mtime() > d1, "턴 끝 = 대시보드 신호")

# ── 도착 👀 끄기: 받은 순간에만 훅이 단다(형 결정) ──
acc = json.loads((sd / "access.json").read_text())
check("ackReaction" not in acc, f"새 상태 폴더엔 도착 👀 없음: {acc}")
stt = json.loads((sd / "settings.json").read_text())
check("hook-typing" in json.dumps(stt["hooks"].get("UserPromptSubmit")), "받은 순간 훅")
(sd / "access.json").write_text(json.dumps(dict(acc, ackReaction="👀")))
ms._drop_ack_reaction(sd / "access.json")
check("ackReaction" not in json.loads((sd / "access.json").read_text()), "예전 상태 폴더는 start 때 지운다")

# ── 봇 실행 명령(데몬이 띄운다) ──
cmd = mb.bot_command(cfg)
check(cmd is not None and cmd["env"]["DISCORD_BOT_TOKEN"] == "test-token" and cmd["env"]["MARINA_GUILD"] == "G1",
      f"봇 실행 env: {cmd and {k: v for k, v in cmd['env'].items() if k != 'DISCORD_BOT_TOKEN'}}")
check(cmd and Path(cmd["cwd"]).joinpath("bot.ts").is_file(), "봇 코드 위치")
# ── 데몬 한 바퀴: 봇을 띄우고(죽으면 간격을 늘려 다시), 첫 바퀴엔 대시보드·숫자판을 그린다. 설정이 없으면 봇을 내린다 ──
calls = []
class P:
    def __init__(self, *a, **k): calls.append(a[0]); self.returncode = None
    def poll(self): return self.returncode
    def terminate(self): self.returncode = -15
    def wait(self, t=None): return self.returncode
mb._spawn = P
mb.BOT_DIR = mh / "botdir"
mb.bot_command = lambda cfg: {"argv": ["bun", "bot.ts"], "cwd": str(mb.BOT_DIR), "env": {}, "bun": "bun"}
(mb.BOT_DIR / "node_modules").mkdir(parents=True)
mb.dashboard_tick = lambda st: calls.append("dash"); mb.meter_tick = lambda st: calls.append("week"); ms.reconcile_gone = lambda now: calls.append("gone") or []
# 리뷰 M6: #상태 그리기가 계속 실패해도 사라진 워크트리 정리·잠금은 돈다
_dt = mb.dashboard_tick
mb.dashboard_tick = lambda st: (_ for _ in ()).throw(RuntimeError("render boom"))
bad = mb.Loop(); bad.started = 0
try:
    bad.view(time.time())
except Exception:
    pass
check("gone" in calls, f"그리기가 터져도 reconcile 은 먼저 돈다: {calls}")
calls.clear(); mb.dashboard_tick = _dt
mb.dashboard_tick = lambda st: calls.append("dash")
lp = mb.Loop(); t0 = time.time() + 5
check(lp.step(t0) is True and calls == [["bun", "bot.ts"], "gone", "dash", "week"], f"첫 바퀴(+사라진 워크트리 정리): {calls}")
calls.clear(); lp.step(t0 + 4)
check(calls == [], f"다음 바퀴(신호·작업 없음)엔 아무것도: {calls}")
lp.proc.returncode = 1; lp.step(t0 + 10)
check(calls == [] and lp.next_start == t0 + 20, f"1분 안에 죽으면 간격 2배: {lp.next_start}")
lp.step(t0 + 21)
check(calls == [["bun", "bot.ts"]], f"간격 뒤 다시 띄움: {calls}")
time.sleep(0.01); os.utime(ms.dashboard_signal_path(), (t0 + 25, t0 + 25)); calls.clear(); lp.step(t0 + 30)
check("dash" in calls, f"신호 오면 다시 그림: {calls}")
other = mb.Loop()
check(other.step(t0 + 32) is False, "같은 마리나 홈에선 한 인스턴스만 봇·대시보드를 돌린다(리뷰 I1)")
p = lp.proc
(mh / "discord.json").rename(mh / "discord.json.off")
check(lp.step(t0 + 40) is False and p.returncode == -15 and lp.proc is None, "설정을 지우면 봇을 내린다")
(mh / "discord.json.off").rename(mh / "discord.json")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-bot"
