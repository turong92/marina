#!/usr/bin/env bash
# 프로젝트별 봇 — discord.json projects.<p>.tokenFile 이 있으면 세션이 말할 때 그 토큰(상태 폴더 .env 심링크)을 쓰고,
# 없으면 전역 tokenFile. 프로젝트 토큰 파일이 없거나 비면 전역으로 되돌아가지 않고 분명히 실패한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
setpt() {   # setpt <tokenFile 경로 | ""> [프로젝트=proj]
  python3 - "$MARINA_HOME/discord.json" "$1" "${2:-proj}" <<'PY'
import json, sys
p, tf, proj = sys.argv[1], sys.argv[2], sys.argv[3]
c = json.load(open(p))
pc = c["projects"].setdefault(proj, {"categoryId": None, "allow": []})
if tf: pc["tokenFile"] = tf
else: pc.pop("tokenFile", None)
json.dump(c, open(p, "w"))
PY
}
sdir_of() { python3 -c "import sys;sys.path[:0]=['$DSCRIPTS','$SCRIPTS'];import marina_session as m;print(m.state_dir('$1','$2'))"; }
PT="$MARINA_HOME/token-proj.env"
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"      # 채팅방은 chat 폴더 신뢰를 이 파일에 적는다

# 1) 없는 파일 → 분명한 오류, 아무것도 안 만든다
setpt "$PT"
out="$(msess new proj feat/a --no-start 2>&1)" && fail "프로젝트 토큰 파일이 없는데 성공함"
echo "$out" | grep -q "$PT" || fail "오류에 프로젝트 토큰 경로가 없음: $out"
[ ! -e "$(python3 -c "import sys;sys.path[:0]=['$DSCRIPTS','$SCRIPTS'];import marina_session as m;print(m.state_dir('proj','feat/a'))")" ] || fail "상태 폴더가 남음"

# 2) 빈 파일 → 오류(전역으로 조용히 되돌아가지 않음)
: > "$PT"
out="$(msess new proj feat/a --no-start 2>&1)" && fail "빈 토큰 파일인데 성공함"
echo "$out" | grep -q "$PT" || fail "빈 파일 오류에 경로가 없음: $out"

# 3) 정상 → 프로젝트 토큰이 걸린다
# 2b) 형식은 맞지만 Discord 가 거부하는 토큰(오타·만료) → 401 로 분명히 실패, 아무것도 안 만든다
printf 'DISCORD_BOT_TOKEN=typo-token\n' > "$PT"
out="$(msess new proj feat/a --no-start 2>&1)" && fail "Discord 가 거부할 토큰인데 성공함"
echo "$out" | grep -q "401" || fail "거부 오류에 401 이 없음: $out"
echo "$out" | grep -q "$PT" || fail "거부 오류에 경로가 없음: $out"
[ ! -e "$(sdir_of proj feat/a)" ] || fail "거부됐는데 상태 폴더가 남음"

printf 'DISCORD_BOT_TOKEN=proj-bot-token\n' > "$PT"
echo proj-bot-token > "$FD/extra_tokens"
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new 실패"
sd="$(python3 -c "import sys;sys.path[:0]=['$DSCRIPTS','$SCRIPTS'];import marina_session as m;print(m.state_dir('proj','feat/a'))")"
[ "$(readlink "$sd/.env")" = "$PT" ] || fail ".env 가 프로젝트 토큰이 아님: $(readlink "$sd/.env")"

# 4) tokenFile 없으면 전역
setpt ""
msess new proj feat/b --no-start >/dev/null 2>&1 || fail "전역 new 실패"
sd="$(python3 -c "import sys;sys.path[:0]=['$DSCRIPTS','$SCRIPTS'];import marina_session as m;print(m.state_dir('proj','feat/b'))")"
[ "$(readlink "$sd/.env")" = "$MARINA_HOME/token.env" ] || fail ".env 가 전역 토큰이 아님: $(readlink "$sd/.env")"

# 5) 재시작하면 .env 가 설정을 따라간다 — 기존 방이 영영 옛 봇으로 말하지 않게
msess new proj feat/c --no-start >/dev/null 2>&1 || fail "재시작용 new 실패"      # 전역으로 만든 방
sd="$(sdir_of proj feat/c)"
[ "$(readlink "$sd/.env")" = "$MARINA_HOME/token.env" ] || fail "전역으로 만들었는데 .env 가 전역이 아님"
msess stop feat/c >/dev/null
setpt "$PT"
msess start feat/c >/dev/null || fail "start 실패"
[ "$(readlink "$sd/.env")" = "$PT" ] || fail "재시작했는데 .env 가 프로젝트 토큰으로 안 바뀜: $(readlink "$sd/.env")"
msess stop feat/c >/dev/null
setpt ""
msess start feat/c >/dev/null || fail "start(되돌리기) 실패"
[ "$(readlink "$sd/.env")" = "$MARINA_HOME/token.env" ] || fail "tokenFile 을 지웠는데 .env 가 전역으로 안 돌아옴"
msess stop feat/c >/dev/null
# 설정이 깨져 있어도 재시작은 된다(load_config 실패가 전체를 막지 않는다)
cp "$MARINA_HOME/discord.json" "$MARINA_HOME/discord.json.bak"; echo '{broken' > "$MARINA_HOME/discord.json"
msess start feat/c >/dev/null 2>&1 || true
cp "$MARINA_HOME/discord.json.bak" "$MARINA_HOME/discord.json"
alive() { tmux -L "$MARINA_TMUX_SOCKET" has-session -t "=$1" 2>/dev/null; }
alive proj-feat-c || fail "설정이 깨졌다고 재시작이 막힘"
msess stop feat/c >/dev/null

# 6) 채팅방(cmd_new_chat) — .env 가 프로젝트 토큰이고, 방 첫 안내도 그 봇 명의
setpt "$PT" chat
out="$(msess new chat room1 --title 쇼핑 2>&1)" || fail "chat new 실패: $out"
sd="$(sdir_of chat room1)"
[ "$(readlink "$sd/.env")" = "$PT" ] || fail "채팅방 .env 가 프로젝트 토큰이 아님: $(readlink "$sd/.env")"
python3 - "$FD/log.jsonl" <<'PY' || fail "방 첫 안내가 프로젝트 봇 명의가 아님"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
w = [r for r in rows if r["m"] == "POST" and "대화방이야" in str((r.get("b") or {}).get("content", ""))]
assert w, "첫 안내 POST 가 없음"
assert all(r["a"] == "Bot proj-bot-token" for r in w), w
PY
# 채팅 프로젝트의 거부 토큰도 막힌다
printf 'DISCORD_BOT_TOKEN=typo-token\n' > "$PT"
out="$(msess new chat room2 2>&1)" && fail "채팅방: 거부될 토큰인데 성공함"
echo "$out" | grep -q "401" || fail "채팅방 거부 오류에 401 이 없음: $out"
[ ! -e "$(sdir_of chat room2)" ] || fail "채팅방: 거부됐는데 상태 폴더가 남음"
echo "PASS"
