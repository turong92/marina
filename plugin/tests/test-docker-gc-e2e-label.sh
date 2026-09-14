#!/usr/bin/env bash
# 테스트 스위트가 만드는 도커 산출물은 전부 라벨 marina.e2e=1 을 달아야 한다 — 그래야 정리를 빠뜨려도 GC 정책(3일)이 회수한다.
#   ① 하네스가 MARINA_E2E=1 을 세운다(compose 경로는 오버레이가 라벨을 붙인다)
#   ② 테스트가 직접 치는 `docker run` 은 --label marina.e2e=1 을 달아야 한다(여기서 강제)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

[ "${MARINA_E2E:-}" = "1" ] || { echo "FAIL: 하네스가 MARINA_E2E=1 을 세우지 않는다"; exit 1; }

bad=""
for t in "$HERE"/test-*.sh; do
  # 주석 제외, `docker run` 을 실제로 치는 줄만
  while IFS= read -r line; do
    case "$line" in *"--label marina.e2e=1"*) ;; *) bad="$bad
  $(basename "$t"): $line" ;; esac
  done < <(grep -nE '^[^#]*\bdocker run\b' "$t" || true)
done
if [ -n "$bad" ]; then
  echo "FAIL: --label marina.e2e=1 없는 docker run —$bad"
  echo "  (컨테이너 이름을 marina-*-e2e-* 로 짓는 것만으론 이미지·네트워크가 안 잡힌다)"
  exit 1
fi
echo "PASS test-docker-gc-e2e-label"
