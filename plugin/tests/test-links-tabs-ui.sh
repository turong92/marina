#!/usr/bin/env bash
# Dashboard link/import UI: subrepo chips + multi-pick browser (no per-row button spam), selection persists.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP="$HERE/../scripts/marina-web/app-6-modals.js"
CORE="$HERE/../scripts/marina-web/app-1-core.js"
CSS="$HERE/../scripts/marina-web/styles.css"

grep -q '"links-open-btn"' "$APP" || { echo "FAIL: link open button missing"; exit 1; }
grep -q '>link</span>' "$APP" || { echo "FAIL: dashboard link button should say link"; exit 1; }
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

# list toggle is in-place (no destructive reload that makes rows flash/disappear)
grep -q "row.classList.toggle('off'" "$APP" || { echo "FAIL: list toggle should flip row state in place, not reload the whole list"; exit 1; }

# main(source checkout) shows configured links even when not present on disk; missing ones flagged
grep -q "session.source === 'main'" "$APP" || { echo "FAIL: main checkout should still show configured links"; exit 1; }
grep -q 'lk-missing' "$APP" || { echo "FAIL: links absent on disk should be flagged (원본 없음)"; exit 1; }

# trash clears BOTH base and worktree override — no orphan row left with the trash icon gone
grep -q "scope: 'override', op: 'clear'" "$APP" || { echo "FAIL: deleting a shared link must also clear the worktree override (orphan prevention)"; exit 1; }

# dangling override (shared def deleted, only the worktree 'off' remains) is flagged and removable from the UI
grep -q '"dangling"' "$HERE/../scripts/marina-lib-links.sh" || { echo "FAIL: links API should flag dangling overrides"; exit 1; }
grep -q 'l.dangling' "$APP" || { echo "FAIL: dangling override should render distinctly (끄기 잔재)"; exit 1; }
grep -q 'data-lk-rm-ovr' "$APP" || { echo "FAIL: dangling remnant needs an explicit remove (✕) control"; exit 1; }

# main(source checkout) link modal: distinct action semantics — static shared dot (toggle is a no-op on main), clarified copy
grep -q "session.source === 'main'" "$APP" || { echo "FAIL: main link modal should clarify it manages shared config (not per-worktree toggle)"; exit 1; }
grep -q 'lk-shared-dot' "$APP" || { echo "FAIL: main rows should show a static shared indicator, not a meaningless toggle"; exit 1; }
# main can disable default links project-wide (base toggle), not just per-worktree
grep -q 'data-lk-base' "$APP" || { echo "FAIL: main should let you toggle default links project-wide (base disable)"; exit 1; }
grep -q "scope: 'base', op: on ? 'clear' : 'disable'" "$APP" || { echo "FAIL: base toggle should disable/clear at base scope"; exit 1; }
grep -q 'l.baseOff' "$APP" || { echo "FAIL: project-wide disabled default should render distinctly (프로젝트 꺼짐)"; exit 1; }

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
