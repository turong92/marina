#!/usr/bin/env bash
# 박스 단위 `docker ps` 한 줄을 `compose ps` 와 **같은 모양**으로 옮기는 변환.
#
# 왜 변환이 필요했나: 원격은 워크트리마다 `compose ps` 를 부르면 워크트리 수만큼 ssh 접속이 생긴다.
# `docker ps` 한 번이면 박스의 모든 compose 프로젝트를 읽을 수 있지만 출력 모양이 달라서, 호출부가
# 원격·로컬을 구분하지 않도록 여기서 같은 키(Service/Name/State/Health/ExitCode/Publishers)로 맞춘다.
# 이 변환이 틀어지면 대시보드가 **도는 서비스를 안 돈다고** 하므로 실 docker 출력으로 고정해 둔다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import subprocess, unittest

import marina_compose_svc as mcs


def line(name, state, status, ports, project, service):
    return "\t".join([name, state, status, ports, project, service])


class TranslationTests(unittest.TestCase):
    def rows(self, *lines, project="p"):
        return mcs._ps_rows_by_project("\n".join(lines) + "\n").get(project, [])

    def test_running_container(self):
        r = self.rows(line("p-web-1", "running", "Up 4 days", "127.0.0.1:50909->8080/tcp", "p", "web"))
        self.assertEqual(r, [{"Service": "web", "Name": "p-web-1", "State": "running", "Health": "",
                              "ExitCode": None,
                              "Publishers": [{"PublishedPort": 50909, "TargetPort": 8080, "Protocol": "tcp"}]}])

    def test_health_states(self):
        # 실측 문자열: 도커는 `(healthy)` · `(unhealthy)` · `(health: starting)` 로 적는다.
        for status, want in (("Up 2 minutes (healthy)", "healthy"),
                             ("Up 2 minutes (unhealthy)", "unhealthy"),
                             ("Up 3 seconds (health: starting)", "starting"),
                             ("Up 4 days", "")):
            r = self.rows(line("p-web-1", "running", status, "", "p", "web"))
            self.assertEqual(r[0]["Health"], want, status)
            # 대시보드 pill 까지 같은 뜻이어야 한다
            self.assertEqual(mcs.compose_health(r[0]["State"], r[0]["Health"]),
                             {"healthy": "ok", "": "ok", "unhealthy": "bad", "starting": "starting"}[want])

    def test_exit_code_only_for_exited(self):
        r = self.rows(line("p-w-1", "exited", "Exited (137) 3 minutes ago", "", "p", "w"))
        self.assertEqual(r[0]["ExitCode"], 137)
        r = self.rows(line("p-w-1", "restarting", "Restarting (1) 2 seconds ago", "", "p", "w"))
        self.assertIsNone(r[0]["ExitCode"], "재시작 중인 컨테이너의 (1) 은 종료코드가 아니다")

    def test_publishers(self):
        f = mcs._ps_publishers
        self.assertEqual(f(""), [])
        self.assertEqual(f("8080/tcp"), [], "게시 안 된 포트는 제외")
        self.assertEqual([p["PublishedPort"] for p in f("0.0.0.0:8008->8008/tcp, [::]:8008->8008/tcp")], [8008],
                         "IPv4·IPv6 로 두 번 나오는 같은 게시는 한 번만")
        self.assertEqual([(p["PublishedPort"], p["Protocol"]) for p in f("0.0.0.0:53->53/udp")], [(53, "udp")])
        self.assertEqual([p["PublishedPort"] for p in f("0.0.0.0:3000-3002->3000-3002/tcp")], [3000],
                         "범위는 시작 포트만 — 소비자는 최소값을 대표로 쓴다")
        self.assertEqual([p["PublishedPort"] for p in f("127.0.0.1:1->2/tcp, 127.0.0.1:3->4/tcp")], [1, 3])

    def test_non_compose_and_broken_lines_are_skipped(self):
        by = mcs._ps_rows_by_project("\n".join([
            line("vaultwarden", "running", "Up 1 day", "", "", ""),        # compose 가 만든 게 아님
            "쓰레기 줄",
            line("p-web-1", "running", "Up 1 day", "", "p", "web"),
        ]))
        self.assertEqual(list(by), ["p"])

    def test_service_falls_back_to_name(self):
        r = self.rows(line("p-web-1", "running", "Up 1 day", "", "p", ""))
        self.assertEqual(r[0]["Service"], "p-web-1", "service 라벨이 없어도 행을 잃지 않는다")

    def test_sidecar_port_folds_into_app_card(self):
        """엮기 사이드카가 netns 주인이라 게시 포트는 `<svc>-bind` 행에 잡힌다 — 변환 뒤에도 앱 카드가 URL 을 갖는다."""
        rows = mcs._ps_rows_by_project("\n".join([
            line("p-web-1", "running", "Up 1 day", "", "p", "web"),
            line("p-web-bind-1", "running", "Up 1 day (healthy)", "127.0.0.1:5173->5173/tcp", "p", "web-bind"),
        ]))["p"]
        svcs = {s["service"]: s for s in mcs.build_compose_services(rows)}
        self.assertEqual(svcs["web"]["port"], "5173")
        self.assertTrue(svcs["web"]["running"])


class RealDockerShapeTests(unittest.TestCase):
    """실 docker 로 `compose ps` 와 배치 조회가 **같은 결론**인지 — 도커 버전이 포맷을 바꾸면 여기서 깨진다.
    읽기 전용(ps)만 한다. docker 가 없거나 compose 프로젝트가 없으면 건너뛴다."""

    def test_matches_compose_ps(self):
        try:
            out = subprocess.run(["docker", "ps", "--all", "--filter", "label=com.docker.compose.project",
                                  "--format", mcs._PS_TEMPLATE], capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.SubprocessError):
            self.skipTest("docker 없음")
        if out.returncode != 0:
            self.skipTest("docker 데몬 없음")
        by = mcs._ps_rows_by_project(out.stdout)
        if not by:
            self.skipTest("compose 프로젝트 없음")
        project = sorted(by)[0]
        old = subprocess.run(["docker", "compose", "-p", project, "ps", "--all", "--format", "json"],
                             capture_output=True, text=True, timeout=30)
        if old.returncode != 0:
            self.skipTest("compose ps 실패")
        keys = ("service", "port", "running", "health", "exitCode")
        want = [{k: s[k] for k in keys} for s in mcs.build_compose_services(mcs._parse_ps_rows(old.stdout))]
        got = [{k: s[k] for k in keys} for s in mcs.build_compose_services(by[project])]
        self.assertEqual(got, want, f"프로젝트 {project}")


unittest.main(verbosity=1)
PY
