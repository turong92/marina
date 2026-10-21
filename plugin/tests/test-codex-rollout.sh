#!/usr/bin/env bash
# 코덱스 rollout 읽기 — 찾기·sid 확보·턴 상태·받은 지시·rate_limits. 줄 모양은 스파이크 실측(codex-cli 0.146).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
export CODEX_HOME="$MARINA_HOME/not-used-codex-home"
export MARINA_CODEX_SESSIONS="$MARINA_HOME/codex-sessions"       # 실 ~/.codex/sessions 를 읽지 않는다
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$MARINA_HOME" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone
from pathlib import Path
import marina_codex as mc
import marina_discord_usage as du

home = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)

def ts(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

def line(epoch, typ, payload):
    return json.dumps({"timestamp": ts(epoch), "type": typ, "payload": payload}, ensure_ascii=False)

def ev(epoch, t, **kw):
    return line(epoch, "event_msg", dict(type=t, **kw))

def user(epoch, text):
    return [line(epoch, "response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}),
            ev(epoch, "user_message", message=text)]

def tag(chat, mid, body="hi"):
    return f'<channel source="plugin:discord:discord" chat_id="{chat}" message_id="{mid}">\n{body}\n</channel>'

def token_count(epoch, used, window_min, resets, secondary=None):
    rl = {"limit_id": "codex", "primary": {"used_percent": used, "window_minutes": window_min, "resets_at": resets},
          "secondary": secondary, "plan_type": "unknown"}
    return ev(epoch, "token_count", info={"total_token_usage": {"total_tokens": 100}, "last_token_usage": {"total_tokens": 100},
                                          "model_context_window": 1000}, rate_limits=rl)

def write_rollout(sid, cwd, lines, day="2026/10/21", mtime=None, name_ts="2026-10-21T19-03-26"):
    d = mc.sessions_root() / day
    d.mkdir(parents=True, exist_ok=True)
    f = d / f"rollout-{name_ts}-{sid}.jsonl"
    # 첫 줄 session_meta 는 실제로 18KB 넘는다(base_instructions) — discover_sid 가 첫 줄을 통째로 읽어야 한다
    meta = line(1792577040, "session_meta", {"id": sid, "session_id": sid, "cwd": cwd, "base_instructions": {"text": "x" * 20000}})
    f.write_text("\n".join([meta] + lines) + "\n", encoding="utf-8")
    if mtime is not None:
        os.utime(f, (mtime, mtime))
    return f

now = time.time()
SID1, SID2, SID3 = ("01a15df6-ad2d-74f3-a376-1093930d23a9", "01a15dfd-1cc7-7cc0-8a92-33cae8fa7c82", "01a15dea-6b55-7ed3-bb4f-672e4a953103")
work = home / "work"; work.mkdir()
other = home / "other"; other.mkdir()

# find_rollout / rollout_of
f1 = write_rollout(SID1, str(work), [])
check(mc.find_rollout(SID1) == f1, "find_rollout 은 파일 이름 끝 sid 로 찾는다")
check(mc.find_rollout("ffffffff-0000-0000-0000-000000000000") is None, "없는 sid")
check(mc.rollout_of({"sessionId": SID1}) == f1, "rollout_of: sid 로 다시 찾기")
check(mc.rollout_of({"sessionId": SID1, "rollout": str(f1)}) == f1, "rollout_of: 캐시 경로")
check(mc.rollout_of({"sessionId": SID1, "rollout": str(home / "gone.jsonl")}) == f1, "rollout_of: 캐시 파일이 사라지면 sid 로")
check(mc.rollout_of({}) is None, "rollout_of: sid 도 경로도 없음")

# discover_sid — 같은 폴더에 새 rollout 이 정확히 하나일 때만
since = now - 10
check(mc.discover_sid(work, since, set()) == SID1, "discover_sid: 하나면 그 sid")
write_rollout(SID2, str(work), [])
check(mc.discover_sid(work, since, set()) == "", "discover_sid: 둘이면 짐작하지 않는다")
check(mc.discover_sid(work, since, {SID2}) == SID1, "discover_sid: 다른 방이 가진 sid 는 제외")
check(mc.discover_sid(other, since, set()) == "", "discover_sid: cwd 가 다르면 제외")
check(mc.discover_sid(work, now + 60, set()) == "", "discover_sid: since 보다 오래된 파일은 제외")

# turn_busy
def busy(lines, at=None):
    f = write_rollout(SID3, str(work), lines, day="2026/10/22")
    return mc.turn_busy(f, now=at if at is not None else now)
t0 = now - 20
check(busy([ev(t0, "task_started", turn_id="t1")]) is True, "turn_busy: started 만 → True")
check(busy([ev(t0, "task_started", turn_id="t1"), ev(t0 + 5, "task_complete", turn_id="t1")]) is False, "turn_busy: complete → False")
check(busy([ev(t0, "task_started", turn_id="t1"), ev(t0 + 5, "turn_aborted", reason="interrupted")]) is False, "turn_busy: aborted → False")
old = now - 31 * 60
check(busy([ev(old, "task_started", turn_id="t1")]) is False, "turn_busy: 마지막 줄이 31분 전이면 쉬는 것으로")
check(busy([ev(t0, "task_started", turn_id="t1"), ev(t0 + 5, "task_complete", turn_id="t1"), ev(t0 + 9, "task_started", turn_id="t2")]) is True,
      "turn_busy: 다음 턴이 시작되면 True")
check(mc.turn_busy(home / "nope.jsonl", now=now) is False, "turn_busy: 파일 없음")

# inbound_ids
f = write_rollout("01a15dea-0000-0000-0000-000000000001", str(work),
                  user(now - 9, tag("111", "m1")) + user(now - 8, tag("111", "m2")) + user(now - 7, tag("222", "m3"))
                  + user(now - 6, tag("111", "m2")), day="2026/10/23")
check(mc.inbound_ids(f, "111") == ["m1", "m2"], f"inbound_ids: 이 채널만, 순서대로, 중복 없이: {mc.inbound_ids(f, '111')}")
check(mc.inbound_ids(f, "999") == [], "inbound_ids: 다른 채널")

# window_label
check(mc.window_label(300) == ("fiveHour", "5시간"), "window_label 300")
check(mc.window_label(10080) == ("weekly", "주간"), "window_label 10080")
check(mc.window_label(2880) == ("w2880", "2일"), "window_label 2880")
check(mc.window_label(720) == ("w720", "12시간"), "window_label 720")

# rate_windows — 계정 방의 rollout 만, 가장 최근 것
future = int(now + 3 * 86400)
rl_room = write_rollout("01a15dea-0000-0000-0000-0000000000a1", str(work),
                        [token_count(now - 100, 12.0, 10080, future), ev(now - 99, "task_complete", turn_id="x")], day="2026/10/24")
rl_other = write_rollout("01a15dea-0000-0000-0000-0000000000b2", str(other),
                         [token_count(now - 10, 99.0, 10080, future)], day="2026/10/24")        # 방 기록에 없는 더 최신 rollout(데스크톱 무료 계정)
recs = [{"kind": "codex", "codexAccount": "b", "rollout": str(rl_room)},
        {"kind": "codex", "codexAccount": "z", "rollout": str(rl_other)},      # 다른 계정 방
        {"kind": "claude-ish", "codexAccount": "b", "rollout": str(rl_other)}]  # 코덱스 방이 아님
mc._RATE_CACHE.clear()
w = mc.rate_windows(recs, "b", now=now)
check(len(w) == 1 and w[0]["key"] == "weekly" and w[0]["label"] == "주간" and w[0]["usedPercent"] == 12.0
      and w[0]["resetsAt"] == future and w[0]["remainingPercent"] == 88.0, f"rate_windows: 방 rollout 값: {w}")
mc._RATE_CACHE.clear()
check(mc.rate_windows(recs, "b", now=future + 5)[0]["usedPercent"] == 0.0, "rate_windows: resets_at 이 지나면 0%")
check(mc.rate_windows(recs, "b", now=future + 5)[0]["resetsAt"] is None, "rate_windows: 지나면 리셋 시각 없음")
check(mc.rate_windows([], "b", now=now) == [], "rate_windows: 방이 없으면 빈 목록")
# secondary 가 있으면 창 둘
rl_two = write_rollout("01a15dea-0000-0000-0000-0000000000c3", str(work),
                       [token_count(now - 5, 30.0, 300, int(now + 3600), secondary={"used_percent": 8.0, "window_minutes": 10080, "resets_at": future})],
                       day="2026/10/24")
mc._RATE_CACHE.clear()
two = mc.rate_windows([{"kind": "codex", "codexAccount": "b", "rollout": str(rl_two)}], "b", now=now)
check([(x["key"], x["usedPercent"]) for x in two] == [("fiveHour", 30.0), ("weekly", 8.0)], f"rate_windows: primary+secondary: {two}")

# context_percent(source)
check(du.context_percent(rl_room, "codex") == du.agent_usage_from_path(rl_room, "codex")["contextPercent"] == 10.0,
      f"context_percent(codex): {du.context_percent(rl_room, 'codex')}")
tr = home / "claude.jsonl"
tr.write_text(json.dumps({"type": "assistant", "message": {"model": "claude-opus-5-5", "usage": {"input_tokens": 1000, "output_tokens": 500}}}) + "\n")
check(du.context_percent(tr) == du.agent_usage_from_path(tr, "claude")["contextPercent"] is not None, "context_percent: 기본 claude 는 그대로")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-codex-rollout"
