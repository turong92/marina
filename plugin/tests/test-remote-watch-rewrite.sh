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
import importlib.util, os, sys, tempfile, unittest

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
        for bad in ["/p/my libs #1/build", "/p/a: b/build"]:
            cfg = {"services": {"svc": {"build": {"context": "/p"},
                "volumes": [{"type": "bind", "source": bad, "target": "/app/libs"}],
                "develop": {"watch": [{"path": bad, "action": "restart"}]}}}}
            out = mctl.build_overlay(cfg, target=RemoteTarget("ssh://box"))
            got = mctl.load_compose(out)["services"]["svc"]["develop"]["watch"][0]
            self.assertEqual(got["path"], bad, f"경로가 깨짐: {bad}")
            self.assertEqual(got["target"], "/app/libs")

    # ── 동기화 선언 없는 바인드 디렉터리도 원격에선 바로 반영(형 2026-11-11 "동적 반영 되게") ──
    # ovation server 는 '.:/workspace' 바인드만 있고 develop.watch 가 없어, 박스에선 기동 때 한 번 복사로 끝났다.
    def _dir(self):
        d = tempfile.mkdtemp(); self.addCleanup(os.rmdir, d); return d

    def test_uncovered_dir_bind_gets_sync_rule(self):
        src = self._dir()
        cfg = {"services": {"server": {"image": "x",
            "volumes": [{"type": "bind", "source": src, "target": "/workspace"}]}}}
        out = mctl.build_overlay(cfg, target=RemoteTarget("ssh://box"))
        rules = mctl.load_compose(out)["services"]["server"]["develop"]["watch"]
        self.assertEqual(len(rules), 1, rules)
        r = rules[0]
        self.assertEqual((r["action"], r["path"], r["target"]), ("sync", src, "/workspace"))
        for pat in ("**/build/", "**/node_modules/", ".git/"):
            self.assertIn(pat, r["ignore"], "빌드 산출물·의존성·git 은 덮지 않는다")
        self.assertNotIn("initial_sync", r, "기동 때 이미 통째로 주입했다")
        self.assertNotIn("develop:", mctl.build_overlay(cfg, target=LocalTarget()), "맥은 바인드 그대로")

    def test_declared_sync_under_source_means_project_handles_it(self):
        # 프로젝트가 그 폴더(또는 하위)를 이미 동기화하면 추측해 덧붙이지 않는다
        src = self._dir()
        cfg = {"services": {"web": {"image": "x",
            "volumes": [{"type": "bind", "source": src, "target": "/app"}],
            "develop": {"watch": [{"path": src + "/src", "action": "sync", "target": "/app/src"}]}}}}
        out = mctl.build_overlay(cfg, target=RemoteTarget("ssh://box"))
        self.assertNotIn("develop:", out)

    def test_gitignored_paths_are_not_synced(self):
        # 기동 주입은 .gitignore 대상을 뺀다 — sync 도 같은 기준이어야 .env·워크트리 폴더가 박스로 흘러가지 않는다
        import subprocess
        src = tempfile.mkdtemp(); self.addCleanup(__import__("shutil").rmtree, src, True)
        subprocess.run(["git", "init", "-q", src], check=True)
        open(os.path.join(src, ".gitignore"), "w").write(".env\nout/\n")
        open(os.path.join(src, ".env"), "w").write("x")
        os.mkdir(os.path.join(src, "out")); open(os.path.join(src, "out", "a"), "w").write("x")
        cfg = {"services": {"server": {"image": "x",
            "volumes": [{"type": "bind", "source": src, "target": "/workspace"}]}}}
        r = mctl.load_compose(mctl.build_overlay(cfg, target=RemoteTarget("ssh://box")))["services"]["server"]["develop"]["watch"][0]
        self.assertIn(".env", r["ignore"]); self.assertIn("out", r["ignore"])

    def test_overlapping_binds_each_get_their_own_sync(self):
        # 루트와 하위가 서로 다른 볼륨이면 각자 동기화해야 한다 — 순서에 따라 하나가 조용히 낡으면 안 된다
        root = self._dir(); sub = os.path.join(root, "web"); os.mkdir(sub); self.addCleanup(os.rmdir, sub)
        for order in ([root, sub], [sub, root]):
            vols = [{"type": "bind", "source": s, "target": "/workspace" if s == root else "/app"} for s in order]
            cfg = {"services": {"svc": {"image": "x", "volumes": vols}}}
            rules = mctl.load_compose(mctl.build_overlay(cfg, target=RemoteTarget("ssh://box")))["services"]["svc"]["develop"]["watch"]
            self.assertEqual(sorted((r["path"], r["target"]) for r in rules),
                             sorted([(root, "/workspace"), (sub, "/app")]), f"순서 {order}")

    def test_declared_sync_to_other_target_does_not_count(self):
        src = self._dir()
        cfg = {"services": {"svc": {"image": "x",
            "volumes": [{"type": "bind", "source": src, "target": "/w"}],
            "develop": {"watch": [{"path": src, "action": "sync", "target": "/elsewhere"}]}}}}
        rules = mctl.load_compose(mctl.build_overlay(cfg, target=RemoteTarget("ssh://box")))["services"]["svc"]["develop"]["watch"]
        self.assertIn((src, "/w"), [(r["path"], r["target"]) for r in rules])

    def test_missing_or_file_source_gets_nothing(self):
        cfg = {"services": {"svc": {"image": "x",
            "volumes": [{"type": "bind", "source": "/no/such/dir", "target": "/w"}]}}}
        self.assertNotIn("develop:", mctl.build_overlay(cfg, target=RemoteTarget("ssh://box")),
                         "맥에 없는 경로(파일 추정 포함)는 추측해 붙이지 않는다")

    def test_existing_rules_kept_when_sync_added(self):
        src = self._dir()
        cfg = {"services": {"svc": {"image": "x",
            "volumes": [{"type": "bind", "source": src, "target": "/w"}],
            "develop": {"watch": [{"path": src + "/Dockerfile", "action": "rebuild"}]}}}}
        rules = mctl.load_compose(mctl.build_overlay(cfg, target=RemoteTarget("ssh://box")))["services"]["svc"]["develop"]["watch"]
        self.assertEqual([r["action"] for r in rules], ["rebuild", "sync"])

    def test_watch_list_uses_override_tag(self):
        self.assertIn("watch: !override", self._service_block("user-api"))

    def _watch(self, name):
        d = mctl.load_compose(self.out)
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
