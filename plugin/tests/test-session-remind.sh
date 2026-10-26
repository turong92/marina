#!/usr/bin/env bash
# remind_at / remind_list / remind_cancel — 한 번만 울리는 알림 예약(매일 같은 시각은 brief 가 맡는다).
# 다은이 "내일 9시 30분에 기안 올리라고 알림해줘" 했을 때 비서가 "정해진 시각엔 먼저 말 못 건다" 고 답했다(형 2026-10-26).
#  - 예약은 방별로 갈린다. 지난 시각·꼴이 틀린 시각·빈 내용은 거부
#  - 데몬은 '때가 된 게 있나' 만 보고(due_reminders), 보내는 건 떼어 낸 프로세스(remind-run)
#  - 늦은 알림은 '늦었어' 를 붙여 보내고, 하루 넘은 것은 버린다. 못 보낸 것은 백오프를 두고 다시
#  - 보내는 동안 방이 만든 예약이 사라지지 않는다(한 건씩 그 건만 고친다) · 들어간 걸 확인 못 하면 한 번만 다시
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
msess new proj feat/r --no-start >/dev/null 2>&1 || fail "new"
msess new chat room --title "방" >/dev/null 2>&1 || fail "new chat"
msess new chat other --title "옆방" >/dev/null 2>&1 || fail "new chat2"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
import datetime, json, os, sys
from pathlib import Path
import marina_session as ms
import marina_discord_brief as mbr
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]

room, other, dev = ms.find_session("chat/room"), ms.find_session("chat/other"), ms.find_session("proj/feat/r")
os.environ["DISCORD_STATE_DIR"] = room["stateDir"]
names = [t["name"] for t in ms._CHAT_TOOLS_MCP]
for n in ("remind_at", "remind_list", "remind_cancel"):
    check(n in names, f"도구 목록에 {n}: {names}")
st = json.loads((Path(room["stateDir"]) / "settings.json").read_text())
check("mcp__marina__remind_at" in st["permissions"]["allow"], "대화방에 허용")
dst = json.loads((Path(dev["stateDir"]) / "settings.json").read_text())
check("mcp__marina__remind_at" not in dst["permissions"]["allow"], "개발 세션엔 허용하지 않는다")

# 시각 읽기 — 상대적인 말은 부르는 쪽이 날짜로 바꿔 준다
check(ms.parse_when("2026-10-27 09:30") == datetime.datetime(2026, 10, 27, 9, 30), "공백 꼴")
check(ms.parse_when("2026-10-27T09:30") == datetime.datetime(2026, 10, 27, 9, 30), "T 꼴")
for bad in ("내일 9시", "2026-10-27", "09:30", "2026-13-01 09:30", "2026-02-30 09:30", ""):
    try:
        ms.parse_when(bad); check(False, f"잘못된 시각 통과: {bad!r}")
    except ms.SessionError:
        pass

soon = (datetime.datetime.now() + datetime.timedelta(days=1)).replace(hour=9, minute=30, second=0, microsecond=0)
when = soon.strftime("%Y-%m-%d %H:%M")
out = ms.chat_tool("remind_at", {"when": when, "text": "  출장 장소 섭외   기안 올리기 "})
rows = ms.load_reminders()
check(len(rows) == 1 and rows[0]["ref"] == "chat/room", f"예약 저장: {rows}")
check(rows[0]["text"] == "출장 장소 섭외 기안 올리기", f"공백은 다듬는다: {rows}")
check(rows[0]["at"] == soon.strftime("%Y-%m-%dT%H:%M"), f"시각 저장: {rows}")
rid = rows[0]["id"]
check(rid in out and "09:30" in out, f"번호·시각을 알려 준다: {out}")

# 거부 — 지난 시각·빈 내용·너무 긴 내용
past = (datetime.datetime.now() - datetime.timedelta(minutes=5)).strftime("%Y-%m-%d %H:%M")
for bad in ({"when": past, "text": "x"}, {"when": when, "text": "   "}, {"when": when, "text": "가" * 501}, {"text": "x"}, {"when": when}):
    try:
        ms.chat_tool("remind_at", bad); check(False, f"거부해야: {str(bad)[:60]}")
    except ms.SessionError:
        pass
