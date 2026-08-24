#!/usr/bin/env bash
# 메모리 판단은 **컨테이너가 실제로 도는 기계**를 봐야 한다.
#
# 원격 모드에서 지금 코드는 macOS `sysctl`(개발자 맥)로 여유를 재고 `docker info`(로컬 데몬)로 용량을
# 잡는다. 두 값이 서로 다른 기계 것이라 판단이 양방향으로 틀린다 — 맥이 꽉 차면 여유로운 박스에서
# 띄우는 걸 막고, 맥이 한가하면 꽉 찬 박스에 더 밀어넣는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json, tempfile, unittest
from pathlib import Path

import marina_memory as mm
from marina_runtime_target import LocalTarget, RemoteTarget


class DockerEnvRoutingTests(unittest.TestCase):
    """docker 호출이 타깃의 데몬을 향해야 한다."""

    def setUp(self):
        self.calls = []
        self._orig = mm._run

        def fake(args, timeout, env=None):
            self.calls.append((args, dict(env) if env else None))
            return "{}"
        mm._run = fake

    def tearDown(self):
        mm._run = self._orig

    def test_local_passes_no_docker_host(self):
        mm.memory_snapshot(force=True, target=LocalTarget())
        self.assertTrue(self.calls, "docker 호출이 없었다")
        for args, env in self.calls:
            self.assertTrue(env is None or "DOCKER_HOST" not in env, f"로컬인데 DOCKER_HOST: {args}")

    def test_remote_routes_every_docker_call_to_the_box(self):
        mm.memory_snapshot(force=True, target=RemoteTarget("ssh://crabs@box"))
        docker_calls = [(a, e) for a, e in self.calls if "docker" in a[0]]
        self.assertTrue(docker_calls, "docker 호출이 없었다")
        for args, env in docker_calls:
            self.assertIsNotNone(env, f"원격인데 env 없음: {args}")
            self.assertEqual(env.get("DOCKER_HOST"), "ssh://crabs@box", f"라우팅 안 됨: {args}")

    def test_remote_also_reads_the_box_meminfo(self):
        # 호스트 여유는 ssh 로 박스에서 읽는다(docker 명령이 아니라 DOCKER_HOST 는 불필요).
        mm.memory_snapshot(force=True, target=RemoteTarget("ssh://crabs@box"))
        self.assertTrue(any(a[0] == "ssh" and "/proc/meminfo" in " ".join(a) for a, _ in self.calls),
                        "박스 meminfo 를 안 읽었다")


class HostMemoryTests(unittest.TestCase):
    """호스트 여유 메모리도 데몬을 따라가야 한다."""

    def test_local_reads_this_machine(self):
        got = mm.host_memory(LocalTarget())
        self.assertIn("totalMb", got)

    def test_remote_reads_the_box_over_ssh(self):
        seen = {}

        def fake(args, timeout, env=None):
            seen["args"] = args
            return "MemTotal:       64000000 kB\nMemAvailable:   32000000 kB\n"
        orig, mm._run = mm._run, fake
        try:
            got = mm.host_memory(RemoteTarget("ssh://crabs@192.168.0.251"))
        finally:
            mm._run = orig
        self.assertEqual(got["totalMb"], 62500)          # 64000000 kB → MiB
        self.assertEqual(got["availableMb"], 31250)
        self.assertEqual(got["availablePercent"], 50)
        self.assertIn("ssh", seen["args"][0])
        self.assertIn("crabs@192.168.0.251", seen["args"])
        self.assertIn("/proc/meminfo", " ".join(seen["args"]))

    def test_remote_ssh_port_is_honoured(self):
        seen = {}

        def fake(args, timeout, env=None):
            seen["args"] = args
            return "MemTotal: 1000 kB\nMemAvailable: 500 kB\n"
        orig, mm._run = mm._run, fake
        try:
            mm.host_memory(RemoteTarget("ssh://crabs@box:2222"))
        finally:
            mm._run = orig
        self.assertIn("-p", seen["args"])
        self.assertIn("2222", seen["args"])
        self.assertIn("crabs@box", seen["args"])

    def test_unreachable_box_does_not_raise(self):
        def boom(args, timeout, env=None):
            raise OSError("no route to host")
        orig, mm._run = mm._run, boom
        try:
            got = mm.host_memory(RemoteTarget("ssh://nope"))
        finally:
            mm._run = orig
        self.assertIsNone(got["totalMb"])               # 판단 불가 — 터지지 않고 unknown

    def test_non_ssh_remote_falls_back_to_unknown(self):
        # tcp:// 등 ssh 가 아닌 데몬은 meminfo 를 읽을 방법이 없다. 로컬 값을 쓰면 거짓말이 된다.
        got = mm.host_memory(RemoteTarget("tcp://box:2375"))
        self.assertIsNone(got["totalMb"])


class GuardTargetTests(unittest.TestCase):
    """memory_guard 는 워크트리 root 에서 타깃을 스스로 찾아야 한다(호출부 변경 없이)."""

    def test_guard_uses_worktree_target(self):
        import marina_paths
        tmp = tempfile.TemporaryDirectory()
        try:
            root = Path(tmp.name)
            sd = marina_paths.session_dir(root)
            sd.mkdir(parents=True, exist_ok=True)
            (sd / "runtime-target.json").write_text(
                json.dumps({"kind": "remote", "host": "ssh://box"}), encoding="utf-8")
            seen = []

            def fake(args, timeout, env=None):
                seen.append(dict(env) if env else None)
                return "{}"
            orig, mm._run = mm._run, fake
            try:
                mm.memory_guard(root, ["web"])
            finally:
                mm._run = orig
            self.assertTrue(seen, "docker 호출이 없었다")
            self.assertTrue(any(e and e.get("DOCKER_HOST") == "ssh://box" for e in seen),
                            "guard 가 워크트리 타깃을 안 따랐다")
        finally:
            tmp.cleanup()


unittest.main(verbosity=1)
PY
