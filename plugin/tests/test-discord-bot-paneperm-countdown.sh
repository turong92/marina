#!/usr/bin/env bash
# (실사용 2026-10-30 interactions-review) 권한 창에 '… automatically block this request in 0:55' 초읽기가 붙자
#  서명이 매초 바뀌어 카드를 닫고 새로 올리기를 반복했고(1분에 17개), 버튼은 '화면이 바뀌어서 안 눌렀어'로 안 먹었다
#  - 초읽기가 달라도 같은 창이다 · 제목에 초읽기 줄을 넣지 않는다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
import json, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fd = Path(sys.argv[1])
rec = ms.find_session("proj/feat/a"); ch = rec["channelId"]
base = ms._tmux_base()
def pane(text):
    subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
    subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", f"printf '{text}'; exec cat"], check=True)
    time.sleep(0.5)
def prompt(left):
    return ("────\\n Edit file\\n docs/handoff/review.md\\n"
            f" ⚠ Claude Code will automatically block this request in {left}, to avoid holding up an unattended session\\n"
            " Do you want to make this edit?\\n ❯ 1. Yes\\n   2. No\\n Esc to cancel\\n")
def posts():
    log = fd / "log.jsonl"
    rows = [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []
    return [x for x in rows if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages"]
pane(prompt("0:55")); first = mb._pane_prompt(rec["tmux"]); mb.pane_perm_tick()
pane(prompt("0:46")); second = mb._pane_prompt(rec["tmux"]); mb.pane_perm_tick()
assert first and second and first[0] == second[0], "초읽기만 다르면 서명이 같아야 한다"
assert len(posts()) == 1, f"같은 창은 카드 한 장: {len(posts())}"
assert "automatically block" not in posts()[0]["b"]["content"], "제목에 초읽기 줄이 들어가면 안 된다"
print("PASS")
PY
