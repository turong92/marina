#!/usr/bin/env bash
# 런타임 타깃이 실제 compose 호출의 env 에 물리는지.
#
# 모든 compose 호출이 `_env_with()` 에서 env 를 받는다(marina-compose.py 의 up/watch/config/build 전부).
# 초크포인트가 하나라서, 여기에 타깃의 docker_env() 를 합치면 원격 지정이 끝난다.
# 로컬은 반드시 **빈 델타**여야 한다 — 기존 호출과 한 글자도 달라지면 안 된다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS/marina-compose.py" <<'PY'
import importlib.util, json, os, sys, tempfile, unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("mctl", sys.argv[1])
mctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mctl)


class EnvWiringTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.session = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_local_session_adds_nothing(self):
        base = mctl._env_with([])
        withsess = mctl._env_with([], session_dir=self.session)
        self.assertEqual(base, withsess)
        self.assertNotIn("DOCKER_HOST", withsess)

    def test_remote_session_sets_docker_host(self):
        Path(self.session, "runtime-target.json").write_text(
            json.dumps({"kind": "remote", "host": "ssh://crabs@192.168.0.251"}), encoding="utf-8")
        env = mctl._env_with([], session_dir=self.session)
        self.assertEqual(env["DOCKER_HOST"], "ssh://crabs@192.168.0.251")

    def test_explicit_override_beats_target(self):
        # 사용자가 --env DOCKER_HOST=... 를 직접 주면 그게 이긴다(디버깅 탈출구).
        Path(self.session, "runtime-target.json").write_text(
            json.dumps({"kind": "remote", "host": "ssh://box"}), encoding="utf-8")
        env = mctl._env_with(["DOCKER_HOST=unix:///var/run/docker.sock"], session_dir=self.session)
        self.assertEqual(env["DOCKER_HOST"], "unix:///var/run/docker.sock")

    def test_session_dir_is_optional(self):
        # 기존 호출부가 session_dir 없이 부르던 형태가 계속 동작해야 한다.
        self.assertNotIn("DOCKER_HOST", mctl._env_with([]))


unittest.main(argv=[sys.argv[0]], verbosity=1)
PY
