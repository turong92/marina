#!/usr/bin/env bash
# 역할 에이전트(2026-10-04): role-hook 이 남긴 서브에이전트 시작·끝 이벤트를 봇이 읽어 지시 스레드에 한 줄씩 —
#  형이 '무엇이 어떤 모델로 돌았나'를 본다. 봇은 이벤트 파일만 읽는다(역할 코드 import 없음)
#  - 그 세션(sessionId)이 Discord 세션이고 지금 지시 메시지(activity mid)가 있을 때만 · 오프셋으로 한 번씩 · 깨진 줄 무시
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"
export ROLE_EVENTS="$TMPROOT/role-events.jsonl"

PYTHONPATH="$SCRIPTS" python3 - "$FD" <<'PY'
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
def put(*rows):
    with open(ev, "a") as fh:
        for r in rows: fh.write((r if isinstance(r, str) else json.dumps(r, ensure_ascii=False)) + "\n")
def thread_posts():
    return [x["b"]["content"] for x in log() if x["m"] == "POST" and x["p"].startswith("/channels/")
            and x["p"].endswith("/messages") and x["p"] != f"/channels/{ch}/messages"]

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
check(len(got) == 4, f"내 세션 것 4줄: {got}")
want = ["⚠️ developer 모델 지정(opus) 무시 — 역할표대로 sonnet",
        "🤖 developer 시작 · sonnet/medium · test-driven-development · 결제 버그 Task 3",
        "✅ developer 끝 · 4분 · 52k",
        "🤖 서브에이전트 시작 · 코드 찾기"]
check(got == want, f"줄 형식: {got}")
mb.role_events_tick()
check(len(thread_posts()) == 4, "오프셋 — 같은 줄 두 번 안 올림")
# 회전(파일이 줄어듦) → 처음부터
ev.write_text(json.dumps({"ev": "stop", "ts": 5, "session": "S1", "agent": "a2", "role": "-", "model": "inherit", "effort": "",
                          "skills": [], "desc": "코드 찾기", "secs": 12.0, "tokens": {"in": 1, "out": 2, "cache_read": 0, "cache_write": 0},
                          "models": []}) + "\n")
mb.role_events_tick()
check(thread_posts()[-1] == "✅ 서브에이전트 끝 · 12초 · 3", f"회전 후 · 짧은 시간·작은 토큰: {thread_posts()[-1:]}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-role-events"
