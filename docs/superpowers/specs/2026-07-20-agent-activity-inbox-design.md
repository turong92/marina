# Agent Activity Inbox

## Goal

Show Claude and Codex work that is running or needs attention across all registered Marina projects, without relying on the existing two-minute file timestamp heuristic.

## State Model

Marina derives one normalized state from each native session log:

- `working`: a turn started or produced tool/reasoning activity and has not ended.
- `waiting`: a turn ended successfully while its Marina agent terminal is still alive and can accept the next prompt.
- `completed`: a turn ended successfully and no live Marina agent terminal exists.
- `failed`: the latest turn ended with an explicit API error or abort.
- `idle`: no reliable boundary event was found.

Codex uses `task_started`, `task_complete`, and `turn_aborted`. Claude uses user/assistant turn boundaries, `stop_reason=end_turn`, `stop_hook_summary`, and `api_error`. Recent file activity is a fallback only when a native boundary is unavailable.

Each agent payload includes `status`, `statusTs`, and an optional `statusReason`. The existing `ts` remains the session recency value.

## Inbox

The inbox is derived from the same agent payloads already returned for worktrees. It contains `waiting`, `completed`, and `failed` sessions across every project, newest first. `working` remains visible in project cards and session lists but does not create an attention item.

Opening an inbox item stores its event key (`source:sid:status:statusTs`) in browser local storage. Read state is presentation-only and does not alter the native agent session. A new terminal state transition creates a new event key and becomes unread again.

## Desktop

Add a compact inbox button to the global header with an unread count. Its popover groups attention items by project and shows source, normalized state, title, and relative time. Selecting an item closes the popover and opens the existing agent terminal flow for that worktree and session.

Agent rows consume the normalized status. The old two-minute activity check remains only as a compatibility fallback for older payloads.

## Mobile

Add an inbox entry and unread count to the existing hamburger menu. It opens a full-height sheet optimized for phone scanning. Selecting an item closes the sheet and selects the existing native chat session, preserving the current composer and transcript behavior.

## Failure And Compatibility

Malformed or truncated log lines are skipped. Missing logs produce `idle` without breaking the worktree response. Sessions without a resumable session ID remain display-only and are excluded from actionable inbox entries. Older Marina payloads continue to render through the timestamp fallback.

## Verification

- Fixture tests cover Claude and Codex working, waiting, completed, failed, and malformed-log cases.
- Contract tests verify status fields and desktop/mobile inbox hooks.
- Existing dashboard, terminal, mobile control, and gateway tests remain green.
- Browser verification checks unread count, opening an item, destination navigation, and narrow mobile layout.
