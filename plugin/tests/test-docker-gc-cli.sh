#!/usr/bin/env bash
# `marina docker gc` CLI — 정책 읽기/쓰기/오류코드, --dry-run/--now/--json, enabled=false 안내. 가짜 docker 로 실 도커 무접촉.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENTRY="$HERE/../scripts/marina-entrypoint.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"; cp "$HERE/lib/fake-docker.sh" "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log"
fail() { echo "FAIL: $1"; exit 1; }
m() { bash "$ENTRY" docker gc "$@"; }

# ── policy 읽기/쓰기 ──
out="$(m policy)" || fail "policy 출력 실패"
grep -q 'interval_hours' <<<"$out" && grep -q 'build_cache_keep_days' <<<"$out" || fail "policy 에 키가 없다: $out"
m policy interval_hours 12 >/dev/null || fail "policy set 실패"
python3 -c "import json,sys; assert json.load(open('$MARINA_HOME/docker-gc.json'))['interval_hours']==12" || fail "파일 반영 안 됨"
m policy stale_test_artifact_names 'marina-*-e2e-*,mdce2e*' >/dev/null || fail "글롭 set 실패"
python3 -c "import json; assert json.load(open('$MARINA_HOME/docker-gc.json'))['stale_test_artifact_names']==['marina-*-e2e-*','mdce2e*']" || fail "글롭 반영 안 됨"
set +e; m policy nope 1 >/dev/null 2>&1; rc=$?; set -e; [ "$rc" = 2 ] || fail "모르는 키는 exit 2 (got $rc)"
set +e; m policy interval_hours abc >/dev/null 2>&1; rc=$?; set -e; [ "$rc" = 2 ] || fail "틀린 값은 exit 2 (got $rc)"

# ── dry-run: 판정만, 삭제 0회 ──
: > "$FAKE_DOCKER_LOG"
out="$(m --dry-run --json)" || fail "dry-run 실패"
python3 - "$out" <<'PY' || fail "dry-run JSON 형태"
import json, sys
d = json.loads(sys.argv[1]); assert d["dryRun"] is True and [s["name"] for s in d["steps"]] == ["build-cache", "dangling", "volumes", "e2e", "orphans"], d
assert d["reclaimedMb"] == 1024, d["reclaimedMb"]      # 가짜 df 의 오래된 빌드캐시 1GB
PY
grep -qE '^(builder prune|image prune|volume prune|volume rm|rm |image rm|network rm)' "$FAKE_DOCKER_LOG" && fail "dry-run 이 삭제 명령을 냈다: $(cat "$FAKE_DOCKER_LOG")"
[ ! -e "$MARINA_HOME/docker-gc-state.json" ] || fail "dry-run 이 상태를 썼다"
grep -q 'would reclaim' "$MARINA_HOME/docker-gc.log" || fail "dry-run 로그 없음"
out="$(m --dry-run)"; grep -q '1.0GB' <<<"$out" || fail "사람용 dry-run 출력에 회수량이 없다: $out"

# ── enabled=false + 인자 없음 → 안내만(exit 0), 도커 무접촉 ──
m policy enabled false >/dev/null; : > "$FAKE_DOCKER_LOG"
out="$(m)" || fail "비활성 안내가 실패코드"
grep -qi '꺼' <<<"$out" || fail "비활성 안내가 없다: $out"
[ ! -s "$FAKE_DOCKER_LOG" ] || fail "비활성인데 도커를 불렀다"

# ── --now: 정책 무관 실행 → prune 호출·상태 기록 ──
out="$(m --now --json)" || fail "--now 실패"
grep -q '^builder prune --all -f --filter until=168h$' "$FAKE_DOCKER_LOG" || fail "--now 가 builder prune 을 안 냈다: $(cat "$FAKE_DOCKER_LOG")"
python3 -c "import json; s=json.load(open('$MARINA_HOME/docker-gc-state.json')); assert s['source']=='cli' and s['reclaimedMb']==1024, s" || fail "상태 기록"
m policy enabled true >/dev/null

# ── 인자 없음: 방금 돌아서 not-due → 안내, 실행 안 함 ──
: > "$FAKE_DOCKER_LOG"
out="$(m)" || fail "not-due 안내 실패"
grep -q '다음' <<<"$out" || fail "다음 실행 시각 안내가 없다: $out"
grep -q 'builder prune' "$FAKE_DOCKER_LOG" && fail "not-due 인데 실행했다"

# ── status ──
out="$(m status --json)" || fail "status 실패"
python3 - "$out" <<'PY' || fail "status JSON"
import json, sys
d = json.loads(sys.argv[1]); assert d["policy"]["enabled"] is True and d["state"]["reclaimedMb"] == 1024 and d["disk"]["buildCacheMb"] == 1024, d
PY
out="$(m status)"; grep -q '마지막' <<<"$out" && grep -q '정책' <<<"$out" || fail "사람용 status: $out"
bash "$ENTRY" --help 2>&1 | grep -q 'docker gc' || fail "entrypoint usage 에 docker gc 가 없다"
echo "PASS test-docker-gc-cli"
