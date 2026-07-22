# Mobile Chat History Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken aggregate history UI with paged Q&A exchanges, stable reader-controlled scrolling, and a compact chat header with on-demand usage details.

**Architecture:** Keep the existing transcript API and normalize loaded timeline items into exchange view models in the mobile client. The transcript owns scrolling and cursor pagination; chat-mode navigation and usage details are rendered in a compact top row without changing list mode.

**Tech Stack:** Embedded HTML/CSS/JavaScript in Python, JSONL byte-cursor API, shell/Node regression tests, Playwright browser QA.

## Global Constraints

- Do not fetch complete history on chat entry.
- Do not change desktop transcript behavior or server endpoint contracts.
- Polling must not change reader position after the reader leaves the bottom.
- Remove the visible previous-message button and permanent usage rail.
- Keep redaction, pending sends, links, controls, and composer behavior intact.

---

### Task 1: Paged Exchange Rendering

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Produces: `conversationExchanges(items) -> Array<{id,user,activities,assistants}>`
- Consumes: merged `history.timeline` pages.

- [ ] Add failing assertions that the old button and aggregate previous container are absent and page items are split at user messages.
- [ ] Run `bash plugin/tests/test-mobile-control.sh`; expect failure on the old markup and missing exchange renderer.
- [ ] Implement stable exchange IDs, latest-expanded rendering, older collapsed rows, and page-boundary regrouping.
- [ ] Make transcript children non-shrinking so the transcript is the only working scroll surface.
- [ ] Re-run the focused test and confirm it passes.

### Task 2: Cursor Loading And Scroll Intent

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Produces: `followLatest`, `captureScrollAnchor()`, `restoreScrollAnchor(anchor)`, and top-triggered `loadOlderMessages()`.

- [ ] Add failing assertions for explicit bottom-follow state, stable exchange anchors, and removal of the 120 px polling heuristic.
- [ ] Run the focused test and confirm the new assertions fail.
- [ ] Preserve the first visible exchange while prepending a page and retain exact scroll position during polling.
- [ ] Load one previous page only when the reader reaches the top; show transient loading/error text without a button.
- [ ] Make composer focus scroll only when bottom-follow is already enabled.
- [ ] Re-run focused history, send, and inbox tests.

### Task 3: Compact Chat Header And Usage Panel

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Produces: chat-mode header state and `usageBtn`/`usagePanel` interaction.

- [ ] Add failing assertions for hidden list navigation in chat mode, one-line title controls, and an initially hidden usage panel.
- [ ] Run the focused test and confirm the compact-header assertions fail.
- [ ] Hide project/source/service navigation in chat mode, move the title and usage button into the shell row, and remove the duplicate chat header.
- [ ] Toggle the anchored usage panel and close it on outside press, back, and session switch.
- [ ] Re-run focused mobile tests.

### Task 4: Verification And Commit

**Files:**
- Modify: `docs/superpowers/plans/2026-07-23-mobile-chat-history-fixes.md`

**Interfaces:**
- Produces: verified behavior at `http://127.0.0.1:3900/mobile`.

- [ ] Run timeline, pagination, mobile control, admin boundary, agents, and inbox regression tests.
- [ ] Run Python compilation, shell syntax checks, and `git diff --check`.
- [ ] Restart the worktree dashboard and verify 390 x 844 scrolling, polling, middle exchange expansion, previous-page loading, compact header, and usage panel.
- [ ] Complete this checklist and commit without pushing.
