#!/usr/bin/env bash
# live CLI 의 거부 경로 — 기동 전에 큰 소리로 막는 것들 (도커 불필요).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

python3 - "$SCRIPTS" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import marina_live as L

# 1) compose 에 없는 서비스를 적으면 거부한다 — compose 는 모르는 이름을 조용히 무시하므로,
#    막지 않으면 "떴다는데 아무것도 없다" 가 된다.
cfg = {"services": {"server": {}, "web": {}}}
L.validate_services(cfg, ["server"])            # 통과
try:
    L.validate_services(cfg, ["server", "nope"])
    raise AssertionError("없는 서비스인데 통과했다")
except L.LiveConfigError as e:
    assert "nope" in str(e), e
    assert "server" in str(e) and "web" in str(e), "있는 것을 알려주지 않는다: %s" % e

# 2) 빈 목록은 거부한다 — "전부" 를 뜻하게 두면 개발용 보조 서비스까지 운영에 끌려온다
try:
    L.validate_services(cfg, [])
    raise AssertionError("빈 목록인데 통과했다")
except L.LiveConfigError as e:
    assert "services" in str(e), e

# 3) 데이터 디렉토리를 미리 만든다 — 도커는 바인드 소스를 자동 생성하지 않는다
d = L.ensure_data_dir("p")
assert d.is_dir(), d
assert d == L.live_data("p")
L.ensure_data_dir("p")                          # 멱등
print("ok")
PY

echo "--- CLI 분기"
# 4) live 가 서브커맨드로 존재하고, 알 수 없는 하위명령은 사용법을 낸다
out="$(bash "$SCRIPTS/marina.sh" live 2>&1 || true)"
case "$out" in *"live up"*) ;; *) echo "FAIL: live 사용법이 안 나온다: $out"; exit 1 ;; esac

# 5) 등록 안 된 프로젝트는 거부한다 (프로젝트명이 메시지에 있어야 원인을 찾는다)
out="$(bash "$SCRIPTS/marina.sh" live up definitely-not-a-project 2>&1 || true)"
case "$out" in *definitely-not-a-project*) ;; *) echo "FAIL: 거부에 프로젝트명이 없다: $out"; exit 1 ;; esac

# 6) 프로젝트명을 안 주면 거부한다
bash "$SCRIPTS/marina.sh" live up >/dev/null 2>&1 && { echo "FAIL: 프로젝트명 없이 통과"; exit 1; } || true

# 7) live 설정이 없는 프로젝트는 pin 을 안내한다
mkdir -p "$MARINA_HOME"
cat > "$MARINA_HOME/projects.json" <<'JSON'
{"projects":[{"id":"plainproj","root":"/tmp","composeFile":"docker-compose.yml"}],"schemaVersion":1}
JSON
out="$(bash "$SCRIPTS/marina.sh" live up plainproj 2>&1 || true)"
case "$out" in *pin*) ;; *) echo "FAIL: pin 안내가 없다: $out"; exit 1 ;; esac

# 8) pin 은 레지스트리에 ref 를 쓴다
bash "$SCRIPTS/marina.sh" live pin plainproj v9 >/dev/null
grep -q '"ref": "v9"' "$MARINA_HOME/projects.json" || { echo "FAIL: pin 이 ref 를 안 썼다"; cat "$MARINA_HOME/projects.json"; exit 1; }

echo "--- live 는 예약된 세션 이름이다"
# 워크트리 이름이 'live' 면 session_id 가 "live" 가 되어 compose 프로젝트명이 운영 스택과
# **완전히 같아진다**(<id>-live). 그 워크트리에서 marina start 를 하면 개발 overlay 로
# 운영 컨테이너를 재생성해 선언 포트가 사라지고 GC 면제 라벨도 풀린다. marina stop 은
# 운영 스택을 내린다. 확률은 낮지만 대가가 운영 중단이라 이름 단계에서 막는다.
cd "$SCRIPTS/../.."
set +e
out="$(bash "$SCRIPTS/marina.sh" worktree create live 2>&1)"
rc=$?
set -e
[ "$rc" != "0" ] || { echo "FAIL: 'live' 워크트리 생성이 통과했다: $out"; exit 1; }
case "$out" in *예약*) ;; *) echo "FAIL: 예약어라고 알려주지 않는다: $out"; exit 1 ;; esac
[ ! -e ".claude/worktrees/live" ] || { echo "FAIL: live 워크트리가 만들어졌다"; exit 1; }
# 슬래시가 '-' 로 치환돼 live 가 되는 경우도 막는다 (feature/live → feature-live 는 괜찮다)
set +e
out="$(bash "$SCRIPTS/marina.sh" worktree create LIVE 2>&1)"
rc=$?
set -e
[ "$rc" != "0" ] || { echo "FAIL: 'LIVE' 가 통과했다: $out"; exit 1; }
echo "PASS test-live-cli (예약어 포함)"
