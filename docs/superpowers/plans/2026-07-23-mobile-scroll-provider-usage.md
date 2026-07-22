# Mobile Scroll And Provider Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve mobile transcript position during polling and expose Codex/Claude account limits, including Claude Fable 5 weekly usage.

**Architecture:** Extend the existing provider-aware usage response in `marina_sessions.py` without changing the session context contract. Render provider windows in the existing mobile usage panel. Harden the existing transcript anchor flow so follow-latest is controlled by explicit scroll intent and not by internal DOM updates.

**Tech Stack:** Python stdlib, embedded mobile HTML/JavaScript, shell regression tests, Playwright-compatible browser verification.

## Global Constraints

- Preserve unrelated dirty changes in the mobile history files.
- Do not read or expose OAuth/access tokens in Marina responses or tests.
- Account usage collection must be best-effort and must not block mobile state polling.
- Missing provider data must remain visibly unavailable, never fabricated.

### Task 1: Provider usage normalization tests

**Files:**
- Modify: `plugin/tests/test-agent-usage.sh`
- Test: `plugin/tests/test-agent-usage.sh`

- [x] **Step 1: Write failing fixtures and assertions**

Add Codex `rate_limits` records for 300 and 10080 minute windows, Claude HUD cache fixtures with five-hour, weekly, and Fable weekly fields, and assertions for normalized `accountUsage` values.

- [x] **Step 2: Run the focused test and confirm it fails**

Run: `bash plugin/tests/test-agent-usage.sh`

Expected: FAIL because provider account usage is not yet returned.

### Task 2: Provider usage collection

**Files:**
- Modify: `plugin/scripts/marina_sessions.py`
- Test: `plugin/tests/test-agent-usage.sh`

- [x] **Step 1: Implement Codex rate-limit discovery**

Scan the newest valid rollout event records, map `window_minutes == 300` to `fiveHour`, `10080` to `weekly`, and preserve `usedPercent` and `resetsAt`.

- [x] **Step 2: Implement Claude cache normalization**

Read the configured Claude HUD usage cache without credentials. Normalize `fiveHour`, `sevenDay`, and optional Fable fields into the same window shape. Return unavailable values when the cache is absent, invalid, or stale.

- [x] **Step 3: Expose account usage from the existing usage endpoint**

Keep session context fields at the top level for compatibility and add `accountUsage` for the selected provider. Do not make provider collection errors fail the endpoint.

- [x] **Step 4: Run the focused test and confirm it passes**

Run: `bash plugin/tests/test-agent-usage.sh`

Expected: `PASS test-agent-usage`.

### Task 3: Mobile usage panel

**Files:**
- Modify: `plugin/scripts/marina_mobile.py`
- Modify: `plugin/tests/test-mobile-control.sh`

- [x] **Step 1: Add failing HTML assertions**

Assert provider usage rows, five-hour/weekly labels, Claude Fable label, reset display, and unavailable-state rendering.

- [x] **Step 2: Implement provider usage rendering**

Render the selected provider's account windows above the existing context metrics. Keep the panel compact on mobile and refresh usage on the existing lazy usage cadence.

- [x] **Step 3: Run the focused UI test**

Run: `bash plugin/tests/test-mobile-control.sh`

Expected: `PASS test-mobile-control`.

### Task 4: Polling scroll regression

**Files:**
- Modify: `plugin/scripts/marina_mobile.py`
- Modify: `plugin/tests/test-mobile-control.sh`

- [x] **Step 1: Add a failing browser-script assertion**

Exercise the extracted scroll helpers with a synthetic transcript, update content while scrolled above the bottom, and assert the anchor id and viewport offset remain stable. Also assert internal scroll events do not enable follow-latest.

- [x] **Step 2: Implement explicit scroll intent preservation**

Capture the intent before render, suppress only internal scroll events, restore by stable exchange id, and only follow the bottom when the pre-render intent was true.

- [x] **Step 3: Run the focused UI and syntax tests**

Run: `bash plugin/tests/test-mobile-control.sh && python3 -m py_compile plugin/scripts/marina_mobile.py`

Expected: both commands exit zero.

### Task 5: Integration verification

**Files:**
- No production file changes.

- [x] **Step 1: Run provider and mobile regressions**

Run: `bash plugin/tests/test-agent-usage.sh && bash plugin/tests/test-mobile-control.sh && bash plugin/tests/test-mobile-admin-http.sh`

- [x] **Step 2: Verify the live mobile endpoint**

Open the Tailscale mobile URL in Aside, select a Codex session and a Claude session, and confirm the usage panel renders the available account windows without console errors.

- [x] **Step 3: Run final diff checks**

Run: `git diff --check` and `python3 -m py_compile plugin/scripts/marina_mobile.py plugin/scripts/marina_sessions.py`.
