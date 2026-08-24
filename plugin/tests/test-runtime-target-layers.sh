#!/usr/bin/env bash
# 런타임 타깃의 계층: **전역 기본 < 세션(워크트리) override**.
#
# 형 지시(2026-08-24): "전역 설정으로 고르게 하고, 각 세션에서도 변경 가능하게."
# 박스 주소는 전역에 한 번 저장하고(팀원이 매번 IP 를 칠 일 없게), 워크트리별로는 켜고 끄기만 한다.
# 세션이 켜기만 하고 주소를 안 적으면 전역 주소를 물려받는다 — 그게 실사용 형태다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json, tempfile, unittest
from pathlib import Path

from marina_runtime_target import load_target


class LayerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name, "home"); self.home.mkdir()
        self.session = Path(self.tmp.name, "session"); self.session.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def write_global(self, data):
        (self.home / "runtime-target.json").write_text(json.dumps(data), encoding="utf-8")

    def write_session(self, data):
        (self.session / "runtime-target.json").write_text(json.dumps(data), encoding="utf-8")

    def load(self):
        return load_target(str(self.session), home=str(self.home))

    # ── 아무것도 없으면 로컬 ──
    def test_nothing_configured_is_local(self):
        self.assertFalse(self.load().is_remote)

    # ── 전역만 있으면 전역을 따른다 ──
    def test_global_remote_applies(self):
        self.write_global({"kind": "remote", "host": "ssh://box"})
        t = self.load()
        self.assertTrue(t.is_remote)
        self.assertEqual(t.host, "ssh://box")

    def test_global_local_is_local(self):
        self.write_global({"kind": "local"})
        self.assertFalse(self.load().is_remote)

    # ── 세션이 전역을 덮는다(양방향) ──
    def test_session_remote_overrides_global_local(self):
        self.write_global({"kind": "local"})
        self.write_session({"kind": "remote", "host": "ssh://mine"})
        t = self.load()
        self.assertTrue(t.is_remote)
        self.assertEqual(t.host, "ssh://mine")

    def test_session_local_overrides_global_remote(self):
        # 전역이 원격이어도 이 워크트리만 로컬로 되돌릴 수 있어야 한다.
        self.write_global({"kind": "remote", "host": "ssh://box"})
        self.write_session({"kind": "local"})
        self.assertFalse(self.load().is_remote)

    # ── 세션이 주소를 생략하면 전역 주소를 물려받는다(실사용 형태) ──
    def test_session_remote_without_host_inherits_global_host(self):
        self.write_global({"kind": "remote", "host": "ssh://box"})
        self.write_session({"kind": "remote"})
        t = self.load()
        self.assertTrue(t.is_remote)
        self.assertEqual(t.host, "ssh://box")

    def test_session_remote_without_host_and_no_global_host_is_local(self):
        # 물려받을 주소도 없으면 로컬로 떨어진다 — 어디로 갈지 모르는 채 원격을 시도하지 않는다.
        self.write_session({"kind": "remote"})
        self.assertFalse(self.load().is_remote)

    def test_session_host_beats_global_host(self):
        self.write_global({"kind": "remote", "host": "ssh://box"})
        self.write_session({"kind": "remote", "host": "ssh://other"})
        self.assertEqual(self.load().host, "ssh://other")

    # ── 깨진 파일은 무시하고 다음 계층으로 ──
    def test_broken_session_file_falls_back_to_global(self):
        self.write_global({"kind": "remote", "host": "ssh://box"})
        (self.session / "runtime-target.json").write_text("{ not json", encoding="utf-8")
        self.assertTrue(self.load().is_remote)

    def test_broken_global_file_is_local(self):
        (self.home / "runtime-target.json").write_text("{ not json", encoding="utf-8")
        self.assertFalse(self.load().is_remote)

    # ── 기존 호출 형태(home 없음)가 계속 동작해야 한다 ──
    def test_home_argument_is_optional(self):
        self.write_session({"kind": "remote", "host": "ssh://only-session"})
        self.assertEqual(load_target(str(self.session)).host, "ssh://only-session")


unittest.main(verbosity=1)
PY
