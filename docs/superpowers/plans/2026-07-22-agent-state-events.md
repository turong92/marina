# Agent State Events Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude and Codex session states prefer explicit lifecycle events, expose a narrow `blocked` state, and preserve native JSONL parsing as a compatibility fallback.

**Architecture:** A dependency-free hook recorder writes metadata-only, per-session JSONL under `~/.marina/agent-events`. `marina_sessions.py` merges the newest valid hook event with the existing bounded native transcript result, then the existing terminal-activity pass distinguishes `waiting` from `completed`. Desktop and mobile reuse their current Inbox flows and add `blocked` as one actionable state.

**Tech Stack:** Python 3 standard library, Claude/Codex `hooks.json`, Bash fixture tests, vanilla JavaScript, embedded mobile HTML.

## Global Constraints

- Never infer `blocked` from assistant prose.
- Store no prompt, response, tool input, tool output, token, or credential content.
- Hook failures must exit zero and must never interrupt Claude or Codex.
- Existing installations without journal rows must retain current native JSONL behavior.
- Add no daemon, database, package, or runtime dependency.
- Keep journal directories at `0700`, files at `0600`, at most 100 rows per session, and reject timestamps over five minutes in the future.

---

### Task 1: Metadata-Only Hook Journal

**Files:**
- Create: `plugin/scripts/marina_agent_events.py`
- Create: `plugin/scripts/marina-agent-event-hook.sh`
- Modify: `plugin/hooks/hooks.json`
- Create: `plugin/tests/test-agent-events.sh`

**Interfaces:**
- Produces: `record_hook_event(payload: dict[str, Any], *, environ: Mapping[str, str] | None = None, home: Path | None = None, now: float | None = None) -> dict[str, Any] | None`
- Produces: `latest_agent_event(source: str, sid: str, root: Path, *, home: Path | None = None, now: float | None = None) -> dict[str, Any] | None`
- Consumes: hook JSON fields `hook_event_name`, `session_id` or `thread_id`, `cwd`, `transcript_path`, and optional `notification_type`.

- [x] **Step 1: Write the failing hook journal test**

Create `plugin/tests/test-agent-events.sh` with Python fixtures that call `record_hook_event` for:

```python
claude_base = {
    "session_id": "claude-1",
    "cwd": str(root),
    "transcript_path": str(tmp / ".claude/projects/root/claude-1.jsonl"),
}
assert record_hook_event({**claude_base, "hook_event_name": "UserPromptSubmit"}, home=home, now=1000)["event"] == "working"
assert record_hook_event({**claude_base, "hook_event_name": "Notification", "notification_type": "permission_prompt"}, home=home, now=1001)["event"] == "blocked"
assert record_hook_event({**claude_base, "hook_event_name": "Stop"}, home=home, now=1002)["event"] == "ended"
assert record_hook_event({**claude_base, "hook_event_name": "Notification", "notification_type": "auth_success"}, home=home, now=1003) is None
```

Also assert Codex detection from a `.codex/sessions/.../rollout.jsonl` transcript, malformed input rejection, path-traversal session IDs, consecutive duplicate suppression, `0700`/`0600` modes, 100-row retention, root matching, and future-row rejection. Exercise the shell wrapper with invalid and valid stdin and assert both exit zero.

- [x] **Step 2: Run the journal test and verify RED**

Run: `bash plugin/tests/test-agent-events.sh`

Expected: FAIL because `marina_agent_events` and the hook wrapper do not exist.

- [x] **Step 3: Implement the journal module and fail-open wrapper**

Implement these constants and mappings in `marina_agent_events.py`:

```python
MAX_ROWS = 100
MAX_FUTURE_SECONDS = 300
VALID_SOURCES = {"claude", "codex"}
BLOCKED_REASONS = {"permission_prompt", "idle_prompt", "elicitation_dialog"}
HOOK_EVENTS = {
    "UserPromptSubmit": "working",
    "Stop": "ended",
}
```

Infer source from `.claude` or `.codex` components in `transcript_path` before checking `CODEX_THREAD_ID`/`CODEX_HOME` and `CLAUDE_PLUGIN_ROOT` environment fallbacks. Validate session IDs with `^[A-Za-z0-9._-]{1,160}$`, canonicalize `cwd`, and use `fcntl.flock` around read-trim-rewrite so concurrent macOS/Linux hooks cannot lose rows. Rewrite through a temporary file plus `os.replace` and keep only the newest 100 valid rows. The CLI path reads one JSON object from stdin and returns zero for every error.

Create `marina-agent-event-hook.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
command -v python3 >/dev/null 2>&1 || exit 0
python3 "$SCRIPT_DIR/marina_agent_events.py" 2>/dev/null || true
exit 0
```

- [x] **Step 4: Register lifecycle hooks**

Add command hooks for `UserPromptSubmit`, `Notification`, and `Stop` to `plugin/hooks/hooks.json`, each invoking `marina-agent-event-hook.sh` with `"async": false`. Synchronous registration is required because Codex skips asynchronous command hooks, and it preserves Claude lifecycle order instead of allowing delayed child processes to record a stale state after `Stop`. Keep `SessionStart` and `PreToolUse` unchanged.

