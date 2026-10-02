#!/usr/bin/env bash
# marina session new — 워크트리 + 채널 + 상태 폴더 + tmux claude 를 한 번에. 겹치면 아무것도 안 만들고,
# 중간에 실패하면 채널·상태 폴더를 되돌리되 워크트리는 남긴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
nposts() { grep -c '"POST"' "$FD/log.jsonl" 2>/dev/null || echo 0; }

# 1) 정상
out="$(msess new proj feat/one --no-start 2>&1)" || fail "new 실패: $out"
WT="$SRC/.claude/worktrees/feat-one"
[ -d "$WT" ] || fail "워크트리 없음"
[ "$(git -C "$WT" branch --show-current)" = "feat/one" ] || fail "워크트리 브랜치"
tmux -L "$MARINA_TMUX_SOCKET" has-session -t =proj-feat-one 2>/dev/null || fail "tmux 세션 없음"
echo "$out" | grep -q "discord.com/channels/G1/" || fail "채널 링크 출력 없음: $out"
for _ in $(seq 50); do ls "$FAKE_OUT"/*/argv >/dev/null 2>&1 && break; sleep 0.1; done   # tmux 안 claude 기동은 비동기

PYTHONPATH="$SCRIPTS" python3 - "$FD" "$WT" "$MARINA_HOME" "$FAKE_OUT" <<'PY'
import json, os, stat, sys
from pathlib import Path
import marina_session as ms
fd, wt, mh, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
posts = [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines() if '"POST"' in l]
cat = ms.load_config()["projects"]["proj"]["categoryId"]
check(posts[0]["b"] == {"name": "PROJ", "type": 4}, "카테고리 생성")
chposts = [x for x in posts if x["b"].get("name") == "feat-one"]
check(chposts and chposts[0]["b"] == {"name": "feat-one", "type": 0, "parent_id": cat}, f"채널 생성: {chposts}")
check(any(x["b"].get("name") == "자료실" and x["b"].get("parent_id") == cat for x in posts), "프로젝트 #자료실 도 깐다")
rec = ms.find_session("proj/feat/one")
check(rec["root"] == str(wt) and rec["tmux"] == "proj-feat-one" and rec["rcName"] == "proj/feat/one", f"기록: {rec}")
sd = Path(rec["stateDir"])
check(sd == ms.state_dir("proj", "feat/one"), "상태 폴더 위치")
check(stat.S_IMODE(sd.stat().st_mode) == 0o700, "상태 폴더 권한 700")
acc = json.loads((sd / "access.json").read_text())
check(acc["dmPolicy"] == "allowlist" and acc["allowFrom"] == [], f"access.json DM 허용자는 비움: {acc}")
check(acc["groups"] == {rec["channelId"]: {"requireMention": False, "allowFrom": ["U1"]}}, "access.json 채널")
check((sd / ".env").is_symlink() and os.readlink(sd / ".env") == str(mh / "token.env"), ".env → 토큰 파일 심링크")
calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
check(argv == ms.claude_argv("proj", "feat/one")[1:], "claude 인자(프로그램 이름 제외)")
env = dict(l.split("=", 1) for l in (calls[-1] / "env").read_text().splitlines() if "=" in l)
check(env.get("DISCORD_STATE_DIR") == str(sd), "DISCORD_STATE_DIR")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY

# 2) 사전 점검 — 같은 이름은 아무것도 안 만든다
before="$(nposts)"
out="$(msess new proj feat/one --no-start 2>&1)" && fail "같은 이름이 성공함"
echo "$out" | grep -q "이미" || fail "겹침 안내 없음: $out"
[ "$(nposts)" = "$before" ] || fail "겹침인데 Discord POST 가 나감"

# 3) Discord 에 같은 이름 채널이 이미 있으면 워크트리도 안 만든다
CAT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["projects"]["proj"]["categoryId"])' "$MARINA_HOME/discord.json")"
curl -s -X POST -H "Authorization: Bot test-token" -H "Content-Type: application/json" \
  -d "{\"name\":\"feat-two\",\"type\":0,\"parent_id\":\"$CAT\"}" "$MARINA_DISCORD_API/guilds/G1/channels" >/dev/null
out="$(msess new proj feat/two --no-start 2>&1)" && fail "채널 겹침이 성공함"
echo "$out" | grep -q "#feat-two" || fail "채널 겹침 안내 없음: $out"
[ ! -e "$SRC/.claude/worktrees/feat-two" ] || fail "채널 겹침인데 워크트리를 만듦"

# 4) 되돌리기 — claude 가 바로 죽으면 채널·상태 폴더 삭제, 워크트리는 남김, 기록 없음
touch "$TMPROOT/claude-fail"
out="$(msess new proj feat/three --no-start 2>&1)" && fail "claude 실패가 성공으로 끝남"
rm -f "$TMPROOT/claude-fail"
echo "$out" | grep -q "워크트리는 남겨" || fail "워크트리 남김 안내 없음: $out"
[ -d "$SRC/.claude/worktrees/feat-three" ] || fail "워크트리를 지움(남겨야 함)"
[ ! -e "$MARINA_CHANNELS_DIR/discord-proj-feat-three" ] || fail "상태 폴더가 남음"
grep -q '"DELETE"' "$FD/log.jsonl" || fail "만든 채널 삭제 요청 없음"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["sessions"]; sys.exit(0 if all(x["task"]!="feat/three" for x in s) else 1)' "$MARINA_HOME/sessions.json" || fail "실패한 세션이 기록됨"

# 5) 미등록 프로젝트
out="$(msess new nope feat/x --no-start 2>&1)" && fail "미등록 프로젝트가 성공함"
echo "$out" | grep -q "discord.json" || fail "프로젝트 추가 안내 없음: $out"

# 6) marina start 실패는 경고만(세션은 연다) — 함수 단위
PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import subprocess, sys
import marina_session as ms
ms.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a, 1, stdout="", stderr="compose 없음")
w = ms.marina_start(ms.Path("/tmp"))
sys.exit(0 if "marina start 실패" in w and "compose 없음" in w else 1)
PY
echo "PASS test-session-new"
