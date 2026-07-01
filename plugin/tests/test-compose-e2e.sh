#!/usr/bin/env bash
# 실 docker E2E: up → Docker 할당 포트를 marina ports 로 읽음 → 127.0.0.1 도달 → down. 데몬 없으면 SKIP.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-e2e (docker 데몬 미가용)"; exit 0; }
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
export MARINA_GATEWAY=off   # 게이트웨이 auto-spawn 차단(이 테스트는 게이트웨이 대상 아님 → caddy leak 방지)
P="$TMP/proj-$$"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"   # 고유 basename — 실제 'proj' 프로젝트(-p proj-main)와 충돌 방지
cat > "$P/docker-compose.yml" <<'YML'
services:
  web:
    image: "python:3-alpine"
    command: ["sh","-c","echo $APP_ENV && python -m http.server 8000"]
    ports: ["8000:8000"]
    environment: ["APP_ENV"]
YML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" --env-var APP_ENV --env-default e2elocal >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" "$@"); }
cleanup() { mrun stop --all >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
mrun start --all
port="$(mrun ports 2>/dev/null | awk -F= '/^web=/{print $2}')"   # docker 가 할당한 호스트포트
[[ -n "$port" ]] || { echo "FAIL: no web port from marina ports"; exit 1; }
ok=false
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$port/" >/dev/null 2>&1 && { ok=true; break; }; sleep 0.5; done
[[ "$ok" == true ]] || { echo "FAIL: not reachable on 127.0.0.1:$port"; mrun logs web 2>/dev/null | tail -20 || true; exit 1; }
mrun stop --all
echo "PASS test-compose-e2e"
