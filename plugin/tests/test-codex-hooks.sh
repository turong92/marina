#!/usr/bin/env bash
# 코덱스 방 훅 — SessionStart 로 sid·rollout 확보, 받음 👀·도구 이모지·턴 끝 정리. payload 는 스파이크 S6 실측 모양.
# 가장 중요한 것: DISCORD_STATE_DIR 없이(데스크톱 코덱스가 클로드 방 워크트리에서 돌 때) 불려도 아무것도 안 건드린다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
export CODEX_HOME="$TMPROOT/real-codex-home-must-not-be-used"
export MARINA_CODEX_SESSIONS="$TMPROOT/codex-sessions"
export FD TMPROOT MARINA_SH
mkdir -p "$MARINA_HOME/accounts/codex-b" "$MARINA_CODEX_SESSIONS/2026/10/21"
echo '{"tokens":{"x":1}}' > "$MARINA_HOME/accounts/codex-b/auth.json"
msess new proj feat/cx --codex --no-start >/dev/null 2>&1 || fail "코덱스 방 만들기 실패"
msess new proj feat/claude --no-start >/dev/null 2>&1 || fail "클로드 방 만들기 실패"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_codex as mc
FD, T = Path(os.environ["FD"]), Path(os.environ["TMPROOT"])
fails = []
def check(c, m):
    if not c: fails.append(m)
def log(): return [json.loads(l) for l in (FD / "log.jsonl").read_text().splitlines()]
def reqs(since=0): return [x for x in log()[since:] if x["m"] in ("PUT", "DELETE", "POST", "PATCH")]
def wait_for(pred, secs=6.0):
    end = time.time() + secs
    while time.time() < end:
        if pred(): return True
        time.sleep(0.1)
    return False

