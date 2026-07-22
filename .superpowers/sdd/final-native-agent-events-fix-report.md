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
