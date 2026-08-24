#!/usr/bin/env bash
# 원격 모드에서 갈라지는 두 가지 판단.
#
# ① PreToolUse 의 "원격 = 마리나 밖" 분류가 뒤집힌다. 원래 취지는 옳다 — 사무실 PC 나 남의 도커
#    호스트엔 워크트리 포트 격리 개념이 없으니 막으면 안 되고, 막으면 MARINA_DIRECT 를 습관적으로
#    붙이게 되어 탈출구가 망가진다. 그런데 **그 박스가 이 워크트리의 런타임**이면 얘기가 다르다.
#    거기서 도는 컨테이너가 곧 마리나가 관리하는 그것이라, 우회를 허용하면 격리가 그대로 뚫린다.
#
# ② `forward: host` 는 원격에서 의미가 바뀐다. 로컬에선 개발자 맥의 redis/kafka 를 가리키지만
#    원격에선 박스를 가리킨다. 조용히 다른 기계에 붙는 것보다 경고하는 편이 낫다.
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


class HostForwardWarningTests(unittest.TestCase):
    CONN = {"forward": {"6379": "host", "8081": "user-api", "9092": "host"}}

    def test_local_says_nothing(self):
        self.assertIsNone(mctl.host_forward_warning(self.CONN, LocalTarget()))

    def test_remote_warns_and_names_the_ports(self):
        msg = mctl.host_forward_warning(self.CONN, RemoteTarget("ssh://crabs@box"))
        self.assertIsNotNone(msg)
        self.assertIn("6379", msg)
        self.assertIn("9092", msg)

    def test_service_targets_are_not_warned(self):
        # 서비스 타겟(8081→user-api)은 컨테이너 DNS 라 기계가 바뀌어도 뜻이 그대로다.
        msg = mctl.host_forward_warning(self.CONN, RemoteTarget("ssh://box"))
        self.assertNotIn("8081", msg)

    def test_no_host_forward_no_warning(self):
        self.assertIsNone(mctl.host_forward_warning(
            {"forward": {"8081": "user-api"}}, RemoteTarget("ssh://box")))

    def test_empty_connectivity_is_safe(self):
        self.assertIsNone(mctl.host_forward_warning({}, RemoteTarget("ssh://box")))
        self.assertIsNone(mctl.host_forward_warning(None, RemoteTarget("ssh://box")))


unittest.main(argv=[sys.argv[0]], verbosity=1)
PY

# ── ② PreToolUse: 이 워크트리의 런타임인 박스로 향하는 명령은 예외가 아니다 ──
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/wt"; mkdir -p "$P"; (cd "$P" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)
cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"p","root":"$P"}]}
JSON
# 세션 디렉터리는 추측하지 않는다 — session_id 는 디렉터리명이 아니라 브랜치명을 쓴다.
SD="$(PYTHONPATH="$SCRIPTS" python3 -c 'from pathlib import Path; from marina_paths import session_dir; import sys; print(session_dir(Path(sys.argv[1])))' "$P")"; mkdir -p "$SD"

hook() {   # stdin=명령 → 종료코드 0=통과, 그 외/출력=차단
  printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":%s}}' "$P" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
    | MARINA_HOME="$MARINA_HOME" python3 "$SCRIPTS/marina_pretooluse.py" 2>/dev/null
}
blocked() { [[ -n "$(hook "$1")" ]]; }
fail() { echo "FAIL: $1"; exit 1; }

# 로컬 워크트리: 로컬 기동은 막고, 남의 원격은 통과(기존 동작 유지)
blocked 'docker compose up -d'                    || fail "로컬 기동이 안 막힘"
blocked 'DOCKER_HOST=ssh://other-box docker compose up -d' && fail "무관한 원격이 막힘(기존 동작 훼손)"

# 원격 워크트리: 그 박스로 향하는 명령은 **마리나 영역**이라 막아야 한다
printf '{"kind":"remote","host":"ssh://crabs@192.168.0.251"}\n' > "$SD/runtime-target.json"
blocked 'DOCKER_HOST=ssh://crabs@192.168.0.251 docker compose up -d' || fail "이 워크트리의 런타임 박스로 향하는 기동이 안 막힘"
# 다른 기계는 여전히 통과 — 마리나 관할이 아니다
blocked 'DOCKER_HOST=ssh://someone-else docker compose up -d' && fail "무관한 원격이 막힘"
# 탈출구는 유지
blocked 'MARINA_DIRECT=1 DOCKER_HOST=ssh://crabs@192.168.0.251 docker compose up -d' && fail "MARINA_DIRECT 탈출구가 막힘"

echo PASS
