# Gateway-first Web Open Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every default dashboard web-open action use the stable Marina gateway URL, with the published host port only as an explicit fallback or secondary action.

**Architecture:** Add one URL policy helper beside `gatewayUrlFor` and reuse it from the log header and service action menu. Keep card and connection-tab gateway behavior unchanged, and retain direct host-port access as an explicitly labeled diagnostic path.

**Tech Stack:** Browser JavaScript, shell regression tests, Node.js syntax/behavior checks, Aside browser verification.

## Global Constraints

- Keep dashboard/control on port `3900` and gateway service URLs on port `3902` by default.
- Prefer gateway URLs whenever Caddy gateway state is available.
- Fall back to a running service's published host port only when the gateway URL is unavailable.
- Open new tabs with `noopener`.

---

### Task 1: Shared gateway-first URL policy

**Files:**
- Modify: `plugin/scripts/marina-web/app-3-util.js`
- Modify: `plugin/scripts/marina-web/app-4-logs.js`
- Modify: `plugin/scripts/marina-web/app-5b-actions.js`
- Modify: `plugin/scripts/marina-web/app-6-modals.js`
- Create: `plugin/tests/test-gateway-first-open.sh`

**Interfaces:**
- Consumes: `gatewayUrlFor(session, svc)` and service `running`/`port` state.
- Produces: `preferredServiceUrl(session, svc) -> string|null` and `openServiceInBrowser(session, svc) -> string|null`.

- [x] **Step 1: Add a failing helper and UI contract test**

  Assert gateway preference, host fallback, no URL for stopped services, `noopener`, and removal of the log header's hard-coded `localhost` URL.

- [x] **Step 2: Run the focused test and verify it fails**

  Run: `bash plugin/tests/test-gateway-first-open.sh`

  Expected: failure because `preferredServiceUrl` is not defined.

- [x] **Step 3: Implement the shared helper and route UI actions through it**

  Add the helper in `app-3-util.js`, set the log header button's target/title from the helper in `app-4-logs.js`, open it in `app-6-modals.js`, and make it the first service menu action in `app-5b-actions.js`.

- [x] **Step 4: Verify focused and dashboard regression tests**

  Run: `bash plugin/tests/test-gateway-first-open.sh && bash plugin/tests/test-dash-workspace-tabs.sh && bash plugin/tests/test-dash-state-ui.sh && bash plugin/tests/test-conn-tab.sh`

  Expected: all tests print `PASS`.

- [x] **Step 5: Verify the real dashboard**

  In `http://localhost:3900`, select a running web service and verify the log header button targets its `*.localhost:3902` gateway URL and carries the gateway tooltip.
