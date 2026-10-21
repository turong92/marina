#!/usr/bin/env bash
# 코덱스 판 — chat-bot 카테고리 안의 #상태와 최상위 숫자판(📊 코덱스 주간 N%). 전역 #상태는 코덱스 방을 안 그린다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
export CODEX_HOME="$TMPROOT/real-codex-home-must-not-be-used"
export MARINA_CODEX_SESSIONS="$TMPROOT/codex-sessions"
export FD TMPROOT
mkdir -p "$MARINA_HOME/accounts/codex-b" "$MARINA_CODEX_SESSIONS"
echo '{"tokens":{"x":1}}' > "$MARINA_HOME/accounts/codex-b/auth.json"
touch "$TMPROOT/codex-tui"
msess new proj feat/cxroom --codex >/dev/null 2>&1 || fail "코덱스 방 만들기 실패"
msess new proj feat/clroom --no-start >/dev/null 2>&1 || fail "클로드 방 만들기 실패"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
FD, T = Path(os.environ["FD"]), Path(os.environ["TMPROOT"])
fails = []
def check(c, m):
    if not c: fails.append(m)
def log(): return [json.loads(l) for l in (FD / "log.jsonl").read_text().splitlines()]
mb.claude_usage = lambda: [{"key": "weekly", "label": "주간", "usedPercent": 6.0}]
mb.account_usage = lambda: {}
mb.role_usage = lambda *a, **k: []
mb.sys_stats = lambda: {}

cx = ms.find_session("proj/feat/cxroom"); cl = ms.find_session("proj/feat/clroom")
CX, CL = f"<#{cx['channelId']}>", f"<#{cl['channelId']}>"
cat = json.loads((Path(os.environ["MARINA_HOME"]) / "discord.json").read_text())["codex"]["categoryId"]
ro = next(f for f in Path(os.environ["MARINA_CODEX_SESSIONS"]).glob("*/*/*/rollout-*.jsonl")
          if json.loads(f.open().readline())["payload"]["cwd"] == os.path.realpath(cx["root"]))
sid = ro.name[:-len(".jsonl")].split("-", 6)[-1]
def ev(t, **kw): return json.dumps({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()), "type": "event_msg", "payload": dict(type=t, **kw)})
with ro.open("a") as fh:
    fh.write(ev("token_count", info={"total_token_usage": {"total_tokens": 1}, "last_token_usage": {"total_tokens": 1}, "model_context_window": 1000},
                rate_limits={"limit_id": "codex", "primary": {"used_percent": 12.0, "window_minutes": 10080, "resets_at": int(time.time()) + 86400}, "secondary": None}) + "\n")
items = ms.load_sessions()
for x in items:
    if x["stateDir"] == cx["stateDir"]: x["sessionId"], x["rollout"] = sid, str(ro)
ms.save_sessions(items)

def msgs(since): return [x for x in log()[since:] if x["m"] in ("POST", "PATCH") and "/messages" in x["p"]]
def creates(since): return [x for x in log()[since:] if x["m"] == "POST" and x["p"] == "/guilds/G1/channels"]

# 1) 전역 #상태 — 코덱스 방이 없다. 코덱스 판 — chat-bot 카테고리 안에 #상태, 코덱스 방 줄과 주간 12%
n = len(log()); st = {}
mb.dashboard_tick(st)
body = json.dumps([x["b"] for x in msgs(n)], ensure_ascii=False)
check(CL in body and CX not in body, f"전역 #상태: 클로드 방만: {body[:300]}")
check(not any(c["b"].get("parent_id") for c in creates(n)), "전역 #상태 채널은 카테고리 밖")
n = len(log()); st2 = {}
mb.dashboard_tick(st2, codex=True)
made = [c for c in creates(n) if c["b"].get("name") == "상태"]
check(len(made) == 1 and made[0]["b"].get("parent_id") == cat, f"코덱스 #상태 는 chat-bot 카테고리 안: {made}")
body = json.dumps([x["b"] for x in msgs(n)], ensure_ascii=False)
check(CX in body and CL not in body, f"코덱스 #상태: 코덱스 방만: {body[:300]}")
check("주간" in body and "12%" in body, f"코덱스 #상태에 주간 12%: {body[:400]}")
check(json.loads((Path(os.environ["MARINA_HOME"]) / "discord-bot.json").read_text()).get("codexDashboard", {}).get("channelId"), "codexDashboard 상태 저장")
n = len(log()); mb.dashboard_tick(st2, codex=True)
check(not msgs(n) and not creates(n), "내용이 같으면 다시 안 쓴다")

# 2) 코덱스 숫자판 — type 4 카테고리 하나, 10분 안 재호출은 PATCH 0
n = len(log()); meters = {}
mb.codex_meter_tick(meters)
made = [c for c in creates(n) if c["b"].get("type") == 4]
check(len(made) == 1 and made[0]["b"]["name"] == "📊 코덱스 주간 12%", f"코덱스 숫자판: {[c['b'].get('name') for c in made]}")
n = len(log()); mb.codex_meter_tick(meters)
check([x for x in log()[n:] if x["m"] in ("POST", "PATCH")] == [], "10분 안 재호출은 요청 0")

# 3) rate_limits 가 없으면(rollout 없음) 숫자판을 만들지 않는다
items = ms.load_sessions()
for x in items:
    if x["stateDir"] == cx["stateDir"]: x["sessionId"], x["rollout"] = "", ""
ms.save_sessions(items)
n = len(log()); mb.codex_meter_tick({})
check(not creates(n), "rollout 이 없으면 숫자판 POST 0")

# 4) 카테고리 id 가 없으면(방을 한 번도 안 만듦) 코덱스 #상태는 아무것도 안 한다
cfgp = Path(os.environ["MARINA_HOME"]) / "discord.json"
cfg = json.loads(cfgp.read_text()); saved_cat = cfg["codex"].pop("categoryId"); cfgp.write_text(json.dumps(cfg))
n = len(log()); mb.dashboard_tick({}, codex=True)
check(len(log()) == n, "카테고리 없으면 요청 0")
cfg["codex"]["categoryId"] = saved_cat; cfgp.write_text(json.dumps(cfg))
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo PASS
