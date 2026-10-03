#!/usr/bin/env bash
# 봇 1(슬래시 자동완성): Discord 에서 '/' 치면 뜨는 명령 — /compact · /model · /effort · /stop · /skill(이름 자동완성)
#  - compact·model·effort 는 쉬는 순간 입력창에 그대로, 스킬은 '[Discord 슬래시] /이름 인자' 로 쳐서 Claude 가 Skill 도구로
#  - 스킬 목록 = 사용자·플러그인(설치 목록의 installPath)·프로젝트(.claude/skills·commands)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"
CH="$TMPROOT/claudehome"; mkdir -p "$CH/skills/aside-browser" "$CH/commands" "$CH/plugins/cache/m/sp/1/skills/brainstorming" "$CH/plugins/cache/m/sp/1/commands"
touch "$CH/skills/aside-browser/SKILL.md" "$CH/commands/standup.md" "$CH/plugins/cache/m/sp/1/skills/brainstorming/SKILL.md" "$CH/plugins/cache/m/sp/1/commands/plan.md"
printf '{"version":2,"plugins":{"superpowers@m":[{"installPath":"%s"}]}}\n' "$CH/plugins/cache/m/sp/1" > "$CH/plugins/installed_plugins.json"
export MARINA_CLAUDE_HOME="$CH"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
rec = ms.find_session("proj/feat/a"); ch = rec["channelId"]
root = Path(rec["root"]); (root / ".claude/skills/deploy").mkdir(parents=True); (root / ".claude/skills/deploy/SKILL.md").touch()

names = mb.list_skills(rec)
check({"aside-browser", "standup", "superpowers:brainstorming", "superpowers:plan", "deploy"} <= set(names), f"스킬 목록: {names}")
check(mb.list_skills(rec, "brain") == ["superpowers:brainstorming"], f"자동완성 거르기: {mb.list_skills(rec, 'brain')}")
check(len(mb.list_skills(rec, "")) <= 25, "Discord 자동완성 최대 25")

typed = []; mids = []
mb._spawn_type = lambda tmux, text, channel, mid, button="": (typed.append(text), mids.append(mid))
check("권한" in mb.slash(ch, "U2", "compact"), "허용 목록 밖은 못 씀")
mb.slash(ch, "U1", "compact"); mb.slash(ch, "U1", "model", "opus"); mb.slash(ch, "U1", "effort", "high")
check(typed == ["/compact", "/model opus", "/effort high"], f"기본 명령은 그대로: {typed}")
typed.clear()
check("못" in mb.slash(ch, "U1", "model", "a; rm") and not typed, "인자 검사")
mb.slash(ch, "U1", "skill", "superpowers:brainstorming", "새 기능 아이디어")
check(typed == ["[Discord 슬래시] /superpowers:brainstorming 새 기능 아이디어"], f"스킬은 표시 붙여 입력: {typed}")
log = [json.loads(l) for l in (Path(sys.argv[1]) / "log.jsonl").read_text().splitlines()]
post = [x for x in log if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages" and "brainstorming" in json.dumps(x["b"], ensure_ascii=False)]
check(post and mids[-1] == "m-sent", f"(실사용) 보낸 명령이 채널에 보이고, 그 메시지에 ⚙️→✅ 가 붙는다: {post} {mids}")
typed.clear()
check("없는" in mb.slash(ch, "U1", "skill", "nope") and not typed, "없는 스킬 거절")
n = len(json.loads("[" + ",".join((Path(sys.argv[1]) / "log.jsonl").read_text().splitlines()) + "]"))
mids.clear(); mb.slash(ch, "U1", "compact", message="REPLY1")
log2 = [json.loads(l) for l in (Path(sys.argv[1]) / "log.jsonl").read_text().splitlines()][n:]
check(mids == ["REPLY1"] and not any(x["m"] == "POST" for x in log2), "봇 공개 답(명령 응답)이 있으면 거기에 표시 — 따로 안 올림")
check("[Discord 슬래시]" in ms.CHANNEL_RULES, "규칙: 슬래시 입력은 Skill 도구 + Discord 로 답")
check(mb.typeable("[Discord 슬래시] /x y") and mb.typeable("/compact") and not mb.typeable("rm -rf ~"), "(리뷰 M6) type 이 받는 글")
check(mb.type_timeout("[Discord 추천 버튼] a") == 120 and mb.type_timeout("[Discord 슬래시] /x") == 1800 and mb.type_timeout("/compact") == 1800,
      "(리뷰 I5) 슬래시·명령은 오래 바빠도 기다리고, 추천은 금방 포기")
recs = ms.load_sessions(); ms.save_sessions([dict(x, kind="chat") for x in recs])
check("안 받아" in mb.slash(ch, "U1", "compact"), "채팅방은 슬래시 안 받음"); ms.save_sessions(recs)
check(mb.SLASH_COMMANDS and {c["name"] for c in mb.SLASH_COMMANDS} == {"compact", "model", "effort", "stop", "skill"}, "등록할 명령")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-slash"
