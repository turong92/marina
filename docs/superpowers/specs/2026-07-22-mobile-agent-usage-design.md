# Mobile Agent Usage Design

## Goal

Show reliable per-session context percentage, used tokens, and remaining tokens
in Marina Mobile without slowing the session list. Keep interruption
limited to the selected current turn when Marina can address that turn safely.

## Data Sources

- Codex: read the newest `event_msg/token_count` record. Use
  `last_token_usage.total_tokens` for used tokens and `model_context_window` for
  the limit. The lifetime API-call total is intentionally not shown.
- Claude: use the newest assistant message usage for current context. Count input,
  cache creation, cache read, and output tokens once; duplicated records for the
  same response do not require a full-history scan.
- Claude context limits are reported only when a local model option explicitly
  carries a `[Nk]` or `[Nm]` context suffix. Unknown limits remain unknown.

## Delivery

Usage is loaded from a token-protected `/mobile/api/usage` endpoint only for the
selected agent session. The session-list endpoint must not scan full transcripts.
The chat header shows a compact usage rail with context percent, used tokens, and
remaining tokens. Missing values render as `-`, not estimates.

## Interruption Safety

Marina PTY sessions remain interruptible with scoped `Ctrl+C`. App-owned sessions
are shown as working but not interruptible until a source adapter can identify both
the owning runtime and the exact active turn. Process-wide signals are forbidden.

## Testing

- Parser fixtures cover Codex native counters, Claude latest message records,
  known/unknown context limits, and malformed input.
- HTTP tests cover authentication, root/session ownership, and response shape.
- Mobile source assertions cover lazy loading, number formatting, and missing data.
