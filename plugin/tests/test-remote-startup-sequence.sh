#!/usr/bin/env bash
# 원격 기동 시퀀스: `up --no-start` → `docker cp` 주입 → `start`.
#
# 왜 3단계인가. named volume 으로 치환한 파일(JAR 등)은 컨테이너가 **뜨기 전에** 들어가 있어야 한다.
# watch sync 는 돌고 있는 컨테이너에만 넣으므로 JVM 은 JAR 이 도착하기 전에 죽는다(실측).
# `docker cp` 는 Docker API 로 흐르므로 원격에서도 안전하고, 정지된 컨테이너에도 넣을 수 있다.
#
# 로컬은 **지금 그대로 `up -d` 한 방**이어야 한다 — 바인드 마운트가 공짜로 해주므로 주입이 불필요하다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS/marina-compose.py" <<'PY'
import importlib.util, os, sys, unittest

spec = importlib.util.spec_from_file_location("mctl", sys.argv[1])
mctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mctl)

from marina_runtime_target import Injection, LocalTarget, RemoteTarget


def _w(path, text):
    with open(path, "w") as fh:
        fh.write(text)


class UpArgvTests(unittest.TestCase):
    def base(self, **kw):
        return mctl.up_argv("/s/compose.yml", None, "/proj", "p", ["web"], **kw)

    def test_local_is_single_up_d(self):
        self.assertIn("-d", self.base())
        self.assertNotIn("--no-start", self.base())

    def test_no_start_variant_drops_detach_flag(self):
        # `up --no-start -d` 는 compose 가 거부한다 — 컨테이너를 만들기만 한다.
        argv = self.base(no_start=True)
        self.assertIn("--no-start", argv)
        self.assertNotIn("-d", argv)

    def test_no_start_keeps_project_wiring(self):
        argv = self.base(no_start=True)
        self.assertEqual(argv[:4], ["docker", "compose", "-f", "/s/compose.yml"])
        self.assertIn("--project-directory", argv)
        self.assertIn("p", argv)
        self.assertEqual(argv[-1], "web")


class StartArgvTests(unittest.TestCase):
    def test_start_argv_targets_named_services(self):
        argv = mctl.start_argv("/s/compose.yml", None, "/proj", "p", ["user-api", "batch"])
        self.assertIn("start", argv)
        self.assertEqual(argv[-2:], ["user-api", "batch"])
        self.assertNotIn("-d", argv)


class InjectTarTests(unittest.TestCase):
    """docker cp 는 부모 폴더를 안 만든다 — 대상 상대경로를 담은 tar 를 `docker cp - c:/` 로 넣는다."""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()

    def _members(self, inj, is_dir=False, exists=()):
        import io, tarfile
        argv = mctl.inject_argv(inj, "p", self.tmp, is_dir=is_dir)
        data = argv.tar_bytes(lambda path: path in exists)
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            return argv, {m.name: m for m in tf.getmembers()}, tf

    def test_argv_streams_tar_to_container_root(self):
        f = os.path.join(self.tmp, "adc.json"); _w(f, "{}")
        inj = Injection("web", f, "/run/gcp/adc.json", "v")
        argv, _, _ = self._members(inj)
        self.assertEqual(list(argv), ["docker", "cp", "-", "p-web-1:/"])

    def test_file_entry_has_relative_path_and_parent_dirs_0755(self):
        f = os.path.join(self.tmp, "adc.json"); _w(f, "{}")
        os.chmod(f, 0o600)
        inj = Injection("web", f, "/run/gcp/adc.json", "v")
        _, m, _ = self._members(inj)
        self.assertEqual(set(m), {"run", "run/gcp", "run/gcp/adc.json"})
        self.assertTrue(m["run"].isdir() and m["run/gcp"].isdir())
        self.assertEqual(m["run/gcp"].mode, 0o755)
        self.assertEqual(m["run/gcp/adc.json"].mode, 0o644)   # 원본 + 읽기 비트

    def test_dir_source_contents_land_under_target(self):
        d = os.path.join(self.tmp, "libs"); os.makedirs(os.path.join(d, "sub"))
        _w(os.path.join(d, "a.jar"), "x")
        _w(os.path.join(d, "sub", "b.jar"), "y")
        inj = Injection("api", d, "/app/libs", "v")
        _, m, _ = self._members(inj, is_dir=True)
        self.assertIn("app/libs/a.jar", m)
        self.assertIn("app/libs/sub/b.jar", m)
        self.assertTrue(m["app/libs"].isdir())

    def test_display_says_tar(self):
        f = os.path.join(self.tmp, "x.env"); _w(f, "k=v")
        inj = Injection("web", f, "/app/x.env", "v")
        argv = mctl.inject_argv(inj, "p", self.tmp, is_dir=False)
        self.assertIn("tar", argv.describe())
        self.assertIn("/app/x.env", argv.describe())


