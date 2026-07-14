#!/usr/bin/env bash
# compose start 가 서비스별 docker compose logs -f 를 run-NNN.log 로 캡처하고 logtail.pid 추적, stop 이 tailer 를 죽인다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
export MARINA_GATEWAY=off   # 게이트웨이 auto-spawn 차단(이 테스트는 게이트웨이 대상 아님 → caddy leak 방지)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose version --short") echo "2.40.3" ;;
  info) exit 0 ;;
  *"config --format json"*) cat "$DOCKER_CONFIG_FIXTURE" ;;
  *"ps --services --status running"*) echo "web" ;;
  *"ps --all --format json"*) echo '[{"Service":"web","State":"running","Health":"","Publishers":[{"PublishedPort":5555}]}]' ;;
  *"logs -f"*) echo "HELLO-COMPOSE-LOG"; exec sleep 30 ;;   # follow 시뮬레이션
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" DOCKER_CONFIG_FIXTURE="$TMP/cfg.json"
cat > "$TMP/cfg.json" <<'JSON'
{"services":{"web":{"image":"x","ports":[{"target":80,"published":"3000","protocol":"tcp"}]}}}
JSON
P="$TMP/proj"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"; cp "$TMP/cfg.json" "$P/docker-compose.yml"
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
mrun(){ (cd "$P" && MARINA_HOME="$MARINA_HOME" PATH="$TMP/bin:$PATH" DOCKER_CONFIG_FIXTURE="$DOCKER_CONFIG_FIXTURE" bash "$SH" "$@"); }

mrun start --all >/dev/null
SD="$P/.workspace/marina/main"
runlog="$(ls "$SD"/logs/web/run-*.log 2>/dev/null | head -1)"
[[ -n "$runlog" ]] || { echo "FAIL: no run-NNN.log for compose web"; exit 1; }
ok=false   # tailer 가 nohup 비동기로 append → 마커 뜰 때까지 대기
for _ in $(seq 1 40); do grep -q "HELLO-COMPOSE-LOG" "$runlog" 2>/dev/null && { ok=true; break; }; sleep 0.1; done
[[ "$ok" == true ]] || { echo "FAIL: tailer output not captured"; cat "$runlog"; exit 1; }
tpf="$SD/web.logtail.pid"
[[ -f "$tpf" ]] || { echo "FAIL: no logtail pid"; exit 1; }
tpid="$(cat "$tpf")"; kill -0 "$tpid" 2>/dev/null || { echo "FAIL: tailer not alive"; exit 1; }

mrun stop --all >/dev/null
[[ ! -f "$tpf" ]] || { echo "FAIL: logtail pid not cleaned"; exit 1; }
kill -0 "$tpid" 2>/dev/null && { echo "FAIL: tailer still alive after stop"; exit 1; } || true
echo "PASS test-compose-logtail"
