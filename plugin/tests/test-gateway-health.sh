#!/usr/bin/env bash
# 게이트웨이 health: 테스트 admin 격리 + PID 생존/리스너 드리프트 감지 + start 자동복구.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"; GWC="$HERE/../scripts/marina-gateway-control.sh"
CADDY="$(command -v caddy 2>/dev/null || true)"
for c in "$HOME/.local/bin/caddy" /opt/homebrew/bin/caddy /usr/local/bin/caddy; do
  [ -z "$CADDY" ] && [ -x "$c" ] && CADDY="$c"
done
[ -n "$CADDY" ] || { echo "SKIP test-gateway-health (caddy 미설치)"; exit 0; }

TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
freeport() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
GP="$(freeport)"; DRIFT_PORT="$(freeport)"; BACKEND_PORT="$(freeport)"; ADMIN_PORT="$(freeport)"
export MARINA_GATEWAY_PORT="$GP" MARINA_GATEWAY_ADMIN="127.0.0.1:$ADMIN_PORT"
mkdir -p "$MARINA_HOME/gateway" "$TMP/backend"
printf 'HEALTHY\n' > "$TMP/backend/index.html"
(cd "$TMP/backend" && python3 -m http.server "$BACKEND_PORT" >/dev/null 2>&1) & BACKEND_PID=$!
FOREIGN_PID=""
cleanup() {
  bash "$GWC" stop >/dev/null 2>&1 || true
  pkill -f "$MARINA_HOME/gateway/Caddyfile" 2>/dev/null || true
  [ -n "$FOREIGN_PID" ] && kill "$FOREIGN_PID" 2>/dev/null || true
  kill "$BACKEND_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

snapshot() {
  printf '[{"id":"main","projectId":"health","services":[{"service":"web","port":"%s","running":true}]}]' "$BACKEND_PORT"
}
snapshot | python3 "$GW" gen --port "$GP" > "$MARINA_HOME/gateway/Caddyfile"
grep -q "admin $MARINA_GATEWAY_ADMIN" "$MARINA_HOME/gateway/Caddyfile" || {
  echo "FAIL: MARINA_GATEWAY_ADMIN 이 Caddyfile 에 반영되지 않음"; exit 1;
}

# start 반환 시점에는 admin 과 실제 게이트웨이 리스너가 모두 준비돼 있어야 한다.
bash "$GWC" start >/dev/null
curl -fsS "http://$MARINA_GATEWAY_ADMIN/config/" >/dev/null
curl -fsS -H 'Host: main.health.localhost' "http://127.0.0.1:$GP/" | grep -q HEALTHY

# admin env 변경 시 기존 Caddyfile의 global admin도 마이그레이션돼야 한다.
bash "$GWC" stop >/dev/null
OLD_ADMIN="$MARINA_GATEWAY_ADMIN"; ADMIN_PORT_2="$(freeport)"
export MARINA_GATEWAY_ADMIN="127.0.0.1:$ADMIN_PORT_2"
bash "$GWC" start >/dev/null
curl -fsS "http://$MARINA_GATEWAY_ADMIN/config/" >/dev/null
if curl -fsS --max-time 1 "http://$OLD_ADMIN/config/" >/dev/null 2>&1; then
  echo "FAIL: admin 변경 후 이전 admin이 남아 있음"; exit 1
fi
curl -fsS -H 'Host: main.health.localhost' "http://127.0.0.1:$GP/" | grep -q HEALTHY

# 같은 Caddy 프로세스에 다른 포트 config 를 로드해 실제 장애(PID alive, gateway listener 없음)를 재현한다.
snapshot | python3 "$GW" gen --port "$DRIFT_PORT" > "$TMP/drift.Caddyfile"
"$CADDY" reload --config "$TMP/drift.Caddyfile" --adapter caddyfile --address "$MARINA_GATEWAY_ADMIN" >/dev/null
kill -0 "$(cat "$MARINA_HOME/gateway/caddy.pid")"
if curl -fsS --max-time 1 "http://127.0.0.1:$GP/" >/dev/null 2>&1; then
  echo "FAIL: drift 후에도 원래 게이트웨이 포트가 열려 있음"; exit 1
fi
# 다른 프로세스가 원래 포트를 점유해도 Caddy listener로 오판하면 안 된다.
(cd "$TMP/backend" && python3 -m http.server "$GP" >/dev/null 2>&1) & FOREIGN_PID=$!
for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$GP/" >/dev/null 2>&1 && break; sleep 0.1; done

set +e
status="$(bash "$GWC" status 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] && echo "$status" | grep -q degraded || {
  echo "FAIL: listener drift 를 degraded 로 감지하지 못함: rc=$rc [$status]"; exit 1;
}
kill "$FOREIGN_PID" 2>/dev/null || true; wait "$FOREIGN_PID" 2>/dev/null || true; FOREIGN_PID=""

