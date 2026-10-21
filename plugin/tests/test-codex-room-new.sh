#!/usr/bin/env bash
# 코덱스 방 만들기·띄우기(kind codex) — chat-bot 카테고리 + tmux 안 codex. 클로드 방 경로는 test-session-new 가 지킨다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
nposts() { grep -c '"POST"' "$FD/log.jsonl" 2>/dev/null || echo 0; }
export CODEX_HOME="$TMPROOT/real-codex-home-must-not-be-used"      # 실 계정 폴더를 못 읽게 — 계정 폴더는 $MARINA_HOME/accounts/codex-b
wait_call() { for _ in $(seq 60); do ls "$FAKE_CODEX_OUT"/*/argv >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }

# 1) 계정 폴더(auth.json)가 없으면 아무것도 안 만든다
before="$(nposts)"
out="$(msess new proj feat/cx --codex --no-start 2>&1)" && fail "auth.json 없이 성공함"
echo "$out" | grep -q "auth.json" || fail "auth.json 안내 없음: $out"
[ "$(nposts)" = "$before" ] || fail "auth.json 없는데 Discord POST 가 나감"
[ ! -e "$SRC/.claude/worktrees/feat-cx" ] || fail "auth.json 없는데 워크트리를 만듦"

# 2) 정상
mkdir -p "$MARINA_HOME/accounts/codex-b"; echo '{"tokens":{"x":1}}' > "$MARINA_HOME/accounts/codex-b/auth.json"
out="$(msess new proj feat/cx --codex --no-start 2>&1)" || fail "new --codex 실패: $out"
WT="$SRC/.claude/worktrees/feat-cx"
[ -d "$WT" ] || fail "워크트리 없음"
echo "$out" | grep -q "discord.com/channels/G1/" || fail "채널 링크 출력 없음: $out"
wait_call || fail "가짜 codex 가 안 떴다"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" "$WT" "$MARINA_HOME" "$FAKE_CODEX_OUT" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
import marina_codex as mc
fd, wt, mh, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
posts = [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines() if '"POST"' in l]
cats = [x for x in posts if x["b"].get("type") == 4]
check(len(cats) == 1 and cats[0]["b"] == {"name": "chat-bot", "type": 4}, f"chat-bot 카테고리 생성 1회: {cats}")
cfg = json.loads((mh / "discord.json").read_text())
cat = (cfg.get("codex") or {}).get("categoryId")
check(bool(cat), f"discord.json.codex.categoryId 저장: {cfg.get('codex')}")
check(cfg["projects"]["proj"].get("categoryId") is None, "프로젝트 카테고리는 안 만든다(코덱스 방은 chat-bot 에)")
chposts = [x for x in posts if x["b"].get("name") == "feat-cx"]
check(chposts and chposts[0]["b"].get("parent_id") == cat and chposts[0]["b"].get("type") == 0, f"채널은 chat-bot 카테고리 아래: {chposts}")
rec = ms.find_session("proj/feat/cx")
check(rec.get("kind") == "codex" and rec.get("codexAccount") == "b", f"기록 kind/codexAccount: {rec}")
check("sessionId" not in rec, "sessionId 는 사후 확보 — 처음엔 없다")
check(rec["root"] == str(wt) and rec["tmux"] == "proj-feat-cx", f"기록: {rec}")
sd = Path(rec["stateDir"])
calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
check(argv == mc.codex_argv(rec)[1:], f"codex 인자: {argv}")
check("resume" not in argv, "처음엔 resume 없음")
check(argv[argv.index("-a") + 1] == "never", "승인 정책 never")
check("check_for_update_on_startup=false" in argv, "업데이트 확인 끔")
check("--dangerously-bypass-hook-trust" in argv, "훅 신뢰 확인 창 끔")
check(any(a.startswith("projects={") and str(wt) in a and "trusted" in a for a in argv), "폴더 신뢰 -c")
check(any(a.startswith("mcp_servers.marina={") and "mcp-chat" in a and str(sd) in a for a in argv), "marina MCP -c (env 칸에 상태 폴더)")
check(any(a.startswith("developer_instructions=") and "mcp__marina__reply" in a for a in argv), "시스템 프롬프트 -c")
env = dict(l.split("=", 1) for l in (calls[-1] / "env").read_text().splitlines() if "=" in l)
check(env.get("CODEX_HOME") == str(mh / "accounts" / "codex-b"), f"CODEX_HOME: {env.get('CODEX_HOME')}")
check(env.get("DISCORD_STATE_DIR") == str(sd), "DISCORD_STATE_DIR")
check("CLAUDE_CODE_OAUTH_TOKEN" not in env and "MARINA_ACCOUNT_TOKEN_FILE" not in env, "클로드 토큰 변수 없음")
check((sd / "account-running").read_text().strip() == "b", "account-running == b")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY

# 3) 같은 이름 채널이 chat-bot 카테고리에 이미 있으면 워크트리도 안 만든다
CAT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["codex"]["categoryId"])' "$MARINA_HOME/discord.json")"
curl -s -X POST -H "Authorization: Bot test-token" -H "Content-Type: application/json" \
  -d "{\"name\":\"feat-dup\",\"type\":0,\"parent_id\":\"$CAT\"}" "$MARINA_DISCORD_API/guilds/G1/channels" >/dev/null
before="$(nposts)"
out="$(msess new proj feat/dup --codex --no-start 2>&1)" && fail "채널 겹침이 성공함"
echo "$out" | grep -q "이미" || fail "채널 겹침 안내 없음: $out"
[ ! -e "$SRC/.claude/worktrees/feat-dup" ] || fail "채널 겹침인데 워크트리를 만듦"
[ "$(nposts)" = "$before" ] || fail "채널 겹침인데 Discord POST 가 나감"

# 4) stop → start: sessionId 가 없으니 resume 없이 새로 띄운다
msess stop proj/feat/cx >/dev/null 2>&1 || fail "stop 실패"
rm -rf "${FAKE_CODEX_OUT:?}"/*
msess start proj/feat/cx >/dev/null 2>&1 || fail "start 실패"
wait_call || fail "start 후 가짜 codex 가 안 떴다"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FAKE_CODEX_OUT" <<'PY' || fail "start 인자 / resume 규칙"
import sys
from pathlib import Path
import marina_session as ms
import marina_codex as mc
out = Path(sys.argv[1])
calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
rec = ms.find_session("proj/feat/cx")
ok = argv == mc.codex_argv(rec, resume=True)[1:] and "resume" not in argv
# sessionId 가 있으면 resume <sid> 로 잇는다(Task 2·5 가 sid 를 적는다)
a2 = mc.codex_argv(dict(rec, sessionId="01a15df6-ad2d-74f3-a376-1093930d23a9"), resume=True, first="이어서")
ok = ok and a2[:3] == ["codex", "resume", "01a15df6-ad2d-74f3-a376-1093930d23a9"] and a2[-1] == "이어서"
a3 = mc.codex_argv(dict(rec, sessionId="01a15df6-ad2d-74f3-a376-1093930d23a9"), resume=False)
ok = ok and "resume" not in a3
sys.exit(0 if ok else 1)
PY
msess stop proj/feat/cx >/dev/null 2>&1

# 5) 막는 화면(PANE_BLOCKING)이 남으면 실패로 올리고 tmux 를 내린다 — 조용히 입력을 삼키는 방을 만들지 않는다
msess rm proj/feat/cx >/dev/null 2>&1 || true
echo "Do you trust the contents of this directory? Press enter to continue" > "$TMPROOT/codex-block"
out="$(MARINA_SESSION_BOOT_WAIT=1 msess new proj feat/blk --codex --no-start 2>&1)" && fail "막는 화면인데 성공함"
echo "$out" | grep -q "Do you trust the contents" || fail "막는 화면 문구가 안내에 없음: $out"
tmux -L "$MARINA_TMUX_SOCKET" has-session -t =proj-feat-blk 2>/dev/null && fail "막힌 tmux 가 남음"
rm -f "$TMPROOT/codex-block"
# 6) 입력창이 떠 있으면, 화면에 막는 문구가 (resume 으로 다시 그려진 지난 대화처럼) 남아 있어도 멀쩡한 방이다
printf 'Update available in an old chat\n› Use /skills to list available skills\n' > "$TMPROOT/codex-block"
out="$(MARINA_SESSION_BOOT_WAIT=1 msess new proj feat/hist --codex --no-start 2>&1)" || fail "입력창이 있는데 막힌 방으로 봤다: $out"
tmux -L "$MARINA_TMUX_SOCKET" has-session -t =proj-feat-hist 2>/dev/null || fail "멀쩡한 방을 내렸다"
rm -f "$TMPROOT/codex-block"

# 7) 처음 new --codex 로 띄운 방의 mcp-chat 은 기록이 아직 없어도(표식 env 만으로) Discord 도구 다섯을 낸다
mcp_env="$(PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 -c 'import marina_codex as mc; from pathlib import Path; print(mc._mcp_env(Path("/nowhere/sd"))["MARINA_ROOM_KIND"])')"
[ "$mcp_env" = "codex" ] || fail "MCP env 칸에 방 종류 표식이 없다"
names="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | DISCORD_STATE_DIR=/nowhere/sd MARINA_ROOM_KIND=codex bash "$MARINA_SH" session mcp-chat | python3 -c 'import sys,json; print(" ".join(sorted(t["name"] for t in [json.loads(l) for l in sys.stdin][1]["result"]["tools"])))')"
for n in reply react edit_message fetch_messages download_attachment; do case " $names " in *" $n "*) ;; *) fail "기록 없는 mcp-chat 에 $n 이 없다: $names";; esac; done
echo "PASS test-codex-room-new"