- [x] **Step 5: Run the journal test and syntax checks**

Run:

```bash
bash plugin/tests/test-agent-events.sh
python3 -m py_compile plugin/scripts/marina_agent_events.py
bash -n plugin/scripts/marina-agent-event-hook.sh
python3 -m json.tool plugin/hooks/hooks.json >/dev/null
```

Expected: all commands exit zero and the test prints `PASS test-agent-events`.

- [x] **Step 6: Commit the hook journal**

```bash
git add plugin/scripts/marina_agent_events.py plugin/scripts/marina-agent-event-hook.sh plugin/hooks/hooks.json plugin/tests/test-agent-events.sh
git commit -m "feat(agent): record native lifecycle events"
```

### Task 2: Newest-Event State Resolution

**Files:**
- Modify: `plugin/scripts/marina_sessions.py`
- Modify: `plugin/tests/test-agent-inbox.sh`
- Test: `plugin/tests/test-agent-events.sh`

**Interfaces:**
- Consumes: `latest_agent_event(source, sid, root, home=None, now=None)` from Task 1.
- Produces: `merge_agent_status(native: dict[str, Any], event: dict[str, Any] | None, terminal_active: bool = False) -> dict[str, Any]`.
- Extends: `agent_status(path, source, terminal_active=False, *, sid="", root=None, event_home=None, now=None)`.

- [x] **Step 1: Add failing merge assertions**

Extend `test-agent-inbox.sh` so a newer blocked journal event overrides an older native Claude end turn, a newer working event clears blocked, an older journal event cannot override `task_complete`, an equal-timestamp journal event wins, a future event is ignored, and `ended` renders as `waiting` only when `terminal_active=True`.

Use explicit assertions such as:

```python
blocked = ms.agent_status(claude_done, "claude", sid="claude-1", root=tmp, event_home=events, now=event_ts + 1)
assert blocked == {"status": "blocked", "statusTs": event_ts, "statusReason": "permission_prompt"}
waiting = ms.merge_agent_status({"status": "completed", "statusTs": event_ts}, {"event": "ended", "ts": event_ts + 1}, True)
assert waiting["status"] == "waiting"
```

- [x] **Step 2: Run and verify RED**

Run: `bash plugin/tests/test-agent-inbox.sh`

Expected: FAIL because the journal merge interface is missing.

- [x] **Step 3: Implement deterministic event merging**

Move the existing native parsing body to `_native_agent_status`. Implement `merge_agent_status` with this mapping:

```python
EVENT_TO_STATUS = {
    "working": "working",
    "blocked": "blocked",
    "ended": "completed",
    "failed": "failed",
}
```

Choose the journal event only when its canonical root matches, its timestamp is not in the future window, and `event.ts >= native.statusTs`. Copy only a bounded enum reason into `statusReason`. Apply `terminal_active` after the merge so successful `completed` becomes `waiting`; never promote `blocked` or `failed`.

Update `agents_payload` to pass each session's `sid`, canonical root, and event home to `agent_status`. Preserve `activate_agent_payloads` for callers that obtain live terminal identities after payload construction.

- [x] **Step 4: Run focused state tests**

Run:

```bash
bash plugin/tests/test-agent-events.sh
bash plugin/tests/test-agent-inbox.sh
bash plugin/tests/test-agents-section.sh
bash plugin/tests/test-mobile-control.sh
```

Expected: all four tests pass.

- [x] **Step 5: Commit state resolution**

```bash
git add plugin/scripts/marina_sessions.py plugin/tests/test-agent-inbox.sh
git commit -m "feat(agent): resolve states from native events"
```

### Task 3: Blocked State In Desktop And Mobile Inbox

**Files:**
- Modify: `plugin/scripts/marina-web/app-1-core.js`
- Modify: `plugin/scripts/marina-web/app-5-sessions.js`
- Modify: `plugin/scripts/marina_mobile.py`
- Modify: `plugin/tests/test-agent-inbox.sh`
- Test: `plugin/tests/test-dash-state-ui.sh`
- Test: `plugin/tests/test-mobile-control.sh`

**Interfaces:**
- Consumes: agent payload `{status: "blocked", statusTs, statusReason}`.
- Produces: desktop `AGENT_STATUS_META.blocked`, desktop/mobile actionable Inbox membership, and mobile label `응답 필요`.

- [x] **Step 1: Add failing UI contract assertions**

Require all three UI sources to contain `blocked`, `응답 필요`, and actionable sets that include blocked. Add a Node VM assertion that a blocked session contributes to the attention count and desktop Inbox entries.

- [x] **Step 2: Run and verify RED**

Run: `bash plugin/tests/test-agent-inbox.sh`

Expected: FAIL on the first missing blocked UI contract.

- [x] **Step 3: Add the desktop blocked presentation**

Add:

