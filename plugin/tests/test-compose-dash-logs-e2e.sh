#!/usr/bin/env bash
# 실 docker: compose start → 컨테이너 로그가 run-NNN.log 로 캡처된다(대시보드 뷰어가 읽는 그 파일). 데몬 없으면 SKIP.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-dash-logs-e2e (docker 미가용)"; exit 0; }
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
export MARINA_GATEWAY=off   # 게이트웨이 auto-spawn 차단(이 테스트는 게이트웨이 대상 아님 → caddy leak 방지)
P="$TMP/proj-$$"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"   # 고유 basename — 실제 'proj' 프로젝트(-p proj-main)와 충돌 방지
cat > "$P/docker-compose.yml" <<'YML'
services:
  web: { image: "python:3-alpine", command: ["sh","-c","echo MARINA-LOG-MARKER; python -m http.server 8000"], ports: ["8000:8000"] }
YML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
cleanup(){ (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" stop --all >/dev/null 2>&1)||true; rm -rf "$TMP"; }
trap cleanup EXIT
(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" start --all >/dev/null)
SD="$P/.workspace/marina/main"
ok=false
for _ in $(seq 1 40); do grep -q "MARINA-LOG-MARKER" "$SD"/logs/web/run-*.log 2>/dev/null && { ok=true; break; }; sleep 0.5; done
[[ "$ok" == true ]] || { echo "FAIL: container log not captured to run-NNN"; ls -la "$SD"/logs/web/ 2>/dev/null; cat "$SD"/logs/web/run-*.log 2>/dev/null; exit 1; }
echo "PASS test-compose-dash-logs-e2e"
