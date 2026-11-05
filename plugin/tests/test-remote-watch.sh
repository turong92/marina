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
import json, shutil, tempfile, unittest
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
