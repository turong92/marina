#!/usr/bin/env bash
# develop.watch 선언 서비스만 compose watch --no-up 프로세스를 띄우고 lifecycle에 맞춰 정리한다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"

cleanup() {
  if [[ -d "$TMP" ]]; then
    while IFS= read -r file; do
      pid="$(cat "$file" 2>/dev/null || true)"
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < <(find "$TMP" -name '*.pid' -type f 2>/dev/null)
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

export MARINA_HOME="$TMP/home"
export MARINA_GATEWAY=off
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
case "$*" in
  "compose version --short") echo "2.40.3" ;;
  info) exit 0 ;;
  *"config --format json"*) cat "$DOCKER_CONFIG_FIXTURE" ;;
  *"ps --all --services"*) printf 'web\nbe\n' ;;
  *"ps --format json"*) echo '[]' ;;
  *"logs -f"*) exec sleep 30 ;;
  *"watch --no-up web"*) echo "WATCH-WEB"; exec sleep 30 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
export DOCKER_LOG="$TMP/docker.log"
export DOCKER_CONFIG_FIXTURE="$TMP/config.json"
: > "$DOCKER_LOG"

cat > "$DOCKER_CONFIG_FIXTURE" <<'JSON'
{
  "services": {
    "web": {
      "image": "web-image",
      "develop": {
        "watch": [
          {"action": "sync", "path": "/tmp/src", "target": "/app/src"}
        ]
      }
    },
    "be": {"image": "be-image"}
  }
}
JSON

P="$TMP/project"
mkdir -p "$P"
P="$(cd "$P" && pwd -P)"
cp "$DOCKER_CONFIG_FIXTURE" "$P/docker-compose.yml"
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
mrun() {
  (cd "$P" && MARINA_HOME="$MARINA_HOME" PATH="$TMP/bin:$PATH" \
    DOCKER_LOG="$DOCKER_LOG" DOCKER_CONFIG_FIXTURE="$DOCKER_CONFIG_FIXTURE" \
    bash "$SH" "$@")
}

wait_for_pid() {
  local file="$1" pid=""
  for _ in $(seq 1 50); do
    if [[ -f "$file" ]]; then
      pid="$(cat "$file" 2>/dev/null || true)"
      [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    sleep 0.1
  done
  return 1
}

mrun start --all >/dev/null
SD="$P/.workspace/marina/main"
WEB_PID_FILE="$SD/web.watch.pid"
BE_PID_FILE="$SD/be.watch.pid"
wait_for_pid "$WEB_PID_FILE" || { echo "FAIL: web watcher not running"; exit 1; }
[[ ! -e "$BE_PID_FILE" ]] || { echo "FAIL: non-watch service has watcher"; exit 1; }
grep -q "watch --no-up web" "$DOCKER_LOG" || { echo "FAIL: compose watch command missing"; cat "$DOCKER_LOG"; exit 1; }
first_pid="$(cat "$WEB_PID_FILE")"

mrun start --all >/dev/null
wait_for_pid "$WEB_PID_FILE" || { echo "FAIL: replacement watcher not running"; exit 1; }
second_pid="$(cat "$WEB_PID_FILE")"
[[ "$first_pid" != "$second_pid" ]] || { echo "FAIL: watcher pid not replaced"; exit 1; }
kill -0 "$first_pid" 2>/dev/null && { echo "FAIL: old watcher still alive"; exit 1; } || true

mrun stop --web >/dev/null
[[ ! -e "$WEB_PID_FILE" ]] || { echo "FAIL: service stop left watcher pid"; exit 1; }
kill -0 "$second_pid" 2>/dev/null && { echo "FAIL: watcher alive after service stop"; exit 1; } || true

mrun restart --web >/dev/null
wait_for_pid "$WEB_PID_FILE" || { echo "FAIL: restart did not start watcher"; exit 1; }
restart_pid="$(cat "$WEB_PID_FILE")"

mrun stop --all >/dev/null
[[ ! -e "$WEB_PID_FILE" ]] || { echo "FAIL: stop all left watcher pid"; exit 1; }
kill -0 "$restart_pid" 2>/dev/null && { echo "FAIL: watcher alive after stop all"; exit 1; } || true

echo "PASS test-compose-watch"
