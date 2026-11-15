#!/usr/bin/env bash
# marina session rename — 방 별칭: 워크트리 meta.json 의 alias(폰 rename·대시보드가 쓰는 자리)를 방끼리 대화에도 쓴다.
# ① `marina session rename <방> <이름>` 이 meta.json 에 쓴다(빈 이름 = 지움) ② ls 에 별칭이 보인다
# ③ room-send 꼬리표가 '<프로젝트>/<작업>(별칭)' ④ room-send 등 ref 자리에 별칭을 받는다(기존 주소는 그대로).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
export TMPROOT
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new a"
msess new proj feat/b --no-start >/dev/null 2>&1 || fail "new b"
msess stop proj/feat/a >/dev/null 2>&1 || true; msess stop proj/feat/b >/dev/null 2>&1 || true   # 잠든 방 — room-send 가 보관함(room-inbox)에 넣는다
run() { PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$@"; }
field() { run <<PY
import marina_session as ms
print(ms.find_session("$1")["$2"])
PY
}
A_SD="$(field proj/feat/a stateDir)"; B_SD="$(field proj/feat/b stateDir)"; B_ROOT="$(field proj/feat/b root)"

# ── rename: meta.json 에 쓴다 ──
out="$(msess rename proj/feat/b 스켈레톤 2>&1)" || fail "rename 실패: $out"
echo "$out" | grep -q "스켈레톤" || fail "rename 안내: $out"
meta="$(ls "$B_ROOT"/.workspace/marina/*/meta.json 2>/dev/null | head -1)"
[ -n "$meta" ] || fail "meta.json 이 안 생김"
python3 -c "import json,sys; assert json.load(open(sys.argv[1]))['alias']=='스켈레톤'" "$meta" || fail "meta.json alias: $(cat "$meta")"
# marina 런타임(대시보드·폰)과 같은 자리를 읽는지 — runtime 의 read_meta 로 확인
run <<PY || fail "runtime read_meta 가 다른 자리를 본다"
from pathlib import Path
import marina_paths as mp
assert mp.read_meta(Path("$B_ROOT"))["alias"] == "스켈레톤", mp.read_meta(Path("$B_ROOT"))
PY

# ── ls 에 별칭 ──
msess ls 2>/dev/null | grep "^proj/feat/b" | grep -q "스켈레톤" || fail "ls 에 별칭 없음: $(msess ls 2>&1)"

# ── 꼬리표: 보낸 방 별칭이 붙는다, 답 주소는 그대로 ──
out="$(DISCORD_STATE_DIR="$B_SD" msess room-send proj/feat/a "별칭 꼬리표 확인" 2>&1)" || fail "b→a 전송 실패: $out"
grep -q '\[마리나 · proj/feat/b(스켈레톤) 방에서\] 별칭 꼬리표 확인' "$A_SD/room-inbox.jsonl" || fail "꼬리표: $(cat "$A_SD/room-inbox.jsonl")"
grep -q 'room-send proj/feat/b \\"…\\"' "$A_SD/room-inbox.jsonl" || fail "답 주소: $(cat "$A_SD/room-inbox.jsonl")"

# ── 별칭으로 보내기 ──
out="$(DISCORD_STATE_DIR="$A_SD" msess room-send 스켈레톤 '별칭 주소로 보냄' 2>&1)" || fail "별칭 주소 실패: $out"
echo "$out" | grep -q "proj/feat/b" || fail "별칭 주소 안내: $out"
grep -q '별칭 주소로 보냄' "$B_SD/room-inbox.jsonl" || fail "b 보관함에 없음"

# ── 같은 별칭을 다른 방에 못 쓴다 ──
out="$(msess rename proj/feat/a 스켈레톤 2>&1)" && fail "중복 별칭이 성공함"
echo "$out" | grep -q "이미" || fail "중복 안내: $out"

# ── 빈 이름 = 지움 ──
msess rename proj/feat/b "" >/dev/null 2>&1 || fail "지우기 실패"
python3 -c "import json,sys; assert json.load(open(sys.argv[1]))['alias']==''" "$meta" || fail "지운 뒤 alias: $(cat "$meta")"
out="$(DISCORD_STATE_DIR="$A_SD" msess room-send 스켈레톤 x 2>&1)" && fail "지운 별칭이 아직 풀림"

# ── 꼬리표를 읽는 쪽(반송 알림의 ROOM_FROM)이 별칭 꼬리에 안 깨진다 — 공백·괄호 섞인 별칭도 ──
msess rename proj/feat/b "로그인 (고치기)" >/dev/null 2>&1 || fail "공백 별칭 rename 실패"
DISCORD_STATE_DIR="$B_SD" msess room-send proj/feat/a '반송 확인' >/dev/null 2>&1 || fail "b→a 두 번째 전송 실패"
run <<PY || fail "ROOM_FROM 이 별칭 꼬리표에서 보낸 방을 못 뽑음: $(tail -1 "$A_SD/room-inbox.jsonl")"
import json
import marina_discord_wake as mw
lines = [json.loads(l)["text"] for l in open("$A_SD/room-inbox.jsonl") if "반송 확인" in l]
assert lines and lines[0].startswith("[마리나 · proj/feat/b(로그인 고치기) 방에서]"), lines
m = mw.ROOM_FROM.match(lines[0])
assert m and m.group(1) == "proj/feat/b", m and m.group(1)
assert mw.ROOM_FROM.match("[마리나 · 메인 proj/feat/b(스켈레톤) 방의 지시] x").group(1) == "proj/feat/b"
assert mw.ROOM_FROM.match("[마리나 · proj/feat/b 방에서] x").group(1) == "proj/feat/b"
PY

# ── 채팅방은 폴더를 여럿이 같이 쓴다 — 별칭 거부 ──
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
o="$(msess new chat shopping 2>&1)" || fail "new chat: $o"
out="$(msess rename chat/shopping 쇼핑 2>&1)" && fail "채팅방 rename 이 성공함"
echo "$out" | grep -q "개발 방이 아니야" || fail "채팅방 안내: $out"
echo "PASS test-session-room-rename"
