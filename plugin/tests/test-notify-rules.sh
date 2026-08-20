#!/usr/bin/env bash
# 알림을 보낼지 정하는 규칙 — 여기가 "진동 지옥"과 "알림이 안 온다" 사이를 가른다.
#
# 형이 고른 네 순간(질문·작업 끝남·막힘·서비스)만 부르고, 세션은 34개니 지금 쓰는 것만 부른다.
# 상태가 떨렸다고 두 번 울리면 안 되고, 알림 본문에 대화 내용을 싣지 않는다(잠금화면에 남는다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import json
import sys
from pathlib import Path

import marina_notify as nf

nf.ALERTS_FILE = Path(sys.argv[1]) / "alerts.json"
now = 1_000_000.0

def event(kind, session="agent:claude:s1:/wt", **extra):
    return {"kind": kind, "session": session, "root": "/wt", "source": "claude",
            "sid": "s1", "title": "마리나 고치기", **extra}

# ① 사람을 불러야 하는 것만. message·status 는 화면 갱신 전용이다.
fired = {}
assert nf.should_notify(event("question"), engaged=True, hidden=False, now=now, last_fired=fired)
assert nf.should_notify(event("idle"), engaged=True, hidden=False, now=now, last_fired=fired)
assert nf.should_notify(event("blocked"), engaged=True, hidden=False, now=now, last_fired=fired)
assert not nf.should_notify(event("message"), engaged=True, hidden=False, now=now, last_fired={})
assert not nf.should_notify(event("status"), engaged=True, hidden=False, now=now, last_fired={})

# ② 같은 (세션, 종류)는 잠깐 사이 한 번만 — 상태가 떨려도 한 번만 울린다.
again = {}
assert nf.should_notify(event("idle"), engaged=True, hidden=False, now=now, last_fired=again)
assert not nf.should_notify(event("idle"), engaged=True, hidden=False, now=now + 5, last_fired=again)
assert nf.should_notify(event("idle"), engaged=True, hidden=False, now=now + nf.DEDUPE_S + 1, last_fired=again)
# 다른 세션은 서로를 막지 않는다.
assert nf.should_notify(event("idle", session="agent:claude:s2:/wt"), engaged=True,
                        hidden=False, now=now + 5, last_fired=again)

# ③ 안 쓰는 세션·숨긴 세션은 부르지 않는다(세션이 34개다).
assert not nf.should_notify(event("idle"), engaged=False, hidden=False, now=now, last_fired={})
assert not nf.should_notify(event("idle"), engaged=True, hidden=True, now=now, last_fired={})
# 서비스는 형이 직접 띄운 것이라 세션과 무관하게 알린다.
assert nf.should_notify({"kind": "service", "event": "ready", "root": "/wt", "service": "web"},
                        engaged=False, hidden=False, now=now, last_fired={})

# ④ '지금 쓰는 세션' 판정은 최근 활동으로 — 어제 세션까지 부르면 알림이 의미를 잃는다.
marks = {"agent:claude:s1:/wt": {"ts": now - 60}, "agent:claude:old:/wt": {"ts": now - 3 * 24 * 3600}}
assert nf.is_engaged(event("idle"), marks, now) is True
assert nf.is_engaged(event("idle", session="agent:claude:old:/wt"), marks, now) is False
assert nf.is_engaged(event("idle", session="agent:claude:없음:/wt"), marks, now) is False

# ⑤ **중복 억제는 재시작을 넘겨야 한다.** 메모리에만 두면 데몬이 새로 뜰 때마다 초기화되어
# 같은 알림이 다시 간다 — 형 폰엔 같은 말이 반복해서 뜨고, 그게 쌓이면 브라우저가 스팸으로 본다.
nf._last_fired.clear()
assert nf.should_notify(event("idle"), engaged=True, hidden=False, now=now, last_fired=None)
nf._last_fired.clear()          # 프로세스가 죽었다 다시 뜬 셈
assert not nf.should_notify(event("idle"), engaged=True, hidden=False, now=now + 5, last_fired=None), \
    "재시작하면 같은 알림이 또 간다"