check(len(ms.load_reminders()) == 1, "거부된 것은 저장되지 않는다")

# 방별로 갈린다 — 옆방 목록에 안 보이고, 옆방이 번호로 지울 수도 없다
os.environ["DISCORD_STATE_DIR"] = other["stateDir"]
check(ms.chat_tool("remind_list", {}) == "예약해 둔 알림이 없어", "옆방에는 안 보인다")
try:
    ms.chat_tool("remind_cancel", {"id": rid}); check(False, "옆방이 지우면 안 된다")
except ms.SessionError:
    pass
check(len(ms.load_reminders()) == 1, "옆방이 못 지웠다")
os.environ["DISCORD_STATE_DIR"] = room["stateDir"]
check(rid in ms.chat_tool("remind_list", {}), "내 방 목록에는 보인다")

# 개발 세션은 쓸 수 없다(대화방 전용)
os.environ["DISCORD_STATE_DIR"] = dev["stateDir"]
try:
    ms.chat_tool("remind_at", {"when": when, "text": "x"}); check(False, "개발 세션 거부")
except ms.SessionError as exc:
    check("대화방" in str(exc), f"거부 문구: {exc}")
os.environ["DISCORD_STATE_DIR"] = room["stateDir"]

# 상한
rows = ms.load_reminders()
ms.save_reminders(rows + [dict(rows[0], id=f"x{i:04d}") for i in range(ms.REMINDERS_MAX)])
try:
    ms.chat_tool("remind_at", {"when": when, "text": "꽉 찬 뒤"}); check(False, "상한에서 거부")
except ms.SessionError as exc:
    check("꽉" in str(exc), f"상한 문구: {exc}")
ms.save_reminders(rows)

# 데몬이 매분 묻는 것 — 파일만 읽고 아무것도 보내지 않는다
now = datetime.datetime.now()
check(mbr.due_reminders(ms.load_reminders(), now) is False, "아직 때가 안 됐다")
check(mbr.due_reminders([{"at": "2020-01-01T00:00"}], now) is True, "지난 것은 때가 됐다")
check(mbr.due_reminders([{"at": "엉망"}], now) is True, "꼴이 깨진 줄도 치워야 한다")
check(mbr.due_reminders([], now) is False, "빈 목록")

# 보내기 — say 를 가로채 어느 방에 무슨 글이 갔는지 본다
said = []
import marina_discord_wake as mw
real_say = mw.say
def fake_say(ref, message, source="say"):
    said.append((ref, message, source))
    return "started"
