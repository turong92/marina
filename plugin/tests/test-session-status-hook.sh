#!/usr/bin/env bash
# 작업 중/끝남을 Claude 판단이 아니라 훅으로 기계적으로 보인다: 플러그인이 받은 메시지에 👀, Stop 훅이 턴 끝에 👀→✅.
# 훅은 어떤 실패에도 세션을 방해하지 않는다(항상 exit 0).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }

PYTHONPATH="$SCRIPTS" python3 - "$TMPROOT" "$SRC" <<'PY'
import json, sys
from pathlib import Path
import marina_session as ms
tmp, src = Path(sys.argv[1]), Path(sys.argv[2])
cfg = ms.load_config(); dc = ms.Discord("test-token")
cat = ms.ensure_category(dc, cfg, "proj"); ch = dc.create_text_channel("G1", "st", cat)
sd = ms.state_dir("proj", "st"); ms.write_state_dir(sd, ch, ["U1"], ms.token_file(cfg))
f = ms.write_settings(sd)
s = json.loads(f.read_text())
assert f == sd / "settings.json"
assert "hook-stop" in s["hooks"]["Stop"][0]["hooks"][0]["command"], s
assert s["enabledPlugins"] == {"discord@claude-plugins-official": True}, s
argv = ms.claude_argv("proj", "st")
i = argv.index("--settings")
assert argv[i + 1] == str(sd / "settings.json") and argv[-2:] == ["--disallowedTools", "AskUserQuestion"], argv
env = ms.session_env(sd)
assert env["DISCORD_STATE_DIR"] == str(sd) and env["MARINA_HOME"] == str(ms.marina_home()), env
ms.save_sessions([{"project": "proj", "task": "st", "root": str(src), "channelId": ch, "tmux": "proj-st",
                   "stateDir": str(sd), "rcName": "proj/st", "createdAt": 0}])
# 세션 기록(jsonl): 다른 채널 메시지 → 이 채널 M1 → 이 채널 M2. JSON 안이라 따옴표가 \" 로 이스케이프된다.
def line(cid, mid):
    text = f'<channel source="plugin:discord:discord" chat_id="{cid}" message_id="{mid}" user="u" ts="t">\nhi\n</channel>'
    return json.dumps({"type": "user", "message": {"role": "user", "content": text}})
(tmp / "t.jsonl").write_text("\n".join([line("999", "MX"), line(ch, "M1"), line(ch, "M2")]) + "\n")
(tmp / "chan").write_text(ch); (tmp / "sd").write_text(str(sd))
PY
CH="$(cat "$TMPROOT/chan")"; SD="$(cat "$TMPROOT/sd")"
hook() { DISCORD_STATE_DIR="$1" PYTHONPATH="$SCRIPTS" python3 "$SCRIPTS/marina_session.py" hook-stop; }

printf '{"cwd":"%s","transcript_path":"%s"}' "$SRC" "$TMPROOT/t.jsonl" | hook "$SD" || fail "훅이 0 이 아닌 코드로 끝남"
grep -q "\"PUT\", \"p\": \"/channels/$CH/messages/M2/reactions/%E2%9C%85/@me\"" "$FD/log.jsonl" || fail "마지막 메시지(M2)에 ✅ 추가 요청 없음"
grep -q "\"DELETE\", \"p\": \"/channels/$CH/messages/M2/reactions/%F0%9F%91%80/@me\"" "$FD/log.jsonl" || fail "👀 제거 요청 없음"
grep -q "/messages/MX/" "$FD/log.jsonl" && fail "다른 채널 메시지에 반응함"

n="$(wc -l < "$FD/log.jsonl")"
printf '{"cwd":"/nowhere","transcript_path":"%s"}' "$TMPROOT/t.jsonl" | hook "/no/such/state" || fail "모르는 세션에서 실패 코드"
printf 'not json' | hook "$SD" || fail "깨진 입력에서 실패 코드"
printf '{"cwd":"%s","transcript_path":"/no/file"}' "$SRC" | hook "$SD" || fail "기록 파일 없음에서 실패 코드"
[ "$(wc -l < "$FD/log.jsonl")" = "$n" ] || fail "할 일 없는 훅이 Discord 를 불렀음"
mv "$MARINA_HOME/discord.json" "$MARINA_HOME/discord.json.bak"
printf '{"cwd":"%s","transcript_path":"%s"}' "$SRC" "$TMPROOT/t.jsonl" | hook "$SD" || fail "설정 없음에서 실패 코드"
mv "$MARINA_HOME/discord.json.bak" "$MARINA_HOME/discord.json"
echo "PASS test-session-status-hook"
