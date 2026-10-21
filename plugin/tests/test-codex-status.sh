#!/usr/bin/env bash
# 코덱스 방 상태 판정 통합 — 바쁨·ctx(rollout)·정지(Esc)·답 못 한 지시 재촉·쉬면 내리기·sid 사후 확보·꺼진 방 깨우기.
# 클로드 방 경로는 그대로(회귀는 test-discord-bot·idle·nudge-unanswered·safe-restart 가 지킨다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
export CODEX_HOME="$TMPROOT/real-codex-home-must-not-be-used"
export MARINA_CODEX_SESSIONS="$TMPROOT/codex-sessions"
export MARINA_CODEX_CONFIRM_TIMEOUT=2 MARINA_ENTER_DELAY=0.3
export MARINA_CODEX_ADOPT_WAIT=4 MARINA_CODEX_ADOPT_POLL=0.3     # sid 사후 확보 루프를 짧게(기본 30초·2초)
export FD TMPROOT FAKE_CODEX_OUT
mkdir -p "$MARINA_HOME/accounts/codex-b" "$MARINA_CODEX_SESSIONS"
echo '{"tokens":{"x":1}}' > "$MARINA_HOME/accounts/codex-b/auth.json"
touch "$TMPROOT/codex-tui"
msess new proj feat/st --codex >/dev/null 2>&1 || fail "코덱스 방 만들기 실패"
for _ in $(seq 60); do ls "$MARINA_CODEX_SESSIONS"/*/*/*/rollout-*.jsonl >/dev/null 2>&1 && break; sleep 0.1; done
msess new proj feat/ad --codex --no-start >/dev/null 2>&1 || fail "ad 방 만들기 실패"
msess new proj feat/ok --codex --no-start >/dev/null 2>&1 || fail "ok 방 만들기 실패"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
import marina_discord_idle as mi
import marina_discord_wake as mw
import marina_discord_usage as du
import marina_codex as mc
FD, T = Path(os.environ["FD"]), Path(os.environ["TMPROOT"])
fails = []
def check(c, m):
    if not c: fails.append(m)
def finish():
    if fails:
        print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
def log(): return [json.loads(l) for l in (FD / "log.jsonl").read_text().splitlines()]
def wait_for(pred, secs=8.0):
    end = time.time() + secs
    while time.time() < end:
        if pred(): return True
        time.sleep(0.1)
    return False
