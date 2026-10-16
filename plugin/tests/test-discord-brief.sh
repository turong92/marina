#!/usr/bin/env bash
# 예약 브리핑: ~/.marina/brief.json 의 시각에 launchd(marina.brief)가 `session brief-run` 을 부르고, 그게 방에 글을 넣는다(session say).
#  - 파일이 없으면 아무것도 설치하지 않는다(다른 사람 맥에서 안 돈다) · 같은 날 두 번 안 돈다 · 격리 홈은 실제 launchctl 을 안 부른다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
fail() { echo "FAIL: $*"; exit 1; }
REAL="$HOME/Library/LaunchAgents/marina.brief.plist"
REAL_SUM_BEFORE="$(cksum "$REAL" 2>/dev/null || echo none)"
LC="$TMPROOT/lc"; mkdir -p "$LC"
cat > "$TMPROOT/bin/fake-launchctl" <<SH
#!/bin/sh
echo "\$*" >> "$LC/log"
case "\$1" in
  print) [ -f "$LC/loaded" ] || exit 113; echo "state = not running" ;;
  bootstrap) touch "$LC/loaded" ;;
  bootout) rm -f "$LC/loaded" ;;
esac
SH
chmod +x "$TMPROOT/bin/fake-launchctl"
export MARINA_LAUNCH_AGENTS_DIR="$MARINA_HOME/LaunchAgents" LC MARINA_DISCORD_LAUNCHCTL="$TMPROOT/bin/fake-launchctl"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import datetime, json, os, plistlib, sys
from pathlib import Path
import marina_session as ms
import marina_discord_brief as br
import marina_discord_wake as mw
fails = []
def check(c, m):
    if not c: fails.append(m)
LC = Path(os.environ["LC"]); log = LC / "log"
def calls(): return log.read_text().splitlines() if log.exists() else []
cfgp = ms.marina_home() / "brief.json"
prog = [str(ms.marina_home() / "bin" / "marina-session-hook"), "brief-run"]
CFG = {"ref": "secretary/daeun", "hour": 8, "minute": 30, "weekdays": [1, 2, 3, 4, 5], "message": "아침 브리핑"}

# 파일이 없으면 아무것도 설치하지 않는다
check(br.load() is None, "설정 없음 → None")
check(br.install(prog) == "none" and not br.plist_path().exists() and calls() == [], f"설정 없으면 조용히 끝: {calls()}")
check(br.run() == "none", "설정 없으면 run 도 조용히")
check(br.uninstall() == "absent", "설치 안 된 걸 해제하면 absent")
# 잘못된 설정은 분명한 오류
for bad in ({**CFG, "hour": 24}, {**CFG, "minute": 60}, {**CFG, "ref": ""}, {**CFG, "message": " "}, {**CFG, "weekdays": [8]}, {**CFG, "weekdays": []}):
    cfgp.write_text(json.dumps(bad))
    try:
        br.load(); check(False, f"잘못된 설정을 받아들임: {bad}")
    except ms.SessionError:
        pass
cfgp.write_text("{깨짐"); 
try:
    br.load(); check(False, "깨진 JSON 을 받아들임")
except ms.SessionError:
    pass
# 기본값: minute 0 · weekdays 매일
cfgp.write_text(json.dumps({"ref": "a/b", "hour": 7, "message": "m"}))
c = br.load(); check(c["minute"] == 0 and sorted(c["weekdays"]) == [0, 1, 2, 3, 4, 5, 6], f"기본값: {c}")

# plist: 평일마다 한 칸씩, 시작할 때 바로 돌지 않는다(RunAtLoad 없음)
cfgp.write_text(json.dumps(CFG))
d = plistlib.loads(br.plist_text(prog, br.load()).encode())
check(d["Label"] == "marina.brief" and d["ProgramArguments"] == prog, f"라벨·인자: {d}")
check(d["StartCalendarInterval"] == [{"Hour": 8, "Minute": 30, "Weekday": w} for w in (1, 2, 3, 4, 5)], f"달력: {d['StartCalendarInterval']}")
check(not d.get("RunAtLoad") and d["EnvironmentVariables"]["PATH"] == ms.daemon_path() and d["EnvironmentVariables"]["MARINA_HOME"] == str(ms.marina_home()), f"환경·RunAtLoad: {d}")
check(d["StandardOutPath"].endswith("brief.log"), "로그")
cfgp.write_text(json.dumps({**CFG, "weekdays": [7, 0]}))
d = plistlib.loads(br.plist_text(prog, br.load()).encode())
check(sorted(x["Weekday"] for x in d["StartCalendarInterval"]) == [0], f"7 과 0 은 같은 일요일: {d['StartCalendarInterval']}")

# 설치: 시각만 바꿔 다시 설치하면 새 시각이 된다
cfgp.write_text(json.dumps(CFG))
check(br.install(prog) == "installed" and br.plist_path().is_file() and br.status() == "loaded", "설치")
check(plistlib.loads(br.plist_path().read_bytes())["StartCalendarInterval"][0]["Minute"] == 30, "30분")
log.unlink()
cfgp.write_text(json.dumps({**CFG, "hour": 9, "minute": 5}))
check(br.install(prog) == "installed", "다시 설치")
cs = calls()
check([c.split()[0] for c in cs if c.split()[0] in ("bootout", "bootstrap")] == ["bootout", "bootstrap"], f"내렸다 올린다: {cs}")
check(plistlib.loads(br.plist_path().read_bytes())["StartCalendarInterval"][0] == {"Hour": 9, "Minute": 5, "Weekday": 1}, "새 시각")
st = br.describe()
check("09:05" in st and "secretary/daeun" in st and "loaded" in st, f"status 한 눈에: {st!r}")
# 해제
check(br.uninstall() == "removed" and not br.plist_path().exists() and br.status() == "absent", "해제")
check(br.uninstall() == "absent", "두 번 해제하면 absent")