rec = ms.find_session("proj/feat/cx"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
crec = ms.find_session("proj/feat/claude"); csd = Path(crec["stateDir"])
SID = "01a15df6-ad2d-74f3-a376-1093930d23a9"
ro = Path(os.environ["MARINA_CODEX_SESSIONS"]) / f"2026/10/21/rollout-2026-10-21T10-00-00-{SID}.jsonl"
tag = f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="7001" user="u">\n해줘\n</channel>'
def ev(t, **kw): return json.dumps({"timestamp": "2026-10-21T10:00:00.000Z", "type": "event_msg", "payload": dict(type=t, **kw)})
ro.write_text(json.dumps({"timestamp": "2026-10-21T10:00:00.000Z", "type": "session_meta", "payload": {"id": SID, "cwd": rec["root"]}}) + "\n"
              + ev("task_started", turn_id="t1") + "\n" + ev("user_message", message=tag) + "\n")
base = {"session_id": SID, "transcript_path": str(ro), "cwd": rec["root"], "model": "gpt-5.6-sol", "permission_mode": "bypassPermissions"}

def run_cli(cmd, payload, env_sd=None, cwd=None):
    env = {k: v for k, v in os.environ.items() if k != "DISCORD_STATE_DIR"}
    if env_sd: env["DISCORD_STATE_DIR"] = str(env_sd)
    return subprocess.run(["bash", os.environ.get("MARINA_SH") or str(Path(ms.__file__).resolve().parents[2] / "plugin/scripts/marina.sh"), "session", cmd],
                          input=json.dumps(payload), text=True, capture_output=True, env=env, cwd=cwd or str(T), timeout=30)

# 1) SessionStart → sid·rollout 이 방 기록에 적힌다(/new 로 갈아타면 새 sid 로 바뀐다)
r = run_cli("hook-codex-start", dict(base, hook_event_name="SessionStart", source="startup"), env_sd=sd)
rec = ms.find_session("proj/feat/cx")
check(rec.get("sessionId") == SID and rec.get("rollout") == str(ro), f"sid·rollout 기록: {rec.get('sessionId')} {rec.get('rollout')} {r.stderr[-200:]}")
run_cli("hook-codex-start", dict(base, hook_event_name="SessionStart", source="startup", session_id="01a15dfd-1cc7-7cc0-8a92-33cae8fa7c82"), env_sd=sd)
check(ms.find_session("proj/feat/cx").get("sessionId") == "01a15dfd-1cc7-7cc0-8a92-33cae8fa7c82", "/new 뒤 새 sid 로 교체")
run_cli("hook-codex-start", dict(base, hook_event_name="SessionStart", source="resume"), env_sd=sd)
check(ms.find_session("proj/feat/cx").get("sessionId") == SID, "resume 은 원래 sid")
# 클로드 방 상태 폴더로는 아무것도 적지 않는다
run_cli("hook-codex-start", dict(base, hook_event_name="SessionStart", source="startup", session_id="01a15dfd-0000-0000-0000-000000000000"), env_sd=csd)
check(ms.find_session("proj/feat/claude").get("sessionId") != "01a15dfd-0000-0000-0000-000000000000", "클로드 방 기록은 안 건드린다")

# 2) 받음 👀 → 도구 이모지 → 턴 끝 정리 (in-process, 상태 폴더 = 코덱스 방)
os.environ["DISCORD_STATE_DIR"] = str(sd)
n0 = len(log())
ms.hook_prompt(dict(base, hook_event_name="UserPromptSubmit", turn_id="t1", prompt=tag))
check((sd / "turn-at").exists(), "turn-at 생김")
ms.hook_activity(dict(base, hook_event_name="UserPromptSubmit", turn_id="t1", prompt=tag), min_gap=0.0)
puts = [x["p"] for x in reqs(n0) if x["m"] == "PUT"]
check(any("/messages/7001/reactions/%F0%9F%91%80" in p for p in puts), f"m1 에 👀: {puts}")
ms.hook_activity(dict(base, hook_event_name="PreToolUse", turn_id="t1", tool_name="Bash", tool_input={"command": "ls"}), min_gap=0.0)
puts = [x["p"] for x in reqs(n0) if x["m"] == "PUT"]
check(any("%F0%9F%9B%91" in p for p in puts), "🛑 정지 버튼")
check(any("%F0%9F%94%A7" in p for p in puts), f"Bash 도구 이모지 🔧: {puts}")
check((sd / "activity-at").exists(), "activity-at 갱신")
ms.hook_stop(dict(base, hook_event_name="Stop", turn_id="t1", stop_hook_active=False, last_assistant_message="끝"))
dels = [x["p"] for x in reqs(n0) if x["m"] == "DELETE"]
check(any("%F0%9F%91%80" in p or "%F0%9F%94%A7" in p for p in dels) and any("%F0%9F%9B%91" in p for p in dels), f"턴 끝에 표시 뗌: {dels}")
check((sd / "stopped-at").exists(), "stopped-at 생김")
# 터미널에서 직접 친 말로 열린 턴(rollout 의 마지막 user 메시지에 이 채널 태그가 없음)은 방에 아무 표시도 안 한다
with ro.open("a") as fh:
    fh.write(ev("task_started", turn_id="t2") + "\n" + ev("user_message", message="터미널에서 직접 친 말") + "\n")
n2 = len(log())
ms.hook_activity(dict(base, hook_event_name="PreToolUse", turn_id="t2", tool_name="Bash", tool_input={"command": "ls"}), min_gap=0.0)
check(len(log()) == n2, f"터미널에서 연 턴엔 표시 0건: {log()[n2:]}")
del os.environ["DISCORD_STATE_DIR"]

# 3) DISCORD_STATE_DIR 없이 클로드 방 워크트리에서 — 네 훅 모두 Discord 0건, 클로드 방 상태 폴더 변화 0
def snap(d): return {str(p): (p.stat().st_mtime_ns, p.stat().st_size) for p in d.rglob("*") if p.is_file()}
before, n1 = snap(csd), len(log())
cp = dict(base, cwd=crec["root"], turn_id="t9")
for cmd, payload in (("hook-stop", dict(cp, hook_event_name="Stop", stop_hook_active=False)),
                     ("hook-typing", dict(cp, hook_event_name="PreToolUse", tool_name="Bash", tool_input={"command": "ls"})),
                     ("hook-typing", dict(cp, hook_event_name="UserPromptSubmit", prompt=tag.replace(ch, crec["channelId"]))),
                     ("hook-prompt", dict(cp, hook_event_name="UserPromptSubmit", prompt=tag.replace(ch, crec["channelId"]))),
                     ("hook-rm-guard", dict(cp, hook_event_name="PreToolUse", tool_name="Bash", tool_input={"command": "ls"})),
                     ("hook-codex-start", dict(cp, hook_event_name="SessionStart", source="startup"))):
    run_cli(cmd, payload, env_sd=None, cwd=crec["root"])
time.sleep(1.5)                                  # hook-typing 은 떼어 낸 프로세스가 일한다
check(len(log()) == n1, f"상태 폴더 없는 코덱스 훅은 Discord 요청 0건: {log()[n1:]}")
check(snap(csd) == before, "클로드 방 상태 폴더 파일 변화 0")

# 4) 코덱스 방 argv 에 인라인 훅이 들어간다
argv = mc.codex_argv(ms.find_session("proj/feat/cx"))
hk = [a for a in argv if a.startswith("hooks=")]
check(len(hk) == 1 and argv.count("--dangerously-bypass-hook-trust") == 1, f"hooks -c 하나, 훅 신뢰 우회 하나: {len(hk)}")
if hk:
    for name in ("hook-codex-start", "hook-prompt", "hook-typing", "hook-rm-guard", "hook-stop"):
        check(name in hk[0], f"훅 명령 {name}")
    try:
        import tomllib
        parsed = tomllib.loads(hk[0])["hooks"]
        check(set(parsed) == {"SessionStart", "UserPromptSubmit", "PreToolUse", "Stop"}, f"TOML 로 읽힘: {sorted(parsed)}")
        cmds = [h["command"] for g in parsed["UserPromptSubmit"] for h in g["hooks"]]
        check(all(c.endswith("|| true") for c in cmds) and len(cmds) == 2, f"UserPromptSubmit 명령 둘, 실패는 지나가게: {cmds}")
        check(any(g.get("matcher") == "Bash" for g in parsed["PreToolUse"]), "Bash 매처(rm 가드)")
    except ImportError:
        pass
# 5) 방 스레드 글도 방 글처럼 — inbound_pairs 가 (id, 스레드) 짝을, turn_from_terminal·unanswered_mid 가 방+스레드를 본다
ms.remember_room_thread(str(sd), "9100")
tro = T / "rollout-thread.jsonl"
ttag = f'<channel source="plugin:discord:discord" chat_id="9100" message_id="7100" user="u">\n스레드\n</channel>'
tro.write_text(ev("user_message", message=ttag) + "\n")
chans = ms.room_chans(rec)
check(mc.inbound_pairs(tro, chans) == [("7100", "9100")], f"스레드 글 짝: {mc.inbound_pairs(tro, chans)}")
check(mc.inbound_pairs(tro, ch) == [], "방 채널만 보면 스레드 글은 안 보임")
check(ms.inbound_pairs(tro, chans) == [("7100", "9100")], "ms.inbound_pairs 가 코덱스 rollout 에 위임")
check(not mc.turn_from_terminal(tro, chans), "스레드 글로 연 턴은 터미널 입력이 아님")
check(mc.unanswered_mid(rec, tro) == "7100", "스레드 지시도 답 전엔 미답")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-codex-hooks"
