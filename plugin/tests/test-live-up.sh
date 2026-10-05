#!/usr/bin/env bash
# live up/down 왕복 — 실제 compose 프로젝트를 띄워 확인한다. 도커 없으면 원격 거부만 보고 스킵.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"
MARINA="bash $SCRIPTS/marina.sh"

# 하네스의 MARINA_HOME 은 $TMPDIR(= /var/folders/...) 아래인데 **Docker Desktop 의 기본
# 공유 경로에 /var/folders 가 없다**(실측 2026-10-06): 그 아래 바인드 마운트는 조용히 VM
# 내부 디렉터리로 만들어져 컨테이너에는 보이지만 호스트에는 안 보인다. live 는 데이터
# 경로를 단정하는 기능이라 공유되는 경로(/tmp → /private/tmp)로 옮겨 본다.
# 실사용의 ~/.marina 는 /Users 아래라 공유된다.
MARINA_HOME="/tmp/marina-test-home/$(basename -- "$0" .sh)"
rm -rf "$MARINA_HOME"; mkdir -p "$MARINA_HOME"; export MARINA_HOME

TMP="$(mktemp -d)"
PORT=38421
cleanup() {
  docker compose -p livetest-live down --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$TMP" "$MARINA_HOME"
}
trap cleanup EXIT

# 운영 대상 레포 — compose 파일이 ref 에 들어 있어야 배포가 ref 하나로 표현된다
REPO="$TMP/repo"; mkdir -p "$REPO"
cat > "$REPO/docker-compose.yml" <<Y
services:
  a:
    image: alpine:3.20
    command: ["sh", "-c", "mkdir -p /srv/data && echo live > /srv/data/marker && sleep 600"]
    ports: ["127.0.0.1:$PORT:80"]
    volumes:
      - ./data/a:/srv/data
  helper:
    image: alpine:3.20
    command: ["sleep", "600"]
Y
git -C "$REPO" init -q .
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" add .
git -C "$REPO" commit -qm one

mkdir -p "$MARINA_HOME"
cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"livetest","root":"$REPO","composeFile":"docker-compose.yml",
  "live":{"ref":"HEAD","services":["a"]}}],"schemaVersion":1}
JSON

echo "--- 1) 원격이 설정됐는데 안 닿으면 실패한다 (조용히 로컬로 떨어지지 않는다)"
# 개발에서는 '박스가 안 닿으면 로컬로 떨어진다' 가 친절한 폴백이지만, live 에서는 두 기계에
# 같은 서비스가 뜨는 조용히 틀린 상태가 된다.
set +e
out="$(MARINA_LIVE_REMOTE='ssh://nobody@127.0.0.1:1' $MARINA live up livetest 2>&1)"
rc=$?
set -e
[ "$rc" != "0" ] || { echo "FAIL: 원격 미도달인데 성공했다: $out"; exit 1; }
case "$out" in *원격*) ;; *) echo "FAIL: 원격 실패를 알리지 않는다: $out"; exit 1 ;; esac
[ ! -d "$MARINA_HOME/livetest/live/src" ] || { echo "FAIL: 원격 실패인데 체크아웃을 만들었다"; exit 1; }

echo "--- 2) compose 에 없는 서비스는 기동 전에 거부한다"
python3 - "$MARINA_HOME/projects.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["projects"][0]["live"]["services"] = ["a", "nope"]
json.dump(d, open(p, "w"))
PY
set +e; out="$($MARINA live up livetest 2>&1)"; rc=$?; set -e
[ "$rc" != "0" ] || { echo "FAIL: 없는 서비스인데 성공했다"; exit 1; }
case "$out" in *nope*) ;; *) echo "FAIL: 없는 서비스명을 안 알려준다: $out"; exit 1 ;; esac
python3 - "$MARINA_HOME/projects.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["projects"][0]["live"]["services"] = ["a"]
json.dump(d, open(p, "w"))
PY

if ! docker info >/dev/null 2>&1; then
  echo "docker 미가동 — 왕복은 스킵"
  echo "PASS test-live-up (부분: 거부 경로만)"
  exit 0
fi

echo "--- 3) up 이 실제로 띄운다"
$MARINA live up livetest
pname="$(python3 - "$SCRIPTS" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1] + "/marina-compose.py")
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
print(mc.compose_project_name("livetest", "live"))
PY
)"
[ "$pname" = "livetest-live" ] || { echo "FAIL: 프로젝트명 $pname"; exit 1; }

names="$(docker ps --filter "label=marina.live=1" --filter "label=marina.project=livetest" --format '{{.Names}}')"
case "$names" in *livetest-live-a-1*) ;; *) echo "FAIL: live 컨테이너가 없다: [$names]"; exit 1 ;; esac

# live.services 에 없는 서비스는 안 뜬다 — 개발용 보조 서비스를 운영에 끌고 가지 않는다
case "$names" in *helper*) echo "FAIL: 선언 안 한 서비스가 떴다: $names"; exit 1 ;; esac

# 선언한 포트가 그대로 열린다 (개발의 127.0.0.1:: 자동할당이 아니다)
docker ps --filter "label=marina.live=1" --format '{{.Ports}}' | grep -q "$PORT" \
  || { echo "FAIL: 선언 포트 $PORT 가 안 열렸다: $(docker ps --filter label=marina.live=1 --format '{{.Ports}}')"; exit 1; }

# 데이터가 워크트리가 아니라 ~/.marina/<id>/live/data 아래 쌓인다
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MARINA_HOME/livetest/live/data/a/marker" ] && break; sleep 1; done
[ -f "$MARINA_HOME/livetest/live/data/a/marker" ] \
  || { echo "FAIL: 데이터가 live/data 에 없다: $(find "$MARINA_HOME/livetest/live" -maxdepth 3 | head)"; exit 1; }

# restart 정책이 덮였다
[ "$(docker inspect livetest-live-a-1 --format '{{.HostConfig.RestartPolicy.Name}}')" = "unless-stopped" ] \
  || { echo "FAIL: restart 정책이 안 덮였다"; exit 1; }

echo "--- 4) status 가 세 신호와 경로를 보여준다"
out="$($MARINA live status livetest 2>&1)"
case "$out" in *"$MARINA_HOME/livetest/live/data"*) ;; *) echo "FAIL: 데이터 경로가 안 보인다: $out"; exit 1 ;; esac
case "$out" in *"자동 기동"*) ;; *) echo "FAIL: 자동 기동 여부가 안 보인다: $out"; exit 1 ;; esac
case "$out" in *running*) ;; *) echo "FAIL: 컨테이너 상태가 안 보인다: $out"; exit 1 ;; esac

echo "--- 5) 멱등 — 두 번 up 해도 성공한다"
$MARINA live up livetest >/dev/null

echo "--- 6) down 이 내리고 자동 기동을 해제한다"
$MARINA live down livetest >/dev/null
n="$(docker ps -a --filter "label=marina.live=1" --filter "label=marina.project=livetest" --format '{{.Names}}' | wc -l | tr -d ' ')"
[ "$n" = "0" ] || { echo "FAIL: down 후에도 컨테이너 $n 개"; exit 1; }
out="$($MARINA live status livetest 2>&1)"
case "$out" in *"안 됨"*) ;; *) echo "FAIL: down 후 자동 기동이 해제되지 않았다: $out"; exit 1 ;; esac

# 데이터는 남는다 — down 은 정지이지 삭제가 아니다
[ -f "$MARINA_HOME/livetest/live/data/a/marker" ] || { echo "FAIL: down 이 데이터를 지웠다"; exit 1; }
echo "PASS test-live-up"