class TarExistingDirsTests(unittest.TestCase):
    setUp = InjectTarTests.setUp
    _members = InjectTarTests._members

    def test_existing_ancestors_are_not_in_tar(self):
        f = os.path.join(self.tmp, "e.env"); _w(f, "k")
        inj = Injection("web", f, "/home/node/app/.env", "v")
        _, m, _ = self._members(inj, exists={"/home/node", "/home"})
        self.assertEqual(set(m), {"home/node/app", "home/node/app/.env"})

    def test_all_ancestors_exist_means_file_only(self):
        f = os.path.join(self.tmp, "e.env"); _w(f, "k")
        inj = Injection("web", f, "/home/node/.env", "v")
        _, m, _ = self._members(inj, exists={"/home/node", "/home"})
        self.assertEqual(set(m), {"home/node/.env"})

    def test_existing_dir_target_and_parents_skipped(self):
        d = os.path.join(self.tmp, "libs"); os.makedirs(d); _w(os.path.join(d, "a.jar"), "x")
        inj = Injection("api", d, "/app/libs", "v")
        _, m, _ = self._members(inj, is_dir=True, exists={"/app/libs", "/app"})
        self.assertEqual(set(m), {"app/libs/a.jar"})

    def test_readable_bit_added_to_0600_source(self):
        f = os.path.join(self.tmp, "adc.json"); _w(f, "{}"); os.chmod(f, 0o600)
        inj = Injection("web", f, "/run/gcp/adc.json", "v")
        _, m, _ = self._members(inj, exists={"/run"})
        self.assertEqual(m["run/gcp/adc.json"].mode, 0o644)

    def test_exec_bit_kept(self):
        f = os.path.join(self.tmp, "r.sh"); _w(f, "x"); os.chmod(f, 0o700)
        inj = Injection("web", f, "/run/r.sh", "v")
        _, m, _ = self._members(inj, exists={"/run"})
        self.assertEqual(m["run/r.sh"].mode, 0o744)


class ContainerPathExistsTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()
        fake = os.path.join(self.tmp, "docker")
        _w(fake, "#!/bin/sh\np=\"${2#*:}\"\n"
            "if [ -n \"$FAKE_CHECK_FAIL\" ]; then echo 'Cannot connect to the Docker daemon' >&2; exit 1; fi\n"
            "case \":$FAKE_EXISTS:\" in *\":$p:\"*) if [ -n \"$FAKE_INFINITE\" ]; then yes; else printf x; fi; exit 0;; esac\n"
            "echo \"Error response from daemon: Could not find the file $p in container c\" >&2; exit 1\n")
        os.chmod(fake, 0o755)
        self.env = dict(os.environ, PATH=self.tmp + os.pathsep + os.environ["PATH"], FAKE_EXISTS="/home/node")

    def test_present_and_absent(self):
        self.assertTrue(mctl.container_path_exists("c", "/home/node", self.env))
        self.assertFalse(mctl.container_path_exists("c", "/run/gcp", self.env))

    def test_infinite_stream_ends_quickly(self):
        import time
        self.env["FAKE_INFINITE"] = "1"
        t = time.time()
        self.assertTrue(mctl.container_path_exists("c", "/home/node", self.env))
        self.assertLess(time.time() - t, 5)

    def test_connection_error_raises(self):
        self.env["FAKE_CHECK_FAIL"] = "1"
        with self.assertRaises(OSError):
            mctl.container_path_exists("c", "/home/node", self.env)