print("ok 규칙: 네 순간만·중복 억제(재시작 넘김)·지금 쓰는 세션만")

# ⑤ 알림 문구에 **대화 내용을 싣지 않는다** — 잠금화면에 남고, 열면 어차피 보인다.
title, body = nf.alert_text(event("question", preview="비밀번호는 hunter2 야"))
assert title == "물어볼 게 있어요", title
assert "hunter2" not in title + body, (title, body)
assert body == "마리나 고치기", body            # 어느 세션인지는 알려줘야 쓸모가 있다
ready_title, ready_body = nf.alert_text({"kind": "service", "event": "ready",
                                         "service": "web", "alias": "wt-a"})
assert "기동 완료" in ready_title and ready_body == "wt-a", (ready_title, ready_body)
assert "실패" in nf.alert_text({"kind": "service", "event": "failed", "service": "web"})[0]

# ⑥ 기록·회수: 서비스워커가 깨서 since 이후 것만 가져간다(같은 알림 두 번 방지).
nf.record_alerts([event("question")], now)
nf.record_alerts([event("idle")], now + 10)
assert [a["kind"] for a in nf.pending_alerts(0, now + 11)] == ["question", "idle"]
assert [a["kind"] for a in nf.pending_alerts(now + 5, now + 11)] == ["idle"]
# 오래된 것은 사라진다 — 폰이 한참 뒤에 깨서 옛 알림을 띄우면 안 된다.
assert nf.pending_alerts(0, now + nf.ALERT_KEEP_S + 100) == []
# 무한히 쌓이지 않는다.
for i in range(50):
    nf.record_alerts([event("idle", session=f"s{i}")], now + 20 + i)
assert len(json.loads(nf.ALERTS_FILE.read_text())) <= nf.ALERT_MAX
assert oct(nf.ALERTS_FILE.stat().st_mode)[-3:] == "600"

print("ok 문구·기록: 내용 비공개·since 회수·상한")
PY

# ⑦ 서비스워커는 **보고 있는 대화**엔 알림을 안 띄운다 — 서버는 누가 뭘 보는지 모른다.
node -e '
const fs = require("fs");
const src = fs.readFileSync("'"$SCR"'/marina-web/sw.js", "utf8");
if (!/visibilityState === "visible"/.test(src)) { console.error("FAIL: 보이는 창 판정이 없다"); process.exit(1); }
if (!/watchingSession/.test(src)) { console.error("FAIL: 보고 있는 세션을 거르지 않는다"); process.exit(1); }
if (!/notificationclick/.test(src)) { console.error("FAIL: 알림을 눌러도 대화로 못 간다"); process.exit(1); }
if (!/userVisibleOnly|showNotification/.test(src)) { console.error("FAIL: 알림을 안 띄운다"); process.exit(1); }
// 아이콘이 없으면 브라우저 기본 아이콘으로 떠서 무슨 알림인지 알 수 없다(형: "아이콘 같은건 못넣나").
if (!/icon:\s*NOTIFICATION_ICON/.test(src)) { console.error("FAIL: 알림에 아이콘이 없다"); process.exit(1); }
if (!/badge:/.test(src)) { console.error("FAIL: 상태표시줄 배지 아이콘이 없다"); process.exit(1); }
// 질문은 답할 때까지 일이 멈춘다 — 데스크톱에서 몇 초 만에 사라지면 놓친다.
if (!/requireInteraction:\s*alert\.kind === "question"/.test(src)) {
  console.error("FAIL: 질문 알림이 저절로 사라진다"); process.exit(1); }
console.log("ok 서비스워커: 보는 대화는 안 울리고, 누르면 그 대화로 간다");
'

echo "PASS test-notify-rules"
