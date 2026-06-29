#!/usr/bin/env bash
# compose-kind 라우팅: no-arg 가드, bare 인자 거부, config 단계 env 주입, -f overlay, 서비스별 stop, live ps 포트.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
case "$*" in
  "compose version --short") echo "2.40.3" ;;
  info) exit 0 ;;
  *"config --format json"*) echo "APP_ENV_AT_CONFIG=${APP_ENV:-MISSING}" >> "$DOCKER_LOG"; cat "$DOCKER_CONFIG_FIXTURE" ;;
  *"ps --format json"*) cat "$DOCKER_PS_FIXTURE" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" DOCKER_LOG="$TMP/docker.log" DOCKER_CONFIG_FIXTURE="$TMP/cfg.json" DOCKER_PS_FIXTURE="$TMP/ps.json"; : > "$DOCKER_LOG"
cat > "$TMP/cfg.json" <<'JSON'
{"services":{
  "web":{"image":"nginx","ports":[{"target":80,"published":"3000","protocol":"tcp"}]},
  "be":{"image":"temurin","ports":[{"target":8081,"published":"8081","protocol":"tcp"}]}
}}
JSON
cat > "$TMP/ps.json" <<'JSON'
[{"Service":"web","Publishers":[{"URL":"127.0.0.1","TargetPort":80,"PublishedPort":55001,"Protocol":"tcp"}]}]
JSON

P="$TMP/proj"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"   # macOS /var→/private/var 해석(로그 경로와 일치)
cp "$TMP/cfg.json" "$P/docker-compose.yml"
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" --env-var APP_ENV --env-default local >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" PATH="$TMP/bin:$PATH" \
  DOCKER_LOG="$DOCKER_LOG" DOCKER_CONFIG_FIXTURE="$DOCKER_CONFIG_FIXTURE" DOCKER_PS_FIXTURE="$DOCKER_PS_FIXTURE" bash "$SH" "$@"); }

# no-arg 가드
if mrun start >/dev/null 2>&1; then echo "FAIL: no-arg start should guard"; exit 1; fi
# bare positional 거부 (전체 안 띄움)
: > "$DOCKER_LOG"
if mrun start web >/dev/null 2>&1; then echo "FAIL: bare positional should error"; exit 1; fi
grep -q "up -d" "$DOCKER_LOG" && { echo "FAIL: bad arg leaked to up"; exit 1; } || true

# start --all → overlay 생성 + up + env at config
: > "$DOCKER_LOG"; mrun start --all >/dev/null
grep -q "compose .*up -d --build --remove-orphans" "$DOCKER_LOG" || { echo "FAIL: up not routed (--build 포함)"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "-p proj-main" "$DOCKER_LOG" || { echo "FAIL: project name"; exit 1; }
grep -q "APP_ENV_AT_CONFIG=local" "$DOCKER_LOG" || { echo "FAIL: env not at config (P1)"; cat "$DOCKER_LOG"; exit 1; }
SD="$P/.workspace/marina/main"
grep -q '!override' "$SD/marina-overlay.yml" || { echo "FAIL: overlay missing !override"; cat "$SD/marina-overlay.yml"; exit 1; }
grep -q '127.0.0.1::80' "$SD/marina-overlay.yml" || { echo "FAIL: overlay localhost target"; exit 1; }
grep -q -- "-f $SD/marina-overlay.yml" "$DOCKER_LOG" || { echo "FAIL: overlay not passed to up"; exit 1; }

# ports → live ps 파싱
mrun ports 2>/dev/null | grep -q "web=55001" || { echo "FAIL: live ps ports"; exit 1; }

# stop --web → stop web (down 아님)
: > "$DOCKER_LOG"; mrun stop --web >/dev/null
grep -q "compose -p proj-main stop web" "$DOCKER_LOG" || { echo "FAIL: per-svc stop"; cat "$DOCKER_LOG"; exit 1; }
grep -q "down --remove-orphans" "$DOCKER_LOG" && { echo "FAIL: per-svc stop did down"; exit 1; } || true
# stop --all → down
: > "$DOCKER_LOG"; mrun stop --all >/dev/null
grep -q "compose -p proj-main down --remove-orphans" "$DOCKER_LOG" || { echo "FAIL: stop --all not down"; exit 1; }
echo "PASS test-compose-dispatch"
