#!/usr/bin/env bash
# 방 캐시(1시간)가 살아 있는 동안 손쓰기(형 2026-11-05): 일 조각이 끝난 방은 마지막 턴 뒤 50분에 /compact 한 번,
# 하던 중인 방은 8시간까지 50분마다 캐시 유지 글(내용 없는 턴)·8시간이 지나면 /compact 뒤 내림.
# 캐시 유지 글·컴팩트가 '사람이 마지막으로 말한 시각'을 갱신하면 안 된다. 코덱스 방은 대상이 아니다.
# 시간은 주입한 now, 입력은 mb._spawn_type 을 가로채 기록만 한다 — 실제 tmux 입력·실 ~/.marina 는 건드리지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
export FD
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a >/dev/null 2>&1 || fail "new a"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import datetime, json, os, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
import marina_discord_idle as mi
import marina_discord_wake as mw
fails = []
def check(c, m):
    if not c: fails.append(m)
assert os.environ["MARINA_TMUX_SOCKET"].startswith("marina-test-")
def row(r): return json.dumps(r, ensure_ascii=False) + "\n"
def iso(t): return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"])
sid = "aaaaaaaa-0000-1111-2222-333344445555"
ms.save_sessions([dict(x, sessionId=sid) for x in ms.load_sessions()])
rec = ms.find_session("proj/feat/a")
tr = ms.transcript_path(Path(rec["root"]), sid); tr.parent.mkdir(parents=True, exist_ok=True)
tr.write_text(row({"type": "user", "message": {"role": "user", "content": "hi"}}))
MIN = 60.0; H = 3600.0
T0 = time.time() + 100                       # 사람이 마지막으로 말한 시각(tmux 가 뜬 시각보다 늦다)
(sd / "turn-at").write_text(str(T0)); (sd / "stopped-at").write_text(str(T0 + 5))
H0 = T0 + 5
typed = []
mb._spawn_type = lambda tmux, text, channel, mid, button="": typed.append(text)
blockers = [[]]
mb.restart_blockers = lambda r: list(blockers[0])
mi._work_stale = lambda *a: False
attached = [False]
mi._attached = lambda name: attached[0]
cfg = {}
K = mi.Idler(started=0.0)
def ksf(t, c=None):
    global K
    K = mi.Idler(started=0.0); return ks(t, c)
def ks(t, c=None): typed.clear(); K.keep_tick(t, cfg if c is None else c); return list(typed)
# ── 설정 ──
check(mi.keep_config({}) == (50 * MIN, 8 * H), f"기본 50분·8시간: {mi.keep_config({})}")
check(mi.keep_config({"cacheKeep": False}) is None, "끄는 스위치")
check(mi.keep_config({"cacheKeepMinutes": 30, "cacheKeepHours": 4}) == (30 * MIN, 4 * H), "설정 값")
check(mi.keep_config({"cacheKeepMinutes": "x", "cacheKeepHours": None}) == (50 * MIN, 8 * H), "이상한 값은 기본")
check(mi.keep_config({"cacheKeepMinutes": 0}) == (50 * MIN, 8 * H) and mi.keep_config({"cacheKeepMinutes": 90}) == (50 * MIN, 8 * H), "0 이하·캐시(60분) 넘는 간격은 기본")
# ── 사람이 마지막으로 말한 시각: 캐시 유지 글·컴팩트는 갱신하지 않는다 ──
base = row({"type": "user", "timestamp": iso(H0 - 10), "message": {"role": "user", "content": "형 말"}}) \
     + row({"type": "assistant", "timestamp": iso(H0 - 5), "message": {"role": "assistant", "content": "답"}})
tr.write_text(base)
check(abs(mi.last_activity(rec) - (H0 - 5)) < 2 or abs(mi.last_activity(rec) - H0) < 2, f"기준선: {mi.last_activity(rec) - H0}")
keep = row({"type": "user", "timestamp": iso(H0 + 3000), "message": {"role": "user", "content": ms.KEEPALIVE_TEXT}}) \
     + row({"type": "assistant", "timestamp": iso(H0 + 3002), "message": {"role": "assistant", "content": [{"type": "text", "text": "."}]}})
tr.write_text(base + keep)
check(abs(mi.last_activity(rec) - H0) < 2, f"캐시 유지 글·그 답은 활동이 아니다: {mi.last_activity(rec) - H0}")
comp = row({"type": "user", "timestamp": iso(H0 + 3100), "message": {"role": "user", "content": "<command-name>/compact</command-name>"}}) \
     + row({"type": "system", "subtype": "compact_boundary", "timestamp": iso(H0 + 3101)}) \
     + row({"type": "user", "timestamp": iso(H0 + 3102), "isCompactSummary": True, "message": {"role": "user", "content": "요약"}})
