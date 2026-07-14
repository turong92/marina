#!/usr/bin/env bash
# develop.watch 선언 서비스만 compose watch --no-up 프로세스를 띄우고 lifecycle에 맞춰 정리한다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"

cleanup() {
  if [[ -d "$TMP" ]]; then
    while IFS= read -r file; do
      pid="$(head -n 1 "$file" 2>/dev/null || true)"
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
  *"ps --services --status running"*) printf '%s\n' "${DOCKER_RUNNING_SERVICES:-web
be}" ;;
  *"ps --all --services"*) printf 'web\noptional\nbe\n' ;;
  *"ps --format json"*) echo '[]' ;;
  *"logs -f"*) exec sleep 30 ;;
  *"up -d"*)
    if [[ "${WATCH_DELAY_UP:-}" == "1" ]]; then
      : > "$WATCH_UP_BARRIER"
      sleep 1
    fi
    exit 0
    ;;
  *"watch --no-up "*)
    echo "$$" >> "$WATCH_PIDS"
    echo "WATCH-$*"
    if [[ "${WATCH_IGNORE_TERM:-}" == "1" ]]; then
      exec python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'
    fi
    if [[ "${WATCH_WITH_CHILD:-}" == "1" ]]; then
      exec python3 -c 'import os,subprocess,sys,time; child=subprocess.Popen(["sleep","30"]); open(sys.argv[1],"a").write(str(child.pid)+"\n"); time.sleep(30)' "$WATCH_CHILD_PIDS"
    fi
    exec sleep 30
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
export DOCKER_LOG="$TMP/docker.log"
export WATCH_PIDS="$TMP/watch-pids.log"
export WATCH_CHILD_PIDS="$TMP/watch-child-pids.log"
export WATCH_UP_BARRIER="$TMP/watch-up.barrier"
export DOCKER_CONFIG_FIXTURE="$TMP/config.json"
: > "$DOCKER_LOG"
: > "$WATCH_PIDS"
: > "$WATCH_CHILD_PIDS"

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
    "optional": {
      "image": "optional-image",
      "develop": {
        "watch": [
          {"action": "sync", "path": "/tmp/optional", "target": "/app/optional"}
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
      pid="$(head -n 1 "$file" 2>/dev/null || true)"
      [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    sleep 0.1
  done
  return 1
}

mrun start --all >/dev/null
SD="$P/.workspace/marina/main"
WATCH_PID_FILE="$SD/compose.watch.pid"
wait_for_pid "$WATCH_PID_FILE" || { echo "FAIL: project watcher not running"; exit 1; }
watch_pid_count="$(find "$SD" -name '*.watch.pid' -type f | wc -l | tr -d ' ')"
[[ "$watch_pid_count" == "1" ]] || { echo "FAIL: expected one project watcher, found $watch_pid_count"; exit 1; }
grep -q "watch --no-up web" "$DOCKER_LOG" || { echo "FAIL: compose watch command missing"; cat "$DOCKER_LOG"; exit 1; }
first_pid="$(head -n 1 "$WATCH_PID_FILE")"

mrun start --all >/dev/null
wait_for_pid "$WATCH_PID_FILE" || { echo "FAIL: replacement watcher not running"; exit 1; }
second_pid="$(head -n 1 "$WATCH_PID_FILE")"
[[ "$first_pid" != "$second_pid" ]] || { echo "FAIL: watcher pid not replaced"; exit 1; }
kill -0 "$first_pid" 2>/dev/null && { echo "FAIL: old watcher still alive"; exit 1; } || true

DOCKER_RUNNING_SERVICES=$'web\noptional\nbe' mrun start --optional >/dev/null
wait_for_pid "$WATCH_PID_FILE" || { echo "FAIL: multi-service watcher not running"; exit 1; }
multi_pid="$(head -n 1 "$WATCH_PID_FILE")"
[[ "$multi_pid" != "$second_pid" ]] || { echo "FAIL: multi-service watcher pid not replaced"; exit 1; }
grep -Eq "watch --no-up (web optional|optional web)" "$DOCKER_LOG" || {
  echo "FAIL: running watchable services were not grouped into one command"
  cat "$DOCKER_LOG"
  exit 1
}
second_pid="$multi_pid"

DOCKER_RUNNING_SERVICES=be mrun stop --web >/dev/null
[[ ! -e "$WATCH_PID_FILE" ]] || { echo "FAIL: last watchable service stop left watcher pid"; exit 1; }
kill -0 "$second_pid" 2>/dev/null && { echo "FAIL: watcher alive after service stop"; exit 1; } || true

mrun restart --web >/dev/null
wait_for_pid "$WATCH_PID_FILE" || { echo "FAIL: restart did not start watcher"; exit 1; }
restart_pid="$(head -n 1 "$WATCH_PID_FILE")"

mrun stop --all >/dev/null
[[ ! -e "$WATCH_PID_FILE" ]] || { echo "FAIL: stop all left watcher pid"; exit 1; }
kill -0 "$restart_pid" 2>/dev/null && { echo "FAIL: watcher alive after stop all"; exit 1; } || true

# A stale legacy PID must not kill an unrelated process after PID reuse.
sleep 30 &
unrelated_pid=$!
printf '%s\n' "$unrelated_pid" > "$WATCH_PID_FILE"
mrun stop --web >/dev/null
kill -0 "$unrelated_pid" 2>/dev/null || { echo "FAIL: stale watcher PID killed an unrelated process"; exit 1; }
kill "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true

# Stop waits for a watcher that ignores SIGTERM and escalates instead of orphaning it.
WATCH_IGNORE_TERM=1 mrun start --web >/dev/null
wait_for_pid "$WATCH_PID_FILE" || { echo "FAIL: stubborn watcher not running"; exit 1; }
stubborn_pid="$(head -n 1 "$WATCH_PID_FILE")"
mrun stop --web >/dev/null
if kill -0 "$stubborn_pid" 2>/dev/null; then
  kill -9 "$stubborn_pid" 2>/dev/null || true
  echo "FAIL: watcher survived service stop"
  exit 1
fi

# Concurrent starts serialize replacement so exactly one recorded watcher remains alive.
: > "$WATCH_PIDS"
jobs=()
for _ in 1 2 3 4; do
  mrun start --web >/dev/null 2>&1 &
  jobs+=("$!")
done
for job in "${jobs[@]}"; do wait "$job"; done
wait_for_pid "$WATCH_PID_FILE" || { echo "FAIL: concurrent starts left no watcher"; exit 1; }
alive=0
while IFS= read -r p; do
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && alive=$((alive + 1))
done < "$WATCH_PIDS"
[[ "$alive" == "1" ]] || { echo "FAIL: concurrent starts left $alive watcher processes"; exit 1; }
mrun stop --web >/dev/null

# Stop signals the full watcher process group, including descendants.
: > "$WATCH_CHILD_PIDS"
WATCH_WITH_CHILD=1 mrun start --web >/dev/null
for _ in $(seq 1 50); do [[ -s "$WATCH_CHILD_PIDS" ]] && break; sleep 0.1; done
child_pid="$(head -n 1 "$WATCH_CHILD_PIDS")"
[[ -n "$child_pid" ]] || { echo "FAIL: watcher child was not created"; exit 1; }
mrun stop --web >/dev/null
if kill -0 "$child_pid" 2>/dev/null; then
  kill -9 "$child_pid" 2>/dev/null || true
  echo "FAIL: watcher child survived service stop"
  exit 1
fi

# A stop that lands during a slow up prevents the older start from spawning a late watcher.
rm -f "$WATCH_UP_BARRIER"
: > "$WATCH_PIDS"
WATCH_DELAY_UP=1 mrun start --web >/dev/null &
slow_start_job=$!
for _ in $(seq 1 50); do [[ -e "$WATCH_UP_BARRIER" ]] && break; sleep 0.1; done
[[ -e "$WATCH_UP_BARRIER" ]] || { echo "FAIL: slow start barrier not reached"; exit 1; }
mrun stop --all >/dev/null
wait "$slow_start_job"
sleep 0.2
[[ ! -e "$WATCH_PID_FILE" ]] || { echo "FAIL: start spawned watcher after concurrent stop --all"; exit 1; }
while IFS= read -r p; do
  [[ -z "$p" ]] || ! kill -0 "$p" 2>/dev/null || { echo "FAIL: late watcher survived concurrent stop --all"; exit 1; }
done < "$WATCH_PIDS"

# A service stop also supersedes an older start before it can replace the project watcher.
rm -f "$WATCH_UP_BARRIER"
: > "$WATCH_PIDS"
WATCH_DELAY_UP=1 mrun start --web >/dev/null &
slow_service_start_job=$!
for _ in $(seq 1 50); do [[ -e "$WATCH_UP_BARRIER" ]] && break; sleep 0.1; done
[[ -e "$WATCH_UP_BARRIER" ]] || { echo "FAIL: service-stop barrier not reached"; exit 1; }
DOCKER_RUNNING_SERVICES=be mrun stop --web >/dev/null
wait "$slow_service_start_job"
sleep 0.2
[[ ! -e "$WATCH_PID_FILE" ]] || { echo "FAIL: start spawned watcher after concurrent service stop"; exit 1; }
while IFS= read -r p; do
  [[ -z "$p" ]] || ! kill -0 "$p" 2>/dev/null || { echo "FAIL: late watcher survived concurrent service stop"; exit 1; }
done < "$WATCH_PIDS"

echo "PASS test-compose-watch"
