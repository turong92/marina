#!/usr/bin/env bash
# 데스크톱 앱이 연 대화를 marina 가 놓아 준다 — "한 대화 = 한 주인".
#
# 사고(2026-09-23): 모바일에서 이어받은 대화를 marina 가 PTY 로 쥔 채 놓지 않아, 데스크톱 앱에서 열면
# "외부에서 실행 중" 이라며 입력이 막혔다. 신호는 데스크톱 기록의 lastFocusedAt(열기만 해도 찍힘, 실측).
# 계약: ① 데스크톱이 marina 보다 **나중에** 열었을 때만 ② 쉬는 중일 때만(작업·질문 대기 중엔 안 끊음)
# ③ 데스크톱이 다리(bridge)로 붙어 쓰는 대화는 절대 안 놓는다 ④ 데스크톱 기록 없는 대화는 안 건드린다.
# 죽이는 코드라 **실제로 죽이지 않는다** — kill 을 주입해 호출만 센다(리퍼 사고 교훈).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json, os, tempfile, unittest
from pathlib import Path

tmp = tempfile.TemporaryDirectory()
os.environ["CLAUDE_DESKTOP_SESSIONS_DIR"] = str(Path(tmp.name, "desktop"))
import marina_desktop_handoff as h
import marina_term as mt

DESK = Path(os.environ["CLAUDE_DESKTOP_SESSIONS_DIR"], "acct")
NOW = 1_800_000_000.0


class FakeTerm:
    def __init__(self, tid, sid, created, last_input=None, alive=True):
        self.tid, self.root, self.alive = tid, "/wt", alive
        self.agent = {"source": "claude", "sid": sid}
        self.created, self.last_input = created, (created if last_input is None else last_input)


def desk(sid, focus, bridge=None):
    DESK.mkdir(parents=True, exist_ok=True)
    rec = {"cliSessionId": sid, "lastFocusedAt": int(focus * 1000)}
    if bridge:
        rec["bridgeSessionIds"] = bridge
    Path(DESK, f"local_{sid}.json").write_text(json.dumps(rec), encoding="utf-8")


class HandoffTests(unittest.TestCase):
    def setUp(self):
        for p in DESK.glob("*.json"):
            p.unlink()
        h._index, h._index_at = {}, 0.0
        self.killed = []
        self._orig = dict(mt._by_tid)
        mt._by_tid.clear()

    def tearDown(self):
        mt._by_tid.clear(); mt._by_tid.update(self._orig)

    def run_tick(self, status="waiting"):
        return h.tick(NOW, kill=self.killed.append, status=lambda sid, root: status)

    def hold(self, *terms):
        for t in terms:
            mt._by_tid[t.tid] = t

    def test_releases_when_desktop_opened_later_and_idle(self):
        self.hold(FakeTerm("t1", "sid-a", created=NOW - 600))
        desk("sid-a", NOW - 10)                        # marina 가 잡은 뒤 데스크톱이 열었다
        self.assertEqual([r[0] for r in self.run_tick()], ["t1"])
        self.assertEqual(self.killed, ["t1"])

    def test_keeps_when_marina_used_it_after_desktop_focus(self):
        self.hold(FakeTerm("t1", "sid-a", created=NOW - 600, last_input=NOW - 5))
        desk("sid-a", NOW - 60)                        # 데스크톱이 먼저 봤고, 그 뒤 모바일에서 보냈다
        self.run_tick()
        self.assertEqual(self.killed, [], "모바일에서 방금 쓴 대화를 데스크톱의 옛 포커스로 끊었다")

    def test_never_interrupts_work_or_questions(self):
        self.hold(FakeTerm("t1", "sid-a", created=NOW - 600))
        desk("sid-a", NOW - 10)
        for st in ("working", "blocked", "unknown"):
            self.run_tick(status=st)
        self.assertEqual(self.killed, [], "작업 중·질문 대기·판정 불가에서 끊었다")
        self.run_tick(status="waiting")               # 쉬게 되면 그때 놓는다
        self.assertEqual(self.killed, ["t1"])

    def test_bridged_session_is_never_released(self):
        """데스크톱이 다리로 이 프로세스에 붙어 쓰는 중 — 놓으면 데스크톱이 쓰던 게 죽는다(실측)."""
        self.hold(FakeTerm("t1", "sid-a", created=NOW - 600))
        desk("sid-a", NOW - 10, bridge=["session_x"])
        self.run_tick()
        self.assertEqual(self.killed, [])

    def test_no_desktop_record_is_untouched(self):
        self.hold(FakeTerm("t1", "sid-z", created=NOW - 600))
        self.run_tick()
        self.assertEqual(self.killed, [])

    def test_other_sessions_unaffected(self):
        self.hold(FakeTerm("t1", "sid-a", created=NOW - 600), FakeTerm("t2", "sid-b", created=NOW - 600))
        desk("sid-a", NOW - 10); desk("sid-b", NOW - 900)   # b 는 marina 가 잡기 전에 본 것
        self.run_tick()
        self.assertEqual(self.killed, ["t1"])

    def test_disabled_by_env(self):
        self.hold(FakeTerm("t1", "sid-a", created=NOW - 600)); desk("sid-a", NOW - 10)
        os.environ["MARINA_DESKTOP_HANDOFF"] = "0"
        try:
            self.run_tick()
        finally:
            del os.environ["MARINA_DESKTOP_HANDOFF"]
        self.assertEqual(self.killed, [])


unittest.main(verbosity=1)
PY
