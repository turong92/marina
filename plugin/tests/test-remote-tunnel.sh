#!/usr/bin/env bash
# 원격에서 뜬 포트를 개발자 맥으로 되돌린다(ssh -L).
#
# 왜 필요한가. 컨테이너 포트는 **박스의 루프백**에 게시된다(공용 박스라 LAN 노출을 피한다).
# 그런데 게이트웨이 Caddy 는 개발자 맥에서 돌며 맥의 `127.0.0.1:<port>` 로 프록시한다.
# 터널이 없으면 박스에 뜬 걸 맥에서 열 수 없다 — 빌드·기동은 되는데 브라우저로 못 본다.
#
# 같은 포트 번호로 되돌리는 게 핵심이다. 그래야 Caddyfile 생성이 로컬과 **글자 하나 안 달라진다**.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS/marina-compose.py" <<'PY'
import importlib.util, sys, unittest

spec = importlib.util.spec_from_file_location("mctl", sys.argv[1])
mctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mctl)

from marina_runtime_target import LocalTarget, RemoteTarget

PS = """[
 {"Service":"web","Publishers":[{"PublishedPort":32768,"TargetPort":3000,"Protocol":"tcp"}]},
 {"Service":"user-api-bind","Publishers":[{"PublishedPort":32769,"TargetPort":8081,"Protocol":"tcp"}]},
 {"Service":"batch","Publishers":[{"PublishedPort":0,"TargetPort":8081,"Protocol":"tcp"}]}
]"""


class TunnelPortsTests(unittest.TestCase):
    def test_collects_published_ports(self):
        self.assertEqual(mctl.tunnel_ports(PS), [32768, 32769])

    def test_zero_published_is_skipped(self):
        # PublishedPort 0 = 게시 안 됨(사이드카 netns 에 합류한 앱). 터널 대상 아니다.
        self.assertNotIn(0, mctl.tunnel_ports(PS))

    def test_deduplicates_and_sorts(self):
        dup = '[{"Service":"a","Publishers":[{"PublishedPort":5,"Protocol":"tcp"}]},' \
              ' {"Service":"b","Publishers":[{"PublishedPort":5,"Protocol":"tcp"}]}]'
        self.assertEqual(mctl.tunnel_ports(dup), [5])

    def test_empty_input_is_safe(self):
        self.assertEqual(mctl.tunnel_ports(""), [])
        self.assertEqual(mctl.tunnel_ports("not json"), [])


class TunnelArgvTests(unittest.TestCase):
    def test_same_port_both_sides(self):
        # 같은 번호로 되돌려야 게이트웨이 생성이 로컬과 동일해진다.
        argv = mctl.tunnel_argv("ssh://crabs@box", [32768, 32769])
        self.assertIn("-L", argv)
        self.assertIn("32768:127.0.0.1:32768", argv)
        self.assertIn("32769:127.0.0.1:32769", argv)
        self.assertIn("crabs@box", argv)

    def test_one_process_carries_every_port(self):
        argv = mctl.tunnel_argv("ssh://box", [1, 2, 3])
        self.assertEqual(argv.count("-L"), 3)
        self.assertEqual(argv[0], "ssh")

    def test_stays_in_foreground_and_runs_nothing(self):
        # 마리나가 pid 로 수명을 관리한다 → -f(백그라운드 포크) 금지. -N = 원격 명령 실행 안 함.
        argv = mctl.tunnel_argv("ssh://box", [1])
        self.assertIn("-N", argv)
        self.assertNotIn("-f", argv)

    def test_survives_flaky_links(self):
        # 터널이 조용히 죽으면 브라우저가 먹통이 된다 — keepalive 로 끊김을 빨리 드러낸다.
        argv = " ".join(mctl.tunnel_argv("ssh://box", [1]))
        self.assertIn("ServerAliveInterval", argv)
        self.assertIn("ExitOnForwardFailure=yes", argv)   # 포트 못 잡으면 조용히 살아있지 말고 죽어라

    def test_port_is_honoured(self):
        argv = mctl.tunnel_argv("ssh://crabs@box:2222", [1])
        self.assertIn("-p", argv)
        self.assertIn("2222", argv)
        self.assertIn("crabs@box", argv)

    def test_non_ssh_target_has_no_tunnel(self):
        self.assertIsNone(mctl.tunnel_argv("tcp://box:2375", [1]))

    def test_no_ports_means_no_tunnel(self):
        self.assertIsNone(mctl.tunnel_argv("ssh://box", []))


class TunnelNeededTests(unittest.TestCase):
    def test_local_never_tunnels(self):
        self.assertFalse(mctl.tunnel_needed(LocalTarget()))

    def test_remote_ssh_tunnels(self):
        self.assertTrue(mctl.tunnel_needed(RemoteTarget("ssh://box")))

    def test_remote_non_ssh_does_not(self):
        self.assertFalse(mctl.tunnel_needed(RemoteTarget("tcp://box:2375")))


class LifecycleTargetTests(unittest.TestCase):
    """stop/down/restart/status 도 그 워크트리의 데몬을 향해야 한다.

    안 그러면 원격에 띄운 스택을 마리나로 **정지조차 못 한다** — 로컬 데몬을 보며 "없다"고 한다."""

    def test_helper_exists(self):
        self.assertTrue(hasattr(mctl, "_lifecycle_env"), "_lifecycle_env 가 없다")

    def test_local_is_empty_delta(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            self.assertNotIn("DOCKER_HOST", mctl._lifecycle_env(d))

    def test_remote_is_routed(self):
        import json, tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as d:
            Path(d, "runtime-target.json").write_text(json.dumps({"kind": "remote", "host": "ssh://box"}))
            self.assertEqual(mctl._lifecycle_env(d)["DOCKER_HOST"], "ssh://box")

    def test_missing_session_dir_is_local(self):
        self.assertNotIn("DOCKER_HOST", mctl._lifecycle_env(None))

unittest.main(argv=[sys.argv[0]], verbosity=1)
PY
