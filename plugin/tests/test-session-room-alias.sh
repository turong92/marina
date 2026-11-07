#!/usr/bin/env bash
# room-send 대상 별칭 — discord.json 의 roomAliases {"터미널": "proj/feat/a"} 로 대상 이름을 풀어 준다.
# 방들이 `room-send 터미널 …` 로 보내는데 그런 방 이름이 없어 실패하고 다른 방을 거쳐 중계됐다.
# 별칭이 없거나 설정에 키가 없으면 지금처럼(없는 방 → 못 찾았다). 방은 --no-start 로만 만들어 실제 전달·깨움은 없다(보관만).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new a"
msess new proj feat/b --no-start >/dev/null 2>&1 || fail "new b"
msess stop proj/feat/a >/dev/null 2>&1 || true      # 잠든 방이어야 보관(전달·깨움 없음)
run() { PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$@"; }
B_SD="$(run <<'PY'
import marina_session as ms
print(ms.find_session("proj/feat/b")["stateDir"])
PY
)"
A_SD="$(run <<'PY'
import marina_session as ms
print(ms.find_session("proj/feat/a")["stateDir"])
PY
)"

# 별칭 없음 — 지금처럼 못 찾는다
out="$(DISCORD_STATE_DIR="$B_SD" msess room-send 터미널 '별칭 없는 글' 2>&1)" && fail "별칭 없는데 성공함: $out"
echo "$out" | grep -q "세션을 찾지 못했어" || fail "별칭 없음 안내: $out"

# 별칭 있음 — 그 방으로 간다(잠든 방이라 보관)
run <<'PY'
import json
import marina_session as ms
cfg = json.loads(ms.config_path().read_text())
cfg["roomAliases"] = {"터미널": "proj/feat/a", "깨진": "nope/none"}
ms.config_path().write_text(json.dumps(cfg))
PY
out="$(DISCORD_STATE_DIR="$B_SD" msess room-send 터미널 '별칭으로 보낸 글' 2>&1)" || fail "별칭 전송 실패: $out"
echo "$out" | grep -q "보관했어" || fail "보관 안내: $out"
grep -q "별칭으로 보낸 글" "$A_SD/room-inbox.jsonl" || fail "별칭이 가리킨 방 보관함에 글이 없음"
[ ! -e "$B_SD/room-inbox.jsonl" ] || fail "엉뚱한 방(보낸 방)에 보관됨"

# 별칭이 가리키는 방이 없으면 원래 이름이 아니라 가리키는 이름으로 못 찾았다고 알린다
out="$(DISCORD_STATE_DIR="$B_SD" msess room-send 깨진 '글' 2>&1)" && fail "깨진 별칭이 성공함"
echo "$out" | grep -q "nope/none" || fail "깨진 별칭 안내: $out"

# 별칭이 아닌 보통 이름은 그대로
out="$(DISCORD_STATE_DIR="$B_SD" msess room-send proj/feat/a '보통 이름 글' 2>&1)" || fail "보통 이름 실패: $out"
grep -q "보통 이름 글" "$A_SD/room-inbox.jsonl" || fail "보통 이름 보관 안 됨"
echo "OK"
