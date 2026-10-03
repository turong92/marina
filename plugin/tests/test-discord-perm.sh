#!/usr/bin/env bash
# 봇 4: 권한 승인 버튼 — PermissionRequest 훅이 채널에 [허용][거부] 를 올리고 누를 때까지 기다린다(그동안 터미널 창은 숨겨짐)
#  - 시간이 지나면 결정 없이 돌려줘 원래 권한 창으로(터미널·앱에서 결정)
#  - AskUserQuestion 은 질문 버튼이 맡는다(이 훅은 건너뜀) · 명령 원문은 안 보낸다(설명만)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, sys, threading, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
os.environ["DISCORD_STATE_DIR"] = str(sd)
st = json.loads((sd / "settings.json").read_text())
check(any("hook-permission" in h["command"] for e in st["hooks"].get("PermissionRequest", []) for h in e["hooks"]), "권한 훅 등록")

tr = sd / "t.jsonl"
def prompt(content):
    tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n")
prompt(f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="1" user="u">\nfix\n</channel>')
check(ms.hook_permission({"tool_name": "AskUserQuestion", "tool_input": {}, "transcript_path": str(tr)}, wait=0.1) is None, "질문은 건너뜀")
check(ms.hook_permission({"tool_name": "ExitPlanMode", "tool_input": {}, "transcript_path": str(tr)}, wait=0.1) is None,
      "(리뷰 M2) 계획 승인은 내용 없이 버튼으로 안 받는다")
req = {"tool_name": "Bash", "tool_input": {"command": "rm -rf /secret/path --token=abc", "description": "임시 폴더 정리"},
       "tool_use_id": "toolu_1", "transcript_path": str(tr)}
res = {}
th = threading.Thread(target=lambda: res.update(out=ms.hook_permission(req, wait=5, poll=0.05))); th.start()
for _ in range(50):
    posts = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages"]
    if posts and list(sd.glob("perm-*.json")): break
    time.sleep(0.05)
body = json.dumps(posts[-1]["b"], ensure_ascii=False) if posts else ""
check("임시 폴더 정리" in body and "Bash" in body, f"설명·도구 이름: {body}")
check("rm -rf" not in body and "abc" not in body, "명령 원문·비밀은 안 보낸다")
token = next(iter(json.loads(p.read_text())["token"] for p in sd.glob("perm-*.json")), "")
check(token, "(리뷰 I3) 버튼이 보일 땐 요청 기록이 이미 있다")
check("권한" in mb.perm(ch, "U2", token, True), "허용 목록 밖은 못 누른다")
r = [mb.perm(ch, "U1", token, True), mb.perm(ch, "U1", token, False)]
check(r[0] == "허용했어" and "이미" in r[1], f"(리뷰 I1) 먼저 누른 것만 — 두 번째는 이미 결정: {r}")
th.join(5)
check((res.get("out") or {}).get("hookSpecificOutput", {}).get("decision", {}).get("behavior") == "allow", f"허용 결정: {res}")
check(any(x["m"] == "PATCH" and x["p"].startswith(f"/channels/{ch}/messages/") for x in log()), "메시지에 결과 표시(버튼 뗌)")
check(not list(sd.glob("perm-*.json")), "요청 기록 지움")
check("없" in mb.perm(ch, "U1", token, True), "이미 끝난 요청")

# 거부
res.clear()
th = threading.Thread(target=lambda: res.update(out=ms.hook_permission(req, wait=5, poll=0.05))); th.start()
for _ in range(50):
    files = list(sd.glob("perm-*.json"))
    if files: break
    time.sleep(0.05)
mb.perm(ch, "U1", json.loads(files[0].read_text())["token"], False)
th.join(5)
dec = (res.get("out") or {}).get("hookSpecificOutput", {}).get("decision", {})
check(dec.get("behavior") == "deny" and dec.get("message"), f"거부 결정 + 이유: {dec}")
# (리뷰 I7) 터미널에서 직접 친 지시면 버튼 대신 원래 권한 창
prompt("터미널에서 친 말")
check(ms.hook_permission(req, wait=0.3, poll=0.05) is None and not list(sd.glob("perm-*")), "터미널 지시는 건너뜀")
prompt(f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="2" user="u">\nfix\n</channel>')
# (리뷰 I6) 허용 목록이 빈 채널(역할로 보이는 사람 누구나)은 권한 승인 못 함
acc = json.loads((sd / "access.json").read_text()); acc2 = json.loads(json.dumps(acc)); acc2["groups"][ch]["allowFrom"] = []
(sd / "access.json").write_text(json.dumps(acc2))
(sd / "perm-aaaaaaaaaaaa.json").write_text(json.dumps({"token": "aaaaaaaaaaaa", "msg": "x"}))
check("권한" in mb.perm(ch, "U9", "aaaaaaaaaaaa", True), "빈 허용 목록이면 승인 거절")
(sd / "access.json").write_text(json.dumps(acc)); (sd / "perm-aaaaaaaaaaaa.json").unlink()
# 시간 초과 → 결정 없음(원래 권한 창으로)
n = len(log())
out = ms.hook_permission(req, wait=0.3, poll=0.05)
check(out is None, f"시간 초과는 결정 없이: {out}")
check(any(x["m"] == "PATCH" for x in log()[n:]), "시간 초과도 메시지 정리")
check(not list(sd.glob("perm-*")), "시간 초과 기록 지움")
# (리뷰 I2) 🛑 로 멈추면 기다리던 권한 요청 버튼도 정리
(sd / "perm-bbbbbbbbbbbb.json").write_text(json.dumps({"token": "bbbbbbbbbbbb", "msg": "PM"}))
n = len(log()); mb.clear_perms(sd, ch)
check(not list(sd.glob("perm-*")) and any(x["m"] == "PATCH" and x["p"].endswith("/messages/PM") for x in log()[n:]), "멈춤 → 권한 버튼 정리")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-perm"
