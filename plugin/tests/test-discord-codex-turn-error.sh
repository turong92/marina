#!/usr/bin/env bash
# (형 2026-10-28) 코덱스 주간 한도가 바닥나 세 방이 형 메시지마다 429 로 튕겼는데, Discord 엔 아무것도 안 와 형이 모르고 기다렸다
#  → 코덱스 턴이 오류로 끝나면(rollout 의 task_complete.error) 그 메시지에 답을 단다. 한도(429)면 리셋 시각까지. 턴마다 한 번만.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$MARINA_HOME" <<'PY'
import json, sys, time
from datetime import datetime, timezone
from pathlib import Path
import marina_session as ms
import marina_codex as mc
import marina_discord_bot as mb
fails = []
def check(c, m):
    if not c: fails.append(m)
home = Path(sys.argv[1])
ro = home / "rollout.jsonl"; sd = home / "sd"; sd.mkdir()
rec = {"kind": "codex", "tmux": "story-x", "channelId": "111", "stateDir": str(sd), "rollout": str(ro), "codexAccount": "a"}
ms.load_sessions = lambda: [rec]
sent = []
class DC:
    def _req(self, m, p, b=None):
        sent.append((m, p, b)); return {"id": "x"}
mb._dc = lambda cfg: DC()
ms.load_config = lambda: {}
RESET = time.time() + 5 * 86400
mc.rate_windows = lambda recs, acct, now=None: [{"key": "weekly", "label": "주간", "usedPercent": 97.0, "resetsAt": RESET}]
mc.codex_cfg = lambda cfg: {"account": "a"}
def ts(t): return datetime.fromtimestamp(t, timezone.utc).isoformat().replace("+00:00", "Z")
def ev(t, p): return json.dumps({"timestamp": ts(t), "type": "event_msg", "payload": p})
def user(t, mid, ch="111"):
    return ev(t, {"type": "user_message", "message": f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="{mid}" user="u" ts="x">\n야\n</channel>'})
def done(t, turn, err=None):
    p = {"type": "task_complete", "turn_id": turn, "last_agent_message": None}
    if err: p["error"] = {"message": err}
    return ev(t, p)
def write(*rows): ro.write_text("\n".join(rows) + "\n")
now = time.time()
E429 = "exceeded retry limit, last status: 429 Too Many Requests, request id: r1"

write(user(now - 60, "901"), done(now - 59, "t1", E429))
mb.codex_error_tick(now)
check(len(sent) == 1, f"오류 턴에 한 번 답: {sent}")
b = sent[0][2] if sent else {}
check(sent and sent[0][1] == "/channels/111/messages", "그 방 채널에")
check(b.get("message_reference", {}).get("message_id") == "901", f"형 메시지에 답으로: {b}")
check("한도" in b.get("content", "") and "97%" in b.get("content", ""), f"한도·사용률: {b.get('content')}")
lt = time.localtime(RESET)
check(f"{lt.tm_mon}/{lt.tm_mday}({'월화수목금토일'[lt.tm_wday]})" in b.get("content", ""), f"리셋 날짜: {b.get('content')}")
mb.codex_error_tick(now + 5)
check(len(sent) == 1, "같은 턴은 다시 안 보낸다")

write(user(now - 60, "901"), done(now - 59, "t1", E429), user(now - 10, "902"), done(now - 9, "t2", E429))
mb.codex_error_tick(now)
check(len(sent) == 2 and sent[-1][2]["message_reference"]["message_id"] == "902", "새 메시지가 또 튕기면 또 답")

write(user(now - 10, "903"), done(now - 9, "t3", "stream disconnected before completion"))
mb.codex_error_tick(now)
check(len(sent) == 3 and "stream disconnected" in sent[-1][2]["content"] and "한도" not in sent[-1][2]["content"], f"다른 오류는 그 내용: {sent[-1]}")

write(user(now - 10, "904"), done(now - 9, "t4"))
mb.codex_error_tick(now)
check(len(sent) == 3, "정상으로 끝난 턴엔 안 보낸다")

write(user(now - 10, "905"), done(now - 9, "t5", E429), ev(now - 5, {"type": "task_started", "turn_id": "t6"}))
mb.codex_error_tick(now)
check(len(sent) == 3, "다음 턴이 이미 돌고 있으면 안 보낸다")

write(user(now - 9 * 3600, "906"), done(now - 9 * 3600, "t7", E429))
mb.codex_error_tick(now)
check(len(sent) == 3, "오래된 오류(배포 직후 지난 기록)는 안 보낸다")

write(user(now - 10, "907", ch="222"), done(now - 9, "t8", E429))
mb.codex_error_tick(now)
check(len(sent) == 4 and "message_reference" not in sent[-1][2], "다른 채널에서 온 메시지면 답 표시 없이 이 방에")

rec2 = dict(rec, kind="dev"); ms.load_sessions = lambda: [rec2]
write(user(now - 10, "908"), done(now - 9, "t9", E429))
mb.codex_error_tick(now)
check(len(sent) == 4, "코덱스 방만 본다")

# (리뷰 I1) resume 으로 fork 된 rollout — 같은 turn_id 가 새 시각·새 경로로 복사돼도 다시 안 보낸다
rec2["kind"] = "codex"; ms.load_sessions = lambda: [rec]
write(user(now - 10, "911"), done(now - 9, "tA", E429))
mb.codex_error_tick(now); n = len(sent)
ro2 = home / "rollout-fork.jsonl"; ro2.write_text(ro.read_text()); rec["rollout"] = str(ro2)
mb.codex_error_tick(now)
check(len(sent) == n, "fork 사본의 같은 턴은 다시 안 보낸다")
rec["rollout"] = str(ro)
# (리뷰 S1) 터미널에서 친 턴(채널 태그 없음)은 앞 턴의 Discord 메시지에 답을 달지 않는다
write(user(now - 30, "912"), ev(now - 29, {"type": "turn_aborted"}), ev(now - 20, {"type": "task_started", "turn_id": "tB0"}),
      ev(now - 19, {"type": "user_message", "message": "터미널에서 친 말"}), done(now - 9, "tB", E429))
mb.codex_error_tick(now)
check(len(sent) == n + 1 and "message_reference" not in sent[-1][2], f"앞 턴 메시지에 안 단다: {sent[-1]}")
# (리뷰 S2) request id 에 429 가 들어 있어도 한도 오류로 보지 않는다
write(user(now - 10, "913"), done(now - 9, "tC", "stream error, request id: ab429cd"))
mb.codex_error_tick(now)
check("한도" not in sent[-1][2]["content"], f"429 는 상태 코드로만: {sent[-1][2]['content']}")
# (리뷰 I3) 채널이 없어지는 등 Discord 가 거절하면 같은 턴을 계속 다시 보내지 않는다
class Gone:
    def _req(self, m, p, b=None):
        sent.append(("gone", p, b)); raise ms.DiscordError(404, "Unknown Channel")
mb._dc = lambda cfg: Gone()
write(user(now - 10, "914"), done(now - 9, "tD", E429))
mb.codex_error_tick(now); k = len(sent)
mb._CODEX_ERR_MTIME.clear(); mb.codex_error_tick(now + 4)
check(len(sent) == k, "거절된 턴은 포기한다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-codex-turn-error"
