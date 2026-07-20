#!/usr/bin/env bash
# compose-kind 라우팅: no-arg 가드, fast start/explicit rebuild, config env, overlay, 서비스별 stop, live ps 포트.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
export MARINA_GATEWAY=off   # 게이트웨이 auto-spawn 차단(이 테스트는 게이트웨이 대상 아님 → caddy leak 방지)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
case "$*" in
  "compose version --short") echo "2.40.3" ;;
  info) exit 0 ;;
  "image inspect --format={{.Id}} "*) echo "sha256:${INSPECT_IMAGE_ID:-image-a}" ;;
  *"config --format json"*) echo "APP_ENV_AT_CONFIG=${APP_ENV:-MISSING}" >> "$DOCKER_LOG"; cat "$DOCKER_CONFIG_FIXTURE" ;;
  *"images --format json api"*)
    echo "[{\"ID\":\"sha256:${COMPOSE_IMAGE_ID:-image-a}\",\"Repository\":\"proj-api\",\"Tag\":\"latest\"}]" ;;
  *"images --format json worker"*)
    echo "[{\"ID\":\"sha256:${COMPOSE_IMAGE_ID:-image-a}\",\"Repository\":\"proj-worker\",\"Tag\":\"latest\"}]" ;;
  *"ps --format json"*) cat "$DOCKER_PS_FIXTURE" ;;
  *"build --no-cache api"*)
    [[ "${FAIL_CLEAN_BUILD:-0}" != 1 ]] || exit 25 ;;
  *"up -d"*)
    [[ -s "${MARINA_BUILD_INPUT_SNAPSHOT:-}" ]] || { echo "snapshot missing before compose up" >&2; exit 23; }
    rm -f "$MARINA_BUILD_INPUT_SNAPSHOT"
    if [[ "${SLOW_UP:-0}" == 1 ]]; then
      if mkdir "$UP_PROBE" 2>/dev/null; then
        sleep 2
        rmdir "$UP_PROBE"
      else
        : > "$UP_PROBE.overlap"
      fi
    fi
    [[ -z "${MUTATE_FILE:-}" ]] || printf '# changed during build\n' >> "$MUTATE_FILE"
    [[ "${FAIL_UP:-0}" != 1 ]] || exit 24 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" DOCKER_LOG="$TMP/docker.log" DOCKER_CONFIG_FIXTURE="$TMP/cfg.json" DOCKER_PS_FIXTURE="$TMP/ps.json"; : > "$DOCKER_LOG"
export MARINA_BUILD_INPUT_SNAPSHOT="$TMP/build-inputs.json"
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

# start --all → overlay 생성 + no-build up + env at config
: > "$DOCKER_LOG"; mrun start --all >/dev/null
grep -q "compose .*up -d --remove-orphans" "$DOCKER_LOG" || { echo "FAIL: start up not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: start must not force --build"; cat "$DOCKER_LOG"; exit 1; } || true
grep -q -- "-p proj-main" "$DOCKER_LOG" || { echo "FAIL: project name"; exit 1; }
grep -q "APP_ENV_AT_CONFIG=local" "$DOCKER_LOG" || { echo "FAIL: env not at config (P1)"; cat "$DOCKER_LOG"; exit 1; }
SD="$P/.workspace/marina/main"
grep -q '!override' "$SD/marina-overlay.yml" || { echo "FAIL: overlay missing !override"; cat "$SD/marina-overlay.yml"; exit 1; }
grep -q '127.0.0.1::80' "$SD/marina-overlay.yml" || { echo "FAIL: overlay localhost target"; exit 1; }
grep -q -- "-f $SD/marina-overlay\." "$DOCKER_LOG" || { echo "FAIL: invocation overlay not passed to up"; exit 1; }
[[ -f "$SD/marina-overlay.yml" ]] || { echo "FAIL: canonical Watch overlay missing"; exit 1; }

# rebuild --all → 같은 up 경로에서 명시적으로 --build
: > "$DOCKER_LOG"; mrun rebuild --all >/dev/null
grep -q "compose .*up -d --build --remove-orphans" "$DOCKER_LOG" || { echo "FAIL: rebuild must include --build"; cat "$DOCKER_LOG"; exit 1; }

# ports → live ps 파싱
mrun ports 2>/dev/null | grep -q "web=55001" || { echo "FAIL: live ps ports"; exit 1; }

# restart --web → 기존 image로 up 재적용, build는 하지 않음
: > "$DOCKER_LOG"; mrun restart --web >/dev/null
grep -q "compose .*up -d --remove-orphans web" "$DOCKER_LOG" || { echo "FAIL: restart up not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: restart must not force --build"; cat "$DOCKER_LOG"; exit 1; } || true

