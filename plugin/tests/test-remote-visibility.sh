#!/usr/bin/env bash
# 원격에 띄운 스택이 마리나 눈에 보여야 한다 — 대시보드도 게이트웨이도 여기서 출발한다.
#
# 게이트웨이 Caddyfile 은 스냅샷의 `port`/`running` 으로 만들어진다. 그 스냅샷은 `compose_ps` 가
# 채우는데, env 없이 부르면 **로컬 데몬**을 본다. 그러면 원격 스택이 "안 도는 것"으로 보이고
# upstream 이 아예 안 생겨서 `<wt>.<proj>.localhost` 가 열리지 않는다.
#
# docker 호출마다 따로 고치는 걸 그만두려고 라우팅을 공용 헬퍼 하나로 모은다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json, tempfile, unittest
from pathlib import Path

import marina_compose_svc as mcs
from marina_runtime_target import docker_env_for_root


class SharedHelperTests(unittest.TestCase):
    """라우팅 규칙은 한 군데만 산다 — 호출부마다 다시 구현하면 또 빠뜨린다."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def _remote(self):
        import marina_paths
        sd = marina_paths.session_dir(self.root)
        sd.mkdir(parents=True, exist_ok=True)
        (sd / "runtime-target.json").write_text(json.dumps({"kind": "remote", "host": "ssh://box"}))

    def test_local_root_yields_no_override(self):
        self.assertEqual(docker_env_for_root(self.root), {})

    def test_remote_root_yields_docker_host(self):
        self._remote()
        self.assertEqual(docker_env_for_root(self.root), {"DOCKER_HOST": "ssh://box"})

    def test_missing_root_is_safe(self):
        self.assertEqual(docker_env_for_root(None), {})
        self.assertEqual(docker_env_for_root(Path("/nope/nothing")), {})


class ComposePsRoutingTests(unittest.TestCase):
    """compose_ps 가 그 워크트리의 데몬을 봐야 한다."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.seen = []
        self._orig = mcs._ps_exec
        mcs.invalidate_remote_ps(None)

        def fake(argv, cwd, env, timeout):
            self.seen.append(env)
            return "[]"
        mcs._ps_exec = fake

    def tearDown(self):
        mcs._ps_exec = self._orig
        mcs.invalidate_remote_ps(None)
        self.tmp.cleanup()

    def test_local_passes_no_docker_host(self):
        mcs.compose_ps(self.root, "proj-wt")
        self.assertTrue(self.seen)
        self.assertTrue(self.seen[0] is None or "DOCKER_HOST" not in self.seen[0])

    def test_remote_routes_to_the_box(self):
        import marina_paths
        sd = marina_paths.session_dir(self.root)
        sd.mkdir(parents=True, exist_ok=True)
        (sd / "runtime-target.json").write_text(json.dumps({"kind": "remote", "host": "ssh://box"}))
        mcs.compose_ps(self.root, "proj-wt")
        self.assertTrue(self.seen)
        self.assertIsNotNone(self.seen[0], "원격인데 env 가 안 넘어갔다")
        self.assertEqual(self.seen[0].get("DOCKER_HOST"), "ssh://box")


unittest.main(verbosity=1)
PY
