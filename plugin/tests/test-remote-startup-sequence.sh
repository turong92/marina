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
import importlib.util, sys, unittest

spec = importlib.util.spec_from_file_location("mctl", sys.argv[1])
mctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mctl)

from marina_runtime_target import Injection, LocalTarget, RemoteTarget


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


class InjectArgvTests(unittest.TestCase):
    def test_dir_source_copies_contents_not_the_dir(self):
        # `docker cp ./libs c:/app/libs` 는 /app/libs/libs 를 만든다. 내용만 넣으려면 `/.` 이 필요하다.
        inj = Injection(service="user-api", source="./be-api/user-api/build/libs",
                        target="/app/libs", volume="marina_x")
        argv = mctl.inject_argv(inj, "p", "/proj", is_dir=True)
        self.assertEqual(argv[:2], ["docker", "cp"])
        self.assertEqual(argv[2], "/proj/be-api/user-api/build/libs/.")
        self.assertEqual(argv[3], "p-user-api-1:/app/libs")

    def test_file_source_keeps_target_path(self):
        inj = Injection(service="web", source="./web-app-monorepo/apps/web/.env",
                        target="/app/apps/web/.env", volume="marina_y")
        argv = mctl.inject_argv(inj, "p", "/proj", is_dir=False)
        self.assertEqual(argv[2], "/proj/web-app-monorepo/apps/web/.env")
        self.assertEqual(argv[3], "p-web-1:/app/apps/web/.env")

    def test_absolute_source_is_not_reanchored(self):
        inj = Injection(service="svc", source="/abs/libs", target="/app/libs", volume="v")
        argv = mctl.inject_argv(inj, "p", "/proj", is_dir=True)
        self.assertEqual(argv[2], "/abs/libs/.")


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
        srcs = [argv[2] for kind, argv in plan if kind == "inject"]
        self.assertEqual(srcs, ["/proj/x", "/proj/y"])

    def test_dir_detection_appends_dot_only_for_dirs(self):
        injs = [Injection("a", "./libs", "/app/libs", "v"), Injection("b", "./f.env", "/app/f.env", "v")]
        plan = mctl.startup_plan(RemoteTarget("ssh://box"), injs,
                                 is_dir_fn=lambda p: p.endswith("libs"), **self.ARGS)
        srcs = [argv[2] for kind, argv in plan if kind == "inject"]
        self.assertEqual(srcs, ["/proj/libs/.", "/proj/f.env"])

    def test_build_flag_survives_on_create_step(self):
        injs = [Injection("a", "./x", "/x", "v")]
        args = dict(self.ARGS); args["build"] = True
        plan = mctl.startup_plan(RemoteTarget("ssh://box"), injs, is_dir_fn=lambda p: False, **args)
        self.assertIn("--build", plan[0][1])


unittest.main(argv=[sys.argv[0]], verbosity=1)
PY