# build 서비스는 마지막 성공 build baseline과 비교해 낡은 이미지를 안내하되 Start에는 --build를 붙이지 않는다.
mkdir -p "$P/api"
printf 'FROM scratch\n' > "$P/api/Dockerfile.local"
mkdir -p "$P/worker"
printf 'FROM scratch\n' > "$P/worker/Dockerfile.local"
cat > "$TMP/cfg.json" <<JSON
{"services":{
  "web":{"image":"nginx","ports":[{"target":80,"published":"3000","protocol":"tcp"}]},
  "be":{"image":"temurin","ports":[{"target":8081,"published":"8081","protocol":"tcp"}]},
  "api":{"build":{"context":"$P/api","dockerfile":"Dockerfile.local","args":{"TOKEN":"raw-build-secret"}}},
  "worker":{"build":{"context":"$P/worker","dockerfile":"Dockerfile.local"}}
}}
JSON
SD="$P/.workspace/marina/main"

: > "$DOCKER_LOG"; first_out="$(mrun start --api 2>&1)"
grep -q "compose .*up -d --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: first build service Start not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: first build service Start must not auto-build"; cat "$DOCKER_LOG"; exit 1; } || true
grep -q "stale image:" <<<"$first_out" || { echo "FAIL: first stale image reason missing"; echo "$first_out"; exit 1; }
grep -q "marina rebuild --api" <<<"$first_out" || { echo "FAIL: first stale image rebuild hint missing"; echo "$first_out"; exit 1; }
[[ ! -f "$SD/build-baseline.json" ]] || { echo "FAIL: Start without build advanced baseline"; exit 1; }

: > "$DOCKER_LOG"; mrun rebuild --api >/dev/null
grep -q "compose .*up -d --build --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: explicit Rebuild must build"; cat "$DOCKER_LOG"; exit 1; }
[[ -f "$SD/build-baseline.json" ]] || { echo "FAIL: successful build baseline missing"; exit 1; }
python3 - "$SD/build-baseline.json" <<'PY'
import json,sys
baseline=json.load(open(sys.argv[1]))
assert baseline["services"]["api"]["image"] == {
    "id":"sha256:image-a", "ref":"proj-api:latest",
}, baseline
PY

: > "$DOCKER_LOG"; mrun start --api >/dev/null
grep -q "compose .*up -d --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: repeated Start not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: unchanged Start must stay fast"; cat "$DOCKER_LOG"; exit 1; } || true
: > "$DOCKER_LOG"; mrun restart --api >/dev/null
grep -q "compose .*up -d --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: unchanged Restart not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: unchanged Restart must stay fast"; cat "$DOCKER_LOG"; exit 1; } || true

# Watch가 B를 build한 뒤 선언 입력이 baseline A로 되돌아온 ABA도 실제 image ID로 감지한다.
: > "$DOCKER_LOG"; image_out="$(INSPECT_IMAGE_ID=image-b COMPOSE_IMAGE_ID=image-a mrun start --api 2>&1)"
grep -q "compose .*up -d --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: external image ABA Start not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: external image ABA Start must not auto-build"; cat "$DOCKER_LOG"; exit 1; } || true
grep -q "실제 Docker 이미지" <<<"$image_out" || { echo "FAIL: external image ABA reason missing"; echo "$image_out"; exit 1; }

printf '# changed\n' >> "$P/api/Dockerfile.local"
: > "$DOCKER_LOG"; changed_out="$(mrun start --api 2>&1)"
grep -q "compose .*up -d --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: changed Dockerfile Start not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: changed Dockerfile Start must not auto-build"; cat "$DOCKER_LOG"; exit 1; } || true
grep -q "Dockerfile.local" <<<"$changed_out" || { echo "FAIL: changed Dockerfile reason missing"; echo "$changed_out"; exit 1; }
grep -q "marina rebuild --api" <<<"$changed_out" || { echo "FAIL: changed Dockerfile rebuild hint missing"; echo "$changed_out"; exit 1; }
if grep -Eq 'raw-build-secret|file:|hmac' <<<"$changed_out"; then
  echo "FAIL: stale image output exposed secret or digest"; echo "$changed_out"; exit 1
fi

printf '# changed again\n' >> "$P/api/Dockerfile.local"
: > "$DOCKER_LOG"
if FAIL_UP=1 mrun start --api >/dev/null 2>&1; then echo "FAIL: forced compose failure succeeded"; exit 1; fi
grep -q "compose .*up -d --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: failed stale Start not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: failed stale Start must not auto-build"; cat "$DOCKER_LOG"; exit 1; } || true
: > "$DOCKER_LOG"; mrun start --api >/dev/null
grep -q "compose .*up -d --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: stale Start retry not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: failed stale Start advanced baseline"; cat "$DOCKER_LOG"; exit 1; } || true

: > "$DOCKER_LOG"; mrun rebuild --api >/dev/null
grep -q "compose .*up -d --build --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: explicit Rebuild must always build"; cat "$DOCKER_LOG"; exit 1; }

