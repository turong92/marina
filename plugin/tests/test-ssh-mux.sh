#!/usr/bin/env bash
# 원격 폴링이 ssh 접속 하나를 나눠 쓴다 — ssh 껍데기(ControlMaster).
#
# 왜: DOCKER_HOST=ssh:// 면 docker 호출 한 번이 새 접속 하나다(실측 2026-09-23, 사무실 박스:
# 껍데기 없이 20회 → sshd Accepted 20건 / 껍데기 붙이고 20회 → 0건, 마스터 하나 재사용).
# docker 에 ssh 옵션을 넘길 방법이 없어 PATH 앞의 껍데기로 붙이므로, **껍데기가 진짜 ssh 를
# 자기 자신으로 잘못 잡으면 원격이 통째로 무한 exec** 된다 — 그 경계를 여기서 고정한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import os, subprocess, tempfile, unittest
from pathlib import Path

import marina_ssh_mux as mux


class MuxTests(unittest.TestCase):
    def setUp(self):
        # 짧은 경로여야 한다 — 소켓 경로(%C 는 40 hex 로 펴진다)가 104B 를 넘으면 멀티플렉싱이
        # 스스로 꺼져서, 켜진 상태를 보려던 시험이 조용히 빈손이 된다(macOS 기본 임시 경로가 그렇다).
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp", prefix="mux")
        self._home = mux.MARINA_HOME
        mux.MARINA_HOME = Path(self.tmp.name, "mh")
        mux._reset_for_tests()
        self._env = dict(os.environ)

    def tearDown(self):
        mux.MARINA_HOME = self._home
        mux._reset_for_tests()
        os.environ.clear(); os.environ.update(self._env)
        self.tmp.cleanup()

    def _fake_ssh(self) -> Path:
        """PATH 에 놓을 가짜 ssh — 받은 인자를 그대로 기록한다."""
        d = Path(self.tmp.name, "fakebin"); d.mkdir(exist_ok=True)
        log = Path(self.tmp.name, "args.txt")
        (d / "ssh").write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > " + str(log) + "\n", encoding="utf-8")
        os.chmod(d / "ssh", 0o755)
        os.environ["PATH"] = str(d) + os.pathsep + os.environ["PATH"]
        return log

    def test_shim_prepends_options_before_callers_args(self):
        log = self._fake_ssh()
        env = mux.mux_env({"DOCKER_HOST": "ssh://box"})
        shim_dir = env["PATH"].split(os.pathsep)[0]
        self.assertTrue(Path(shim_dir, "ssh").exists(), "껍데기를 PATH 맨 앞에 둔다")
        # docker 가 부르는 모양 그대로 껍데기를 실행
        subprocess.run([str(Path(shim_dir, "ssh")), "-o", "ConnectTimeout=30", "-T", "--", "box",
                        "docker", "system", "dial-stdio"], check=True, env={**os.environ, **env})
        args = log.read_text(encoding="utf-8").split("\n")
        self.assertIn("ControlMaster=auto", args)
        self.assertTrue(any(a.startswith("ControlPath=") for a in args))
        self.assertLess(args.index("ControlMaster=auto"), args.index("ConnectTimeout=30"),
                        "ssh 는 같은 옵션의 **처음 값**을 쓴다 — 우리 옵션이 앞이어야 이긴다")
        self.assertEqual([a for a in args if a][-8:],
                         ["-o", "ConnectTimeout=30", "-T", "--", "box", "docker", "system", "dial-stdio"],
                         "호출부 인자를 순서 그대로, 뒤에 붙여 넘긴다")

    def test_shim_never_execs_itself(self):
        """껍데기 디렉터리가 이미 PATH 에 있어도 자기 자신을 exec 하지 않는다(무한 루프)."""
        self._fake_ssh()
        d = mux._shim_dir()
        os.environ["PATH"] = d + os.pathsep + os.environ["PATH"]
        mux._reset_for_tests()
        body = Path(mux._shim_dir(), "ssh").read_text(encoding="utf-8")
        self.assertNotIn('exec "%s/ssh"' % d, body)
        self.assertIn("fakebin/ssh", body)

    def test_disabled_by_env(self):
        os.environ["MARINA_SSH_MUX"] = "0"
        self.assertEqual(mux.mux_env({"A": "1"}), {"A": "1"}, "끄면 env 를 건드리지 않는다")
        self.assertEqual(mux.ssh_options(), [])

    def test_guard_measures_the_expanded_socket_path(self):
        """`%C` 는 ssh 가 40 hex 로 편다 — **편 길이**로 재야 한다.
        리터럴 2글자로 세면 실제로는 104B 를 넘는 경로를 '괜찮다'고 통과시켜, 이 가드가 막으려던
        접속 실패가 그대로 난다(코드 리뷰 실측 지적 2026-09-23)."""
        mux.MARINA_HOME = Path("/" + "d" * 59)       # 리터럴 69자(짧아 보인다) → 펴면 107자
        mux._reset_for_tests()
        self.assertLess(len(str(mux.MARINA_HOME / "ssh" / "c-%C")), 100, "이 시험의 전제가 깨졌다")
        self.assertEqual(mux.ssh_options(), [], "펴면 넘는 경로를 통과시켰다")

    def test_persist_env_cannot_inject_shell(self):
        """껍데기는 **셸 스크립트**다 — 외부 값이 본문에 그대로 구워지면 안 된다."""
        os.environ["MARINA_SSH_MUX_PERSIST"] = "300; touch /tmp/marina-pwned"
        self.assertEqual(mux._persist_seconds(), "300", "숫자가 아닌 값을 그대로 썼다")

    def test_too_long_control_path_disables_instead_of_breaking_ssh(self):
        """소켓 경로가 104B 를 넘으면 ssh 가 'ControlPath too long' 으로 **접속 자체를 실패**한다(실측).
        그런 환경에선 멀티플렉싱을 포기하고 지금 동작(접속마다 새 ssh)으로 둔다."""
        mux.MARINA_HOME = Path(self.tmp.name, "d" * 120)
        mux._reset_for_tests()
        self.assertEqual(mux.ssh_options(), [])
        self.assertEqual(mux.mux_env({"A": "1"}), {"A": "1"})

    def test_path_is_not_prepended_twice(self):
        e1 = mux.mux_env({"PATH": "/usr/bin"})
        self.assertEqual(mux.mux_env(e1)["PATH"], e1["PATH"], "폴링마다 PATH 가 길어지면 안 된다")

    def test_socket_dir_is_private(self):
        mux.mux_env({})
        self.assertEqual(oct(os.stat(str(mux.MARINA_HOME / "ssh")).st_mode)[-3:], "700",
                         "접속을 공유하는 소켓이므로 디렉터리는 나만")


unittest.main(verbosity=1)
PY
