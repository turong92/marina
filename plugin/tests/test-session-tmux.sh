#!/usr/bin/env bash
# marina session — tmux 안에 claude 를 깨끗한 env 로 띄운다.
# Claude 세션 안에서 부르면 CLAUDECODE·CLAUDE_CODE_* 를 물려받아 자식 세션이 되고 기록이 꺼진다(실측 2026-09-10).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
export CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_PLUGIN_ROOT=/x   # Claude 세션 안에서 부른 상황

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$SRC" "$FAKE_OUT" "$TMPROOT" <<'PY'
import os, subprocess, sys, time
from pathlib import Path
import marina_session as ms
src, out, tmproot = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def last_call():
    calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
    return calls[-1] if calls else None

check(os.path.basename(ms._tmux_base()[0]) == "tmux" and ms._tmux_base()[1:] == ["-L", os.environ["MARINA_TMUX_SOCKET"]], "테스트 소켓으로만 tmux 를 부른다")

argv = ms.claude_argv("proj", "feat/one")
check(argv[:5] == ["claude", "--channels", ms.PLUGIN, "--remote-control", "proj/feat/one"], f"인자 앞부분: {argv[:5]}")
check(argv[5] == "--append-system-prompt" and "reply" in argv[6], "채널 규칙")
check("reply_to" in argv[6], "끝 보고는 지시 메시지에 답장으로 단다(✅ 대신 끝 표시, 형 요청)")
check("Skill 도구" in argv[6], "Discord 로 온 /스킬 은 Skill 도구로")
check("AskUserQuestion" not in argv, "개발 세션은 AskUserQuestion 켬(질문이 Discord 버튼으로 뜬다)")
check(ms.claude_argv("proj", "feat/one", resume=True)[:2] == ["claude", "--continue"], "resume → --continue")

ms.tmux_start("proj-feat-one", src, argv, {"DISCORD_STATE_DIR": "/state/x"})
check(ms.tmux_alive("proj-feat-one"), "tmux 세션 살아 있음")
time.sleep(0.3)
call = last_call()
check(call is not None, "가짜 claude 가 실행됨")
if call:
    got = (call / "argv").read_bytes().split(b"\0")[:-1]
    check([a.decode() for a in got] == argv[1:], "claude 가 받은 인자 = claude_argv(프로그램 이름 제외)")
    env = dict(l.split("=", 1) for l in (call / "env").read_text().splitlines() if "=" in l)
    check(env.get("DISCORD_STATE_DIR") == "/state/x", "DISCORD_STATE_DIR 전달")
    check(env.get("TERM") == "xterm-256color", "TERM")
    leaked = sorted(k for k in env if k == "CLAUDECODE" or k.startswith("CLAUDE_CODE_") or k == "CLAUDE_PLUGIN_ROOT")
    check(not leaked, f"자식 세션 표식이 새어 들어감: {leaked}")
    check((call / "cwd").read_text().strip() == str(src.resolve()), "워크트리에서 실행")

ms.tmux_stop("proj-feat-one")
check(not ms.tmux_alive("proj-feat-one"), "tmux_stop 후 꺼짐")
ms.tmux_stop("proj-feat-one")                                   # 없는 세션 정지는 조용히

(tmproot / "claude-fail").touch()
try:
    ms.tmux_start("proj-dies", src, argv, {}); check(False, "바로 죽으면 SessionError")
except ms.SessionError as exc:
    check("꺼졌" in str(exc), f"바로 꺼짐 안내: {exc}")
check(not ms.tmux_alive("proj-dies"), "죽은 세션이 남지 않음")
(tmproot / "claude-fail").unlink()

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-tmux"
