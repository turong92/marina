#!/usr/bin/env bash
# 계정 상호보완(형 2026-11-12 "토큰 모자라다 하면 다른 계정 써버리게"):
#  - 클로드 방이 사용량 한도 창에 멈추면, 여유 있는 다른 계정으로 방 계정을 바꾸고 같은 대화를 이어 띄운다
#  - 다른 계정도 바닥이면 바꾸지 않고 언제 풀리는지만 알린다
#  - 같은 방은 30분에 한 번만(서로 바닥인 두 계정 사이를 오가지 않게) · 코덱스 방은 건드리지 않는다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"
mkdir -p "$MARINA_HOME/accounts"; printf 'sk-ant-oat-TEST-B\n' > "$MARINA_HOME/accounts/b.token"; chmod 600 "$MARINA_HOME/accounts/b.token"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = str(rec["channelId"])
(sd / "account-running").write_text("a\n")
ok = [{"key": "fiveHour", "usedPercent": 10.0, "resetsAt": 2000}, {"key": "weekly", "usedPercent": 60.0, "resetsAt": 3000}]
gone = [{"key": "weekly", "usedPercent": 100.0, "resetsAt": 5000}, {"key": "fableWeekly", "usedPercent": 0.0, "resetsAt": 9000}]
spawned, said = [], []
def tick(now, limited=True, usage=None, busy=False, restarting=None):
    return mb.account_failover_tick(now, limited=lambda name: limited, usage=lambda: usage,
                                    spawn=spawned.extend, say=lambda c, t: said.append((c, t)),
                                    busy=lambda name: busy, restarting=lambda: restarting)

# 화면엔 한도 문구가 보여도 지금 계정(a)이 여유면 안 바꾼다(리뷰 C1·C2: 출력 속 같은 글자·다시 띄운 뒤 옛 문구)
check(tick(100000.0, usage={"a": ok, "b": ok}) == [] and not spawned and not said, "지금 계정 여유면 그대로")
# 일하는 중이면 안 바꾼다 · 다른 재시작이 돌고 있으면 다음 tick 에
check(tick(100000.0, usage={"a": gone, "b": ok}, busy=True) == [] and not spawned, "일하는 중이면 그대로")
check(tick(100000.0, usage={"a": gone, "b": ok}, restarting={"refs": ["x"]}) == [] and not spawned, "재시작 중이면 다음에")
check(not (sd / "account-failover-at").exists(), "안 바꾼 tick 은 쿨다운을 남기지 않는다")

# 한도 아님 → 아무것도 안 함
check(tick(100000.0, limited=False, usage={"a": gone, "b": ok}) == [] and not spawned and not said, "한도 아니면 그대로")

# a 한도 · b 여유 → 방 계정 b, 재시작, 알림
check(tick(100000.0, usage={"a": gone, "b": ok}) == ["proj/feat/a"], f"옮김: {spawned}")
check(ms.account_of(sd) == "b", f"방 계정 b: {ms.account_of(sd)}")
check(spawned == ["proj/feat/a"], f"계정 바꿈 재시작: {spawned}")
check(said and said[-1][0] == ch and "B" in said[-1][1], f"알림: {said}")

# 30분 안엔 다시 안 건드림(새로 뜬 b 방이 또 한도여도)
(sd / "account-running").write_text("b\n")
n = len(spawned)
check(tick(100000.0 + 600, usage={"a": gone, "b": gone}) == [] and len(spawned) == n, "30분 안엔 한 번만")

# 30분 뒤 b 도 한도인데 a 도 바닥 → 안 바꾸고 풀리는 시각만 알림
said.clear()
check(tick(100000.0 + 1900, usage={"a": gone, "b": gone}) == [] and len(spawned) == n, "둘 다 바닥이면 안 바꿈")
check(ms.account_of(sd) == "b", "둘 다 바닥이면 계정 그대로")
check(said and "바닥" in said[-1][1], f"둘 다 바닥 알림: {said}")
# 다시 쓸 수 있는 때 = 계정마다 바닥 창 중 가장 늦은 것, 그중 가장 이른 것(리뷰 I3)
check(mb._free_at([{"key": "fiveHour", "usedPercent": 100, "resetsAt": 10}, {"key": "weekly", "usedPercent": 100, "resetsAt": 99}]) == 99, "계정은 가장 늦게 풀리는 창에")
# 같은 시각이면 30분마다 또 알리지 않는다(리뷰 I2)
said.clear()
check(tick(100000.0 + 3800, usage={"a": gone, "b": gone}) == [] and not said, f"같은 시각이면 다시 안 알림: {said}")

