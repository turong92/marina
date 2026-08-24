#!/usr/bin/env bash
# 원격 모드에서 `action: restart` 를 `sync+restart` 로 바꾼다 — 주입된 경로에 한해서.
#
# 왜. 로컬은 바인드 마운트라 JAR 을 다시 빌드하면 컨테이너가 바로 새 파일을 보고, `action: restart` 면
# 끝난다. 원격은 named volume 에 **기동 시점** JAR 이 들어가 있어서, restart 를 해도 예전 JAR 을 다시
# 읽는다 — 개발 루프가 끊긴다.
# sync 는 돌고 있는 컨테이너의 그 경로(=볼륨 마운트 지점)에 쓰므로 볼륨에 남고, 이어지는 restart 가
# 새 JAR 을 읽는다. 부팅 닭-달걀 문제는 이미 떠 있으니 해당 없다. 표준 compose 기능만으로 닫힌다.
#
# 범위는 **정확히 일치하는 경로만**이다. 부모/자식 경로를 추측하면 프로젝트가 선언하지 않은 동작을
# 만들어내게 된다.
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

# mdc 실제 모양(resolved config: 절대경로 + exec 기본값)
CONFIG = {
    "services": {
        "user-api": {
            "build": {"context": "/p/be-api/user-api"},
            "volumes": [{"type": "bind", "source": "/p/be-api/user-api/build/libs", "target": "/app/libs"}],
            "develop": {"watch": [
                {"path": "/p/be-api/user-api/build/libs", "action": "restart", "exec": {"command": None}},
                {"path": "/p/be-api/user-api/src", "action": "sync", "target": "/app/src",
                 "ignore": ["node_modules/", ".next/"], "initial_sync": True, "exec": {"command": None}},
                {"path": "/p/be-api/user-api/Dockerfile.local", "action": "rebuild", "exec": {"command": None}},
            ]},
        },
        "web": {
            "build": {"context": "/p/web"},
            "volumes": [{"type": "bind", "source": "/p/web/apps/web/.env", "target": "/app/apps/web/.env"}],
            "develop": {"watch": [
                {"path": "/p/web/apps/web", "action": "sync", "target": "/app/apps/web",
                 "ignore": ["node_modules/", ".next/"], "initial_sync": True, "exec": {"command": None}},
                {"path": "/p/web/pnpm-lock.yaml", "action": "rebuild", "exec": {"command": None}},
            ]},
        },
        # 주입은 없지만 watch 는 있는 서비스 — 건드릴 이유가 없다
        "index-api": {
            "build": {"context": "/p/ai-api"},
            "develop": {"watch": [
                {"path": "/p/ai-api", "action": "sync", "target": "/ai-api", "exec": {"command": None}},
            ]},
        },
        # 주입 안 된 경로에 restart — target 을 알 수 없으니 그대로 둔다
        "batch": {
            "build": {"context": "/p/be-api/batch"},
            "develop": {"watch": [
                {"path": "/p/be-api/batch/somewhere-else", "action": "restart", "exec": {"command": None}},
            ]},
        },
    }
}


class LocalTests(unittest.TestCase):
    def test_local_emits_no_develop_block(self):
        out = mctl.build_overlay(CONFIG, target=LocalTarget())
        self.assertNotIn("develop:", out)
        self.assertNotIn("sync+restart", out)

    def test_local_identical_to_no_target(self):
        self.assertEqual(mctl.build_overlay(CONFIG, target=LocalTarget()), mctl.build_overlay(CONFIG))


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.out = mctl.build_overlay(CONFIG, target=RemoteTarget("ssh://box"))

    def test_restart_on_injected_path_becomes_sync_restart(self):
        self.assertIn("sync+restart", self.out)

    def test_converted_rule_carries_container_target(self):
        # sync+restart 는 target 이 필수다. 주입 대상의 컨테이너 경로를 써야 한다.
        r = self._watch("user-api")[0]
        self.assertEqual(r["action"], "sync+restart")
        self.assertEqual(r["target"], "/app/libs")
        self.assertEqual(r["path"], "/p/be-api/user-api/build/libs")

    def test_restart_on_non_injected_path_stays_restart(self):
        block = self._service_block("batch")
        self.assertNotIn("sync+restart", block)

    def test_service_without_injection_gets_no_develop_override(self):
        self.assertNotIn("index-api", self._services_with_develop())

    def test_sibling_rules_preserved(self):
        # watch 목록을 !override 로 통째 대체하므로, 손대지 않은 규칙도 빠짐없이 남아야 한다.
        rules = self._watch("user-api")
        self.assertEqual([r["action"] for r in rules], ["sync+restart", "sync", "rebuild"])
        self.assertEqual(rules[2]["path"], "/p/be-api/user-api/Dockerfile.local")

    def test_ignore_and_initial_sync_preserved(self):
        r = self._watch("user-api")[1]
        self.assertEqual(r["ignore"], ["node_modules/", ".next/"])
        self.assertIs(r["initial_sync"], True)

    def test_injection_without_matching_restart_rule_changes_nothing(self):
        # web 은 주입은 있지만 그 경로에 restart 규칙이 없다 → 추측하지 않고 그대로 둔다.
        self.assertNotIn("develop:", self._service_block("web"))

    def test_exec_default_noise_not_emitted(self):
        # resolved config 의 `exec: {command: null}` 은 기본값 부산물 — 그대로 내보내면 compose 가 싫어한다.
        self.assertNotIn("command: null", self.out)
        self.assertNotIn("exec:", self.out)

    def test_paths_are_quoted_so_yaml_cannot_mangle_them(self):
        # `#` 는 주석으로 잘리고 `: ` 는 파싱을 깨뜨린다. 이 파일 관례대로 경로는 인용해야 한다.
        import yaml
        for bad in ["/p/my libs #1/build", "/p/a: b/build"]:
            cfg = {"services": {"svc": {"build": {"context": "/p"},
                "volumes": [{"type": "bind", "source": bad, "target": "/app/libs"}],
                "develop": {"watch": [{"path": bad, "action": "restart"}]}}}}
            out = mctl.build_overlay(cfg, target=RemoteTarget("ssh://box")).replace("!override", "").replace("!reset ", "")
            got = yaml.safe_load(out)["services"]["svc"]["develop"]["watch"][0]
            self.assertEqual(got["path"], bad, f"경로가 깨짐: {bad}")
            self.assertEqual(got["target"], "/app/libs")

    def test_watch_list_uses_override_tag(self):
        self.assertIn("watch: !override", self._service_block("user-api"))

    def _watch(self, name):
        import yaml
        d = yaml.safe_load(self.out.replace("!override", "").replace("!reset ", ""))
        return d["services"][name]["develop"]["watch"]

    # ── 헬퍼 ──
    def _service_block(self, name):
        lines = self.out.splitlines()
        try:
            i = lines.index(f"  {name}:")
        except ValueError:
            return ""
        out = []
        for l in lines[i + 1:]:
            if l and not l.startswith("    "):
                break
            out.append(l)
        return "\n".join(out)

    def _services_with_develop(self):
        return [n for n in CONFIG["services"] if "develop:" in self._service_block(n)]


unittest.main(argv=[sys.argv[0]], verbosity=1)
PY