tr.write_text(base + keep + comp)
check(abs(mi.last_activity(rec) - H0) < 2, f"컴팩트 기록도 활동이 아니다: {mi.last_activity(rec) - H0}")
tr.write_text(base + keep + row({"type": "user", "timestamp": iso(H0 + 3200), "message": {"role": "user", "content": "또 말함"}}))
check(abs(mi.last_activity(rec) - (H0 + 3200)) < 2, "캐시 유지 뒤 사람이 말하면 그 시각")
tr.write_text(base)
# ── 일 조각이 끝난 방: 50분에 /compact 한 번 ──
check(ks(H0 + 40 * MIN) == [], "50분 전엔 아무것도")
check(ks(H0 + 55 * MIN) == [ms.COMPACT_KEEP_TEXT], f"끝난 방은 50분 뒤 컴팩트: {typed}")
check(ks(H0 + 56 * MIN) == [] and ks(H0 + 58 * MIN) == [], "한 번만")
check(json.loads((sd / "keep.json").read_text()).get("compactedFor") is not None, "컴팩트한 기준 시각을 적는다")
(sd / "turn-at").write_text(str(H0 + 70 * MIN)); (sd / "stopped-at").write_text(str(H0 + 71 * MIN))   # 형이 말을 걸었다 → 계획 다시
H1 = H0 + 71 * MIN
check(ks(H1 + 40 * MIN) == [] and ks(H1 + 55 * MIN) == [ms.COMPACT_KEEP_TEXT], f"말을 걸면 다시 50분 뒤 컴팩트: {typed}")
# 캐시가 이미 식은 방(60분 넘음)은 컴팩트하지 않는다(다시 쓰는 값이 같다)
(sd / "keep.json").unlink()
check(ks(H1 + 75 * MIN) == [], "캐시가 식은 뒤엔 컴팩트하지 않는다")
(sd / "keep.json").unlink(missing_ok=True)
# ── 하던 중인 방: 50분마다 캐시 유지 글, 8시간 뒤 컴팩트 ──
(sd / "turn-at").write_text(str(T0)); (sd / "stopped-at").write_text(str(H0))
K = mi.Idler(started=0.0)
blockers[0] = ["백그라운드 셸 1"]
check(ks(H0 + 40 * MIN) == [], "50분 전")
check(ks(H0 + 55 * MIN) == [ms.KEEPALIVE_TEXT], f"하던 중이면 캐시 유지 글: {typed}")
check(ks(H0 + 70 * MIN) == [] and ks(H0 + 100 * MIN) == [], "다음은 50분 뒤")
check(ks(H0 + 106 * MIN) == [ms.KEEPALIVE_TEXT], "50분 뒤 또")
check(ks(H0 + 7 * H) == [ms.KEEPALIVE_TEXT], "8시간 전까지 계속")
check(ks(H0 + 8 * H + MIN) == [ms.COMPACT_KEEP_TEXT], f"8시간이 지나면 컴팩트: {typed}")
check(ks(H0 + 8 * H + 2 * MIN) == [] and ks(H0 + 9 * H) == [], "그 뒤엔 더 안 한다")
# 하던 중이던 방이 끝나면: 마지막 캐시 접촉 50분 뒤 컴팩트
(sd / "keep.json").write_text(json.dumps({"lastKeep": H0 + 55 * MIN}))
K = mi.Idler(started=0.0)
blockers[0] = []
check(ks(H0 + 90 * MIN) == [] and ks(H0 + 106 * MIN) == [ms.COMPACT_KEEP_TEXT], f"유지 글로 데운 캐시가 식기 전에 컴팩트: {typed}")
# ── 진행 문서(.superpowers/sdd/*/progress*.md 맨 위 상태: 진행 중|막힘) ──
(sd / "keep.json").unlink(missing_ok=True); K = mi.Idler(started=0.0)
doc = Path(rec["root"]) / ".superpowers" / "sdd" / "x" / "progress.md"; doc.parent.mkdir(parents=True)
for st, want in (("진행 중", True), ("막힘", True), ("완료", False)):
    doc.write_text(f"# 진행\n상태: {st}\n")
    check(mi.progress_open(rec) is want, f"진행 문서 {st} → {want}")
