#!/usr/bin/env bash
# 구독 계정 둘(2026-10-18): 방마다 계정 — 'a' = 키체인 로그인, 그 밖 = ~/.marina/accounts/<이름>.token(setup-token)
#  - 띄울 때 토큰은 셸이 파일에서 읽어 CLAUDE_CODE_OAUTH_TOKEN 으로만 넘긴다(tmux 명령줄·argv 에 안 남게)
#  - 띄운 계정을 account-running 에 적는다(상태 채널 표시)
#  - /account <이름> [default]: 방 계정·기본 계정. 떠 있으면 안전 재시작(쉬면 같은 대화로 다시 띄움)
#  - 사용량: 토큰 계정은 /api/oauth/usage 권한이 없어 응답 헤더(unified-5h/7d-utilization)로 읽는다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"
mkdir -p "$MARINA_HOME/accounts"; printf 'sk-ant-oat-TEST-B\n' > "$MARINA_HOME/accounts/b.token"; chmod 600 "$MARINA_HOME/accounts/b.token"

FD="$FD" PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FAKE_OUT" <<'PY'
import json, os, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
import marina_discord_usage as mu
out = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
ms.tmux_stop(rec["tmux"])          # new 가 띄운 세션(a) — 계정을 정한 뒤 다시 띄운다
for f in out.glob("*/env"):
    f.unlink()

# ── 계정 고르기 ──
check(ms.accounts() == ["a", "b"], f"계정 목록 = a + 토큰 파일: {ms.accounts()}")
check(ms.account_of(sd) == "a", "기본은 a")
check("MARINA_ACCOUNT_TOKEN_FILE" not in ms.session_env(sd), "a 는 토큰 env 없음")
ms.set_account(sd, "b")
check(ms.account_of(sd) == "b", "방 계정 b")
check(ms.session_env(sd).get("MARINA_ACCOUNT_TOKEN_FILE") == str(ms.marina_home() / "accounts" / "b.token"), "b 는 토큰 파일 경로만 env 로")
try:
    ms.set_account(sd, "zz"); fails.append("없는 계정은 거절")
except ms.SessionError:
    pass
ms.set_account(sd, "a")
ms.set_default_account("b")
check(ms.account_of(sd) == "a", f"방 지정(a)이 기본(b)보다 이긴다: {ms.account_of(sd)}")
ms.clear_account(sd)
check(ms.account_of(sd) == "b", "방 지정이 없으면 기본(b)")
ms.set_default_account("a"); ms.set_project_account("proj", "b")
check(ms.account_of(sd) == "b", "프로젝트 기본(b)이 전체 기본(a)보다 이긴다")
ms.set_account(sd, "a"); check(ms.account_of(sd) == "a", "방 지정이 프로젝트보다 이긴다"); ms.clear_account(sd)
(ms.accounts_dir() / "projects.json").unlink(); ms.set_default_account("b")

# ── 띄우기: 토큰은 env 로만, 명령줄엔 안 남는다 ──
started, failed = ms.cmd_start("proj/feat/a")
check(started and not failed, f"시작: {started} {failed}")
time.sleep(0.5)
envs = [p.read_text() for p in out.glob("*/env")]
check(any("CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-TEST-B" in e for e in envs), "claude 가 b 토큰을 env 로 받음")
check(not any("MARINA_ACCOUNT_TOKEN_FILE" in e for e in envs), "파일 경로 변수는 claude 에 안 넘김")
cmdline = ms._tmux("list-panes", "-a", "-F", "#{pane_start_command}").stdout or ""
check("sk-ant-oat-TEST-B" not in cmdline, "tmux 명령줄에 토큰이 안 남음")
check((sd / "account-running").read_text().strip() == "b", "띄운 계정 기록")
# 채널에 '어디 붙어 있나' — 실제로 다른 계정으로 뜨면 한 줄 알림 + 주제 앞 '🔑 B · ', 같은 계정이면 조용
def fdlog():
    return [json.loads(l) for l in (Path(os.environ["FD"]) / "log.jsonl").read_text().splitlines()]
n = len(fdlog())
mb.account_tick()
new = fdlog()[n:]
check(any(x["m"] == "POST" and "B 계정" in json.dumps(x["b"], ensure_ascii=False) for x in new)
      and any(x["m"] == "PATCH" and str((x["b"] or {}).get("topic", "")).startswith("🔑 B · ") for x in new), f"전환 알림·주제: {new}")
