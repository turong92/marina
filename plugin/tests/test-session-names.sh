#!/usr/bin/env bash
# marina session — 이름 규칙 · discord.json · sessions.json · 세션 찾기.
# 브랜치 이름이 Discord 채널(소문자·점 불가 취급)·tmux(점·콜론 불가)·워크트리 폴더로 갈라지는 규칙을 고정한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$SRC" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
src = sys.argv[1]
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def raises(fn, needle):
    try: fn()
    except ms.SessionError as exc: return needle in str(exc)
    return False

check(ms.channel_name("feature/Fix.Login") == "feature-fix-login", "채널 이름: 소문자 + /. → -")
check(ms.worktree_dirname("feature/Fix.Login") == "feature-Fix.Login", "워크트리 폴더: 기존 규칙(/: → -) 그대로")
check(ms.tmux_name("proj", "feature/Fix.Login") == "proj-feature-fix-login", "tmux 이름에 점 없음")
check(ms.rc_name("proj", "feature/x") == "proj/feature/x", "Remote Control 이름")
check(ms.state_dir("proj", "feature/x") == Path(os.environ["MARINA_CHANNELS_DIR"]) / "discord-proj-feature-x", "상태 폴더 위치")
check(raises(lambda: ms.channel_name("a b"), "작업 이름"), "공백 거부")
check(raises(lambda: ms.channel_name("a..b"), "작업 이름"), "'..' 거부")

cfg = ms.load_config()
check(cfg["guildId"] == "G1", "discord.json 읽기")
check(ms.project_config(cfg, "proj")["allow"] == ["U1"], "프로젝트 설정")
check(raises(lambda: ms.project_config(cfg, "nope"), "nope"), "미등록 프로젝트 거부")
check(ms.read_token(cfg) == "test-token", "토큰 읽기")
check(ms.project_root("proj") == Path(os.path.realpath(src)), "projects.json 에서 root")
check(raises(lambda: ms.project_root("nope"), "등록되지 않은"), "미등록 프로젝트 root 거부")

Path(ms.token_file(cfg)).write_text("OTHER=1\n")
check(raises(lambda: ms.read_token(cfg), "DISCORD_BOT_TOKEN"), "토큰 줄 없음 거부")
ms.config_path().rename(ms.config_path().with_suffix(".bak"))
check(raises(ms.load_config, "discord.json"), "설정 없음 → 만드는 법 안내")
ms.config_path().with_suffix(".bak").rename(ms.config_path())

check(ms.load_sessions() == [], "기록 없음 → 빈 목록")
ms.sessions_path().write_text("{broken")
check(ms.load_sessions() == [], "기록 깨짐 → 빈 목록(예외 없음)")
items = [{"project": "proj", "task": "feature/x"}, {"project": "proj2", "task": "feature/x"}, {"project": "proj", "task": "solo"}]
ms.save_sessions(items)
check(ms.load_sessions() == items, "기록 저장·읽기 왕복")
check(ms.find_session("solo")["project"] == "proj", "작업 이름으로 찾기")
check(ms.find_session("proj2/feature/x")["project"] == "proj2", "프로젝트/작업으로 찾기(작업에 슬래시)")
check(raises(lambda: ms.find_session("feature/x"), "모호"), "두 프로젝트에 같은 작업 → 모호")
check(raises(lambda: ms.find_session("none"), "찾지 못했"), "없는 세션")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-names"