doc.write_text("# 진행\n상태: 진행 중\n")
check(ks(H0 + 55 * MIN) == [ms.KEEPALIVE_TEXT], f"진행 문서가 열려 있으면 하던 중: {typed}")
doc.write_text("\n".join(["a"] * 6) + "\n상태: 진행 중\n")
check(mi.progress_open(rec) is False, "맨 위 다섯 줄 밖은 안 본다(role-hook 규칙)")
# ── 건너뛰는 경우 ──
(sd / "keep.json").unlink(missing_ok=True); K = mi.Idler(started=0.0); doc.write_text("상태: 완료\n")
attached[0] = True
check(ksf(H0 + 55 * MIN) == [], "터미널로 보는 중이면 입력하지 않는다")
attached[0] = False
check(ksf(H0 + 55 * MIN, {"cacheKeep": False}) == [], "끄면 아무것도")
K = mi.Idler(started=0.0)
real_codex = ms.is_codex
ms.is_codex = lambda r: True
check(ksf(H0 + 55 * MIN) == [], "코덱스 방은 대상 아님")
ms.is_codex = real_codex
real_alive = ms.tmux_alive
ms.tmux_alive = lambda n: False
check(ksf(H0 + 55 * MIN) == [], "꺼진 방은 아님")
ms.tmux_alive = real_alive
check(ksf(H0 + 55 * MIN) == [ms.COMPACT_KEEP_TEXT], "복구되면 동작")
# ── 내리기와의 관계: 진행 문서가 열린 방은 8시간 전엔(컴팩트 전엔) 2시간에 안 내린다 ──
mw.mark_seen()
mb._input_empty = lambda n: True; mi._pane_tail = lambda n: ""
mw.allow_list = lambda r: []
(sd / "keep.json").unlink(missing_ok=True)
A = 2 * H
doc.write_text("상태: 진행 중\n")
check(any("하던 중" in w for w in mi.verdict(rec, A, H0 + 3 * H)), f"진행 문서가 열린 방은 2시간에 안 내린다: {mi.verdict(rec, A, H0 + 3 * H)}")
check(any("하던 중" in w for w in mi.verdict(rec, A, H0 + 9 * H)), "8시간이 지나도 컴팩트 전엔 안 내린다")
(sd / "keep.json").write_text(json.dumps({"compactedFor": H0}))
check(not any("하던 중" in w for w in mi.verdict(rec, A, H0 + 9 * H)), "컴팩트를 건 뒤엔 내린다")
doc.write_text("상태: 완료\n"); (sd / "keep.json").unlink()
check(not any("하던 중" in w for w in mi.verdict(rec, A, H0 + 3 * H)), "문서가 닫히면 지금처럼 2시간")
# ── 훅: 캐시 유지 글은 turn-at·stopped-at·Discord 진행 표시를 건드리지 않는다 ──
os.environ["DISCORD_STATE_DIR"] = str(sd)
(sd / "turn-at").write_text("111"); (sd / "stopped-at").write_text("222")
ms._ensure_daemon_quiet = lambda: None
ms.hook_prompt({"hook_event_name": "UserPromptSubmit", "prompt": ms.KEEPALIVE_TEXT, "transcript_path": str(tr)})
check((sd / "turn-at").read_text() == "111", "캐시 유지 글은 turn-at 을 안 쓴다")
ms.hook_stop({"transcript_path": str(tr), "session_id": sid})
check((sd / "stopped-at").read_text() == "222", "캐시 유지 턴의 끝은 stopped-at 을 안 쓴다")
calls = []
real_discord = ms.Discord
ms.hook_activity({"hook_event_name": "UserPromptSubmit", "prompt": ms.KEEPALIVE_TEXT, "transcript_path": str(tr)})
check(not (sd / "activity-at").exists(), "캐시 유지 글은 입력 중 표시·반응(activity-at)을 안 단다")
ms.hook_prompt({"hook_event_name": "UserPromptSubmit", "prompt": "진짜 말", "transcript_path": str(tr)})
check((sd / "turn-at").read_text() != "111", "사람 글은 turn-at 을 쓴다")
# ── 입력 허용 ──
check(mb.typeable(ms.KEEPALIVE_TEXT, rec["channelId"]) and mb.typeable(ms.COMPACT_KEEP_TEXT, rec["channelId"]), "type 이 두 글을 친다")
check(not mb.typeable(ms.COMPACT_KEEP_TEXT + " 그리고 rm", rec["channelId"]), "고정 문구 정확 일치만")
check(mb.type_timeout(ms.KEEPALIVE_TEXT) <= 300, "캐시 유지 글은 오래 기다리지 않는다")
check(ms.KEEPALIVE_TEXT.startswith(ms.KEEPALIVE_MARK) and ms.COMPACT_KEEP_TEXT.startswith("/compact "), "문구 형식")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-cache-keep"
