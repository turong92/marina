# Agent Activity Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give desktop and mobile users one accurate cross-project inbox for Claude and Codex sessions that finished or need attention.

**Architecture:** `marina_sessions.py` parses native JSONL turn boundaries into a common agent status and adds it to the existing worktree agent payload. Desktop and mobile derive inbox entries from those payloads, store read event IDs locally, and reuse their existing agent-open paths.

**Tech Stack:** Python 3 standard library, vanilla JavaScript, HTML/CSS, Bash fixture tests.

## Global Constraints

- Keep malformed or truncated JSONL non-fatal.
- Keep older payloads compatible through the timestamp fallback.
- Do not add a database, background daemon, dependency, or server-side read-state store.
- Open desktop items through `openAgentTerminal` and mobile items through the existing selected session/chat flow.

---

### Task 1: Native Agent Status Normalization

**Files:**
- Modify: `plugin/scripts/marina_sessions.py`
- Modify: `plugin/scripts/marina_handler.py`
- Modify: `plugin/scripts/marina_mobile.py`
- Test: `plugin/tests/test-agent-inbox.sh`

**Interfaces:**
- Produces: `agent_status(path: Path, source: str, terminal_active: bool = False) -> dict[str, Any]`
- Produces: agent payload fields `status`, `statusTs`, and optional `statusReason`
- Consumes: live terminal identity tuples `(root, source, sid)` from `term_list()`

- [x] **Step 1: Write fixture assertions before implementation**

Create Claude and Codex JSONL fixtures that assert `working`, `waiting`, `completed`, `failed`, and malformed-line recovery. Assert `waiting` changes to `completed` when `terminal_active=False`.

- [x] **Step 2: Run the fixture test and verify RED**

Run: `bash plugin/tests/test-agent-inbox.sh`

Expected: FAIL because `agent_status` and payload status fields do not exist.

- [x] **Step 3: Implement the native boundary parser**

Read a bounded JSONL tail, scan newest to oldest, and map Codex `task_started`/`task_complete`/`turn_aborted` plus Claude user/tool activity/`end_turn`/`stop_hook_summary`/`api_error`. Return `idle` when no reliable event exists and use recent mtime only as a working fallback.

- [x] **Step 4: Pass live terminal identities to agent payload generation**

Load `term_list()` once per API state request, build a set of live `(root, source, sid)` tuples, and pass it to `agents_payload` so successful endings become `waiting` only when resumable in a live Marina PTY.

- [x] **Step 5: Run the fixture and existing agent tests**

Run: `bash plugin/tests/test-agent-inbox.sh && bash plugin/tests/test-agents-section.sh`

Expected: both PASS.

### Task 2: Desktop Inbox And Agent Status Rows

**Files:**
- Modify: `plugin/scripts/marina-web/index.html`
- Modify: `plugin/scripts/marina-web/app-1-core.js`
- Modify: `plugin/scripts/marina-web/app-5-sessions.js`
- Modify: `plugin/scripts/marina-web/app-7-init.js`
- Modify: `plugin/scripts/marina-web/styles.css`
- Test: `plugin/tests/test-agent-inbox.sh`

**Interfaces:**
- Consumes: worktree agents containing `source`, `sid`, `title`, `status`, `statusTs`, and `statusReason`
- Produces: `agentInboxEntries()`, `renderAgentInbox()`, and `openAgentInboxItem(eventId)`

- [x] **Step 1: Add failing desktop contract assertions**

Assert the header contains an inbox button/count/panel, status rows use `agent.status`, inbox derives stable event IDs, and item activation calls `openAgentTerminal`.

- [x] **Step 2: Run and verify RED**

Run: `bash plugin/tests/test-agent-inbox.sh`

Expected: FAIL on the first missing desktop hook.

- [x] **Step 3: Implement the header inbox**

Add a compact icon button and popover. Flatten all worktree agents, include actionable statuses, sort by `statusTs`, group visually by project, and store opened event IDs under `marinaAgentInboxRead` in local storage.

- [x] **Step 4: Replace the two-minute row state with normalized status**

Render status-specific dot, label, summary count, and tooltip. Keep `agentActive(ts)` only when `status` is absent.

- [x] **Step 5: Run desktop contracts and syntax checks**

Run: `bash plugin/tests/test-agent-inbox.sh && bash plugin/tests/test-dash-state-ui.sh && node --check plugin/scripts/marina-web/app-5-sessions.js`

Expected: all PASS.

### Task 3: Mobile Inbox Sheet

**Files:**
- Modify: `plugin/scripts/marina_mobile.py`
- Test: `plugin/tests/test-agent-inbox.sh`
- Test: `plugin/tests/test-mobile-control.sh`

**Interfaces:**
- Consumes: mobile `sessions` with `status`, `statusTs`, and agent session `key`
- Produces: hamburger inbox count/button and `openInbox`/`closeInbox`/`selectInboxSession`

- [x] **Step 1: Add failing mobile contract assertions**

Assert the hamburger menu exposes the unread count, a sheet renders actionable agent sessions, and selecting an item invokes the existing session selection function.

- [x] **Step 2: Run and verify RED**

Run: `bash plugin/tests/test-agent-inbox.sh`

Expected: FAIL on the first missing mobile hook.

- [x] **Step 3: Add status fields to mobile sessions and render the sheet**

Copy normalized fields from each agent payload into its mobile session, derive stable event IDs client-side, persist read IDs, and select the matching existing session on activation.

- [x] **Step 4: Run mobile and full focused regression tests**

Run: `bash plugin/tests/test-agent-inbox.sh && bash plugin/tests/test-mobile-control.sh && bash plugin/tests/test-agents-section.sh && bash plugin/tests/test-dash-state-ui.sh`

Expected: all PASS.

- [x] **Step 5: Verify in a real browser**

Open desktop at `http://localhost:3900` and the tokenized mobile route. Confirm unread count, popover/sheet layout, item navigation, and no text overlap at desktop and phone widths.