```javascript
blocked: { dot: 'bad', label: '응답 필요', title: '권한 승인 또는 사용자 입력이 필요함' },
```

Include `blocked` in `agentInboxEntries()` and `agentsSummary()` actionable sets. Keep the existing event ID, local read state, sorting, and `openAgentTerminal` navigation unchanged.

- [x] **Step 4: Add the mobile blocked presentation**

Include `blocked` in `inboxSessions()` and add `blocked: "응답 필요"` to the mobile Inbox status label. Reuse `chooseSession`; do not add another navigation or chat path.

- [x] **Step 5: Run UI and syntax verification**

Run:

```bash
bash plugin/tests/test-agent-inbox.sh
bash plugin/tests/test-dash-state-ui.sh
bash plugin/tests/test-mobile-control.sh
node --check plugin/scripts/marina-web/app-1-core.js
node --check plugin/scripts/marina-web/app-5-sessions.js
python3 -m py_compile plugin/scripts/marina_mobile.py
```

Expected: all commands pass.

- [x] **Step 6: Commit blocked UI support**

```bash
git add plugin/scripts/marina-web/app-1-core.js plugin/scripts/marina-web/app-5-sessions.js plugin/scripts/marina_mobile.py plugin/tests/test-agent-inbox.sh
git commit -m "feat(agent): surface blocked sessions in inbox"
```

### Task 4: Roadmap, Full Regression, And Browser Verification

**Files:**
- Modify: `docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md`
- Modify: `docs/superpowers/plans/2026-07-22-agent-state-events.md`

**Interfaces:**
- Consumes: completed hook journal, resolver, and blocked UI.
- Produces: checked P1.4 roadmap status and fresh desktop/mobile verification evidence.

- [x] **Step 1: Run the focused regression set**

Run:

```bash
bash plugin/tests/test-agent-events.sh
bash plugin/tests/test-agent-inbox.sh
bash plugin/tests/test-agents-section.sh
bash plugin/tests/test-agent-history-pagination.sh
bash plugin/tests/test-mobile-control.sh
bash plugin/tests/test-access-http.sh
bash plugin/tests/test-auth-http.sh
bash plugin/tests/test-dash-state-ui.sh
git diff --check
```

Expected: every command exits zero.

- [x] **Step 2: Verify real hook fixtures without user data**

Start a temporary dashboard and create synthetic Claude and Codex session metadata, native JSONL, and hook rows under a temporary `MARINA_HOME`. Verify `/api/worktrees` returns `working`, `blocked`, `waiting`, `completed`, and `failed` with the expected timestamps and no journal payload text.

- [x] **Step 3: Verify desktop and mobile with Aside**

Use `snapshot(page, {interactive: true})` as the primary browser evidence. Confirm:

- desktop Inbox shows `응답 필요`, unread count, source badge, and opens the existing session;
- `/mobile` shows the same blocked item and selects the existing native chat;
- no overlap occurs at desktop and phone layouts;
- malformed or missing event files leave both pages usable.

- [x] **Step 4: Update roadmap and plan checkboxes**

Mark P1.4 complete in `2026-07-14-orca-comparison-and-roadmap-design.md`, explicitly noting that Codex blocked remains capability-based when no stable native event is emitted. Mark every completed step in this plan.

- [x] **Step 5: Commit verification documentation**

```bash
git add docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md docs/superpowers/plans/2026-07-22-agent-state-events.md
git commit -m "docs(agent): complete native state events"
```

- [x] **Step 6: Final verification before integration**

Run:

```bash
set -e
for test in plugin/tests/test-*.sh; do
  bash "$test"
done
git diff --check
git status --short --branch
```

Expected: every repository shell test exits zero, `git diff --check` is clean, and the branch contains only the planned commits. Do not push or update the installed plugin until explicitly requested.

## Verification Evidence (2026-07-22)

- Focused regression passed: lifecycle journal, state merge and Inbox contracts, agent session discovery/history, mobile control, access/auth HTTP boundaries, and dashboard state UI.
- The complete `plugin/tests/test-*.sh` shell suite passed: 144/144 tests, followed by a clean `git diff --check`.
- The same isolated synthetic dashboard used for desktop and mobile Aside verification contained a malformed journal row. Both browser pages remained usable while the malformed row was ignored, and the dashboard returned `working`, `blocked`, `waiting`, `completed`, and `failed` through both worktree and mobile state APIs with expected timestamps.
- Aside desktop verification showed actionable Inbox entries with source badges and the exact `응답 필요` label; selecting the blocked Claude item marked it read and opened the existing agent terminal.
- Aside mobile verification at phone layout showed the same actionable states without overlap; selecting the blocked item opened the existing native chat with its prior turns and composer. Missing event files also used the native fallback.
- Codex `blocked` remains capability-based: when its host does not emit a stable approval or user-input lifecycle event, Marina preserves the other native state and does not infer a blocker from text.
- `git status --short --branch` showed a clean working tree with only the planned commits ahead of `origin/main`. No push or installed-plugin update occurred.