class ExecutePlanTests(unittest.TestCase):
    """주입이 실패하면 이유를 찍고 Created 컨테이너를 치우고 start 는 안 한다."""

    def setUp(self):
        import tempfile, stat
        self.tmp = tempfile.mkdtemp()
        self.log = os.path.join(self.tmp, "calls.log")
        fake = os.path.join(self.tmp, "docker")
        open(fake, "w").write("#!/bin/sh\necho \"$@\" >> \"$FAKE_LOG\"\n"
            "if [ \"$1\" = cp ] && [ \"$3\" = - ]; then p=\"${2#*:}\"; "
            "if [ -n \"$FAKE_CHECK_FAIL\" ]; then echo 'Cannot connect to the Docker daemon' >&2; exit 1; fi; "
            "case \":$FAKE_EXISTS:\" in *\":$p:\"*) "
            "if [ -n \"$FAKE_INFINITE\" ]; then yes; else printf 'x'; fi; exit 0;; "
            "*) echo \"Error response from daemon: Could not find the file $p in container c\" >&2; exit 1;; esac; fi\n"
            "if [ \"$1\" = cp ] && [ \"$2\" = - ]; then cat > \"$FAKE_LOG.tar\"; "
            "[ -n \"$FAKE_TAR_FAIL\" ] && { echo 'Error response from daemon: boom' >&2; exit 1; }; fi\n"
            "exit 0\n")
        os.chmod(fake, 0o755)
        self.env = dict(os.environ, PATH=self.tmp + os.pathsep + os.environ["PATH"], FAKE_LOG=self.log,
                        FAKE_EXISTS="/app")
        self.src = os.path.join(self.tmp, "a.env"); _w(self.src, "S=1")
        injs = [Injection("web", self.src, "/app/a.env", "v")]
        self.plan = mctl.startup_plan(RemoteTarget("ssh://box"), injs, "/s/c.yml", None, self.tmp, "p",
                                      ["web"], is_dir_fn=lambda p: False)
        self.cleanup = mctl.cleanup_argv("/s/c.yml", None, self.tmp, "p", ["web"])

    def calls(self):
        with open(self.log) as fh:
            return fh.read().splitlines()

    def test_success_runs_all_steps_in_order(self):
        rc = mctl.execute_plan(self.plan, self.cleanup, self.env)
        self.assertEqual(rc, 0)
        c = self.calls()
        self.assertTrue(any("--no-start" in x for x in c))
        self.assertTrue(any(x.startswith("cp - p-web-1:/") for x in c))
        self.assertTrue(c[-1].split()[-2:] == ["start", "web"])
        self.assertFalse(any(" rm " in x for x in c))

    def test_inject_failure_reports_removes_and_skips_start(self):
        import io, contextlib
        self.env["FAKE_TAR_FAIL"] = "1"
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = mctl.execute_plan(self.plan, self.cleanup, self.env)
        self.assertNotEqual(rc, 0)
        c = self.calls()
        self.assertFalse(any(x.split()[-2:] == ["start", "web"] for x in c))
        self.assertTrue(any(" rm -f web" in x for x in c))
        self.assertIn("a.env", err.getvalue())
        self.assertIn("boom", err.getvalue())

    def test_existence_check_failure_is_inject_failure(self):
        import io, contextlib
        self.env["FAKE_CHECK_FAIL"] = "1"
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = mctl.execute_plan(self.plan, self.cleanup, self.env)
        self.assertNotEqual(rc, 0)
        self.assertTrue(any(" rm -f web" in x for x in self.calls()))
        self.assertFalse(any(x.split()[-2:] == ["start", "web"] for x in self.calls()))
        self.assertIn("Docker daemon", err.getvalue())

    def test_parent_less_cp_would_fail_but_tar_goes_through(self):
        # 가짜 docker 는 `cp <src> c:/없는/폴더/파일` 형식을 실패시킨다 — tar 방식은 그 형식을 안 쓴다.
        c0 = [a for k, a in self.plan if k == "inject"][0]
        self.assertEqual(list(c0)[:3], ["docker", "cp", "-"])


