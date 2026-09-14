#!/usr/bin/env bash
# /api/docker-gc (GET) · /api/docker-gc/policy · /api/docker-gc/run — 데몬을 띄워 실측. 가짜 docker 로 실 도커 무접촉.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/bin"; cp "$HERE/lib/fake-docker.sh" "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log"
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
echo '{"projects":[]}' > "$MARINA_HOME/projects.json"
PORT=39731; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
fail() { echo "FAIL: $1"; exit 1; }

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >"$TMP/srv.log" 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

out="$(curl -sf "${hdr[@]}" "$base/api/docker-gc")" || fail "GET /api/docker-gc"
python3 - "$out" <<'PY' || fail "GET 형태"
import json, sys
d = json.loads(sys.argv[1]); assert d["policy"]["enabled"] is True and d["policy"]["interval_hours"] == 24 and d["state"] == {} and d["due"] is True, d
assert d["disk"]["buildCacheMb"] == 1024 and d["disk"]["imagesMb"] == 3072, d["disk"]
PY

out="$(curl -sf "${hdr[@]}" -d '{"key":"interval_hours","value":6}' "$base/api/docker-gc/policy")" || fail "POST policy"
python3 -c "import json,sys; assert json.loads(sys.argv[1])['policy']['interval_hours']==6" "$out" || fail "policy 응답: $out"
python3 -c "import json; assert json.load(open('$MARINA_HOME/docker-gc.json'))['interval_hours']==6" || fail "policy 파일"
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -d '{"key":"nope","value":1}' "$base/api/docker-gc/policy")"
[[ "$code" == 4* ]] || fail "모르는 키는 4xx (got $code)"

: > "$FAKE_DOCKER_LOG"
out="$(curl -sf "${hdr[@]}" -d '{"dryRun":true}' "$base/api/docker-gc/run")" || fail "POST run dry"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['dryRun'] is True and d['reclaimedMb']==1024, d" "$out" || fail "dry 응답: $out"
grep -qE '^(builder prune|image prune|volume prune)' "$FAKE_DOCKER_LOG" && fail "dry-run 이 삭제 명령을 냈다"

out="$(curl -sf "${hdr[@]}" -d '{}' "$base/api/docker-gc/run")" || fail "POST run"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['dryRun'] is False and d['source']=='dashboard', d" "$out" || fail "run 응답: $out"
grep -q '^builder prune' "$FAKE_DOCKER_LOG" || fail "실행이 prune 을 안 냈다"
out="$(curl -sf "${hdr[@]}" "$base/api/docker-gc")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['state']['reclaimedMb']==1024 and d['due'] is False, d" "$out" || fail "실행 뒤 상태: $out"
echo "PASS test-docker-gc-api"
