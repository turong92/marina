#!/usr/bin/env bash
# marina session ls/start/stop/rm — 꺼진 세션은 --continue 로 이어 띄우고, rm 은 tmux·채널·상태 폴더·기록을 지운다
# (워크트리는 그대로). 두 프로젝트에 같은 작업 이름이면 <프로젝트>/<작업> 으로만 지정된다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
alive() { tmux -L "$MARINA_TMUX_SOCKET" has-session -t "=$1" 2>/dev/null; }
lsjson() { msess ls --json | python3 -c "import json,sys; r={f\"{s['project']}/{s['task']}\": s for s in json.load(sys.stdin)}; print(json.dumps(r.get(sys.argv[1], {}).get(sys.argv[2])))" "$1" "$2"; }

msess new proj feat/one --no-start >/dev/null 2>&1 || fail "new"
[ "$(lsjson proj/feat/one alive)" = "true" ] || fail "ls: 켜짐"
[ "$(lsjson proj/feat/one channel)" = "true" ] || fail "ls: 채널 있음"
msess ls | grep -q "proj/feat/one" || fail "ls 사람용 출력"

msess stop feat/one >/dev/null || fail "stop"
alive proj-feat-one && fail "stop 후에도 살아 있음"
[ "$(lsjson proj/feat/one alive)" = "false" ] || fail "ls: 꺼짐"

n0="$(ls "$FAKE_OUT" | wc -l)"
msess start feat/one >/dev/null || fail "start"
alive proj-feat-one || fail "start 후 꺼져 있음"
for _ in $(seq 50); do [ "$(ls "$FAKE_OUT" | wc -l)" -gt "$n0" ] && [ -s "$FAKE_OUT/$(ls -t "$FAKE_OUT" | head -1)/argv" ] && break; sleep 0.1; done   # 기동은 비동기
last="$(ls -t "$FAKE_OUT" | head -1)"
python3 -c 'import sys; a=open(sys.argv[1],"rb").read().split(b"\0"); sys.exit(0 if a[0]==b"--continue" else 1)' "$FAKE_OUT/$last/argv" || fail "start 는 --continue 로 이어야 함"

msess stop feat/one >/dev/null; msess start --all >/dev/null || fail "start --all"
alive proj-feat-one || fail "start --all 후 꺼져 있음"

# Discord 에서 채널을 직접 지운 경우
CH="$(lsjson proj/feat/one channelId | tr -d '"')"
curl -s -X DELETE -H "Authorization: Bot test-token" "$MARINA_DISCORD_API/channels/$CH" >/dev/null
[ "$(lsjson proj/feat/one channel)" = "false" ] || fail "ls: 채널 없음 표시"

# 두 번째 프로젝트에 같은 작업 이름
SRC2="$TMPROOT/proj2"; gi "$SRC2"
python3 - "$MARINA_HOME" "$SRC2" <<'PY'
import json, sys
mh, src2 = sys.argv[1], sys.argv[2]
p = json.load(open(f"{mh}/projects.json")); p["projects"].append({"id": "proj2", "root": src2, "subrepos": []})
json.dump(p, open(f"{mh}/projects.json", "w"))
d = json.load(open(f"{mh}/discord.json")); d["projects"]["proj2"] = {"categoryId": None, "allow": ["U1"]}
json.dump(d, open(f"{mh}/discord.json", "w"))
PY
msess new proj2 feat/one --no-start >/dev/null 2>&1 || fail "proj2 new"
out="$(msess rm feat/one 2>&1)" && fail "모호한 rm 이 성공함"
echo "$out" | grep -q "모호" || fail "모호 안내 없음: $out"

msess rm proj/feat/one >/dev/null 2>&1 || fail "rm proj/feat/one (채널은 이미 없음 → 404 는 무시)"
alive proj-feat-one && fail "rm 후 tmux 살아 있음"
[ ! -e "$MARINA_CHANNELS_DIR/discord-proj-feat-one" ] || fail "rm 후 상태 폴더 남음"
[ -d "$SRC/.claude/worktrees/feat-one" ] || fail "rm 이 워크트리를 지움(남겨야 함)"
[ "$(lsjson proj/feat/one alive)" = "null" ] || fail "rm 후 기록 남음"
alive proj2-feat-one || fail "다른 프로젝트 세션까지 꺼짐"

CH2="$(lsjson proj2/feat/one channelId | tr -d '"')"
msess rm proj2/feat/one >/dev/null 2>&1 || fail "rm proj2"
grep -q "\"DELETE\", \"p\": \"/channels/$CH2\"" "$FD/log.jsonl" || fail "rm 이 채널 삭제를 요청하지 않음"

out="$(msess attach nope 2>&1)" && fail "없는 세션 attach 가 성공함"
echo "$out" | grep -q "찾지 못했" || fail "attach 없는 세션 안내"
echo "PASS test-session-lifecycle"