mw.say = fake_say
ms.save_reminders([
    {"id": "a1", "ref": "chat/room", "at": (now - datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M"), "text": "지금 몫"},
    {"id": "a2", "ref": "chat/room", "at": (now - datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M"), "text": "늦은 몫"},
    {"id": "a3", "ref": "chat/room", "at": (now - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M"), "text": "묵은 몫"},
    {"id": "a4", "ref": "chat/room", "at": (now + datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M"), "text": "나중 몫"},
])
r = mbr.run_reminders(now)
check(r.startswith("sent:2 drop:1"), f"때가 된 둘만 보내고 묵은 건 버린다: {r}")
check([t for _, t, _ in said] == [f"(늦었어 — {(now - datetime.timedelta(hours=3)):%m월 %d일 %H:%M} 에 알리려던 거야) 늦은 몫", "지금 몫"],
      f"두 시간 넘게 늦으면 늦었다고 붙이고, 오래된 것부터 보낸다: {said}")
check(all(s == "remind" for _, _, s in said), f"출처는 remind: {said}")
check(all(ref == "chat/room" for ref, _, _ in said), f"그 방으로만: {said}")
left = ms.load_reminders()
check([x["id"] for x in left] == ["a4"], f"보낸 것은 목록에서 빠진다: {left}")
check(mw.SAY_NOTES["remind"].format(ch="1", text="x").startswith("[마리나] 이 방에서 예약해 둔 알림"), "예약 알림 출처 문구")

# 들어간 걸 확인 못 하면(typed) 한 번만 다시 — 두 번째도 그러면 버린다(중복이 더 눈에 띈다)
due = lambda m=1: (now - datetime.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M")
mw.say = lambda ref, message, source="say": "typed"
ms.save_reminders([{"id": "b1", "ref": "chat/room", "at": due(), "text": "안 들어간 몫"}])
check(mbr.run_reminders(now) == "sent:0 drop:0 keep:1", "첫 번째는 남겨 둔다")
row = ms.load_reminders()[0]
check(int(row.get("typed") or 0) == 1 and int(row.get("tries") or 0) == 1, f"확인 못 함을 적는다: {row}")
check(float(row.get("nextTryAt") or 0) > now.timestamp(), f"백오프로 미뤄 둔다: {row}")
check(mbr.due_reminders(ms.load_reminders(), now) is False, "미뤄 둔 사이엔 때가 아니다")
check(mbr.run_reminders(now) == "sent:0 drop:0 keep:1", "백오프 중엔 다시 보내지 않는다")
ms.save_reminders([dict(row, nextTryAt=0)])
check(mbr.run_reminders(now) == "sent:0 drop:1 keep:0", "두 번째도 확인 못 하면 버린다")
# 방을 못 띄워도(어떤 예외든) 다음 판에 다시 — 백오프는 배로 늘어난다
mw.say = lambda ref, message, source="say": (_ for _ in ()).throw(ms.SessionError("방을 못 띄웠어"))
ms.save_reminders([{"id": "c1", "ref": "chat/room", "at": due(), "text": "실패 몫"}])
check(mbr.run_reminders(now) == "sent:0 drop:0 keep:1", "실패도 남겨 두고 다시")
w1 = float(ms.load_reminders()[0]["nextTryAt"]) - now.timestamp()
ms.save_reminders([dict(ms.load_reminders()[0], nextTryAt=0)])
mbr.run_reminders(now)
w2 = float(ms.load_reminders()[0]["nextTryAt"]) - now.timestamp()
check(w2 > w1, f"기다리는 시간이 늘어난다: {w1:.0f} → {w2:.0f}")
ms.save_reminders([dict(ms.load_reminders()[0], tries=ms.REMIND_TRIES - 1, nextTryAt=0)])
check(mbr.run_reminders(now) == "sent:0 drop:1 keep:0", f"{ms.REMIND_TRIES}번 실패하면 버린다")
mw.say = lambda ref, message, source="say": (_ for _ in ()).throw(RuntimeError("엉뚱한 예외"))
ms.save_reminders([{"id": "c2", "ref": "chat/room", "at": due(), "text": "터진 몫"}])
check(mbr.run_reminders(now) == "sent:0 drop:0 keep:1", "SessionError 가 아닌 예외도 삼키고 남겨 둔다")
# 보내는 동안 방이 만든 예약이 사라지지 않는다 — say 가 기다리는 사이에 끼어든 것(리뷰 C1)
def say_then_add(ref, message, source="say"):
    rows = ms.load_reminders()
    ms.save_reminders(rows + [{"id": "z9", "ref": "chat/room", "at": "2099-01-01T09:00", "text": "그 사이 예약"}])
    return "started"
mw.say = say_then_add
ms.save_reminders([{"id": "d1", "ref": "chat/room", "at": due(), "text": "보낼 몫"}])
check(mbr.run_reminders(now) == "sent:1 drop:0 keep:1", "보내는 사이 들어온 예약이 남는다")
check([x["id"] for x in ms.load_reminders()] == ["z9"], f"보낸 것만 빠진다: {ms.load_reminders()}")
# 방을 지우고 같은 이름으로 다시 열면 엉뚱한 방에 가지 않는다
mw.say = fake_say
said.clear()
ms.save_reminders([{"id": "e1", "ref": "chat/room", "channelId": "9999", "at": due(), "text": "옛 방 몫"}])
check(mbr.run_reminders(now) == "sent:0 drop:1 keep:0" and said == [], f"채널이 다르면 버린다: {said}")
mw.say = real_say
ms.save_reminders([])
# id 없는 줄은 들이지 않는다 — 보낸 뒤에도 남아 30초마다 영구히 다시 보냈다(리뷰 A)
ms.save_reminders([{'ref': 'chat/room', 'at': due(), 'text': 'id 없는 몫'}])
check(ms.load_reminders() == [], 'id 없는 줄은 무시한다')
check(mbr.run_reminders(now) == 'none', 'id 없는 줄은 보내지도 않는다')
ms.save_reminders([{'id': 'g1', 'ref': 'chat/room', 'at': due(), 'text': 'a'},
                   {'id': 'g1', 'ref': 'chat/room', 'at': due(), 'text': 'b'}])
check(len(ms.load_reminders()) == 1, '번호가 겹치면 하나만 들인다')
ms.save_reminders([])
# 버린 알림은 방에 알린다 — 약속한 알림이 조용히 사라지지 않게(리뷰 B)
mw.say = lambda ref, message, source='say': 'typed'
ms.save_reminders([{'id': 'h1', 'ref': 'chat/room', 'channelId': str(room['channelId']),
                    'at': due(), 'text': '통보 몫', 'typed': 1, 'tries': 1}])
rmsg = f"/channels/{room['channelId']}/messages"
n = len([x for x in log() if x['m'] == 'POST' and x['p'] == rmsg])
check(mbr.run_reminders(now) == 'sent:0 drop:1 keep:0', '두 번째 확인 실패로 버린다')
posts = [x for x in log() if x['m'] == 'POST' and x['p'] == rmsg][n:]
check(posts and '보내지 못했어' in str(posts[-1]['b'].get('content') or ''), f'방에 알린다: {posts}')
mw.say = real_say
ms.save_reminders([])
# 깨진 파일이면 빈 목록 — 알림 때문에 데몬이 멈추지 않게
ms.reminders_path().write_text("{깨")
check(ms.load_reminders() == [], "깨진 파일은 빈 목록")
check(mbr.run_reminders(now) == "none", "깨진 파일이어도 조용히 지나간다")

# 앞 판이 아직 보내는 중이면 겹쳐 보내지 않는다
import fcntl
hold = open(ms.marina_home() / "reminders-run.lock", "w")
fcntl.flock(hold, fcntl.LOCK_EX)
check(mbr.run_reminders(now) == "skip:busy", "겹치면 비켜 준다")
hold.close()

# 데몬은 때가 된 게 없으면 자식을 띄우지 않는다
import marina_discord_bot as mb
spawned = []
real_popen = mb.subprocess.Popen
mb.subprocess.Popen = lambda argv, **kw: spawned.append(argv) or type("P", (), {"pid": 1})()
ms.save_reminders([{"id": "f1", "ref": "chat/room", "at": "2099-01-01T09:00", "text": "먼 몫"}])
mb._spawn_reminders()
check(spawned == [], "때가 안 됐으면 안 띄운다")
ms.save_reminders([{"id": "f2", "ref": "chat/room", "at": "2020-01-01T09:00", "text": "지난 몫"}])
mb._spawn_reminders()
check(len(spawned) == 1 and spawned[0][-1] == "remind-run", f"때가 됐으면 remind-run 을 띄운다: {spawned}")
mb.subprocess.Popen = real_popen
ms.save_reminders([])

# tmux 가 'command too long' 으로 거절하면 스크립트로 빼고 다시 — 방 규칙이 1KB 늘자 방 둘이 안 떴다
one = ms._launch_script('secretary-test', 'echo ' + 'y' * 5000, str(room['stateDir']))
check(one.startswith('/bin/sh ') and len(one) < 300, f'짧은 한 줄을 돌려준다: {one[:80]}')
sh = Path(one.split(' ', 1)[1])
check(sh.is_file() and sh.parent == Path(room['stateDir']), f'상태 폴더에 쓴다: {sh}')
check(sh.read_text().startswith('#!/bin/sh\nexec echo ') and ('y' * 200) in sh.read_text(), '명령을 그대로 담는다')
check(oct(sh.stat().st_mode)[-3:] == '700', f'남이 못 읽게: {oct(sh.stat().st_mode)}')
nos = ms._launch_script('없는방', 'echo z', '/nonexistent')
check(Path(nos.split(' ', 1)[1]).is_file(), '상태 폴더가 없으면 marina 폴더에')
# 같은 파일을 다시 써도 제자리에서 자르지 않는다(앞 기동의 /bin/sh 가 읽던 중이면 반쯤 잘린 걸 실행한다)
old_ino = sh.stat().st_ino
ms._launch_script('secretary-test', 'echo ' + 'w' * 5000, str(room['stateDir']))
check(sh.stat().st_ino != old_ino, '바꿔 끼운다(inode 가 바뀐다)')
check(not list(Path(room['stateDir']).glob('.launch-*')), '임시 파일을 남기지 않는다')

# 폴백 분기 — 오늘 두 방을 못 띄웠던 그 길. tmux 를 가짜로 끼워 세 가지를 못 박는다
calls = []
real_tmux, real_alive, real_save, real_sig = ms._tmux, ms.tmux_alive, ms._save_launch_env, ms.dashboard_signal
def fake_tmux(*a, **kw):
    calls.append(a)
    bad = a[0] == "new-session" and len([c for c in calls if c[0] == "new-session"]) == 1
    return type("R", (), {"returncode": 1 if bad else 0, "stderr": fake_tmux.err if bad else "", "stdout": ""})()
fake_tmux.err = "command too long"
ms._tmux, ms.tmux_alive, ms._save_launch_env, ms.dashboard_signal = fake_tmux, lambda n: True, lambda d: None, lambda: None
os.environ["MARINA_SESSION_BOOT_WAIT"] = "0"
env = {"DISCORD_STATE_DIR": str(room["stateDir"])}
ms.tmux_start("fallback-room", Path(room["root"]), ["echo", "x" * 100], env)
ns = [c for c in calls if c[0] == "new-session"]
check(len(ns) == 2, f"거절당하면 한 번 더 — 두 번 불린다: {len(ns)}")
check(ns[1][-1].startswith("/bin/sh ") and "launch-fallback-room.sh" in ns[1][-1],
      f"두 번째는 스크립트로: {ns[1][-1][:70]}")
check("launch-" not in ns[0][-1] and "echo" in ns[0][-1], f"첫 번째는 명령 그대로: {ns[0][-1][:60]}")
# 길이 때문이 아닌 실패(이름 중복 등)에는 스크립트를 쓰지 않는다 — 실패한 기동마다 파일을 쓰면 안 된다
calls.clear()
fake_tmux.err = "duplicate session: dup-room"
(Path(room["stateDir"]) / "launch-dup-room.sh").unlink(missing_ok=True)
try:
    ms.tmux_start("dup-room", Path(room["root"]), ["echo", "x" * 100], env)
    check(False, "그 실패는 그대로 올라와야")
except ms.SessionError as exc:
    check("duplicate" in str(exc) and "처음은" not in str(exc), f"첫 에러를 그대로: {exc}")
check(len([c for c in calls if c[0] == "new-session"]) == 1, "한 번만 부른다")
check(not (Path(room["stateDir"]) / "launch-dup-room.sh").exists(), "스크립트를 쓰지 않는다")
# 긴 명령이면 거절 문구가 달라도 한 번 더 — tmux 가 말을 바꿔도 방이 뜨게
calls.clear()
fake_tmux.err = "something else"
ms.tmux_start("long-room", Path(room["root"]), ["echo", "y" * (ms.TMUX_RETRY_OVER + 100)], env)
ns = [c for c in calls if c[0] == "new-session"]
check(len(ns) == 2 and "launch-long-room.sh" in ns[1][-1], f"긴 명령은 문구와 무관하게 다시: {len(ns)}")
ms._tmux, ms.tmux_alive, ms._save_launch_env, ms.dashboard_signal = real_tmux, real_alive, real_save, real_sig

# 도구 목록 — 대화방에만 보인다(쓸 수 없는 도구를 개발 세션에 보여 주면 권한 창에서 멈춘다)
room_names = [t["name"] for t in ms.chat_tools_for(room)]
dev_names = [t["name"] for t in ms.chat_tools_for(dev)]
for n in ("remind_at", "remind_list", "remind_cancel"):
    check(n in room_names and n not in dev_names, f"{n}: 대화방 목록에만")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-remind"
