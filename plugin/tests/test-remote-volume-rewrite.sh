#!/usr/bin/env bash
# 원격 모드에서 바인드 마운트를 named volume 으로 치환하고, 기동 전 주입 계획을 만든다.
#
# 왜. `--project-directory` 는 이중 역할이다 — 빌드컨텍스트·watch 소스는 *클라이언트*, 바인드 마운트는
# *데몬* 에서 푼다. 원격이면 개발자 맥의 경로가 박스에 없어 바인드가 풀리지 않는다. 그리고 watch sync 는
# *돌고 있는* 컨테이너에 넣으므로 부팅에 JAR 이 필요한 JVM 은 그 전에 죽는다(실측).
# → named volume 으로 치환하고 `up --no-start` → `docker cp` → `start` 로 기동 전에 넣는다.
#
# 로컬은 **오버레이 출력이 한 글자도 달라지지 않아야** 한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS/marina-compose.py" <<'PY'
import importlib.util, sys, unittest

spec = importlib.util.spec_from_file_location("mctl", sys.argv[1])
mctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mctl)

from marina_runtime_target import LocalTarget, RemoteTarget

# mdc 실제 모양: JAR 디렉터리 바인드 + .env 파일 바인드(ro) + 이미 named volume 인 .next 캐시
CONFIG = {
    "services": {
        "user-api": {
            "build": {"context": "./be-api/user-api"},
            "volumes": [{"type": "bind", "source": "./be-api/user-api/build/libs", "target": "/app/libs"}],
        },
        "web": {
            "build": {"context": "./web-app-monorepo"},
            "volumes": [
                {"type": "bind", "source": "./web-app-monorepo/apps/web/.env", "target": "/app/apps/web/.env"},
                {"type": "bind", "source": "./web-app-monorepo/apps/web/.env.ssm.local",
                 "target": "/app/apps/web/.env.ssm.local", "read_only": True},
                {"type": "volume", "source": "web_app_next", "target": "/app/apps/web/.next"},
            ],
        },
    }
}


class LocalUnchangedTests(unittest.TestCase):
    def test_local_overlay_identical_to_no_target(self):
        # 로컬 타깃은 기존 호출과 동일한 오버레이를 만들어야 한다.
        self.assertEqual(
            mctl.build_overlay(CONFIG, target=LocalTarget()),
            mctl.build_overlay(CONFIG),
        )

    def test_local_overlay_has_no_volume_lines(self):
        out = mctl.build_overlay(CONFIG, target=LocalTarget())
        self.assertNotIn("volumes:", out)
        self.assertNotIn("marina_", out)

    def test_local_injection_plan_empty(self):
        self.assertEqual(mctl.injection_plan_for(CONFIG, LocalTarget()), [])