class StartupPlanTests(unittest.TestCase):
    """기동을 몇 단계로 쪼갤지 — 순서가 핵심 로직이라 여기서 못 박는다."""

    ARGS = dict(stored="/s/c.yml", overlay=None, project_dir="/proj", project_name="p",
                services=["web", "user-api"], build=False)

    def test_local_is_one_step(self):
        plan = mctl.startup_plan(LocalTarget(), [], **self.ARGS)
        self.assertEqual([k for k, _ in plan], ["up"])
        self.assertIn("-d", plan[0][1])

    def test_remote_without_injections_is_one_step(self):
        # 주입할 게 없으면 쪼갤 이유가 없다 — 원격도 up -d 한 방.
        plan = mctl.startup_plan(RemoteTarget("ssh://box"), [], **self.ARGS)
        self.assertEqual([k for k, _ in plan], ["up"])

    def test_remote_with_injections_is_create_inject_start(self):
        injs = [Injection("user-api", "./libs", "/app/libs", "v1"),
                Injection("web", "./apps/web/.env", "/app/apps/web/.env", "v2")]
        plan = mctl.startup_plan(RemoteTarget("ssh://box"), injs,
                                 is_dir_fn=lambda p: p.endswith("libs"), **self.ARGS)
        self.assertEqual([k for k, _ in plan], ["create", "inject", "inject", "start"])

    def test_create_step_uses_no_start(self):
        injs = [Injection("user-api", "./libs", "/app/libs", "v1")]
        plan = mctl.startup_plan(RemoteTarget("ssh://box"), injs, is_dir_fn=lambda p: True, **self.ARGS)
        self.assertIn("--no-start", plan[0][1])
        self.assertNotIn("-d", plan[0][1])

    def test_start_step_starts_every_requested_service(self):
        injs = [Injection("user-api", "./libs", "/app/libs", "v1")]
        plan = mctl.startup_plan(RemoteTarget("ssh://box"), injs, is_dir_fn=lambda p: True, **self.ARGS)
        self.assertEqual(plan[-1][1][-2:], ["web", "user-api"])

    def test_inject_steps_keep_injection_order(self):
        injs = [Injection("a", "./x", "/x", "v"), Injection("b", "./y", "/y", "v")]
        plan = mctl.startup_plan(RemoteTarget("ssh://box"), injs, is_dir_fn=lambda p: False, **self.ARGS)
        srcs = [argv.src for kind, argv in plan if kind == "inject"]
        self.assertEqual(srcs, ["/proj/x", "/proj/y"])

    def test_dir_detection_appends_dot_only_for_dirs(self):
        injs = [Injection("a", "./libs", "/app/libs", "v"), Injection("b", "./f.env", "/app/f.env", "v")]
        plan = mctl.startup_plan(RemoteTarget("ssh://box"), injs,
                                 is_dir_fn=lambda p: p.endswith("libs"), **self.ARGS)
        srcs = [(argv.src, argv.is_dir) for kind, argv in plan if kind == "inject"]
        self.assertEqual(srcs, [("/proj/libs", True), ("/proj/f.env", False)])

    def test_build_flag_survives_on_create_step(self):
        injs = [Injection("a", "./x", "/x", "v")]
        args = dict(self.ARGS); args["build"] = True
        plan = mctl.startup_plan(RemoteTarget("ssh://box"), injs, is_dir_fn=lambda p: False, **args)
        self.assertIn("--build", plan[0][1])


unittest.main(argv=[sys.argv[0]], verbosity=1)
PY