n = len(fdlog()); mb.account_tick()
check(len(fdlog()) == n, "같은 계정이면 다시 안 알림")
ms.tmux_stop(rec["tmux"])
# 토큰 파일이 사라졌으면 a 로 뜨고 기록도 a
os.rename(ms.marina_home() / "accounts" / "b.token", ms.marina_home() / "accounts" / "b.gone")
check("MARINA_ACCOUNT_TOKEN_FILE" not in ms.session_env(sd), "토큰 파일 없으면 a 로")
ms.cmd_start("proj/feat/a"); time.sleep(0.3)
check((sd / "account-running").read_text().strip() == "a", "토큰 없이 뜨면 기록도 a")
ms.tmux_stop(rec["tmux"])
check("MARINA_ACCOUNT_TOKEN_FILE" not in ms.chat_env(sd), "채팅방·로비는 늘 a")
os.rename(ms.marina_home() / "accounts" / "b.gone", ms.marina_home() / "accounts" / "b.token")

# ── /account ──
restarted = []
mb._spawn_account_restart = lambda ref: restarted.append(ref)
ms.set_default_account("a")
r = mb.slash(ch, "U1", "account", "b", "")
check(ms.account_of(sd) == "b" and "B" in r and not restarted, f"잠든 방: 정하기만(다음에 깨면 b): {r} {restarted}")
ms.cmd_start("proj/feat/a"); time.sleep(0.3)
r = mb.slash(ch, "U1", "account", "a", "")
check(ms.account_of(sd) == "a" and restarted == ["proj/feat/a"], f"떠 있으면 안전 재시작 예약: {r} {restarted}")
mb.owner_ids = lambda cfg: ["U1"]
_al = mb._allowed; mb._allowed = lambda *a: True
check("형만" in mb.slash(ch, "U9", "account", "b", "default"), "기본 계정은 형만")
mb._allowed = _al
r = mb.slash(ch, "U1", "account", "b", "default")
check(ms.default_account() == "b" and ms.account_of(sd) == "a", f"default: 기본만 바꾼다: {r}")
check("없는" in mb.slash(ch, "U1", "account", "zz", ""), "없는 계정")
cmds = json.loads(json.dumps(mb.slash_commands()))
acc = next((c for c in cmds if c["name"] == "account"), None)
check(acc and [x["value"] for x in acc["options"][0]["choices"]] == ["a", "b"], f"/account 선택지 = 계정 목록: {acc}")

# ── /account 재시작: 기다리지 않고 강제(2026-10-22 ovation/a2-1 — 30분 기다리다 조용히 포기해 한도 창에 멈춤) ──
mb.owner_ids = lambda cfg: ["U1"]
def posts(since):
    return [(x["b"] or {}).get("content", "") for x in fdlog()[since:] if x["m"] == "POST" and "/messages" in x.get("p", x.get("path", "/messages"))]
forced, state = [], {"busy": False, "limit": False, "blockers": [], "fail": False}
mb.force_restart = lambda refs, log=None: (forced.append(list(refs)) or ([], ["✗ 방 잠금 — 지금 꺼져 있다"])) if state["fail"] else (forced.append(list(refs)) or (list(refs), []))
mb.restart_blockers = lambda r: list(state["blockers"])
mb._pane_limit = lambda name: state["limit"]
def run(**kw):
    n = len(fdlog()); t0 = time.time()
    ok = mb.account_switch_restart("proj/feat/a", poll=0.05, **kw)
    return ok, time.time() - t0, " | ".join(posts(n))
# 1) 백그라운드 셸·에이전트가 있어도 기다리지 않고 바로, 끊은 것을 알린다
state.update(busy=False, limit=False, blockers=["백그라운드 셸 2", "에이전트 1개 일하는 중"], fail=False)
mb._room_busy = lambda rec: (True, False)
forced.clear(); ok, dt, msg = run(grace=5.0)
check(ok and forced == [["proj/feat/a"]] and dt < 1.0, f"뒤에서 도는 일은 안 기다리고 강제: ok={ok} dt={dt} {forced}")
check("백그라운드 셸 2" in msg and "에이전트 1개" in msg and "기다리지 않" in msg and "✓" in msg, f"끊은 것·결과를 채널에: {msg}")
# 2) 턴이 진행 중이면 끝나길 기다린다(끝나면 그때 재시작)
calls = {"n": 0}
def busy_then_idle(rec):
    calls["n"] += 1
    return True, calls["n"] < 4