def iso(t=None): return datetime.fromtimestamp(time.time() if t is None else t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def ev(t, **kw): return json.dumps({"timestamp": iso(), "type": "event_msg", "payload": dict(type=t, **kw)})
def append(path, *rows):
    with path.open("a", encoding="utf-8") as fh:
        for r in rows: fh.write(r + "\n")
def redraw(): ms._tmux("send-keys", "-t", tmux, "Enter")      # 가짜 TUI 는 키가 와야 화면을 다시 그린다(입력창이 비었을 때만 안전)
def rec_of(task): return ms.find_session(f"proj/feat/{task}")
def last_argv():
    calls = sorted((p for p in Path(os.environ["FAKE_CODEX_OUT"]).iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
    return [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]

mb.claude_usage = lambda: []
mb.account_usage = lambda: {}
mb.role_usage = lambda *a, **k: []
mb.sys_stats = lambda: {}

rec = rec_of("st"); sd = Path(rec["stateDir"]); ch = rec["channelId"]; tmux = rec["tmux"]
ro = next(f for f in Path(os.environ["MARINA_CODEX_SESSIONS"]).glob("*/*/*/rollout-*.jsonl")
          if json.loads(f.open().readline())["payload"]["cwd"] == os.path.realpath(rec["root"]))
sid = ro.name[:-len(".jsonl")].split("-", 6)[-1]
items = ms.load_sessions()
for x in items:
    if x["stateDir"] == rec["stateDir"]: x["sessionId"], x["rollout"] = sid, str(ro)
ms.save_sessions(items)
rec = rec_of("st")
tag = f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="m1" user="u">\n해줘\n</channel>'
append(ro, ev("user_message", message=tag))

# 1) 바쁨·ctx — rollout 이 task_started 뿐이어도 바쁨, ctx 는 rollout 계산값, complete 가 오면 쉼
append(ro, ev("task_started", turn_id="t1"),
       ev("token_count", info={"total_token_usage": {"total_tokens": 100}, "last_token_usage": {"total_tokens": 100}, "model_context_window": 1000}, rate_limits=None))
row = next(r for r in mb.snapshot()["sessions"] if r["channelId"] == str(ch))
want = du.context_percent(ro, "codex")
check(want is not None, "픽스처 ctx 계산값이 있어야 한다")
check(row["alive"] and row["busy"] is True, f"rollout 이 일하는 중이면 busy: {row}")
check(row["ctx"] == want, f"ctx = rollout 계산값: {row['ctx']} != {want}")
append(ro, ev("task_complete", turn_id="t1"))
row = next(r for r in mb.snapshot()["sessions"] if r["channelId"] == str(ch))
check(row["busy"] is False, f"complete 뒤엔 쉼: {row}")
check(mb._turn_in_progress(ro) is False, "_turn_in_progress: complete 뒤엔 아님")
append(ro, ev("task_started", turn_id="t2"))
check(mb._turn_in_progress(ro) is True, "_turn_in_progress: started 뒤엔 진행 중")
append(ro, ev("turn_aborted", turn_id="t2", reason="interrupted"))

# 2) 정지 — 일하는 화면(Working … esc to interrupt)이면 Esc 가 가고 ⏹️ 가 달린다
(T / "codex-ctl").mkdir(exist_ok=True)
(T / "codex-ctl" / "busy").touch(); redraw()
check(wait_for(lambda: mc.pane_busy(tmux)), "화면 판정: Working 줄이면 바쁨")
n0 = len(log())
r = mb.interrupt(str(ch), "U1", "m1")
check(r == "멈췄어", f"interrupt 결과: {r}")
redraw()      # 가짜 TUI 는 Esc 뒤 다음 키가 와야 Esc 한 개로 센다
check(wait_for(lambda: (T / "codex-ctl" / "keys").exists() and "Escape" in (T / "codex-ctl" / "keys").read_text()), "가짜 codex 가 Escape 를 받음")
puts = [x["p"] for x in log()[n0:] if x["m"] == "PUT"]
check(any("/messages/m1/reactions/%E2%8F%B9" in p for p in puts), f"⏹️ PUT: {puts}")
check((sd / "stopped-at").exists(), "진행 표시 정리(stopped-at)")
(T / "codex-ctl" / "busy").unlink(); redraw()
check(wait_for(lambda: not mc.pane_busy(tmux)), "busy 파일을 지우면 화면도 쉼")
r = mb.interrupt(str(ch), "U1", "m1")
check(r == "지금 쉬고 있어", f"쉬는 방 interrupt: {r}")

# 3) 답 못 한 지시 재촉 — Stop 훅에서. replied.json 이 그 지시면 안 친다, 없으면 세 번까지
typed = []
mb._spawn_type = lambda tmux, text, ch, mid, button="": typed.append(text)
os.environ["DISCORD_STATE_DIR"] = str(sd)
payload = {"session_id": sid, "transcript_path": str(ro), "cwd": rec["root"], "hook_event_name": "Stop", "turn_id": "t2", "stop_hook_active": False}
(sd / "replied.json").write_text(json.dumps({"mid": "m1", "at": time.time()}))
ms.hook_stop(dict(payload))
check(typed == [], f"답한 지시는 재촉 안 함: {typed}")
(sd / "replied.json").unlink()
for _ in range(4): ms.hook_stop(dict(payload))
check(typed == [ms.NUDGE_TEXT] * ms.NUDGE_TRIES, f"답 못 한 지시는 NUDGE_TEXT 를 최대 3번: {len(typed)}")
check(mc.unanswered_mid(rec, ro) == "m1", "unanswered_mid")
(sd / "replied.json").write_text(json.dumps({"mid": "m1", "at": 1}))
check(mc.unanswered_mid(rec, ro) == "", "replied.mid == 마지막 지시 → 없음")
(sd / "replied.json").unlink()
del os.environ["DISCORD_STATE_DIR"]

# 4) 쉬면 내리기 — 입력창 빈 가짜 화면은 내려도 됨, 일하는 중이면 막는다
(sd / "replied.json").write_text(json.dumps({"mid": "m1", "at": 1}))
os.utime(ro, (time.time() - 600, time.time() - 600))      # 방금 움직인 기록은 재시작 막음 사유(30초)
v = mi.verdict(rec, 0.0, time.time() + 5)
check(v == [], f"쉬는 코덱스 방은 내려도 됨: {v}")
(T / "codex-ctl" / "busy").touch(); redraw()
check(wait_for(lambda: mc.pane_busy(tmux)), "busy 화면")
v = mi.verdict(rec, 0.0, time.time() + 5)
check(any("작업 중" in x for x in v), f"일하는 중이면 막는다: {v}")
(T / "codex-ctl" / "busy").unlink(); redraw()
check(wait_for(lambda: not mc.pane_busy(tmux)), "쉬는 화면")
ms._tmux("send-keys", "-t", tmux, "-l", "쓰던 글")
wait_for(lambda: not mc.input_empty(tmux))
v = mi.verdict(rec, 0.0, time.time() + 5)
check(any("입력창" in x for x in v), f"입력창에 글이 있으면 막는다: {v}")
finish()

# 5) sid 사후 확보 — 새 rollout 이 둘이면 ""(짐작 금지) + 다음 start 는 새로 띄움, 하나면 기록 + 다음 start 는 resume
ad = rec_of("ad")
for t in ("ad", "ok"): ms.tmux_stop(rec_of(t)["tmux"])      # new --codex 는 --no-start 와 상관없이 띄운다(T1) — 꺼진 방에서 start 를 시험
other = Path(os.environ["MARINA_CODEX_SESSIONS"]) / "2026/10/21/rollout-2026-10-21T11-00-00-01a15dea-6b55-7ed3-bb4f-672e4a953103.jsonl"
other.write_text(json.dumps({"timestamp": iso(), "type": "session_meta", "payload": {"id": "01a15dea-6b55-7ed3-bb4f-672e4a953103", "cwd": ad["root"]}}) + "\n")
os.utime(other, (time.time() + 120, time.time() + 120))      # start 이후 만들어진 것으로 보이게
started, failed = ms.cmd_start("proj/feat/ad")
check(started and not failed, f"ad start: {started} {failed}")
time.sleep(6)
check(not rec_of("ad").get("sessionId"), f"후보가 둘이면 sid 를 정하지 않는다: {rec_of('ad').get('sessionId')}")
ms.tmux_stop(rec_of("ad")["tmux"])
ms.cmd_start("proj/feat/ad")
check("resume" not in last_argv(), f"sid 없으면 새로 띄움: {last_argv()[:3]}")
ms.tmux_stop(rec_of("ad")["tmux"])

okr = rec_of("ok")
started, failed = ms.cmd_start("proj/feat/ok")
check(started and not failed, f"ok start: {started} {failed}")
check(wait_for(lambda: rec_of("ok").get("sessionId")), "후보가 하나면 sid 가 기록된다")
osid = rec_of("ok").get("sessionId")
ms.tmux_stop(rec_of("ok")["tmux"])
ms.cmd_start("proj/feat/ok")
av = last_argv()
check("resume" in av and av[av.index("resume") + 1] == osid, f"다음 start 는 resume <sid>: {av[:4]}")
ms.tmux_stop(rec_of("ok")["tmux"])

# 6) 꺼진 코덱스 방에 wake → resume + 깨우기 글을 첫 지시 인자로
ms.tmux_stop(tmux)
now = time.time()
mid = str((int(now * 1000) - 1420070400000) << 22)
(FD / "messages.json").write_text(json.dumps({ch: [{"id": mid, "type": 0, "content": "일어나", "channel_id": ch,
        "author": {"id": "U1", "username": "sumin", "bot": False}, "attachments": []}]}))
r = mw.wake(ch, "U1", mid)
check(r == "woke", f"꺼진 방 wake: {r}")
av = last_argv()
check("resume" in av and av[av.index("resume") + 1] == sid, f"resume <sid>: {av[:4]}")
check(f'message_id="{mid}"' in av[-1], f"깨우기 글이 첫 지시: {av[-1][:120]}")
finish()
PY
echo PASS