: > "$DOCKER_LOG"
if FAIL_CLEAN_BUILD=1 mrun clean-rebuild --api >/dev/null 2>&1; then echo "FAIL: forced clean rebuild build failure succeeded"; exit 1; fi
grep -q "compose .*build --no-cache api" "$DOCKER_LOG" || { echo "FAIL: clean rebuild did not run no-cache build"; cat "$DOCKER_LOG"; exit 1; }
grep -q "compose .*up -d" "$DOCKER_LOG" && { echo "FAIL: failed clean rebuild still ran up"; cat "$DOCKER_LOG"; exit 1; } || true
[[ ! -e "$SD/build-baseline.json" ]] || { echo "FAIL: failed clean rebuild kept stale baseline"; exit 1; }

: > "$DOCKER_LOG"; mrun clean-rebuild --api >/dev/null
grep -q "compose .*build --no-cache api" "$DOCKER_LOG" || { echo "FAIL: clean rebuild missing no-cache build"; cat "$DOCKER_LOG"; exit 1; }
grep -q "compose .*up -d --build --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: clean rebuild did not start with build"; cat "$DOCKER_LOG"; exit 1; }
[[ -f "$SD/build-baseline.json" ]] || { echo "FAIL: clean rebuild did not refresh baseline"; exit 1; }

: > "$DOCKER_LOG"; mrun start --web >/dev/null
grep -q "compose .*up -d --remove-orphans web" "$DOCKER_LOG" || { echo "FAIL: image-only Start not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: image-only Start must not auto-build"; cat "$DOCKER_LOG"; exit 1; } || true

# 같은 build 서비스의 겹치는 Start는 image 판정부터 baseline 갱신까지 직렬화한다.
export UP_PROBE="$TMP/up-probe"
rm -rf "$UP_PROBE" "$UP_PROBE.overlap"
SLOW_UP=1 mrun start --api >/dev/null 2>&1 & first_start=$!
for _ in $(seq 1 200); do [[ -d "$UP_PROBE" ]] && break; sleep 0.01; done
[[ -d "$UP_PROBE" ]] || { echo "FAIL: first concurrent Start did not enter up"; exit 1; }
SLOW_UP=1 mrun start --api >/dev/null 2>&1 & second_start=$!
wait "$first_start" "$second_start"
[[ ! -e "$UP_PROBE.overlap" ]] || { echo "FAIL: same-service Starts overlapped compose up"; exit 1; }

# 서로 다른 build 서비스는 project Watch coordination 때문에 직렬화되지 않는다.
mrun start --worker >/dev/null
printf '# parallel api\n' >> "$P/api/Dockerfile.local"
printf '# parallel worker\n' >> "$P/worker/Dockerfile.local"
rm -rf "$UP_PROBE" "$UP_PROBE.overlap"
MARINA_BUILD_INPUT_SNAPSHOT="$TMP/api-input.json" SLOW_UP=1 mrun start --api >/dev/null 2>&1 & api_start=$!
for _ in $(seq 1 200); do [[ -d "$UP_PROBE" ]] && break; sleep 0.01; done
[[ -d "$UP_PROBE" ]] || { echo "FAIL: api parallel Start did not enter up"; exit 1; }
MARINA_BUILD_INPUT_SNAPSHOT="$TMP/worker-input.json" SLOW_UP=1 mrun start --worker >/dev/null 2>&1 & worker_start=$!
wait "$api_start" "$worker_start"
[[ -e "$UP_PROBE.overlap" ]] || { echo "FAIL: different build services were serialized"; exit 1; }

# Build 도중 선언 입력이 바뀌면 pre-build snapshot과 post-build image를 baseline으로 묶지 않는다.
rm -f "$SD/build-baseline.json"
MUTATE_FILE="$P/api/Dockerfile.local" mrun rebuild --api >/dev/null
[[ ! -e "$SD/build-baseline.json" ]] || { echo "FAIL: changed-during-build inputs advanced baseline"; exit 1; }
: > "$DOCKER_LOG"; mrun start --api >/dev/null
grep -q "compose .*up -d --remove-orphans api" "$DOCKER_LOG" || { echo "FAIL: changed-during-build stale Start not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "--build" "$DOCKER_LOG" && { echo "FAIL: changed-during-build Start must not auto-build"; cat "$DOCKER_LOG"; exit 1; } || true

# stop --web → stop web (down 아님)
: > "$DOCKER_LOG"; mrun stop --web >/dev/null
grep -q "compose -p proj-main stop web" "$DOCKER_LOG" || { echo "FAIL: per-svc stop"; cat "$DOCKER_LOG"; exit 1; }
grep -q "down --remove-orphans" "$DOCKER_LOG" && { echo "FAIL: per-svc stop did down"; exit 1; } || true
# stop --all → down
: > "$DOCKER_LOG"; mrun stop --all >/dev/null
grep -q "compose -p proj-main down --remove-orphans" "$DOCKER_LOG" || { echo "FAIL: stop --all not down"; exit 1; }
echo "PASS test-compose-dispatch"
