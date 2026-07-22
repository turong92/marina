# Mobile Workspace Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Marina Mobile into a compact remote workspace controller with immediate context switching, service lifecycle controls, steerable agent sessions, keyboard-safe chat, session model settings, collapsed activity, and safe Markdown.

**Architecture:** Extend the existing Python control server with narrow mobile adapters that reuse Compose and PTY primitives. Keep the delivered app dependency-free at runtime by serving local static Markdown assets, and refactor the embedded mobile shell around a fixed-height grid whose transcript owns scrolling.

**Tech Stack:** Python 3 standard library control server, Marina Compose/PTY/session helpers, embedded HTML/CSS/JavaScript, vendored Markdown parser and sanitizer, Bash contract tests, Aside browser verification.

## Global Constraints

- Existing desktop lifecycle behavior and gateway-first service URLs remain authoritative.
- Mobile actions accept only discovered project roots, service names, agent sources, and validated session identifiers.
- Stop means Ctrl-C for the current agent turn; it does not terminate the persisted session.
- Model and effort changes apply to the next turn when work is already active.
- Markdown rendering must work offline and sanitize raw HTML and unsafe URL schemes.
- The session transcript is the only scrolling region while chat is open.

---

### Task 1: Mobile control contracts

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`
- Modify: `plugin/scripts/marina_term.py`

**Interfaces:**
- Produces: validated mobile action functions for service state/action, agent steering/interruption, and session setting read/write.
- Consumes: `safe_root`, `term_list`, `term_input`, and existing Compose lifecycle functions from the control server.

- [ ] Add failing Python assertions to `test-mobile-control.sh` for live-agent `tid` exposure, steering reuse, Ctrl-C interruption, root/service validation, and per-session overrides.
- [ ] Run `bash plugin/tests/test-mobile-control.sh` and verify the new assertions fail for missing contracts.
- [ ] Add the smallest validated helper functions and response fields needed by the assertions.
- [ ] Run `bash plugin/tests/test-mobile-control.sh` and verify it passes.

### Task 2: Agent launch options and persistence

**Files:**
- Modify: `plugin/tests/test-term.sh`
- Modify: `plugin/scripts/marina_term.py`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Produces: `_agent_cli(source, sid, prompt, model="", effort="") -> list[str]` and session-keyed persisted override storage.
- Consumes: the validated model/effort values from Task 1.

- [ ] Add failing tests proving Claude and Codex receive source-correct model/effort arguments and argument values cannot become shell syntax.
- [ ] Run `bash plugin/tests/test-term.sh` and verify argument assertions fail.
- [ ] Replace lambda command construction with validated argv construction and pass saved overrides from `mobile_send`.
- [ ] Run `bash plugin/tests/test-term.sh` and `bash plugin/tests/test-mobile-control.sh` to green.

### Task 3: Service state and lifecycle endpoints

**Files:**
- Modify: `plugin/tests/test-mobile-admin-http.sh`
- Modify: `plugin/scripts/marina-control.py`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Produces: authenticated `GET /mobile/api/services` and `POST /mobile/api/services/action` responses scoped to a selected root.
- Consumes: existing Compose dashboard state/start/stop/restart helpers and gateway link resolution.

- [ ] Add failing HTTP assertions for state, allowed actions, unknown service rejection, wrong-root rejection, and unauthenticated rejection.
- [ ] Run `bash plugin/tests/test-mobile-admin-http.sh` and verify the new routes return 404 or fail their contract.
- [ ] Add route handlers that translate the mobile request into existing lifecycle calls without duplicating Compose execution.
- [ ] Run mobile HTTP and Compose lifecycle tests to green.

### Task 4: Persistent mobile workspace shell

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Produces: two-row project/source shell, service sheet, chat history state, and two-step main back guard.
- Consumes: service and mobile-state contracts from Tasks 1 and 3.

- [ ] Add failing HTML/JavaScript assertions for persistent project/source controls, `pushState`/`popstate`, two-second back guard, service sheet actions, and removal of global notification/subagent menu actions.
- [ ] Run the mobile test and confirm the shell assertions fail.
- [ ] Implement the dense shell and bottom sheet while retaining current project/session selection storage.
- [ ] Run the mobile test to green.

### Task 5: Keyboard-safe steerable chat

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Produces: visual viewport CSS variable, transcript-only scrolling, latest-message focus behavior, visible lifecycle status, steering send, and Ctrl-C stop action.
- Consumes: active `tid` and control capabilities from Task 1.

- [ ] Add failing assertions for `visualViewport`, `100dvh`, safe-area handling, non-fixed composer layout, focus-to-latest, steering target selection, and interrupt action.
- [ ] Run the mobile test and verify the behavior anchors are absent.
- [ ] Refactor the app shell and chat event handlers to satisfy the contract without page scrolling.
- [ ] Run the mobile test to green.

### Task 6: Session settings, collapsed activity, and Markdown

**Files:**
- Create: `plugin/scripts/marina-web/vendor-marked.js`
- Create: `plugin/scripts/marina-web/vendor-dompurify.js`
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina-control.py`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Produces: offline sanitized Markdown rendering, long-message lazy expansion, session-scoped subagent details, and model/effort settings sheet.
- Consumes: session override and local model metadata contracts from Tasks 1 and 2.

- [ ] Add failing tests for static vendor delivery, sanitizer invocation, unsafe-link rejection, Markdown structure, four-line collapsed previews, lazy body rendering, code copy actions, and session-only subagent visibility.
- [ ] Run mobile tests and verify the new assertions fail.
- [ ] Add pinned local vendor assets and serve them through the existing static route.
- [ ] Implement source-aware settings controls and sanitized lazy Markdown rendering.
- [ ] Run mobile tests to green and verify the vendor license headers remain intact.

### Task 7: Regression and phone verification

**Files:**
- Modify as needed: files changed in Tasks 1-6

**Interfaces:**
- Consumes: all prior task deliverables.
- Produces: browser evidence and a clean regression run.

- [ ] Run `bash plugin/tests/test-mobile-control.sh`, `bash plugin/tests/test-mobile-admin-http.sh`, `bash plugin/tests/test-agent-history-pagination.sh`, `bash plugin/tests/test-term.sh`, and affected Compose/gateway tests.
- [ ] Start the worktree dashboard on an unused preview port with isolated `MARINA_HOME` where possible.
- [ ] Use Aside at phone dimensions to verify context switching, service controls, back guard, session entry at latest, keyboard visibility, working/stop state, model sheet, Markdown, and collapsed messages.
- [ ] Inspect screenshots for overlapping text, clipped controls, and keyboard occlusion; fix and repeat until clean.
- [ ] Run the full `plugin/tests/*.sh` suite and record pass/skip/failure totals before declaring completion.
