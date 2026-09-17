#!/usr/bin/env bash
# 원격 타깃 compose ps 가 박스를 두드리지 않는다 — 캐시·합치기·백오프·프로세스 그룹 종료.
#
# 사고(2026-09-17): 사무실 박스(192.168.0.251)에 `docker system dial-stdio` 고아가 1,507개 쌓였다. 원격 타깃을 쓰는
# 팀원 맥 두 대의 marina 데몬이 이벤트 루프(3초)·게이트웨이 루프(5초)마다 워크트리별 compose ps 를 새 ssh 로 날렸고
# (sshd 로그: 두 키로 09시 이후 36,000회 접속), 박스 데몬이 멈춘 동안 그 호출마다 dial-stdio 가 고아로 남았다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json, os, subprocess, sys, tempfile, threading, time, unittest
from pathlib import Path

import marina_compose_svc as mcs
import marina_paths


def _make_remote(root: Path, host="ssh://box"):
    sd = marina_paths.session_dir(root)
    sd.mkdir(parents=True, exist_ok=True)
    (sd / "runtime-target.json").write_text(json.dumps({"kind": "remote", "host": host}))


class RemotePsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name, "wt"); self.root.mkdir()
        self.calls = []
        self.behaviour = lambda: '[{"Service": "web", "State": "running"}]'
        self._orig = mcs._ps_exec
        self._ttl = mcs._REMOTE_PS_TTL_S
        mcs.invalidate_remote_ps(None)

        def fake(argv, cwd, env, timeout):
            self.calls.append((env or {}).get("DOCKER_HOST"))
            return self.behaviour()
        mcs._ps_exec = fake

    def tearDown(self):
        mcs._ps_exec = self._orig
        mcs._REMOTE_PS_TTL_S = self._ttl
        mcs.invalidate_remote_ps(None)
        self.tmp.cleanup()

    def test_local_is_not_cached(self):
        for _ in range(3):
            mcs.compose_ps(self.root, "p")
        self.assertEqual(self.calls, [None, None, None], "로컬은 지금처럼 매번 부른다")

    def test_remote_reuses_within_ttl(self):
        _make_remote(self.root)
        rows = [mcs.compose_ps(self.root, "p") for _ in range(20)]
        self.assertEqual(len(self.calls), 1, "TTL 안에서는 박스에 한 번만 붙는다")
        self.assertTrue(all(r == [{"Service": "web", "State": "running"}] for r in rows))

    def test_remote_refetches_after_ttl(self):
        _make_remote(self.root)
        mcs._REMOTE_PS_TTL_S = 0.05
        mcs.compose_ps(self.root, "p"); time.sleep(0.08); mcs.compose_ps(self.root, "p")
        self.assertEqual(len(self.calls), 2)

    def test_concurrent_callers_coalesce(self):
        _make_remote(self.root)
        gate = threading.Event()

        def slow():
            gate.wait(1)
            return '[{"Service": "web", "State": "running"}]'
        self.behaviour = slow
        results = []
        ts = [threading.Thread(target=lambda: results.append(mcs.compose_ps(self.root, "p"))) for _ in range(8)]
        for t in ts: t.start()
        time.sleep(0.2); gate.set()
        for t in ts: t.join(3)
        self.assertEqual(len(self.calls), 1, "이벤트·게이트웨이·대시보드가 동시에 불러도 접속은 하나")
        self.assertEqual(len(results), 8)
        self.assertTrue(all(r == [{"Service": "web", "State": "running"}] for r in results), results)

    def test_failure_backs_off_and_serves_stale(self):
        _make_remote(self.root)
        mcs._REMOTE_PS_TTL_S = 0.0                      # 캐시 효과를 빼고 백오프만 본다
        good = mcs.compose_ps(self.root, "p")
        self.assertEqual(len(self.calls), 1)

        def boom():
            raise subprocess.TimeoutExpired("docker", 5)
        self.behaviour = boom
        r1 = mcs.compose_ps(self.root, "p")             # 실패 1회 → 박스 쉬게 함
        for _ in range(50):
            r = mcs.compose_ps(self.root, "p")
        self.assertEqual(len(self.calls), 2, "실패한 박스는 백오프 동안 다시 안 붙는다(고아가 쌓이던 구간)")
        self.assertEqual(r1, good); self.assertEqual(r, good)   # 마지막으로 본 값
        h = mcs.remote_ps_health()["ssh://box"]
        self.assertEqual(h["fails"], 1); self.assertGreater(h["retryInS"], 20)

    def test_backoff_is_per_host_and_grows(self):
        _make_remote(self.root, "ssh://a")
        other = Path(self.tmp.name, "wt2"); other.mkdir(); _make_remote(other, "ssh://b")
        mcs._REMOTE_PS_TTL_S = 0.0

        def boom():
            raise subprocess.CalledProcessError(255, "docker")
        self.behaviour = boom
        mcs.compose_ps(self.root, "p")
        self.behaviour = lambda: "[]"
        mcs.compose_ps(other, "q")
        self.assertEqual(self.calls, ["ssh://a", "ssh://b"], "a 가 죽어도 b 는 계속 본다")
        with mcs._remote_ps_lock:                      # 백오프 만료를 흉내 → 다시 실패하면 두 배
            mcs._remote_health["ssh://a"]["until"] = 0
        self.behaviour = boom
        mcs.compose_ps(self.root, "p")
        self.assertEqual(mcs.remote_ps_health()["ssh://a"]["fails"], 2)
        self.assertGreater(mcs.remote_ps_health()["ssh://a"]["retryInS"], 50)

    def test_invalidate_clears_cache_and_backoff(self):
        _make_remote(self.root)
        mcs.compose_ps(self.root, "p")
        mcs.invalidate_remote_ps(self.root)
        mcs.compose_ps(self.root, "p")
        self.assertEqual(len(self.calls), 2, "start/stop 직후엔 바로 새로 본다")


class ProcessGroupKillTests(unittest.TestCase):
    """타임아웃이면 docker CLI 의 자식(원격이면 ssh)까지 죽는다 — check_output 은 직계만 죽였다."""

    def test_timeout_kills_grandchildren(self):
        with tempfile.TemporaryDirectory() as td:
            marker = Path(td, "grandchild.pid")
            script = Path(td, "fake-docker")
            script.write_text(f"#!/usr/bin/env bash\nsleep 30 & echo $! > {marker}\nwait\n")
            script.chmod(0o755)
            with self.assertRaises(subprocess.TimeoutExpired):
                mcs._ps_exec([str(script)], td, None, 0.5)
            time.sleep(0.3)
            pid = int(marker.read_text().strip())
            alive = subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0
            if alive:
                os.kill(pid, 9)
            self.assertFalse(alive, "타임아웃 뒤 손자 프로세스(ssh 자리)가 살아 있다")

    def test_nonzero_exit_raises(self):
        with self.assertRaises(subprocess.CalledProcessError):
            mcs._ps_exec(["false"], "/", None, 5)


unittest.main(verbosity=1)
PY
echo "PASS test-remote-ps-flood"
