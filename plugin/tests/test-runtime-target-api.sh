#!/usr/bin/env bash
# 대시보드에서 런타임 타깃을 읽고 바꾼다.
#
# 자리는 **서버 현황(메모리) 영역**이다(형 판단, 2026-08-24). 워크트리마다 칩을 다는 것보다 낫고,
# 무엇보다 **필수**다 — 원격이면 그 영역에 뜨는 Docker/Host 숫자가 이미 박스의 것이라,
# 어느 기계인지 안 적으면 표시가 거짓말이 된다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json, tempfile, unittest
from pathlib import Path

from marina_runtime_target import describe, load_target, write_target


class DescribeTests(unittest.TestCase):
    """대시보드가 그대로 그릴 수 있는 모양이어야 한다."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name, "home"); self.home.mkdir()
        self.session = Path(self.tmp.name, "s"); self.session.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_local_shape(self):
        d = describe(str(self.session), home=str(self.home))
        self.assertEqual(d["kind"], "local")
        self.assertIsNone(d["host"])
        self.assertEqual(d["scope"], "default")      # 아무도 말 안 함 = 기본값
        self.assertIsNone(d["globalHost"])

    def test_global_remote_scope(self):
        write_target(str(self.home), "remote", "ssh://box")
        d = describe(str(self.session), home=str(self.home))
        self.assertEqual(d["kind"], "remote")
        self.assertEqual(d["host"], "ssh://box")
        self.assertEqual(d["scope"], "global")       # 전역이 정했다
        self.assertEqual(d["globalHost"], "ssh://box")

    def test_session_override_scope(self):
        write_target(str(self.home), "remote", "ssh://box")
        write_target(str(self.session), "local", None)
        d = describe(str(self.session), home=str(self.home))
        self.assertEqual(d["kind"], "local")
        self.assertEqual(d["scope"], "session")      # 이 워크트리가 덮었다 — UI 가 구분해 보여야 한다
        self.assertEqual(d["globalHost"], "ssh://box")   # 되돌릴 대상이 뭔지 알 수 있게


class WriteTargetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_write_remote_then_read_back(self):
        write_target(str(self.d), "remote", "ssh://box")
        self.assertEqual(load_target(str(self.d), home=str(self.d)).host, "ssh://box")

    def test_write_local(self):
        write_target(str(self.d), "local", None)
        self.assertFalse(load_target(str(self.d), home=str(self.d)).is_remote)

    def test_inherit_removes_the_file(self):
        write_target(str(self.d), "remote", "ssh://box")
        write_target(str(self.d), "inherit", None)
        self.assertFalse((self.d / "runtime-target.json").exists())

    def test_write_is_atomic_no_temp_left_behind(self):
        write_target(str(self.d), "remote", "ssh://box")
        leftovers = [p.name for p in self.d.iterdir() if p.name.startswith(".runtime-target.")]
        self.assertEqual(leftovers, [])

    def test_unknown_kind_rejected(self):
        with self.assertRaises(ValueError):
            write_target(str(self.d), "bogus", None)

    def test_remote_without_host_is_valid_for_a_session(self):
        # 세션 계층에선 정상 — 전역 주소를 물려받는다. "전역엔 무의미" 규칙은 계층을 아는
        # 호출부(CLI·API)가 갖는다. 여기서 막으면 정상 형태를 표현할 수 없다.
        write_target(str(self.d), "remote", None)
        self.assertEqual(json.loads((self.d / "runtime-target.json").read_text()), {"kind": "remote"})


unittest.main(verbosity=1)
PY
