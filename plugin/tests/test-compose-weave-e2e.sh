#!/usr/bin/env bash
# 실 docker E2E: 엮기 일원화 — app(build) 컨테이너에서
#   ① 환경변수 주입: APP_ENV=e2elocal (marina --env-var)
#   ② service 타겟(자동도출): localhost:8081 → be:8081 (socat→컨테이너 DNS) → BE-OK
#   ③ host 타겟(선언, redis 호스트공유): localhost:6399 → host redis (socat→host.docker.internal) → PONG
# docker 데몬 없으면 SKIP. 자체 redis 를 호스트 6399(점유 6379 회피)에 띄워 격리.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-weave-e2e (docker 데몬 미가용)"; exit 0; }

TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
P="$TMP/proj-$$"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"
RED="marina-weave-e2e-redis-$$"
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" "$@"); }
cleanup() { mrun stop --all >/dev/null 2>&1 || true; docker rm -f "$RED" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

docker run -d --rm --name "$RED" -p 6379 redis:7-alpine >/dev/null         # host 공유 redis — docker 가 빈 호스트포트 할당(고정포트 충돌 회피, 코덱스 리뷰 P3)
RPORT="$(docker port "$RED" 6379/tcp | head -1 | sed 's/.*://')"           # 할당된 호스트 포트 (host.docker.internal 로 도달)
[ -n "$RPORT" ] || { echo "FAIL: redis 호스트포트 할당 못 읽음"; docker port "$RED"; exit 1; }

cat > "$P/Dockerfile.app" <<'DOCK'
FROM alpine:3.20
RUN apk add --no-cache curl redis
CMD ["sleep","infinity"]
DOCK
cat > "$P/docker-compose.yml" <<'YML'
services:
  be:
    image: hashicorp/http-echo
    command: ["-text=BE-OK","-listen=:8081"]
    expose: ["8081"]
  weaveapp:
    build: { context: ., dockerfile: Dockerfile.app }
    environment: ["APP_ENV"]
YML

# 등록(--env-var APP_ENV 주입) → host 타겟 6399 선언(backing.json forward, start 가 --connectivity 로 픽업) → start
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" --env-var APP_ENV --env-default e2elocal >/dev/null
pid="$(ls -1 "$MARINA_HOME" | grep -vx projects.json | head -1)"
[ -n "$pid" ] || { echo "FAIL: project id 디렉터리 못 찾음"; ls -la "$MARINA_HOME"; exit 1; }
printf '{"version":1,"forward":{"%s":{"target":"host"}}}' "$RPORT" > "$MARINA_HOME/$pid/backing.json"
mrun start --all >/dev/null 2>&1 || { echo "FAIL: marina start"; mrun start --all 2>&1 | tail -20; exit 1; }

# weaveapp 컨테이너 — 유니크 서비스명으로 다른 프로젝트의 'app' 과 충돌 방지(코덱스 리뷰 P3). 사이드카 weaveapp-bind 는 service=weaveapp-bind 라 안 잡힘.
APPC=""
for _ in $(seq 1 30); do
  APPC="$(docker ps --filter "label=com.docker.compose.service=weaveapp" --format '{{.Names}}' | head -1)"
  [ -n "$APPC" ] && break; sleep 1
done
[ -n "$APPC" ] || { echo "FAIL: weaveapp 컨테이너 못 찾음"; docker ps; exit 1; }

# ① 환경변수 주입
envv="$(docker exec "$APPC" sh -c 'printf %s "$APP_ENV"' 2>&1 || true)"
[ "$envv" = "e2elocal" ] || { echo "FAIL: APP_ENV 주입 안 됨: [$envv]"; exit 1; }

# ② service 타겟 — localhost:8081 → be (socat→DNS) → BE-OK
ok_be=false
for _ in $(seq 1 30); do
  out_be="$(docker exec "$APPC" sh -c 'curl -s --max-time 3 localhost:8081' 2>&1 || true)"
  case "$out_be" in *BE-OK*) ok_be=true; break;; esac; sleep 1
done
$ok_be || { echo "FAIL: localhost:8081→be 안 됨: [${out_be:-}]"; docker ps; BC="$(docker ps -a --filter "label=com.docker.compose.service=weaveapp-bind" --format '{{.Names}}' | head -1)"; [ -n "$BC" ] && docker logs "$BC" 2>&1 | tail || true; exit 1; }

# ③ host 타겟 — localhost:$RPORT → host redis (socat→host.docker.internal) → PONG
ok_rd=false
for _ in $(seq 1 30); do
  out_rd="$(docker exec "$APPC" sh -c "redis-cli -h localhost -p $RPORT ping" 2>&1 || true)"
  case "$out_rd" in *PONG*) ok_rd=true; break;; esac; sleep 1
done
$ok_rd || { echo "FAIL: localhost:$RPORT→host redis 안 됨: [${out_rd:-}]"; exit 1; }

echo "PASS test-compose-weave-e2e (env=e2elocal, service=BE-OK, host=PONG)"
