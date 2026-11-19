#!/usr/bin/env bash
# (실사용 2026-11-19 ovation·story-chat) heredoc 경고 권한 창은 줄 끝에 테두리(│)가 붙고 설명도 '│ ' 로 시작한다.
#  카드 제목이 점선(╌╌╌│)으로 나와 무슨 창인지 안 보였고, '2. No │' 라 버튼도 안 달렸다. 형은 몇 시간 동안 몰랐다.
#  - 제목에 설명(dangerous removal)이 나오고 점선은 안 나온다 · 명령 첫 줄이 보인다 · 버튼이 달린다
#  - 10분 넘게 안 풀리면 형을 한 번 부른다(두 번은 안 부른다)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" "$MARINA_HOME" <<'PY'
import json, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fd, mh = Path(sys.argv[1]), Path(sys.argv[2])
c = json.loads((mh / "discord.json").read_text())
c.setdefault("projects", {}).setdefault("proj", {})["allow"] = ["U1"]
(mh / "discord.json").write_text(json.dumps(c))
rec = ms.find_session("proj/feat/a"); ch = rec["channelId"]
base = ms._tmux_base()
screen = "\\n".join([
    "────",
    " Bash command",
    " │ python3 - <<EOF                          │",
    " │ open(p).write(s)                          │",
    " │ EOF                                       │",
    "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌│",
    " │ Claude Code cannot be sure it read this command the way the shell will, so it cannot rule out a dangerous │",
    " │ removal. Read the command, and do not go ahead if you cannot tell what it does.            │",
    "                                             │",
    " Do you want to proceed?                     │",
    " ❯ 1. Yes                                    │",
    "   2. No                                     │",
    "                                             │",
    " Esc to cancel",
]) + "\\n"
subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
subprocess.run(base + ["new-session", "-d", "-x", "200", "-s", rec["tmux"], "sh", "-c", f"printf '{screen}'; exec cat"], check=True)
time.sleep(0.5)
def posts():
    log = fd / "log.jsonl"
    rows = [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []
    return [x for x in rows if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages"]
mb.pane_perm_tick()
ps = posts()
assert len(ps) == 1, f"카드 한 장: {len(ps)}"
body = ps[0]["b"]; title = body["content"].splitlines()[0]
assert "╌" not in body["content"], f"점선이 제목에 나오면 안 된다: {body['content']!r}"
assert "dangerous removal" in body["content"], f"설명이 보여야 한다: {body['content']!r}"
assert "python3 - <<EOF" in body["content"], f"명령 첫 줄이 보여야 한다: {body['content']!r}"
assert body.get("components"), f"평범한 Yes/No 창이라 버튼이 달려야 한다: {body}"
assert "<@" not in body["content"], "처음 카드는 형을 부르지 않는다"
mb.pane_perm_tick()
assert len(posts()) == 1, "같은 창이면 다시 안 올린다"
sd = Path(rec["stateDir"])
f = next(sd.glob("perm-*.json")); d = json.loads(f.read_text()); d["at"] -= mb.PANE_PERM_NUDGE + 5; f.write_text(json.dumps(d))
mb.pane_perm_tick()
ps = posts()
assert len(ps) == 2, f"10분 넘으면 한 번 부른다: {len(ps)}"
assert "<@U1>" in ps[1]["b"]["content"] and ps[1]["b"]["allowed_mentions"].get("users") == ["U1"], f"형 멘션: {ps[1]['b']}"
mb.pane_perm_tick()
assert len(posts()) == 2, "두 번은 안 부른다"
print("PASS")
PY
