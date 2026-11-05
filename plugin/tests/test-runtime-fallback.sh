#!/usr/bin/env bash
# 원격 박스가 꺼져 있으면 맥(로컬)으로 띄운다 — 형 2026-11-05 "어 보장 해야지. 도메인도 신경 써야돼".
#  - 원격 설정이어도 박스에 닿지 않으면 load_target 이 LocalTarget(fallback_from=주소)을 준다
#  - 그렇게 맥에서 띄운 워크트리는 '맥 고정' 기록을 남겨, 박스가 돌아와도 내릴(stop --all) 때까지 맥을 본다
#    (상태·로그·게이트웨이 도메인이 빈 박스를 가리키지 않게)
#  - 접속 확인은 결과를 잠깐 기억해 훅·게이트웨이가 매번 ssh 를 열지 않는다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

MARINA_REMOTE_PROBE=1 PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json, os, tempfile, unittest
from pathlib import Path

import marina_runtime_target as rt


class FallbackTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.sess = tempfile.mkdtemp()
        Path(self.sess, "runtime-target.json").write_text(json.dumps({"kind": "remote", "host": "ssh://box"}))
        self.calls = []
        self.up = True
        rt._HEALTH_TTL_S = 60.0
        rt._MEMO.clear()
        rt._probe = lambda dest, port: self.calls.append((dest, port)) or self.up

    def load(self):
        return rt.load_target(self.sess, home=self.home)

    def test_reachable_box_stays_remote(self):
        t = self.load()
        self.assertTrue(t.is_remote)
        self.assertEqual(self.calls, [("box", None)])

    def test_down_box_falls_back_to_local_with_origin(self):
        self.up = False
        t = self.load()
        self.assertFalse(t.is_remote)
        self.assertEqual(getattr(t, "fallback_from", None), "ssh://box")

    def test_probe_result_is_cached(self):
        self.load(); self.load(); self.load()
        self.assertEqual(len(self.calls), 1, "잠깐은 다시 확인하지 않는다")

    def test_cache_expires(self):
        self.load()
        f = next(Path(self.home, "remote-health").glob("*.json"))
        d = json.loads(f.read_text()); d["ts"] -= 3600; f.write_text(json.dumps(d))
        rt._MEMO.clear()           # 다른 프로세스(다음 명령)라고 친다
        self.load()
        self.assertEqual(len(self.calls), 2)

    def test_pin_keeps_local_even_when_box_returns(self):
        self.up = False
        t = self.load()
        rt.pin_local(self.sess, t)
        self.up = True
        rt._HEALTH_TTL_S = 0       # 박스가 돌아왔다고 다시 확인해도
        rt._MEMO.clear()
        t2 = self.load()
        self.assertFalse(t2.is_remote, "내릴 때까지 맥 고정")
        rt.unpin_local(self.sess)
        self.assertTrue(self.load().is_remote, "내리면 다시 원격")

    def test_pin_only_written_for_fallback(self):
        rt.pin_local(self.sess, rt.LocalTarget())
        rt.pin_local(self.sess, rt.RemoteTarget("ssh://box"))
        self.assertFalse(Path(self.sess, rt.PIN_NAME).exists())

    def test_user_and_port_are_passed_to_probe(self):
        Path(self.sess, "runtime-target.json").write_text(json.dumps({"kind": "remote", "host": "ssh://me@box2:2222"}))
        self.load()
        self.assertEqual(self.calls[-1], ("me@box2", "2222"))

    def test_non_ssh_host_is_not_probed(self):
        Path(self.sess, "runtime-target.json").write_text(json.dumps({"kind": "remote", "host": "tcp://10.0.0.1:2375"}))
        self.assertTrue(self.load().is_remote)
        self.assertEqual(self.calls, [])

    def test_reclaim_view_never_falls_back(self):
        # 회수·GC 는 꺼진 박스 대신 맥 자원을 지우면 안 된다(리뷰 I3)
        self.up = False
        self.assertTrue(rt.load_target(self.sess, home=self.home, fallback=False).is_remote)

    def test_pin_for_other_host_is_ignored_and_config_change_clears_pin(self):
        # 고정은 그 박스 때문일 때만 — 설정을 바꾸면 풀린다(리뷰 I5)
        self.up = False
        rt.pin_local(self.sess, self.load())
        self.up = True
        rt._MEMO.clear(); rt._HEALTH_TTL_S = 0
        Path(self.sess, "runtime-target.json").write_text(json.dumps({"kind": "remote", "host": "ssh://other"}))
        self.assertTrue(self.load().is_remote, "다른 박스로 바꿨으면 고정을 안 따른다")
        rt.write_target(self.sess, "remote", "ssh://box")
        self.assertFalse(Path(self.sess, rt.PIN_NAME).exists(), "설정을 쓰면 고정을 지운다")

    def test_one_process_answers_consistently(self):
        # up 한 번에 타깃을 여러 번 구해도 같은 답(리뷰 I1)
        rt._HEALTH_TTL_S = 0
        a = self.load().is_remote
        self.up = False
        self.assertEqual(self.load().is_remote, a)
        self.assertEqual(len(self.calls), 1)

    def test_probe_off_switch(self):
        os.environ["MARINA_REMOTE_PROBE"] = "0"
        try:
            self.up = False
            self.assertTrue(self.load().is_remote)
            self.assertEqual(self.calls, [])
        finally:
            os.environ["MARINA_REMOTE_PROBE"] = "1"


if __name__ == "__main__":
    unittest.main(verbosity=1)
PY
echo "PASS test-runtime-fallback"