# 모델 전용 창(fableWeekly)이 100% 여도 일반 창이 여유면 쓸 수 있다
said.clear()
fable_full = [{"key": "weekly", "usedPercent": 20.0}, {"key": "fableWeekly", "usedPercent": 100.0}]
check(tick(100000.0 + 5800, usage={"a": fable_full, "b": gone}) == ["proj/feat/a"], "a 로 되돌아감")
check(ms.account_of(sd) == "a", f"방 계정 a: {ms.account_of(sd)}")

# 사용량을 모르면(빈 목록) 여유로 본다 — 쿨다운이 왕복을 막는다
(sd / "account-running").write_text("a\n")
check(tick(100000.0 + 7800, usage={"a": gone}) == ["proj/feat/a"], "b 사용량 모름 → 시도")

# 코덱스 방은 건드리지 않는다
orig = ms.is_codex
ms.is_codex = lambda r: True
try:
    n = len(spawned)
    check(tick(100000.0 + 9900, usage={"a": gone, "b": ok}) == [] and len(spawned) == n, "코덱스 방 제외")
finally:
    ms.is_codex = orig

# 화면 판정: 한도 문구가 마지막으로 보낸 입력 뒤에 있을 때만 — 다시 띄운 뒤 기록에 남은 옛 문구로 또 바꾸지 않게(2026-11-12 daeun 화면)
check(mb.limit_is_latest(["❯ 안녕", "  ⎿  You've hit your weekly limit · resets 12am", "❯ "]), "보낸 입력 뒤 한도 문구 → 한도")
check(not mb.limit_is_latest(["  ⎿  You've hit your weekly limit · resets 12am", "❯ [마리나] 이어서 답해 줘",
                              "⏺ Reading brand/README.md", "❯ "]), "한도 뒤에 새 입력이 있으면 한도 아님")
check(mb.limit_is_latest(["❯ 일 해", "Stop and wait for limit to reset"]), "한도 선택 창")

# 한도가 풀리면 멈췄던 방을 다시 깨운다 — 2026-11-12 형: ovation 방이 한도로 멈춘 채 하루를 놀다 형이 'ㄱㄱ' 해서야 이어 갔다
for f in ("limit-stalled", "account-failover-at", "account-failover-wait"):
    (sd / f).unlink(missing_ok=True)
(sd / "account-running").write_text("b\n"); ms.set_account(sd, "b")
said.clear()
tick(300000.0, usage={"a": gone, "b": gone})
check((sd / "limit-stalled").exists(), "둘 다 바닥이면 '한도로 멈춤' 표시를 남긴다")
sent, restarted = [], []
orig_alive0 = ms.tmux_alive; ms.tmux_alive = lambda n: False      # 잠든 방부터
def revive(now, fa, busy=False, limited=False):
    return mb.limit_revive_tick(now, free_at=lambda: fa, busy=lambda n: busy, send=lambda rec, t: sent.append((rec, t)),
                                limited=lambda n: limited, restart=restarted.extend)
