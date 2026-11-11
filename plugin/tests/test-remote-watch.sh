#!/usr/bin/env bash
# 박스에 띄운 스택이 박스가 꺼지면 맥으로 다시 뜬다 — 형 2026-11-05 "중간에 꺼지는 것도 다 해".
#  - 두 번 연속 안 닿아야 옮긴다(순간 끊김은 넘긴다)
#  - 옮기기 전에 '맥 고정'을 남기고 죽은 터널 기록을 지운다
#  - 맥 고정이거나 터널 기록이 없는(안 떠 있는) 워크트리는 건드리지 않는다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path

import marina_paths
import marina_remote_watch as w
import marina_runtime_target as rt


class WatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = self.tmp / "wt"
        self.root.mkdir()
        self.sd = marina_paths.session_dir(self.root)
        self.sd.mkdir(parents=True)
        (self.sd / "remote-owned.json").write_text(json.dumps({"host": "ssh://box", "project": "p"}))
        (self.sd / "remote-tunnel.pid").write_text("123\n")
        self.up = True
        self.started = []
        self.logs = []

    def tick(self, misses):
        return w.tick([self.root], misses, log=self.logs.append, reachable=lambda h: self.up,
                      start_local=lambda r: self.started.append(r) or 0)

    def test_up_box_is_left_alone(self):
        m = {}
        self.assertEqual(self.tick(m), [])
        self.assertEqual(self.started, [])

    def test_two_misses_move_stack_to_mac_with_pin(self):
        self.up = False
        m = {}
        self.assertEqual(self.tick(m), [], "한 번은 넘긴다")
        self.assertEqual(self.tick(m), [self.root])
        self.assertEqual(self.started, [self.root])
        self.assertEqual(rt._pinned_from(str(self.sd)), "ssh://box", "먼저 맥 고정")
        self.assertFalse((self.sd / "remote-tunnel.pid").exists())
        self.assertIn("맥에서 다시 띄움", self.logs[-1])
        self.assertEqual(self.tick(m), [], "고정 뒤엔 다시 안 옮긴다")

    def test_blip_resets_count(self):
        m = {}
        self.up = False; self.tick(m)
        self.up = True; self.tick(m)
        self.up = False; self.tick(m)
        self.assertEqual(self.started, [], "연속이 아니면 안 옮긴다")

    def test_dead_tunnel_reopened_when_box_up(self):
        # 박스는 닿는데 터널 프로세스만 죽음 → 적어 둔 같은 명령으로 다시 연다(2026-11-09 story-chat 게이트웨이 502)
        dead = subprocess.Popen(["true"]); dead.wait()
        argv = ["ssh", "-N", "-L", "127.0.0.1:33025:127.0.0.1:33025", "box"]
        (self.sd / "remote-tunnel.pid").write_text(f"{dead.pid}\n{json.dumps(argv)}\n")
        spawned = []
        new = w.reopen_tunnel(self.sd, spawn=lambda a, log: spawned.append(a) or 4242)
        self.assertEqual((new, spawned), (4242, [argv]))
        self.assertEqual((self.sd / "remote-tunnel.pid").read_text().splitlines()[0], "4242")
        live = (self.sd / "remote-tunnel.pid")
        live.write_text(f"{os.getpid()}\n{json.dumps(argv)}\n")
        self.assertIsNone(w.reopen_tunnel(self.sd, spawn=lambda a, log: 1), "살아 있으면 그대로")
        live.write_text(f"{dead.pid}\n")
        self.assertIsNone(w.reopen_tunnel(self.sd, spawn=lambda a, log: 1), "명령 기록이 없는 옛 형식은 손대지 않는다")
        live.write_text(f"{dead.pid}\n{json.dumps(['rm', '-rf', '/'])}\n")
        self.assertIsNone(w.reopen_tunnel(self.sd, spawn=lambda a, log: 1), "ssh 가 아니면 안 돌린다")
        m = {}
        calls = []
        w.tick([self.root], m, log=self.logs.append, reachable=lambda h: True,
               start_local=lambda r: 0, reopen=lambda sd: calls.append(sd) or 77)
        self.assertEqual(calls, [self.sd])
        self.assertIn("다시 열었어", self.logs[-1])

    # ── 박스가 돌아오면 다시 박스로(형 2026-11-11 "지속적으로 핑 때려봐서 붙으면 다시 걸로 이사") ──
    # 2026-11-11 15:25 사무실 공유기 끊김에 스택 5개가 맥으로 옮겨지다 실패(rc=1)했는데 고정만 남아,
    # 박스가 멀쩡해진 뒤에도 다음 start 가 맥 빌드로 빠졌다.
    def tick2(self, misses, local=False, notes=None, rc=0):
        return w.tick([self.root], misses, log=self.logs.append, reachable=lambda h: self.up,
                      start_local=lambda r: self.started.append(r) or rc,
                      local_running=lambda name: local,
                      notify=lambda r, msg: (notes if notes is not None else []).append((r, msg)))

    def test_failed_local_start_unpins_when_nothing_runs_on_mac(self):
        self.up = False
        m = {}
        self.tick2(m, rc=1); self.tick2(m, rc=1)
        self.assertEqual(self.started, [self.root])
        self.assertIsNone(rt._pinned_from(str(self.sd)), "맥에 아무것도 안 떴으면 고정을 남기지 않는다")
        self.assertTrue((self.sd / "remote-owned.json").exists(), "박스 기록은 그대로")

    def test_box_back_and_mac_idle_unpins_after_steady_hits(self):
        rt.pin_local(str(self.sd), rt.LocalTarget(fallback_from="ssh://box"))
        (self.sd / "remote-tunnel.pid").unlink()
        self.up = True
        m = {}
        for _ in range(w.RETURN_HITS - 1):
            self.tick2(m)
            self.assertEqual(rt._pinned_from(str(self.sd)), "ssh://box", "몇 번 연속 붙어야 돌아온 걸로 본다")
        self.tick2(m)
        self.assertIsNone(rt._pinned_from(str(self.sd)), "박스가 돌아왔고 맥이 비었으면 고정을 푼다")
        self.assertIn("박스", self.logs[-1])

    def test_box_blip_resets_return_count(self):
        rt.pin_local(str(self.sd), rt.LocalTarget(fallback_from="ssh://box"))
        m = {}
        for _ in range(w.RETURN_HITS - 1):
            self.up = True; self.tick2(m)
        self.up = False; self.tick2(m)
        self.up = True; self.tick2(m)
        self.assertEqual(rt._pinned_from(str(self.sd)), "ssh://box", "연속이 끊기면 처음부터")

    def test_box_back_but_mac_running_notifies_once_and_keeps_pin(self):
        rt.pin_local(str(self.sd), rt.LocalTarget(fallback_from="ssh://box"))
        self.up = True
        m, notes = {}, []
        for _ in range(w.RETURN_HITS + 3):
            self.tick2(m, local=True, notes=notes)
        self.assertEqual(rt._pinned_from(str(self.sd)), "ssh://box", "맥에서 도는 걸 자동으로 옮기지 않는다")
        self.assertEqual(len(notes), 1, f"알림은 한 번만: {notes}")
        self.assertIn("stop --all", notes[0][1])

    def test_not_running_stack_is_ignored(self):
        (self.sd / "remote-tunnel.pid").unlink()
        self.up = False
        m = {}
        self.tick(m); self.tick(m)
        self.assertEqual(self.started, [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
PY
echo "PASS test-remote-watch"
