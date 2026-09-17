#!/usr/bin/env bash
# 가짜 docker — GC 테스트용. 호출을 $FAKE_DOCKER_LOG 에 적고 canned 출력을 돌려준다. 삭제 명령도 "성공" 만 찍는다.
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:-/dev/null}"
case "$*" in
  "system df -v --format json")
    echo '{"Images":[{"Size":"3GB"}],"Containers":[],"Volumes":[{"Name":"named_vol","Size":"10MB"}],"BuildCache":[{"ID":"bc1","InUse":"false","LastUsedAt":"2026-01-01 00:00:00 +0000 UTC","CreatedAt":"2026-01-01 00:00:00 +0000 UTC","Size":"1GB"}]}' ;;
  "builder prune --all -f --filter until="*) printf "ID\tRECLAIMABLE\tSIZE\nbc1\ttrue\t1GB\nTotal:\t1GB\n" ;;   # 실측 형식(builder prune 은 Total:)
  "image prune -f"|"volume prune -f") echo "Total reclaimed space: 0B" ;;
  "images -f dangling=true --format json"|"volume ls -f dangling=true --format json"|"ps -a -q"|"images --format json"|"network ls --format json") ;;
  "images --filter label=marina.e2e=1 -q") ;;
  version*|info*) echo "fake" ;;
  *) echo "fake-docker: unexpected: $*" >&2; exit 1 ;;
esac
