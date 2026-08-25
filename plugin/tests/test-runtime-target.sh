#!/usr/bin/env bash
# 런타임 타깃 — 워크트리별로 "컨테이너가 도는 기계"를 고른다.
#
# 왜 이 추상이 필요한가. 원격이면 compose 가 다른 데몬을 향하고, 바인드 마운트는 풀리지 않으며
# (--project-directory 가 클라이언트/데몬 이중 역할), 부팅에 필요한 파일은 기동 전에 밀어 넣어야 한다.
# 이 차이를 코드 곳곳의 `if remote:` 로 흩뿌리지 않고 타깃 하나에 모은다. 로컬 타깃은 지금 동작을
# 그대로 반환하므로(대개 no-op) 로컬 경로는 물리적으로 바뀌지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json
import tempfile
import unittest
from pathlib import Path

from marina_runtime_target import Mount, load_target


class LocalTargetTests(unittest.TestCase):
    """설정이 없으면 로컬 — 지금 동작 그대로."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.session = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_no_config_is_local(self):
        t = load_target(str(self.session))
        self.assertFalse(t.is_remote)
        self.assertEqual(t.name, "local")

    def test_local_adds_no_docker_env(self):
        # 로컬은 DOCKER_HOST 를 건드리지 않는다 — 기존 호출과 바이트 단위로 같아야 한다.
        self.assertEqual(load_target(str(self.session)).docker_env(), {})

    def test_local_keeps_bind_mounts_untouched(self):
        vols = [Mount("./be-api/user-api/build/libs", "/app/libs"), Mount("web_app_next", "/app/apps/web/.next")]
        rewrite = load_target(str(self.session)).volume_rewrite("user-api", vols)
        self.assertEqual(rewrite.volumes, vols)
        self.assertEqual(rewrite.named_volumes, {})
        self.assertEqual(rewrite.injections, [])

    def test_local_prepare_is_noop(self):
        self.assertEqual(load_target(str(self.session)).injection_plan({}), [])


class RemoteTargetTests(unittest.TestCase):
    """설정이 있으면 원격 — 데몬 지정 + 바인드 치환 + 주입 계획."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.session = Path(self.tmp.name)
        (self.session / "runtime-target.json").write_text(
            json.dumps({"kind": "remote", "host": "ssh://crabs@192.168.0.251"}), encoding="utf-8")
        self.t = load_target(str(self.session))

    def tearDown(self):
        self.tmp.cleanup()

    def test_remote_is_detected(self):
        self.assertTrue(self.t.is_remote)
        self.assertEqual(self.t.name, "remote")

    def test_remote_sets_docker_host(self):
        self.assertEqual(self.t.docker_env(), {"DOCKER_HOST": "ssh://crabs@192.168.0.251"})

    def test_host_path_bind_becomes_named_volume(self):
        # 원격 데몬은 개발자 맥의 경로를 풀 수 없다 → named volume 으로 치환하고 주입 대상으로 기록.
        r = self.t.volume_rewrite("user-api", [Mount("./be-api/user-api/build/libs", "/app/libs")])
        self.assertEqual(r.volumes, [Mount("marina_user_api_app_libs", "/app/libs")])
        self.assertEqual(r.named_volumes, {"marina_user_api_app_libs": None})
        self.assertEqual(len(r.injections), 1)
        inj = r.injections[0]
        self.assertEqual(inj.service, "user-api")
        self.assertEqual(inj.source, "./be-api/user-api/build/libs")
        self.assertEqual(inj.target, "/app/libs")

    def test_named_volume_is_left_alone(self):
        # 이미 named volume 인 것은 원격에서도 그대로 — 데몬 쪽에 살기 때문.
        r = self.t.volume_rewrite("web", [Mount("web_app_next", "/app/apps/web/.next")])
        self.assertEqual(r.volumes, [Mount("web_app_next", "/app/apps/web/.next")])
        self.assertEqual(r.injections, [])

    def test_readonly_flag_is_preserved(self):
        r = self.t.volume_rewrite("web", [Mount("./web-app-monorepo/apps/web/.env.ssm.local",
                                                "/app/apps/web/.env.ssm.local", "ro")])
        self.assertEqual(r.volumes, [Mount("marina_web_app_apps_web_env_ssm_local",
                                           "/app/apps/web/.env.ssm.local", "ro")])
        self.assertEqual(r.injections[0].source, "./web-app-monorepo/apps/web/.env.ssm.local")

    def test_absolute_host_path_also_rewritten(self):
        r = self.t.volume_rewrite("svc", [Mount("/Users/me/proj/libs", "/app/libs")])
        self.assertEqual(r.injections[0].source, "/Users/me/proj/libs")
        self.assertNotIn("/Users", r.volumes[0].source)

    def test_colon_in_host_path_survives(self):
        # 문자열로 합쳐 되쪼개던 시절엔 `/p/a: b` 가 source=`/p/a` 로 갈렸다.
        r = self.t.volume_rewrite("svc", [Mount("/p/a: b/libs", "/app/libs")])
        self.assertEqual(r.injections[0].source, "/p/a: b/libs")
        self.assertEqual(r.injections[0].target, "/app/libs")


    def test_file_mount_is_dropped_not_volumised(self):
        # named volume 은 **디렉터리**로 마운트된다. 파일 경로(.env)에 얹으면 도커가 거부한다:
        #   "source /.../.env.ssm.local is not directory" → 컨테이너 생성 자체가 실패.
        # 파일은 볼륨 없이 컨테이너 안으로 바로 넣는다(주입 목록엔 그대로 남는다).
        r = self.t.volume_rewrite(
            "web",
            [Mount("/p/apps/web/.env", "/app/apps/web/.env"),
             Mount("/p/build/libs", "/app/libs")],
            is_dir_fn=lambda src: src.endswith("libs"),
        )
        self.assertEqual(r.volumes, [Mount("marina_web_app_libs", "/app/libs")])   # 파일 마운트는 사라짐
        self.assertEqual(sorted(r.named_volumes), ["marina_web_app_libs"])         # 파일용 볼륨 안 만듦
        self.assertEqual(sorted(i.target for i in r.injections),
                         ["/app/apps/web/.env", "/app/libs"])                      # 둘 다 주입 대상

    def test_file_injection_records_no_volume(self):
        r = self.t.volume_rewrite("web", [Mount("/p/.env", "/app/.env")], is_dir_fn=lambda src: False)
        self.assertEqual(r.volumes, [])
        self.assertEqual(r.named_volumes, {})
        self.assertEqual(r.injections[0].volume, "")     # 볼륨 없음을 명시

    def test_default_predicate_is_the_filesystem(self):
        import tempfile, os
        with tempfile.TemporaryDirectory() as d:
            os.mkdir(os.path.join(d, "libs"))
            r = self.t.volume_rewrite("s", [Mount(os.path.join(d, "libs"), "/app/libs")])
            self.assertEqual(len(r.volumes), 1)          # 실제 디렉터리 → 볼륨

    def test_missing_host_falls_back_to_local(self):
        # host 없는 깨진 설정으로 원격을 자칭하면 로컬로 떨어진다 — 조용히 원격을 시도하는 게 더 위험하다.
        s = Path(tempfile.mkdtemp())
        (s / "runtime-target.json").write_text(json.dumps({"kind": "remote"}), encoding="utf-8")
        self.assertFalse(load_target(str(s)).is_remote)


unittest.main(verbosity=1)
PY
