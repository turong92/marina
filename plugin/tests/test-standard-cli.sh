#!/usr/bin/env bash
# marina.sh 표준 서브커맨드 dispatch: service/project 그룹 + lifecycle 무인자 가드 + service ls
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"

# project add/ls/rm (구 add/rm/ls 대체)
proj="$TMP/proj"; mkdir -p "$proj"; ( cd "$proj" && git init -q )
"$SH" project add "$proj" >/dev/null
"$SH" project ls | grep -q "$(basename "$proj")" || { echo "FAIL: project ls"; exit 1; }

# service add/ls/rm (구 add-service/rm-service 대체)
id="$(basename "$proj")"
"$SH" service add "$id" '{"name":"web","portBase":3000,"run":"exec true"}' >/dev/null
"$SH" service ls "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); assert any(s['name']=='web' for s in d['services']), d" \
  || { echo "FAIL: service ls 가 정의 json 출력 안 함"; exit 1; }
"$SH" service rm "$id" web >/dev/null
"$SH" service ls "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); assert not d['services'], d" \
  || { echo "FAIL: service rm"; exit 1; }

# service ls 가 source 태그 부여: root(팀) 정의는 source=='root'
"$SH" service add "$id" '{"name":"web","portBase":3000,"run":"exec true"}' --root >/dev/null
"$SH" service ls "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); s=next(x for x in d['services'] if x['name']=='web'); assert s['source']=='root' and s['portBase']==3000, s" \
  || { echo "FAIL: service ls root source 태그"; exit 1; }
# 중앙(개인) override: 같은 name 을 다른 portBase 로 중앙에 두면 source=='central' + 중앙 값이 이김
"$SH" service add "$id" '{"name":"web","portBase":4000,"run":"exec true"}' >/dev/null
"$SH" service ls "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); s=next(x for x in d['services'] if x['name']=='web'); assert s['source']=='central' and s['portBase']==4000, s" \
  || { echo "FAIL: service ls central override source 태그/우선순위"; exit 1; }
"$SH" service rm "$id" web >/dev/null         # 중앙 제거
"$SH" service rm "$id" web --root >/dev/null   # root 제거 (클린업)

# lifecycle 무인자 가드: start 인자 없으면 usage(비-0) + '--all' 힌트, 전체 안 띄움
( cd "$proj" && "$SH" service add "$id" '{"name":"web","portBase":3000,"run":"exec true"}' >/dev/null )
out="$( cd "$proj" && "$SH" start 2>&1 )" && { echo "FAIL: 무인자 start 가 0 exit"; exit 1; }
echo "$out" | grep -q -- "--all" || { echo "FAIL: start 무인자 usage 에 --all 힌트 없음"; exit 1; }

# 구 명령 제거 확인: add-service 는 더 이상 안 받음
( cd "$proj" && "$SH" add-service "$id" '{"name":"x","portBase":3001,"run":"exec true"}' 2>&1 ) && { echo "FAIL: 구 add-service 가 살아있음"; exit 1; }

echo "PASS test-standard-cli (marina.sh)"

EP="$HERE/../scripts/marina-entrypoint.sh"
# start = 서비스(대시보드 아님). 무인자는 usage(비-0).
( cd "$proj" && "$EP" start 2>&1 ) && { echo "FAIL: entrypoint 무인자 start 0 exit"; exit 1; }
# bare 서비스명도 동작(entrypoint 가 --flag 변환): stop web (no-op, exit 0)
( cd "$proj" && "$EP" stop web ) || { echo "FAIL: entrypoint 가 bare 'stop web' 처리 못함"; exit 1; }
# 제거된 별칭: up/down/dash/all/off/quit/add-service 는 unknown(비-0)
for dead in up down dash all off quit add-service; do
  ( cd "$proj" && "$EP" "$dead" 2>&1 ) && { echo "FAIL: 제거된 '$dead' 가 살아있음"; exit 1; }
done
echo "PASS test-standard-cli (entrypoint)"
