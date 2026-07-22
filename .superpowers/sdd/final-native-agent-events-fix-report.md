# Final Native Agent Events Fix Report

## RED Evidence

- `bash plugin/tests/test-agent-events.sh` exited 1 before production edits because the real nullable-transcript Codex `PermissionRequest` fixture returned `None`.
- `bash plugin/tests/test-agent-inbox.sh` exited 1 before production edits with `AssertionError: [-1]`, showing the replacement-descriptor native transcript read was unbounded.
- `bash plugin/tests/test-agents-section.sh` exited 1 before production edits because its real Codex `PermissionRequest` fixture returned `None`.
- An isolated duplicate journal regression exited 1 before production edits: repeated `Stop` returned the stale `ts=100` row instead of the current `ts=200` row.

## GREEN Evidence

- `bash plugin/tests/test-agent-events.sh` exited 0. It covers timestamp-refreshing duplicate coalescence, bounded retention, actual Codex `session_id` plus `transcript_path: null` `PermissionRequest` and `PostToolUse` payloads, and exact synchronous Codex hook registration.
- `bash plugin/tests/test-agent-inbox.sh` exited 0. It covers native-working interleavings followed by repeated blocked/ended hooks and the descriptor replacement bounded-read regression.
- `bash plugin/tests/test-agents-section.sh` exited 0 with the real Codex approval payload path.
- `bash plugin/tests/test-mobile-control.sh` exited 0.
- `python3 -m py_compile plugin/scripts/marina_agent_events.py plugin/scripts/marina_sessions.py` exited 0.
- `bash -n plugin/scripts/marina-agent-event-hook.sh` exited 0.
- JSON validation exited 0 for `plugin/hooks/hooks.json`, `plugin/hooks/codex-hooks.json`, `plugin/.claude-plugin/plugin.json`, and `plugin/.codex-plugin/plugin.json`.
- `git diff --check` exited 0.

## Final Review Follow-Up: Bounded Codex Lifecycle Overhead (2026-07-22)

### RED Evidence

- Added focused regressions to `plugin/tests/test-agent-events.sh` before changing the recorder: exact `PermissionRequest` and `PostToolUse` matchers, Claude cross-source rejection, blocked-to-working timestamp ordering, no-journal/no-rewrite `PostToolUse`, and an oversized real wrapper invocation.
- `bash plugin/tests/test-agent-events.sh` exited 1 before production edits at the new Claude `PermissionRequest` negative fixture (`AssertionError` in the Python fixture block). The existing source-neutral `_event_from_payload` incorrectly produced `blocked(permission_prompt)` for a payload identified as Claude. At that point the manifest still used `"matcher": "*"` for both Codex lifecycle hooks and `main()` still called unbounded `json.load(sys.stdin)`.

### GREEN Evidence

- Scoped both Codex approval lifecycle entries to the exact `^(Bash|apply_patch|Edit|Write|mcp__.*)$` matcher while keeping `async: false` and `timeout: 2`.
- `PermissionRequest` and `PostToolUse` are now source-scoped to Codex. Shared `UserPromptSubmit`/`Stop` and Claude `Notification` behavior remain unchanged.
- `PostToolUse` opens an existing same-session journal without creating one, checks its newest valid canonical row for the matching root under the sidecar lock, and writes `working` only after `blocked`; ordinary/no-journal calls return `None` without a journal rewrite or `fsync`.
- Added documented `MAX_HOOK_INPUT_BYTES = 1 MiB`; `main()` requests at most `MAX_HOOK_INPUT_BYTES + 1` bytes from `sys.stdin.buffer` before decoding and fails open without a row when over the bound. The wrapper regression sends 1 MiB plus one byte, exits zero in under three seconds, and creates no journal; ordinary valid wrapper input still records.
- `bash plugin/tests/test-agent-events.sh` exited 0 after the production edits. It covers the new source, matcher, journal-inode/no-rewrite, timestamp, oversized-wrapper, existing retention, lock, malformed-input, FIFO, symlink, hard-link, and descriptor-race coverage.
- `bash plugin/tests/test-agent-inbox.sh`, `bash plugin/tests/test-agents-section.sh`, and `bash plugin/tests/test-mobile-control.sh` each exited 0 after the change, preserving state merge, desktop/mobile Inbox, agent discovery, transcript, and mobile-control contracts.

## Changed Paths

- `README.md`
- `docs/superpowers/plans/2026-07-22-agent-state-events.md`
- `docs/superpowers/specs/2026-07-22-agent-state-events-design.md`
- `plugin/hooks/codex-hooks.json`
- `plugin/scripts/marina_agent_events.py`
- `plugin/scripts/marina_sessions.py`
- `plugin/tests/test-agent-events.sh`
- `plugin/tests/test-agent-inbox.sh`
- `plugin/tests/test-agents-section.sh`
- `.superpowers/sdd/final-native-agent-events-fix-report.md`
