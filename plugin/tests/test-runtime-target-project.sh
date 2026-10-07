#!/usr/bin/env bash
# 런타임 타깃 계층에 프로젝트를 넣는다: **전역 < 프로젝트 < 세션(워크트리)**.
#
# 형 요구(2026-10-07): "mdc 프로젝트만 원격으로." 전역(모든 프로젝트) 아니면 워크트리 하나씩뿐이라
# 새로 만든 mdc 워크트리가 자동으로 원격이 되지 않았다.
# 프로젝트 설정 위치: <MARINA_HOME>/<project-id>/runtime-target.json (compose 보관 폴더와 같은 곳).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS/marina-compose.py" <<'PY'
import importlib.util, json, os, sys, tempfile, unittest
from pathlib import Path

from marina_runtime_target import describe, load_target, project_dir, write_target

spec = importlib.util.spec_from_file_location("mctl", sys.argv[1])
mctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mctl)

L = {"kind": "local"}
R = lambda h: {"kind": "remote", "host": h}
R0 = {"kind": "remote"}          # 주소 생략 — 위 계층에서 물려받는다
N = None                         # 이 계층은 말 안 함


class ResolveTable(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name, "home"); self.home.mkdir()
        self.session = Path(self.tmp.name, "s"); self.session.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, directory, cfg):
        directory = Path(directory); directory.mkdir(parents=True, exist_ok=True)
        p = directory / "runtime-target.json"
        if cfg is None:
            p.unlink(missing_ok=True)
        else:
            p.write_text(json.dumps(cfg), encoding="utf-8")

    def resolve(self, g, p, s, pid="mdc"):
        self.put(self.home, g)
        self.put(self.home / "mdc", p)
        self.put(self.session, s)
        t = load_target(str(self.session), home=str(self.home), project_id=pid)
        return t.host if t.is_remote else None

    # (전역, 프로젝트, 세션) → 기대 host(None = 로컬)
    TABLE = [
        (N, N, N, None),                       # 아무도 말 안 함
        (R("ssh://g"), N, N, "ssh://g"),       # 전역만
        (L, N, N, None),
        (N, R("ssh://p"), N, "ssh://p"),       # 프로젝트만 — 전역 없이도 그 프로젝트는 원격
        (R("ssh://g"), R("ssh://p"), N, "ssh://p"),   # 프로젝트가 전역을 덮는다
        (R("ssh://g"), L, N, None),            # 프로젝트 local 고정 — 전역이 원격이어도 로컬
        (L, R("ssh://p"), N, "ssh://p"),       # 전역 local 이어도 프로젝트 remote
        (R("ssh://g"), R("ssh://p"), L, None),             # 세션이 최종(local)
        (L, L, R("ssh://s"), "ssh://s"),                   # 세션이 최종(remote)
        (R("ssh://g"), L, R("ssh://s"), "ssh://s"),
        (N, R("ssh://p"), R("ssh://s"), "ssh://s"),
        (R("ssh://g"), R("ssh://p"), R0, "ssh://p"),       # 세션이 주소 생략 → 프로젝트 주소
        (R("ssh://g"), N, R0, "ssh://g"),                  # 프로젝트가 말 없으면 전역 주소
        (R("ssh://g"), R0, N, "ssh://g"),                  # 프로젝트가 주소 생략 → 전역 주소
        (R("ssh://g"), R0, R0, "ssh://g"),                 # 둘 다 생략 → 전역까지 올라간다
        (N, R0, N, None),                                  # 어디에도 주소 없음 → 로컬
        (N, N, R0, None),
        (L, R0, R0, None),
    ]

    def test_table(self):
        for g, p, s, want in self.TABLE:
            with self.subTest(g=g, p=p, s=s):
                self.assertEqual(self.resolve(g, p, s), want)

    def test_no_project_id_ignores_project_layer(self):
        # 프로젝트를 못 알아내면 지금 동작 그대로 — 프로젝트 파일이 있어도 안 본다.
        self.assertIsNone(self.resolve(N, R("ssh://p"), N, pid=None))
        self.assertEqual(self.resolve(R("ssh://g"), R("ssh://p"), N, pid=None), "ssh://g")

    def test_project_id_cannot_escape_home(self):
        for bad in ("../x", "a/b", "", "."):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                project_dir(bad, home=str(self.home))