check(revive(300100.0, {"a": 9e12, "b": 9e12}) == [] and not sent, "아직 바닥이면 안 깨운다")
# 잠든 방: 방 계정(b)이 바닥이어도 다른 계정(a)이 풀렸으면 깨운다 — 깨울 때 여유 계정으로 뜬다(리뷰 I2)
check(revive(9e12 + 10, {"a": 0.0, "b": 9e12 * 2}) == ["proj/feat/a"], f"다른 계정이 풀리면 잠든 방을 깨운다: {sent}")
check(sent and "이어서" in sent[-1][1] and "SendMessage" in sent[-1][1], f"이어서 하라는 글(서브에이전트 포함): {sent}")
check((sd / "limit-stalled").exists(), "보낸 표시는 뒤 프로세스가 성공해야 지운다(리뷰 I1)")
check(revive(9e12 + 20, {"b": 0.0}) == [], "보내는 중엔 다시 안 보낸다")
check(revive(9e12 + 10 + mb.REVIVE_RETRY_S + 1, {"b": 0.0}) == ["proj/feat/a"], "전달이 실패해 표시가 남으면 잠시 뒤 다시")
(sd / "limit-stalled").unlink(); ms.tmux_alive = orig_alive0
# 떠 있는 방
orig_alive = ms.tmux_alive
ms.tmux_alive = lambda n: True
try:
    (sd / "account-running").write_text("b\n")
    (sd / "limit-stalled").write_text('{"freeAt": 0}')
    n = len(sent)
    check(revive(9e12 + 500, {"a": 0.0, "b": 9e12 * 2}) == [] and len(sent) == n, "떠 있는 방은 지금 계정이 풀려야(다른 계정은 failover 몫)")
    check(revive(9e12 + 600, {"b": 0.0}, limited=True) == [] and restarted == ["proj/feat/a"], f"한도 창이 남았으면 다시 띄운다(리뷰 I3): {restarted}")
    check(revive(9e12 + 700, {"b": 0.0}) == ["proj/feat/a"], "다시 뜬 뒤 글을 넣는다")
    (sd / "limit-stalled").write_text('{"freeAt": 0}')
    n = len(sent)
    check(revive(9e12 + 800, {"b": 0.0}, busy=True) == [] and len(sent) == n and not (sd / "limit-stalled").exists(), "일하는 중이면 안 깨우고 표시만 지움")
finally:
    ms.tmux_alive = orig_alive
# 뒤 프로세스: 성공하면 표시를 지우고, 실패하면 남긴다
import marina_discord_wake as mw
(sd / "limit-stalled").write_text('{"freeAt": 0}')
orig_rs = mw.room_send
try:
    def boom(*a, **k): raise ms.SessionError("잠금")
    mw.room_send = boom
    mb.revive_deliver(str(sd), "proj/feat/a", "", "x")
    check((sd / "limit-stalled").exists(), "전달 실패면 표시를 남긴다")
    mw.room_send = lambda *a, **k: "delivered"
    mb.revive_deliver(str(sd), "proj/feat/a", "", "x")
    check(not (sd / "limit-stalled").exists(), "전달 성공이면 표시를 지운다")
finally:
    mw.room_send = orig_rs
# 다른 계정으로 바꿔 다시 띄운 방도 표시를 남긴다(다시 뜬 뒤 '이어서 해' 를 넣으려고)
for f in ("limit-stalled", "account-failover-at", "account-failover-wait"):
    (sd / f).unlink(missing_ok=True)
tick(400000.0, usage={"a": ok, "b": gone})
check((sd / "limit-stalled").exists(), "계정 바꿔 띄운 방도 표시")

# 띄울 때도 고른다 — 바닥난 계정이면 여유 있는 계정으로 띄우고 방에 적는다(2026-11-12 image-admin-assets: a 한도로 멈췄다가
# 쉬어 내려간 방이 깨면 또 a 로 떠 같은 자리에 멈춘다). 상태는 봇이 tick 마다 accounts/state.json 에 적는다.
import json as _j
st = ms.marina_home() / "accounts" / "state.json"
ms.set_account(sd, "a")
check(ms.session_env(sd).get("MARINA_ACCOUNT_TOKEN_FILE") is None, "상태 기록 없으면 정한 대로 a")
gone_now = [{"key": "weekly", "usedPercent": 100.0, "resetsAt": time.time() + 86400}]
mb.write_account_state({"a": gone_now, "b": ok}, time.time())
check(ms.session_env(sd).get("MARINA_ACCOUNT_TOKEN_FILE"), "a 가 바닥이면 b 로 띄운다")
check(ms.account_of(sd) == "b", f"고른 계정을 방에 적는다: {ms.account_of(sd)}")
ms.clear_account(sd)
check(ms.chat_env(sd).get("MARINA_ACCOUNT_TOKEN_FILE"), "채팅방도 a 가 바닥이면 b 로")
ms.clear_account(sd)
mb.write_account_state({"a": gone_now, "b": gone_now}, time.time())
check(ms.session_env(sd).get("MARINA_ACCOUNT_TOKEN_FILE") is None, "둘 다 바닥이면 정한 대로")
mb.write_account_state({"a": gone_now, "b": ok}, time.time() - 3600)
check(ms.session_env(sd).get("MARINA_ACCOUNT_TOKEN_FILE") is None, "오래된 상태 기록은 안 믿는다")
st.unlink()

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
PY
echo "PASS test-account-failover"