class RemoteRewriteTests(unittest.TestCase):
    def setUp(self):
        self.target = RemoteTarget("ssh://crabs@192.168.0.251")
        self.out = mctl.build_overlay(CONFIG, target=self.target)

    def test_host_bind_replaced_by_named_volume(self):
        self.assertIn("marina_user_api_app_libs:/app/libs", self.out)
        self.assertNotIn("./be-api/user-api/build/libs", self.out)

    def test_readonly_mode_preserved(self):
        self.assertIn("marina_web_app_apps_web_env_ssm_local:/app/apps/web/.env.ssm.local:ro", self.out)

    def test_existing_named_volume_untouched(self):
        self.assertIn("web_app_next:/app/apps/web/.next", self.out)
        self.assertNotIn("marina_web_app_apps_web_next", self.out)

    def test_top_level_volumes_declared(self):
        # 오버레이가 새로 만든 볼륨은 top-level `volumes:` 에 선언돼야 compose 가 만든다.
        lines = self.out.splitlines()
        self.assertIn("volumes:", lines)
        idx = lines.index("volumes:")
        decl = [l.strip().rstrip(":") for l in lines[idx + 1:] if l.startswith("  ") and l.strip()]
        self.assertIn("marina_user_api_app_libs", decl)
        self.assertIn("marina_web_app_apps_web_env", decl)
        self.assertNotIn("web_app_next", decl)      # 원래 stored 가 선언한 것 — 중복 선언 금지

    def test_volumes_section_is_top_level_not_under_services(self):
        # `services:` 블록 안에 들어가면 compose 가 서비스로 오해한다.
        lines = self.out.splitlines()
        self.assertTrue(lines[0].startswith("services:"))
        self.assertLess(lines.index("services:"), lines.index("volumes:"))

    def test_injection_plan_lists_every_rewritten_bind(self):
        plan = mctl.injection_plan_for(CONFIG, self.target)
        pairs = sorted((i.service, i.source, i.target) for i in plan)
        self.assertEqual(pairs, sorted([
            ("user-api", "./be-api/user-api/build/libs", "/app/libs"),
            ("web", "./web-app-monorepo/apps/web/.env", "/app/apps/web/.env"),
            ("web", "./web-app-monorepo/apps/web/.env.ssm.local", "/app/apps/web/.env.ssm.local"),
        ]))

    def test_injection_plan_filters_to_requested_services(self):
        # 일부 서비스만 기동할 때 안 뜬 컨테이너에 주입하면 `No such container` 로 기동이 멈춘다(실측 버그).
        plan = mctl.injection_plan_for(CONFIG, self.target, services=["user-api"])
        self.assertEqual([i.service for i in plan], ["user-api"])

    def test_empty_requested_list_injects_nothing(self):
        self.assertEqual(mctl.injection_plan_for(CONFIG, self.target, services=[]), [])

    def test_services_none_means_all(self):
        plan = mctl.injection_plan_for(CONFIG, self.target, services=None)
        self.assertEqual(len(plan), 3)

    def test_unknown_requested_service_is_ignored(self):
        self.assertEqual(mctl.injection_plan_for(CONFIG, self.target, services=["nope"]), [])

    def test_unrenderable_entries_are_preserved(self):
        # `volumes: !override` 는 목록 전체를 대체한다. source 가 없어 문자열로 못 쓰는 항목(익명 볼륨,
        # tmpfs)을 빼먹으면 그 서비스가 원격에서 조용히 볼륨을 잃는다.
        cfg = {"services": {"svc": {"build": {"context": "/p"}, "volumes": [
            {"type": "bind", "source": "/p/libs", "target": "/app/libs"},
            {"type": "volume", "target": "/app/cache"},          # 익명 볼륨
            {"type": "tmpfs", "target": "/tmp/scratch"},         # tmpfs
        ]}}}
        out = mctl.build_overlay(cfg, target=self.target)
        self.assertIn("/app/cache", out)
        self.assertIn("/tmp/scratch", out)
        self.assertIn("marina_svc_app_libs:/app/libs", out)

    def test_preserved_entries_keep_original_order(self):
        cfg = {"services": {"svc": {"build": {"context": "/p"}, "volumes": [
            {"type": "volume", "target": "/app/first"},
            {"type": "bind", "source": "/p/libs", "target": "/app/libs"},
            {"type": "volume", "target": "/app/last"},
        ]}}}
        line = [l for l in mctl.build_overlay(cfg, target=self.target).splitlines() if "volumes: !override" in l][0]
        self.assertLess(line.index("/app/first"), line.index("/app/libs"))
        self.assertLess(line.index("/app/libs"), line.index("/app/last"))

    def test_overlay_with_preserved_entries_is_valid_yaml(self):
        import yaml
        cfg = {"services": {"svc": {"build": {"context": "/p"}, "volumes": [
            {"type": "bind", "source": "/p/libs", "target": "/app/libs"},
            {"type": "tmpfs", "target": "/tmp/scratch"},
        ]}}}
        out = mctl.build_overlay(cfg, target=self.target).replace("!override", "").replace("!reset ", "")
        vols = yaml.safe_load(out)["services"]["svc"]["volumes"]
        self.assertEqual(vols[0], "marina_svc_app_libs:/app/libs")
        self.assertEqual(vols[1].get("type"), "tmpfs")

    def test_file_mount_disappears_from_overlay(self):
        # named volume 은 디렉터리로 마운트된다 → 파일 경로에 얹으면 컨테이너 생성이 실패한다
        # ("source /.../.env is not directory"). 파일 마운트는 오버레이에서 빠지고 주입만 남는다.
        import os, tempfile
        with tempfile.TemporaryDirectory() as d:
            envf = os.path.join(d, ".env"); open(envf, "w").write("A=1")
            libs = os.path.join(d, "libs"); os.mkdir(libs)
            cfg = {"services": {"web": {"build": {"context": d}, "volumes": [
                {"type": "bind", "source": envf, "target": "/app/.env"},
                {"type": "bind", "source": libs, "target": "/app/libs"},
                {"type": "volume", "source": "cache", "target": "/app/.next"},
                {"type": "tmpfs", "target": "/tmp/x"},
            ]}}}
            out = mctl.build_overlay(cfg, target=self.target)
            line = [l for l in out.splitlines() if "volumes: !override" in l][0]
            self.assertNotIn("/app/.env", line)        # 파일 마운트 사라짐
            self.assertIn("/app/libs", line)           # 디렉터리는 볼륨으로
            self.assertIn("cache:/app/.next", line)    # 기존 named volume 그대로
            self.assertIn("/tmp/x", line)              # tmpfs 보존
            plan = mctl.injection_plan_for(cfg, self.target, services=["web"])
            self.assertEqual(sorted(i.target for i in plan), ["/app/.env", "/app/libs"])

    def test_service_with_no_volumes_is_not_broken(self):
        cfg = {"services": {"index-api": {"build": {"context": "./ai-api"}}}}
        out = mctl.build_overlay(cfg, target=self.target)
        self.assertNotIn("marina_", out)
        self.assertEqual(mctl.injection_plan_for(cfg, self.target), [])


unittest.main(argv=[sys.argv[0]], verbosity=1)
PY
