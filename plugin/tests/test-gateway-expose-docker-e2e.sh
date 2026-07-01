#!/usr/bin/env bash
# 실측 e2e: git 워크트리 + 실 docker 로 marina up → 도메인모드 expose 가 소비자 컨테이너 env 에
# 이 워크트리의 be 게이트웨이 도메인을 주입하는지(docker exec 로 실측). docker 없으면 SKIP.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MC="$HERE/../scripts/marina-compose.py"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-gateway-expose-docker-e2e (docker 미가용)"; exit 0; }

TMP="$(mktemp -d)"
export MARINA_HOME="$TMP/marina-home"; mkdir -p "$MARINA_HOME"
export MARINA_GATEWAY=off             # env 주입만 검증 — caddy 안 띄움(leak 회피)
export MARINA_GATEWAY_PORT=3913       # 주입 URL 에 박힐 포트
PROJ="mdce2e$$"; SESS="featbr"; NAME="${PROJ}-${SESS}"

cleanup(){
  docker compose -p "$NAME" down -v >/dev/null 2>&1
  git -C "$TMP/src" worktree remove --force "$TMP/wt" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/src/web" "$TMP/src/be"
printf 'FROM python:3-alpine\nCMD ["python","-m","http.server","8081"]\n' > "$TMP/src/be/Dockerfile"
printf 'FROM alpine\nCMD ["sleep","infinity"]\n' > "$TMP/src/web/Dockerfile"
cat > "$TMP/src/docker-compose.yml" <<'YML'
services:
  web:
    build: { context: ./web }
    ports: ["3000"]
  be:
    build: { context: ./be }
    ports: ["8081"]
x-marina:
  gateway:
    expose:
      web:
        NEXT_PUBLIC_API_URL: "gateway:be"
YML
git -C "$TMP/src" init -q && git -C "$TMP/src" add -A && git -C "$TMP/src" -c user.email=a@b.c -c user.name=t commit -qm init
git -C "$TMP/src" worktree add -q -b featbr "$TMP/wt" >/dev/null 2>&1

python3 "$MC" up --project-id "$PROJ" --session "$SESS" \
  --stored "$TMP/wt/docker-compose.yml" --project-dir "$TMP/wt" --session-dir "$TMP/sess" >/dev/null 2>&1

exp="NEXT_PUBLIC_API_URL=http://featbr-be.${PROJ}.localhost:3913"
val=$(docker compose -p "$NAME" exec -T web env 2>/dev/null | grep '^NEXT_PUBLIC_API_URL=')
[ "$val" = "$exp" ] || { echo "FAIL: env 불일치"; echo " got: $val"; echo " exp: $exp"; exit 1; }

echo "PASS test-gateway-expose-docker-e2e"
