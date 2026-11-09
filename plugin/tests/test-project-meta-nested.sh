#!/usr/bin/env bash
# 중첩 프로젝트: 워크트리 안 폴더를 따로 등록한 프로젝트(예 story-chat 워크트리 안 work/qwen-user-console)는
# ROOT 가 그 폴더면 상위(story-chat)가 아니라 그 프로젝트로 잡혀야 한다(2026-11-09 story-chat 방 보고 — 첫 매칭이 상위를 골랐다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "${TMPROOT:?}"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
W="$TMPROOT/ws"; mkdir -p "$W/parent/.claude/worktrees/wt/work/child"
PROJECTS_FILE="$TMPROOT/projects.json"
printf '{"projects":[{"id":"parent","root":"%s"},{"id":"child","root":"%s","composeFile":"c.yml"}]}\n' \
  "$W/parent" "$W/parent/.claude/worktrees/wt/work/child" > "$PROJECTS_FILE"
. "$HERE/../scripts/marina-lib-services.sh"

ROOT="$W/parent/.claude/worktrees/wt/work/child"; SOURCE_ROOT="$W/parent"
id="$(project_meta | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')"
[ "$id" = "child" ] || fail "ROOT 가 하위 프로젝트면 그것: $id"

ROOT="$W/parent/.claude/worktrees/wt"; SOURCE_ROOT="$W/parent"
id="$(project_meta | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')"
[ "$id" = "parent" ] || fail "워크트리 루트면 상위: $id"

ROOT="$W/elsewhere"; SOURCE_ROOT="$W/parent/.claude/worktrees/wt/work/child"
id="$(project_meta | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')"
[ "$id" = "child" ] || fail "ROOT 가 안 맞으면 SOURCE_ROOT 로: $id"

ROOT="$W/parent/.claude/worktrees/wt/work/child/sub"; SOURCE_ROOT="$W/parent"
MARINA_HOME="$TMPROOT/mh"; mkdir -p "$MARINA_HOME"
echo '{"services":[{"name":"svc-child"}]}' > "$W/parent/.claude/worktrees/wt/work/child/marina-services.json"
got="$(merged_services_json)"
case "$got" in *svc-child*) ;; *) fail "서비스 머지도 하위 프로젝트 루트에서: $got" ;; esac
. "$HERE/../scripts/marina-lib-links.sh"
mkdir -p "$MARINA_HOME/child" "$MARINA_HOME/parent"
echo '{"links":{"child-link":{"glob":"x","kind":"dir"}}}' > "$MARINA_HOME/child/links.json"
echo '{"links":{"parent-link":{"glob":"y","kind":"dir"}}}' > "$MARINA_HOME/parent/links.json"
got="$(central_links_json)"
case "$got" in *child-link*) ;; *) fail "공유 링크도 하위 프로젝트 것(리뷰 I2): $got" ;; esac
echo "PASS test-project-meta-nested"