mb._room_busy = busy_then_idle
state["blockers"] = []; forced.clear(); ok, dt, msg = run(grace=5.0)
check(ok and forced and 0.1 < dt < 3.0 and "턴" in msg and "✓" in msg, f"진행 중 턴은 끝날 때까지: dt={dt} {msg}")
# 3) 턴이 안 끝나면 grace 뒤 강제
mb._room_busy = lambda rec: (True, True)
forced.clear(); ok, dt, msg = run(grace=0.3)
check(ok and forced and 0.25 < dt < 3.0 and "강제" in msg, f"grace 넘으면 강제: dt={dt} {msg}")
# 4) 사용량 한도 창이면 바쁨으로 안 치고 바로
state["limit"] = True
forced.clear(); ok, dt, msg = run(grace=5.0)
check(ok and forced and dt < 1.0 and "한도" in msg, f"한도 창은 바로: dt={dt} {msg}")
state["limit"] = False
# 5) 재시작 실패는 조용히 넘기지 않고 채널에 이유
mb._room_busy = lambda rec: (True, False); state["fail"] = True
ok, dt, msg = run(grace=5.0)
check(not ok and "✗" in msg and "방 잠금" in msg, f"실패 사유를 채널에: {msg}")
state["fail"] = False
# 6) 슬래시 응답은 '쉬면'이 아니라 바로/최대 3분
import subprocess as _sp
spawned = []
mb._spawn_account_restart = lambda ref: spawned.append(ref)
ms.set_account(sd, "a")
mb.restart_status = lambda *a, **k: None
ms.running_account = lambda d: "b"
r = mb.slash(ch, "U1", "account", "a", "")
check(spawned == ["proj/feat/a"] and "3분" in r and "쉬면" not in r, f"슬래시 응답: {r}")

# ── 사용량: 헤더 → 창 ──
w = mu.windows_from_headers({"anthropic-ratelimit-unified-5h-utilization": "0.42", "anthropic-ratelimit-unified-5h-reset": "1792318200",
                             "anthropic-ratelimit-unified-7d-utilization": "0.1", "anthropic-ratelimit-unified-7d-reset": "1792864800"})
check([(x["key"], x["usedPercent"]) for x in w] == [("fiveHour", 42.0), ("weekly", 10.0)], f"헤더 → 5시간·주간 %: {w}")
check(mu.windows_from_headers({}) == [], "헤더 없으면 빈 목록")
check(w[0]["resetsAt"] == 1792318200, f"리셋 시각(epoch 문자열): {w[0]}")
# 토큰 폐기(401·403) → 옛 % 를 지우고 확인 필요, 그 밖 실패 → 마지막 값 유지·잠시 뒤 다시
cd = ms.accounts_dir(); tf = cd / "b.token"
(cd / "b.usage.json").write_text(json.dumps({"at": 0, "windows": [{"key": "fiveHour", "usedPercent": 50}]}))
def boom(tok): raise mu._AuthFailed()
mu._probe = boom
check(mu.token_windows("b", tf, cd) == [] and json.loads((cd / "b.usage.json").read_text()).get("error") == "auth", "토큰 무효 → 빈 값·error")
(cd / "b.usage.json").write_text(json.dumps({"at": 0, "windows": [{"key": "fiveHour", "usedPercent": 50}]}))
calls = []
mu._probe = lambda tok: calls.append(1) or None
check(mu.token_windows("b", tf, cd)[0]["usedPercent"] == 50 and mu.token_windows("b", tf, cd) and len(calls) == 1, f"일시 실패 → 마지막 값, 바로 다시 안 찍음: {calls}")

# ── 상태 채널 ──
snap = {"usage": [{"key": "fiveHour", "label": "5시간", "usedPercent": 12, "resetsAt": 1792315200}, {"key": "weekly", "label": "주간", "usedPercent": 61}],
        "accountUsage": {"b": [{"key": "fiveHour", "label": "5시간", "usedPercent": 3}, {"key": "weekly", "label": "주간", "usedPercent": 1}]},
        "sessions": [], "roleUsage": None}
top = json.dumps(mb.render(snap)[0], ensure_ascii=False)
check("A 5시간" in top and "B 5시간" in top and "3%" in top, f"사용량 줄 계정별: {top}")
check("↻ <t:1792315200:R>" in top and top.count("↻") == 1, f"리셋 시각(있는 창만): {top}")
snap["accountUsage"] = {}
top = json.dumps(mb.render(snap)[0], ensure_ascii=False)
check("A 5시간" not in top and "5시간" in top, f"계정 하나면 예전 그대로: {top}")
rb = mb._row({"ref": "proj/feat/a", "account": "b", "busy": False, "alive": True, "channelId": "1"}, 4)
ra = mb._row({"ref": "proj/feat/a", "account": "a", "busy": False, "alive": True, "channelId": "1"}, 4)
check("B  proj" in rb and "A  proj" in ra and rb.index("<#") == ra.index("<#"), f"방 줄: 모든 줄에 계정 칸(정렬 유지): {rb} / {ra}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-account"
