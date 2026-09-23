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


def _tsv(project="p", service="web", state="running", status="Up 2 minutes", ports=""):
    """박스가 돌려주는 `docker ps --format <탭>` 한 줄. 원격 조회는 이제 박스 단위 `docker ps` 다."""
    return "\t".join([f"{project}-{service}-1", state, status, ports, project, service]) + "\n"


def _row(project="p", service="web", state="running", health="", exit_code=None, pubs=None):
    return {"Service": service, "Name": f"{project}-{service}-1", "State": state,
            "Health": health, "ExitCode": exit_code, "Publishers": pubs or []}


def _make_remote(root: Path, host="ssh://box"):
    sd = marina_paths.session_dir(root)
    sd.mkdir(parents=True, exist_ok=True)
    (sd / "runtime-target.json").write_text(json.dumps({"kind": "remote", "host": host}))


class RemotePsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name, "wt"); self.root.mkdir()
        self.calls = []
        self.behaviour = lambda: _tsv()
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
        self.assertTrue(all(r == [_row()] for r in rows))

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
            return _tsv()
        self.behaviour = slow
        results = []
        ts = [threading.Thread(target=lambda: results.append(mcs.compose_ps(self.root, "p"))) for _ in range(8)]
        for t in ts: t.start()
        deadline = time.time() + 2                                    # 리더가 실제로 조회에 들어갈 때까지(고정 sleep 대신)
        while not self.calls and time.time() < deadline: time.sleep(0.01)
        time.sleep(0.1); gate.set()
        for t in ts: t.join(3)
        self.assertEqual(len(self.calls), 1, "이벤트·게이트웨이·대시보드가 동시에 불러도 접속은 하나")
        self.assertEqual(len(results), 8)
        self.assertTrue(all(r == [_row()] for r in results), results)

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
        self.behaviour = lambda: ""
        mcs.compose_ps(other, "q")
        self.assertEqual(self.calls, ["ssh://a", "ssh://b"], "a 가 죽어도 b 는 계속 본다")
        with mcs._remote_ps_lock:                      # 백오프 만료를 흉내 → 다시 실패하면 두 배
            mcs._remote_health["ssh://a"]["until"] = 0
        self.behaviour = boom
        mcs.compose_ps(self.root, "p")
        self.assertEqual(mcs.remote_ps_health()["ssh://a"]["fails"], 2)
        self.assertGreater(mcs.remote_ps_health()["ssh://a"]["retryInS"], 50)

    def test_invalidate_during_inflight_does_not_resurrect_old_rows(self):
        _make_remote(self.root)
        started, release = threading.Event(), threading.Event()

        def slow_old():
            started.set(); release.wait(2)
            return _tsv(state="exited", status="Exited (0) 1 second ago")     # 조작 전 상태
        self.behaviour = slow_old
        t = threading.Thread(target=lambda: mcs.compose_ps(self.root, "p")); t.start()
        started.wait(2)
        mcs.invalidate_remote_ps(self.root)                         # 그 사이 start 가 끝남
        release.set(); t.join(3)
        self.behaviour = lambda: _tsv()
        self.assertEqual(mcs.compose_ps(self.root, "p"), [_row()],
                         "무효화 전에 출발한 조회가 옛 행을 캐시에 되살렸다")
        self.assertEqual(len(self.calls), 2)

    def test_local_cause_does_not_back_off_the_box(self):
        _make_remote(self.root)
        other = Path(self.tmp.name, "wt3"); other.mkdir(); _make_remote(other)
        mcs._REMOTE_PS_TTL_S = 0.0

        def missing_cwd():
            raise FileNotFoundError("worktree gone")
        self.behaviour = missing_cwd
        self.assertEqual(mcs.compose_ps(self.root, "p"), [])
        self.behaviour = lambda: ""
        mcs.compose_ps(other, "q")
        self.assertEqual(len(self.calls), 2, "로컬 원인 실패로 같은 박스의 다른 프로젝트까지 쉬면 안 된다")
        self.assertNotIn("ssh://box", mcs.remote_ps_health())

    def test_box_failure_pauses_every_project_on_that_box(self):
        _make_remote(self.root)
        other = Path(self.tmp.name, "wt4"); other.mkdir(); _make_remote(other)
        mcs._REMOTE_PS_TTL_S = 0.0

        def hung():
            raise subprocess.TimeoutExpired("docker", 5)
        self.behaviour = hung
        mcs.compose_ps(self.root, "p")
        mcs.compose_ps(other, "q")
        self.assertEqual(len(self.calls), 1, "멈춘 박스는 프로젝트가 달라도 같이 쉰다(고아는 박스 단위로 생긴다)")

    def test_one_query_serves_every_project_on_the_box(self):
        """박스에 워크트리가 몇 개든 조회는 한 번 — `docker ps` 하나를 프로젝트별로 나눠 준다.
        (이전엔 워크트리마다 `compose ps` 를 따로 불러 워크트리 수만큼 접속했다.)"""
        _make_remote(self.root)
        other = Path(self.tmp.name, "wt5"); other.mkdir(); _make_remote(other)
        self.behaviour = lambda: _tsv(project="p") + _tsv(project="q", service="api")
        self.assertEqual(mcs.compose_ps(self.root, "p"), [_row(project="p")])
        self.assertEqual(mcs.compose_ps(other, "q"), [_row(project="q", service="api")])
        self.assertEqual(len(self.calls), 1, "워크트리가 몇 개든 박스에는 한 번만 묻는다")

    def test_project_absent_from_box_is_empty_without_extra_call(self):
        _make_remote(self.root)
        self.behaviour = lambda: _tsv(project="other")
        self.assertEqual(mcs.compose_ps(self.root, "p"), [], "그 박스에 없는 프로젝트는 빈 목록")
        self.assertEqual(len(self.calls), 1, "없다고 다시 묻지 않는다")

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