class DescribeProject(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name, "home"); (self.home / "mdc").mkdir(parents=True)
        self.session = Path(self.tmp.name, "s"); self.session.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def d(self, pid="mdc"):
        return describe(str(self.session), home=str(self.home), project_id=pid)

    def test_scope_project_and_project_host(self):
        write_target(str(self.home / "mdc"), "remote", "ssh://p")
        d = self.d()
        self.assertEqual((d["kind"], d["host"], d["scope"], d["projectHost"]), ("remote", "ssh://p", "project", "ssh://p"))

    def test_session_beats_project_scope(self):
        write_target(str(self.home / "mdc"), "remote", "ssh://p")
        write_target(str(self.session), "local", None)
        d = self.d()
        self.assertEqual((d["kind"], d["scope"], d["projectHost"]), ("local", "session", "ssh://p"))

    def test_project_local_scope_is_project_and_no_project_host(self):
        write_target(str(self.home), "remote", "ssh://g")
        write_target(str(self.home / "mdc"), "local", None)
        d = self.d()
        self.assertEqual((d["kind"], d["scope"], d["projectHost"], d["globalHost"]), ("local", "project", None, "ssh://g"))

    def test_shape_without_project(self):
        d = self.d(pid=None)
        self.assertEqual((d["kind"], d["scope"], d["projectHost"]), ("local", "default", None))

    def test_existing_global_shape_unchanged(self):
        write_target(str(self.home), "remote", "ssh://g")
        d = describe(str(self.session), home=str(self.home))   # 옛 호출 형태
        self.assertEqual((d["kind"], d["host"], d["scope"], d["globalHost"]), ("remote", "ssh://g", "global", "ssh://g"))


class WiringProject(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.session = self.tmp.name
        self.pdir = Path(os.environ["MARINA_HOME"], "mdc")
        write_target(str(self.pdir), "remote", "ssh://p")

    def tearDown(self):
        (self.pdir / "runtime-target.json").unlink(missing_ok=True)
        self.tmp.cleanup()

    def test_env_with_project(self):
        env = mctl._env_with([], session_dir=self.session, project_id="mdc")
        self.assertEqual(env["DOCKER_HOST"], "ssh://p")

    def test_env_with_old_signature_still_local(self):
        self.assertNotIn("DOCKER_HOST", mctl._env_with([], session_dir=self.session))

    def test_lifecycle_env_project(self):
        self.assertEqual(mctl._lifecycle_env(self.session, project_id="mdc")["DOCKER_HOST"], "ssh://p")
        self.assertNotIn("DOCKER_HOST", mctl._lifecycle_env(self.session))


unittest.main(argv=[sys.argv[0]], verbosity=1)
PY

# ── root 에서 프로젝트를 알아내는 호출부(docker_env_for_root) — 레지스트리 경유 ──
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mdcrepo" && printf 'services:\n  app:\n    build: .\n' > "$T/mdcrepo/docker-compose.yml"
bash "$SCRIPTS/marina.sh" project add "$T/mdcrepo" --compose "$T/mdcrepo/docker-compose.yml" >/dev/null
PYTHONPATH="$SCRIPTS" python3 - "$T/mdcrepo" <<'PY'
import os, sys
from pathlib import Path
from marina_runtime_target import docker_env_for_root, write_target
import marina_registry
root = Path(sys.argv[1])
pid = marina_registry.project_for(root)["id"]
assert docker_env_for_root(root) == {}, "아무 설정 없으면 로컬"
write_target(os.path.join(os.environ["MARINA_HOME"], pid), "remote", "ssh://p")
got = docker_env_for_root(root)
assert got == {"DOCKER_HOST": "ssh://p"}, f"프로젝트 설정이 root 호출부에 안 닿음: {got}"
print("OK docker_env_for_root project")
PY
echo PASS
