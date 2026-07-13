#!/usr/bin/env bash
# 워크스페이스 탭 셸: 로그/깃/연결/터미널(실탭 — 2026-07-13 활성화)·로그 DOM id 보존·setWsTab 존재·JS 문법
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
H="$HERE/../scripts/marina-web/index.html"
grep -q 'data-ws-tab="logs"' "$H" || { echo "FAIL: 로그 탭 없음"; exit 1; }
grep -q 'data-ws-tab="git"' "$H" || { echo "FAIL: 깃 탭 없음"; exit 1; }
grep -q 'data-ws-tab="term"' "$H" || { echo "FAIL: 터미널 탭 없음"; exit 1; }
! grep -q 'data-ws-tab="term" disabled' "$H" || { echo "FAIL: 터미널 탭이 disabled — 실탭이어야(2026-07-13)"; exit 1; }
grep -q 'id="tab-logs"' "$H" && grep -q 'id="tab-git"' "$H" || { echo "FAIL: ws-pane 없음"; exit 1; }
for id in log logFilter runSelect logModeTabs olderBar gaugeTrack followLog logClear logDownload openWeb selectedRoot selectedLabel; do
  grep -q "id=\"$id\"" "$H" || { echo "FAIL: 로그 DOM #$id 소실"; exit 1; }
done
grep -q "function setWsTab" "$HERE/../scripts/marina-web/app-6-modals.js" || { echo "FAIL: setWsTab 없음"; exit 1; }
grep -q "WS_VIEWS" "$HERE/../scripts/marina-web/app-6-modals.js" || { echo "FAIL: WS_VIEWS 없음"; exit 1; }
if command -v node >/dev/null 2>&1; then
  for f in "$HERE/../scripts/marina-web/"app-*.js; do
    node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
  done
fi
echo "PASS test-dash-workspace-tabs"
