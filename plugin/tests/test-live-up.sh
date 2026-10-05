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
# 'a' 는 **소스에서 빌드**한다 — compose 의 --project-directory 가 바인드뿐 아니라
# 빌드 컨텍스트까지 옮기므로(실측), live 가 데이터 기준점을 live/ 로 두면서도 빌드는
# 체크아웃(live/src)에서 해야 한다. 이게 안 되면 소스 빌드 live 스택은 전부 깨진다.
printf 'FROM alpine:3.20\nCOPY marker.txt /marker.txt\n' > "$REPO/Dockerfile"
echo built-from-src > "$REPO/marker.txt"
cat > "$REPO/docker-compose.yml" <<Y
services:
  a:
    build: .
    command: ["sh", "-c", "mkdir -p /srv/data && cp /marker.txt /srv/data/marker && sleep 600"]
    ports: ["127.0.0.1:$PORT:80"]
    volumes:
      - ./data/a:/srv/data
      - ./mysql:/var/lib/mysql
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
# 빌드가 체크아웃에서 됐다 — 컨텍스트가 live/ 로 옮겨졌으면 Dockerfile 을 못 찾아 기동 자체가 실패한다
grep -q built-from-src "$MARINA_HOME/livetest/live/data/a/marker" \
  || { echo "FAIL: 빌드 컨텍스트가 체크아웃이 아니다: $(cat "$MARINA_HOME/livetest/live/data/a/marker")"; exit 1; }
# live/ 안이지만 live/data 밖인 바인드도 백업 목록에 들어간다 (./mysql → live/mysql)
out="$($MARINA live backup-paths livetest 2>&1)"
case "$out" in *"/livetest/live/mysql"*) ;; *) echo "FAIL: live/ 안 데이터 바인드가 백업 목록에 없다: $out"; exit 1 ;; esac

# restart 정책이 덮였다
[ "$(docker inspect livetest-live-a-1 --format '{{.HostConfig.RestartPolicy.Name}}')" = "unless-stopped" ] \
  || { echo "FAIL: restart 정책이 안 덮였다"; exit 1; }

echo "--- 3b) 컨테이너가 하나도 안 뜨면 up 은 성공이 아니다"
# live_containers 는 docker ps 가 비0이면 빈 목록을 돌려준다 — 그걸 '죽은 게 없다' 로
# 읽으면 아무것도 안 뜬 상태가 조용히 성공이 된다.
python3 - "$SCRIPTS" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location("cli", sys.argv[1] + "/marina_live_cli.py")
cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
rows = []
bad = cli._unhealthy(rows, ["a", "b"])
assert bad, "컨테이너 0개인데 문제 없다고 했다"
assert "0" in " ".join(bad) or "없" in " ".join(bad), bad
# restarting 은 크래시 루프의 정상 모습이다 — 통과시키면 안 된다
bad = cli._unhealthy([{"name": "x", "service": "a", "state": "restarting", "restarts": 3}], ["a"])
assert bad, "restarting 을 성공으로 봤다"
# running 이고 재시작 0 이면 문제 없다
assert cli._unhealthy([{"name": "x", "service": "a", "state": "running", "restarts": 0}], ["a"]) == []
print("ok")
PY

echo "--- 4) status 가 세 신호와 경로를 보여준다"
out="$($MARINA live status livetest 2>&1)"
case "$out" in *"$MARINA_HOME/livetest/live/data"*) ;; *) echo "FAIL: 데이터 경로가 안 보인다: $out"; exit 1 ;; esac
case "$out" in *"자동 기동"*) ;; *) echo "FAIL: 자동 기동 여부가 안 보인다: $out"; exit 1 ;; esac
case "$out" in *running*) ;; *) echo "FAIL: 컨테이너 상태가 안 보인다: $out"; exit 1 ;; esac

echo "--- 5) 멱등 — 두 번 up 해도 성공한다"
$MARINA live up livetest >/dev/null

echo "--- 5b) up 과 down 이 겹치지 않는다 (둘 다 같은 잠금을 잡는다)"
# 재부팅 직후 launchd 유닛의 up 과 사람의 down 이 겹치면, down 이 유닛을 떼고 내린 뒤
# up 이 컨테이너를 올리고 유닛을 다시 심는다 — "내렸는데 자동 기동은 켜져 있다" 가 된다.
python3 - "$SCRIPTS" "$MARINA_HOME" <<'PY'
import os, subprocess, sys
sys.path.insert(0, sys.argv[1])
import marina_live as L
os.environ["MARINA_HOME"] = sys.argv[2]
with L.src_lock("livetest"):
    for sub in ("down", "restart"):
        r = subprocess.run(["bash", sys.argv[1] + "/marina.sh", "live", sub, "livetest"],
                           capture_output=True, text=True,
                           env={**os.environ, "MARINA_HOME": sys.argv[2]})
        assert r.returncode != 0, f"{sub} 가 잠금을 무시했다: {r.stdout}{r.stderr}"
        assert "이미" in (r.stdout + r.stderr), f"{sub} 잠금 메시지 없음: {r.stdout}{r.stderr}"
print("ok")
PY

echo "--- 6) down 이 내리고 자동 기동을 해제한다"
$MARINA live down livetest >/dev/null
n="$(docker ps -a --filter "label=marina.live=1" --filter "label=marina.project=livetest" --format '{{.Names}}' | wc -l | tr -d ' ')"
[ "$n" = "0" ] || { echo "FAIL: down 후에도 컨테이너 $n 개"; exit 1; }
out="$($MARINA live status livetest 2>&1)"
case "$out" in *"안 됨"*) ;; *) echo "FAIL: down 후 자동 기동이 해제되지 않았다: $out"; exit 1 ;; esac

# 데이터는 남는다 — down 은 정지이지 삭제가 아니다
[ -f "$MARINA_HOME/livetest/live/data/a/marker" ] || { echo "FAIL: down 이 데이터를 지웠다"; exit 1; }
echo "PASS test-live-up"
