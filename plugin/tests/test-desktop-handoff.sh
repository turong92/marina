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
os.environ["CLAUDE_PROJECTS_DIR"] = str(Path(tmp.name, "projects"))
import marina_desktop_handoff as h
import marina_sessions as ms
import marina_term as mt

DESK = Path(os.environ["CLAUDE_DESKTOP_SESSIONS_DIR"], "acct", "org")   # 실제와 같은 두 단계
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
        h._adopted.clear()
        h._account_cache = (-1e18, None)
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


def transcript(root, sid, first_uuid, title="GCP 이관"):
    d = ms.CLAUDE_PROJECTS_DIR / ms._claude_project_slug(Path(root))
    d.mkdir(parents=True, exist_ok=True)
    lines = [{"type": "user", "uuid": first_uuid, "sessionId": sid, "cwd": root,
              "timestamp": "2026-09-24T12:00:00Z", "message": {"role": "user", "content": title}},
             {"type": "assistant", "sessionId": sid, "cwd": root,
              "message": {"role": "assistant", "model": "claude-opus-5-5", "content": []}}]
    Path(d, f"{sid}.jsonl").write_text("\n".join(json.dumps(x) for x in lines) + "\n", encoding="utf-8")


class AdoptTests(unittest.TestCase):
    """반대 방향 — marina 가 만든 대화를 데스크톱 목록에 올린다(앱이 쓰는 입양 기록 모양 그대로)."""

    def setUp(self):
        for p in DESK.glob("*.json"):
            p.unlink()
        h._index, h._index_at = {}, 0.0
        h._adopted.clear()
        h._account_cache = (-1e18, None)
        self._orig = dict(mt._by_tid); mt._by_tid.clear()
        desk("other-sid", NOW - 9999)           # 계정 폴더가 있다는 표시(앱을 쓴 맥)

    def tearDown(self):
        mt._by_tid.clear(); mt._by_tid.update(self._orig)

    def run_tick(self):
        return h.tick(NOW, kill=lambda tid: None, status=lambda sid, root: "working")

    def test_writes_adoption_record_in_app_shape(self):
        t = FakeTerm("t1", "new-sid", created=NOW - 60); t.root = "/wt/gcp"
        transcript(t.root, "new-sid", "u-1")
        mt._by_tid["t1"] = t
        self.run_tick()
        rec = json.loads(Path(DESK, "local_new-sid.json").read_text(encoding="utf-8"))
        self.assertEqual(rec["sessionId"], "local_new-sid")
        self.assertEqual(rec["cliSessionId"], "new-sid")
        self.assertTrue(rec["adoptedFromOtherSurface"])
        self.assertEqual(rec["cwd"], "/wt/gcp"); self.assertEqual(rec["originCwd"], "/wt/gcp")
        self.assertEqual(rec["model"], "claude-opus-5-5")
        self.assertFalse(rec["isArchived"])

    def test_same_conversation_resumed_is_not_doubled(self):
        """resume 으로 sid 만 바뀐 같은 대화가 이미 데스크톱에 있으면 또 올리지 않는다(두 줄 방지)."""
        root = "/wt/gcp"
        transcript(root, "old-sid", "u-same")
        Path(DESK, "local_old-sid.json").write_text(json.dumps({"cliSessionId": "old-sid", "cwd": root}), encoding="utf-8")
        t = FakeTerm("t1", "new-sid", created=NOW - 60); t.root = root
        transcript(root, "new-sid", "u-same")
        mt._by_tid["t1"] = t
        self.run_tick()
        self.assertFalse(Path(DESK, "local_new-sid.json").exists(), "같은 대화를 데스크톱에 두 줄로 올렸다")

    def test_existing_desktop_record_is_left_alone(self):
        t = FakeTerm("t1", "sid-a", created=NOW - 60); t.root = "/wt/gcp"
        transcript(t.root, "sid-a", "u-1")
        desk("sid-a", NOW - 9999)
        before = Path(DESK, "local_sid-a.json").read_text(encoding="utf-8")
        mt._by_tid["t1"] = t
        self.run_tick()
        self.assertEqual(Path(DESK, "local_sid-a.json").read_text(encoding="utf-8"), before, "앱의 기록을 건드렸다")

    def test_retries_after_app_first_launch(self):
        """데스크톱 앱을 켜기 전(계정 폴더 없음)에 쥔 대화도 폴더가 생기면 입양돼야 한다(리뷰 지적 — 영구 누락)."""
        for p in DESK.glob("*.json"):
            p.unlink()
        DESK.rmdir()
        t = FakeTerm("t1", "early", created=NOW - 60); t.root = "/wt/gcp"
        transcript(t.root, "early", "u-e")
        mt._by_tid["t1"] = t
        self.run_tick()
        self.assertFalse(DESK.exists())
        desk("other-sid", NOW - 9999)           # 앱을 처음 켰다
        h._index_at = 0.0
        h._account_cache = (-1e18, None)         # 계정 폴더 캐시(30초)가 지났다
        self.run_tick()
        self.assertTrue(Path(DESK, "local_early.json").exists(), "앱을 켜기 전에 쥔 대화가 영영 안 올라간다")

    def test_write_failure_is_retried(self):
        t = FakeTerm("t1", "flaky", created=NOW - 60); t.root = "/wt/gcp"
        transcript(t.root, "flaky", "u-f")
        mt._by_tid["t1"] = t
        calls = []
        def boom(target, rec):
            calls.append(target); raise OSError("disk full")
        h.tick(NOW, kill=lambda tid: None, status=lambda s, r: "working", write=boom)
        h.tick(NOW, kill=lambda tid: None, status=lambda s, r: "working", write=boom)
        self.assertEqual(len(calls), 2, "쓰기 실패 뒤 다시 시도하지 않았다")

    def test_no_transcript_yet_writes_nothing(self):
        t = FakeTerm("t1", "fresh", created=NOW - 5); t.root = "/wt/gcp"
        mt._by_tid["t1"] = t
        self.run_tick()
        self.assertFalse(Path(DESK, "local_fresh.json").exists())


unittest.main(verbosity=1)
PY
