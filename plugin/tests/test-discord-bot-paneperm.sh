#!/usr/bin/env bash
# (실사용 2026-10-04) 서브에이전트의 권한 창은 PermissionRequest 버튼이 안 와서 ovation 이 아무도 모른 채 터미널에서 멈췄다
#  → 봇이 화면의 권한 창을 보면 채널에 [허용][거부] — 누르면 화면이 그대로일 때만 Enter/Esc. 터미널에서 먼저 풀리면 버튼을 거둔다
#  - 명령 원문(│ 줄)은 안 보낸다 · 훅이 이미 버튼을 올린 요청이면 겹쳐 올리지 않는다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$SCRIPTS" python3 - "$FD" <<'PY'
import json, subprocess, sys, time
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
base = ms._tmux_base()
def pane(text):
    subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
    subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", f"printf '{text}'; exec cat"], check=True)
    time.sleep(0.5)
PROMPT = ("────\\n Bash command · from the general-purpose agent\\n Regenerate all shots\\n"
          " │ rm -rf $O/raw --token=abc\\n Do you want to proceed?\\n ❯ 1. Yes\\n   2. No\\n Esc to cancel\\n")
keys = []; targets = []
real = ms._tmux
def spy(*a):
    if a and a[0] == "send-keys" and "-X" not in a:
        keys.append(a[-1]); targets.append(a[a.index("-t") + 1]); return subprocess.CompletedProcess(a, 0, "", "")
    return real(*a)
ms._tmux = spy
def posts():
    return [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages"]
def perm_files():
    return [json.loads(p.read_text()) for p in sd.glob("perm-*.json")]

pane(PROMPT)
mb.pane_perm_tick()
ps = posts()
body = json.dumps(ps[-1]["b"], ensure_ascii=False) if ps else ""
check(len(ps) == 1 and "mperm:a:" in body and "Regenerate all shots" in body, f"권한 창 → 버튼: {body}")
check("rm -rf $O/raw" in body and "abc" not in body, f"(리뷰 C2) 명령 앞부분은 보이되 비밀은 가린다: {body}")
mb.pane_perm_tick()
check(len(posts()) == 1, "같은 창이면 한 번만")
tok = perm_files()[0]["token"] if perm_files() else ""
check("허용" in mb.perm(ch, "U1", tok, True) and keys == ["Enter"], f"허용 → Enter: {keys}")
check(targets == [f"={rec['tmux']}:"], f"(리뷰 I3) 정확한 세션 이름으로: {targets}")
check(perm_files() == [], "끝나면 기록 정리")
check(any(x["m"] == "PATCH" for x in log()), "버튼 거둠")

# 화면이 바뀐 뒤 누르면 아무것도 안 친다
keys.clear(); pane(PROMPT.replace("Regenerate", "Build")); mb.pane_perm_tick()
tok = perm_files()[0]["token"]
pane(PROMPT.replace("Regenerate", "Delete"))
r = mb.perm(ch, "U1", tok, True)
check(keys == [] and "바뀌" in r, f"다른 창이면 안 누른다: {r} {keys}")
# 거부 → Esc
mb.pane_perm_tick(); tok = perm_files()[0]["token"]
check("거부" in mb.perm(ch, "U1", tok, False) and keys == ["Escape"], f"거부 → Esc: {keys}")
# 터미널에서 먼저 풀리면 버튼을 거둔다
pane(PROMPT); mb.pane_perm_tick(); n = len([x for x in log() if x["m"] == "PATCH"])
pane("✻ Worked\\n────\\n❯ \\n────\\n"); mb.pane_perm_tick()
check(perm_files() == [] and len([x for x in log() if x["m"] == "PATCH"]) == n + 1, "풀리면 정리")
# (리뷰 C1) 1번이 평범한 Yes 가 아닌 창(영구 허용·폴더 신뢰 등)은 버튼 없이 알림만, Enter 는 절대 안 친다
keys.clear()
pane("────\\n Bash command\\n Do you want to proceed?\\n ❯ 1. Yes, and don\\x27t ask again for npm commands\\n   2. No\\n")
mb.pane_perm_tick()
last = json.dumps(posts()[-1]["b"], ensure_ascii=False)
check("mperm:" not in last and "터미널" in last, f"선택지가 다르면 버튼 없음: {last}")
for d in perm_files():
    check("권한 창이 아니" in mb.perm(ch, "U1", d["token"], True) or keys == [], f"눌러도 안 친다: {keys}")
check(keys == [], f"Enter 안 감: {keys}")
pane("✻ Worked\\n────\\n❯ \\n────\\n"); mb.pane_perm_tick()
# (리뷰 I6) 버튼 올리기 실패 → 다음 판에 다시
real_dc = mb._dc
class Boom:
    def _req(self, *a, **k): raise ms.SessionError("down")
mb._dc = lambda cfg: Boom()
pane(PROMPT); mb.pane_perm_tick(); mb._dc = real_dc
c = len(posts()); mb.pane_perm_tick()
check(len(posts()) == c + 1, "실패한 게시는 다시 올린다")
# (리뷰 I5) 오래된 버튼(같은 명령이 다시 떠도 예전 버튼)은 안 먹는다
d = perm_files()[0]; f = sd / f"perm-{d['token']}.json"; f.write_text(json.dumps(dict(d, at=time.time() - 3600)))
keys.clear()
check("오래" in mb.perm(ch, "U1", d["token"], True) and keys == [], f"오래된 버튼: {keys}")
pane("✻ Worked\\n────\\n❯ \\n────\\n"); mb.pane_perm_tick()
# 훅이 이미 올린 요청(본 세션 권한 창)이면 겹쳐 올리지 않는다
(sd / "perm-aaaaaaaaaaaa.json").write_text(json.dumps({"token": "aaaaaaaaaaaa", "msg": "1"}))
pane(PROMPT); c = len(posts()); mb.pane_perm_tick()
check(len(posts()) == c, "훅 요청과 겹치지 않는다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-bot-paneperm"