# 재기동 명령은 PID만 보고 종료하지 않고 저장된 config 를 다시 적용해 원래 리스너를 복구한다.
bash "$GWC" start >/dev/null
curl -fsS -H 'Host: main.health.localhost' "http://127.0.0.1:$GP/" | grep -q HEALTHY
bash "$GWC" status | grep -q '^running '

# 동시 start가 여러 Caddy를 남기면 PID 파일 하나로는 stop/reload를 안전하게 관리할 수 없다.
bash "$GWC" stop >/dev/null; sleep 0.2
LOCK_FILE="$MARINA_HOME/gateway/control.flock"; LOCK_READY="$TMP/lock.ready"; LOCK_RELEASE="$TMP/lock.release"

# outer Python wrapper가 죽어도 실제 상태 전이 중인 inner bash가 lock FD를 계속 보유해야 한다.
HOLD_BIN="$TMP/hold-bin"; HOLD_READY="$TMP/hold-caddy.ready"; mkdir -p "$HOLD_BIN"
cat > "$HOLD_BIN/caddy" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == run ]]; then touch "$HOLD_READY"; sleep 1; fi
exec "$CADDY" "\$@"
SH
chmod +x "$HOLD_BIN/caddy"
PATH="$HOLD_BIN:$PATH" bash "$GWC" start >"$TMP/killed-wrapper.log" 2>&1 & OUTER_PID=$!
for _ in $(seq 1 100); do [ -e "$HOLD_READY" ] && break; sleep 0.02; done
[ -e "$HOLD_READY" ] || { echo "FAIL: delayed caddy did not start"; exit 1; }
kill -9 "$OUTER_PID" 2>/dev/null || true; wait "$OUTER_PID" 2>/dev/null || true
if python3 - "$LOCK_FILE" <<'PY'
import fcntl, sys
with open(sys.argv[1], "a+") as lock:
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise SystemExit(1)
PY
then
  echo "FAIL: outer wrapper 종료 후 inner transition lock이 풀림"; exit 1
fi
for _ in $(seq 1 100); do bash "$GWC" status >/dev/null 2>&1 && break; sleep 0.05; done
bash "$GWC" stop >/dev/null

# 외부 holder가 lock을 가진 동안 start는 어떤 상태도 바꾸면 안 된다.
python3 - "$LOCK_FILE" "$LOCK_READY" "$LOCK_RELEASE" <<'PY' & LOCKER_PID=$!
import fcntl, os, sys, time
with open(sys.argv[1], "a+") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    while not os.path.exists(sys.argv[3]): time.sleep(.02)
PY
for _ in $(seq 1 50); do [ -e "$LOCK_READY" ] && break; sleep 0.02; done
[ -e "$LOCK_READY" ] || { echo "FAIL: external lock setup"; exit 1; }
bash "$GWC" start >"$TMP/blocked-start.log" 2>&1 & BLOCKED_START=$!
sleep 0.3
kill -0 "$BLOCKED_START" 2>/dev/null || { echo "FAIL: start ignored gateway file lock"; exit 1; }
[ ! -e "$MARINA_HOME/gateway/caddy.pid" ] || { echo "FAIL: start mutated state while lock held"; exit 1; }
touch "$LOCK_RELEASE"; wait "$LOCKER_PID"; wait "$BLOCKED_START"

# lock 대기 검증 후에도 동시 idempotent start는 Caddy 하나만 유지해야 한다.
GO="$TMP/start.go"; starters=()
for i in $(seq 1 8); do
  (while [ ! -e "$GO" ]; do sleep 0.01; done; bash "$GWC" start >"$TMP/start.$i.log" 2>&1) & starters+=("$!")
done
touch "$GO"
start_rc=0
for p in "${starters[@]}"; do wait "$p" || start_rc=1; done
sleep 0.5
count="$(pgrep -f "$MARINA_HOME/gateway/Caddyfile" | wc -l | tr -d ' ')"
[[ "$start_rc" = 0 && "$count" = 1 ]] || {
  echo "FAIL: concurrent start rc=$start_rc left $count caddy processes"
  for log in "$TMP"/start.*.log; do
    echo "--- $log"
    grep -E 'p=[0-9]|comm=|expected_ready|reload|kill |게이트웨이 (기동|복구)|이미 실행|release_lock' "$log" || true
  done
  exit 1
}

echo "PASS test-gateway-health (admin isolation + drift detection/recovery + concurrent start)"
