#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"
export MARINA_HOME="$TMP/home"
P="$TMP/proj"
mkdir -p "$P/.workspace/marina/main/logs/build" "$MARINA_HOME"

cat > "$P/.workspace/marina/main/logs/build/run-001.log" <<'LOG'
#1 [web] RUN pnpm install
#1 DONE 4.2s
#2 [web] RUN API_TOKEN=super-secret do-thing
#2 DONE 1.0s
#3 [web] RUN ENV PASSWORD hunter2
#3 DONE 0.5s
#4 [web] RUN tool --password swordfish
#4 DONE 0.4s
#5 [web] RUN curl -H 'Authorization: Bearer abc123'
#5 DONE 0.3s
#6 [web] RUN ENV PASSWORD "quoted-secret"
#6 DONE 0.2s
#7 [web] RUN tool --password 'flag-secret'
#7 DONE 0.2s
#8 [web] RUN curl -H 'Authorization: Basic basic-secret'
#8 DONE 0.2s
#9 [web] RUN API_TOKEN="alpha-secret beta-secret"
#9 DONE 0.2s
LOG
ln -s "logs/build/run-001.log" "$P/.workspace/marina/main/build.log"
cat > "$MARINA_HOME/projects.json" <<JSON
{"schemaVersion":1,"projects":[{"id":"proj","root":"$P","subrepos":[],"worktreeGlobs":[]}]}
JSON

PORT=39714
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
cleanup() {
  kill "$SRV" 2>/dev/null || true
  wait "$SRV" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/api/worktrees" >/dev/null 2>&1 && break
  sleep 0.1
done

code="$(curl -sG -o "$TMP/summary.json" -w '%{http_code}' \
  --data-urlencode "root=$P" \
  --data-urlencode "run=current" \
  "http://127.0.0.1:$PORT/api/build-summary")"
[[ "$code" == "200" ]] || { echo "expected build summary HTTP 200, got $code"; exit 1; }
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); raw=json.dumps(d); assert d["run"] == "run-001.log", d; assert d["bottleneck"]["durationSec"] == 4.2, d; assert all(secret not in raw for secret in ("super-secret", "hunter2", "swordfish", "abc123", "quoted-secret", "flag-secret", "basic-secret", "alpha-secret", "beta-secret")), raw; assert raw.count("<redacted>") >= 8, raw' "$TMP/summary.json"

code="$(curl -sG -o /dev/null -w '%{http_code}' \
  --data-urlencode 'root=/tmp/not-registered' \
  --data-urlencode 'run=current' \
  "http://127.0.0.1:$PORT/api/build-summary")"
[[ "$code" == "400" ]]

echo "PASS test-build-summary-api"
