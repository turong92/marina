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
grep -q "/messages/M1/reactions/%E2%9C%85" "$FD/log.jsonl" && fail "처음엔 마지막 것만(옛 메시지에 몰아서 ✅ 하지 않는다)"

# 연달아 온 메시지(M3·M4)를 한 턴에 처리 → 둘 다 ✅, 이미 ✅ 한 M2 는 다시 안 건드림(2026-10-01 실사용)
python3 - "$TMPROOT/t.jsonl" "$CH" <<'PY2'
import json, sys
def line(cid, mid):
    text = f'<channel source="plugin:discord:discord" chat_id="{cid}" message_id="{mid}" user="u" ts="t">\nhi\n</channel>'
    return json.dumps({"type": "user", "message": {"role": "user", "content": text}})
def tag(cid, mid):
    return f'<channel source="plugin:discord:discord" chat_id="{cid}" message_id="{mid}" user="u" ts="t">\nhi\n</channel>'
ch = sys.argv[2]
rows = [
    # 처리 중 끼어든 메시지는 attachment(queued_command) 로 남는다(실측)
    {"type": "queue-operation", "operation": "enqueue", "content": tag(ch, "M3")},
    {"type": "attachment", "attachment": {"type": "queued_command", "prompt": tag(ch, "M3")}},
    json.loads(line(ch, "M4")),
    # 도착만 하고 아직 안 읽은 메시지 — ✅ 하면 안 된다
    {"type": "queue-operation", "operation": "enqueue", "content": tag(ch, "M5")},
]
open(sys.argv[1], "a").write("".join(json.dumps(r) + "\n" for r in rows))
PY2
before="$(grep -c "/messages/M2/reactions/%E2%9C%85" "$FD/log.jsonl")"
printf '{"cwd":"%s","transcript_path":"%s"}' "$SRC" "$TMPROOT/t.jsonl" | hook "$SD" || fail "두 번째 훅 실패"
for m in M3 M4; do
  grep -q "\"PUT\", \"p\": \"/channels/$CH/messages/$m/reactions/%E2%9C%85/@me\"" "$FD/log.jsonl" || fail "$m 에 ✅ 없음(연달아 온 메시지)"
  grep -q "\"DELETE\", \"p\": \"/channels/$CH/messages/$m/reactions/%F0%9F%91%80/@me\"" "$FD/log.jsonl" || fail "$m 👀 제거 없음"
done
[ "$(grep -c "/messages/M2/reactions/%E2%9C%85" "$FD/log.jsonl")" = "$before" ] || fail "이미 ✅ 한 M2 를 다시 건드림"
grep -q "/messages/M5/reactions/%E2%9C%85" "$FD/log.jsonl" && fail "아직 안 읽은 M5(대기열만)에 ✅"

# 지워진 메시지(404)가 끼어 있어도 나머지는 ✅, 표시는 앞으로 간다(실사용: "1" 을 지웠더니 이후 ✅ 가 전부 멈춤)
python3 - "$TMPROOT/t.jsonl" "$CH" <<'PY2'
import json, sys
t = lambda m: f'<channel source="plugin:discord:discord" chat_id="{sys.argv[2]}" message_id="{m}" user="u" ts="t">\nhi\n</channel>'
open(sys.argv[1], "a").write("".join(json.dumps({"type": "user", "message": {"role": "user", "content": t(m)}}) + "\n" for m in ("M6", "M7")))
PY2
echo "M6" > "$FD/gone"
printf '{"cwd":"%s","transcript_path":"%s"}' "$SRC" "$TMPROOT/t.jsonl" | hook "$SD" || fail "지워진 메시지에서 실패 코드"
grep -q "\"PUT\", \"p\": \"/channels/$CH/messages/M7/reactions/%E2%9C%85/@me\"" "$FD/log.jsonl" || fail "지워진 M6 뒤의 M7 에 ✅ 없음"
[ "$(cat "$SD/acked")" = "M7" ] || fail "✅ 표시가 앞으로 안 감: $(cat "$SD/acked")"

n="$(wc -l < "$FD/log.jsonl")"
printf '{"cwd":"/nowhere","transcript_path":"%s"}' "$TMPROOT/t.jsonl" | hook "/no/such/state" || fail "모르는 세션에서 실패 코드"
printf 'not json' | hook "$SD" || fail "깨진 입력에서 실패 코드"
printf '{"cwd":"%s","transcript_path":"/no/file"}' "$SRC" | hook "$SD" || fail "기록 파일 없음에서 실패 코드"
[ "$(wc -l < "$FD/log.jsonl")" = "$n" ] || fail "할 일 없는 훅이 Discord 를 불렀음"
mv "$MARINA_HOME/discord.json" "$MARINA_HOME/discord.json.bak"
printf '{"cwd":"%s","transcript_path":"%s"}' "$SRC" "$TMPROOT/t.jsonl" | hook "$SD" || fail "설정 없음에서 실패 코드"
mv "$MARINA_HOME/discord.json.bak" "$MARINA_HOME/discord.json"
echo "PASS test-session-status-hook"