# run: 평일·하루 한 번
sent = []
mw.say = lambda ref, text, source="say": (sent.append((ref, text, source)), "started")[1]
cfgp.write_text(json.dumps(CFG))
mon = datetime.datetime(2026, 10, 12, 8, 31)       # 월요일
sat = datetime.datetime(2026, 10, 17, 8, 31)       # 토요일
check(br.run(sat) == "skip:weekday" and sent == [], "주말엔 안 보낸다")
check(br.run(mon) == "sent" and sent == [("secretary/daeun", "아침 브리핑", "brief")], f"보냄: {sent}")
check(br.run(mon.replace(hour=9)) == "skip:done" and len(sent) == 1, "같은 날 두 번째는 안 보낸다(launchd 가 밀린 걸 몰아서 돌려도)")
check(br.run(mon + datetime.timedelta(days=1)) == "sent" and len(sent) == 2, "다음 날은 보낸다")
# 보내기 실패는 기록하지 않는다 — 다음 기회에 다시
def boom(ref, text, source="say"): raise ms.SessionError("방이 없어")
mw.say = boom
try:
    br.run(mon + datetime.timedelta(days=2)); check(False, "say 실패가 삼켜짐")
except ms.SessionError:
    pass
mw.say = lambda ref, text, source="say": (sent.append((ref, text, source)), "delivered")[1]
check(br.run(mon + datetime.timedelta(days=2)) == "sent", "실패한 날은 기록 안 해서 다시 시도된다")
# ③ 입력창에 글만 남고 들어간 게 확인 안 되면(typed) 그날을 소비하지 않는다 — 다음 기회에 다시
n = len(sent)
mw.say = lambda ref, text, source="say": (sent.append((ref, text, source)), "typed")[1]
day = mon + datetime.timedelta(days=3)
check(br.run(day) == "unconfirmed" and not br._last_path().read_text().startswith(day.strftime("%Y-%m-%d")), "확인 안 된 전송이 brief-last 를 썼다")
mw.say = lambda ref, text, source="say": (sent.append((ref, text, source)), "delivered")[1]
check(br.run(day) == "sent", "확인 안 된 날은 다시 시도돼 보내진다")
# ④ 예정 시각 기준 허용 창 — 잠들었다 깨어 엉뚱한 시각에 돌면 그날 정시 몫을 먹지 않는다
n = len(sent)
mon2 = datetime.datetime(2026, 10, 19)             # 월요일
check(br.run(mon2.replace(hour=0, minute=5)) == "skip:early" and len(sent) == n, "자정에 깬 밀린 job 이 보냈다")
check(br._last_path().read_text().strip() != "2026-10-19", "자정에 깬 job 이 그날 몫을 소비했다")
check(br.run(mon2.replace(hour=14, minute=0)) == "skip:late" and len(sent) == n, "한참 늦게 깬 job 이 보냈다")
check(br._last_path().read_text().strip() != "2026-10-19", "늦은 job 이 그날 몫을 소비했다")
check(br.run(mon2.replace(hour=8, minute=29)) == "sent", "정시 몫은 그 뒤에도 살아 있다")   # 8:30 예정, 1분 이른 건 launchd 오차로 허용
check(br.run(mon2.replace(hour=9, minute=0)) == "skip:done", "정시 몫을 보낸 뒤엔 skip:done")
tue = datetime.datetime(2026, 10, 20)
check(br.run(tue.replace(hour=10, minute=29)) == "sent", "늦음 허용 창 안(2시간)")
# 격리 홈 + 실제 LaunchAgents 경로: 아무것도 쓰지 않는다
os.environ.pop("MARINA_LAUNCH_AGENTS_DIR")
check(br.install(prog).startswith("failed:") and br.uninstall() == "absent", "격리 홈은 LaunchAgent 를 안 건드린다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
# CLI: 설치본이 아니면(작업 트리) 고정 입구가 없으니 분명히 거절 · 설정이 없으면 조용히
rm -f "$MARINA_HOME/brief.json"
out="$(msess brief-install 2>&1)" || fail "설정 없으면 조용히 끝나야 함: $out"
echo "$out" | grep -q "brief.json" || fail "설정 없음 안내: $out"
printf '{"ref":"chat/x","hour":8,"message":"m"}\n' > "$MARINA_HOME/brief.json"
out="$(msess brief-install 2>&1)" && fail "작업 트리에서 설치가 성공함(그 트리를 지우면 브리핑이 죽는다): $out"
echo "$out" | grep -q "설치본" || fail "설치본 안내: $out"
out="$(msess brief-status 2>&1)" || fail "status: $out"
echo "$out" | grep -q "08:00" || fail "status 출력: $out"
REAL_SUM_AFTER="$(cksum "$REAL" 2>/dev/null || echo none)"
[ "$REAL_SUM_AFTER" = "$REAL_SUM_BEFORE" ] || fail "테스트가 실제 로그인 항목을 건드렸다"
echo "PASS test-discord-brief"
