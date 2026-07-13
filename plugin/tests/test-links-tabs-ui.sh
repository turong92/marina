#!/usr/bin/env bash
# Dashboard link/import UI: subrepo chips + multi-pick browser (no per-row button spam), selection persists.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP="$HERE/../scripts/marina-web/app-6-modals.js"
CORE="$HERE/../scripts/marina-web/app-1-core.js"
CSS="$HERE/../scripts/marina-web/styles.css"

# link 진입은 카드 ⋯ 메뉴로 이동(카드 다이어트 2026-07-13) — 버튼 잔재 금지 + 메뉴 항목 존재
! grep -q '"links-open-btn"' "$APP" || { echo "FAIL: 구 link 버튼 잔재"; exit 1; }
grep -q "openLinksModal(session)" "$HERE/../scripts/marina-web/app-5b-actions.js" || { echo "FAIL: 카드 ⋯ 메뉴에 link 진입 없음"; exit 1; }
! grep -q '파일 가져오기' "$APP" || { echo "FAIL: old '파일 가져오기' label still present"; exit 1; }
! grep -q '링크 (symlink)' "$APP" || { echo "FAIL: old symlink label still present"; exit 1; }
grep -q 'data-lk-tab' "$APP" || { echo "FAIL: link modal should render subrepo tabs"; exit 1; }

# browse-add: symlink(참조) vs copy(카피) choice
grep -q 'data-lk-mode="copy"' "$APP" || { echo "FAIL: link browse modal should offer copy mode"; exit 1; }
grep -q 'data-lk-mode="symlink"' "$APP" || { echo "FAIL: link browse modal should offer symlink mode"; exit 1; }

# multi-pick: check toggle, not a 가져오기 button on every row; selection persists across navigation
grep -q 'multiPick: true' "$APP" || { echo "FAIL: link browse should use multiPick mode"; exit 1; }
grep -q 'pickedPaths: picked' "$APP" || { echo "FAIL: link browse should track picked paths for persistent selection"; exit 1; }
grep -q 'addedPaths.add' "$APP" || { echo "FAIL: link browse modal should remember added items"; exit 1; }
grep -q 'lk-pick-chip' "$APP" || { echo "FAIL: picked folders should show as removable chips"; exit 1; }
! grep -q "pickLabel: '가져오기'" "$APP" || { echo "FAIL: per-row 가져오기 button should be gone (multi-pick check toggle)"; exit 1; }
! grep -q 'close(); loadLinks(session, body, sub)' "$APP" || { echo "FAIL: link browse modal should stay open after adding"; exit 1; }

# 메인·워크트리 통일: on/off 토글 없음 — 연결(+폴더탐색)/해제(✕)만. 워크트리 override 체크박스·정적 점(●) 제거.
! grep -q 'data-lk-toggle' "$APP" || { echo "FAIL: worktree on/off checkbox(data-lk-toggle) 제거 — 연결/해제로 통일"; exit 1; }
! grep -q 'lk-shared-dot' "$APP" || { echo "FAIL: 정적 점(●) 제거 — 리드 컨트롤 없음(목록 멤버십이 곧 상태)"; exit 1; }

# main(source checkout) shows configured links even when not present on disk; missing ones flagged
grep -q "session.source === 'main'" "$APP" || { echo "FAIL: main checkout should still show configured links"; exit 1; }
grep -q 'lk-missing' "$APP" || { echo "FAIL: links absent on disk should be flagged (원본 없음)"; exit 1; }

# trash clears BOTH base and worktree override — no orphan row left with the trash icon gone
grep -q "scope: 'override', op: 'clear'" "$APP" || { echo "FAIL: deleting a shared link must also clear the worktree override (orphan prevention)"; exit 1; }

# discovered(파생물: build/*.jar 등)는 기본 미선택(unchecked) — 체크는 실제 적용된 링크만. 켜야 등록.
grep -q "l.source === 'discovered'" "$APP" || { echo "FAIL: discovered links must be handled distinctly"; exit 1; }
grep -q 'data-lk-disc' "$APP" || { echo "FAIL: discovered should render an unchecked opt-in toggle, not a default-checked one"; exit 1; }
! grep -qE "data-lk-toggle \\\$\{l.disabled \? '' : 'checked'\}.*discovered" "$APP" || true

# dangling override (shared def deleted, only the worktree 'off' remains) is flagged and removable from the UI
grep -q '"dangling"' "$HERE/../scripts/marina-lib-links.sh" || { echo "FAIL: links API should flag dangling overrides"; exit 1; }
grep -q 'l.dangling' "$APP" || { echo "FAIL: dangling override should render distinctly (끄기 잔재)"; exit 1; }
grep -q 'data-lk-rm-ovr' "$APP" || { echo "FAIL: dangling remnant needs an explicit remove (✕) control"; exit 1; }

# main·worktree 동일: 목록=x-marina 적용목록. 연결(+폴더탐색)/해제(✕)만, 켜짐/꺼짐 별도 상태 없음.
grep -q "session.source === 'main'" "$APP" || { echo "FAIL: main link modal should clarify it manages shared config"; exit 1; }
! grep -q 'data-lk-xm' "$APP" || { echo "FAIL: 항목별 on/off 없음 — 목록 멤버십이 곧 상태"; exit 1; }
grep -q "op: 'clear', subrepo: sub" "$APP" || { echo "FAIL: ✕(해제) should clear at base scope with active subrepo"; exit 1; }

# renderBrowseEntries multiPick support
grep -q 'multiPick' "$CORE" || { echo "FAIL: renderBrowseEntries should support multiPick"; exit 1; }
grep -q 'fb-check' "$CORE" || { echo "FAIL: multiPick rows should render a check toggle"; exit 1; }

# styles
grep -q '\.lk-tabs' "$CSS" || { echo "FAIL: link modal tab styles missing"; exit 1; }
grep -Fq '.dark .lk-tabs .lk-tab.active { color: #fff; }' "$CSS" || { echo "FAIL: selected link tab text should stay high contrast in dark mode"; exit 1; }
grep -q '\.lk-browse-mode' "$CSS" || { echo "FAIL: link browse mode selector styles missing"; exit 1; }
grep -q '\.fb-check' "$CSS" || { echo "FAIL: multiPick check toggle styles missing"; exit 1; }
grep -q '\.lk-pick-chip' "$CSS" || { echo "FAIL: picked-folder chip styles missing"; exit 1; }
grep -q '\.browse-row.added' "$CSS" || { echo "FAIL: browse added row style missing"; exit 1; }
grep -Fq '#tip { position: fixed; z-index: 1000;' "$CSS" || { echo "FAIL: tooltip should render above nested modals"; exit 1; }
! grep -q '\.lk-svc' "$CSS" || { echo "FAIL: old stacked link sections still styled"; exit 1; }

echo "PASS test-links-tabs-ui"
