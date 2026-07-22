# Mobile Scroll And Provider Usage Design

## Goal

Make mobile polling preserve the user's reading position and show provider account limits for Codex and Claude, including Claude's separate Fable 5 weekly allowance.

## Scope

- Preserve the visible conversation while polling appends or updates messages.
- Keep explicit follow-latest behavior when the user is at the bottom or sends a message.
- Show Codex five-hour and weekly account limits.
- Show Claude five-hour, all-model weekly, and Fable 5 weekly limits.
- Keep the existing per-session context-window usage in the same panel.

## Design

The server returns a provider-level `accountUsage` object alongside the existing session context usage. Codex reads the newest valid `rate_limits` record from local rollout logs and maps 300 minutes to `fiveHour` and 10080 minutes to `weekly`. Claude reads the Claude HUD usage cache for the common five-hour and weekly windows, and accepts the optional Fable-specific percentage and reset fields when present. Missing or stale values are returned as unavailable rather than inferred from token counts.

The mobile usage panel renders a provider section with one row per available window. Each row shows used percentage, remaining percentage, and reset time. The context section remains session-specific and is not mixed with account quota percentages.

Polling captures a stable conversation anchor and the user's follow-latest intent before replacing transcript HTML. A programmatic scroll is marked as internal until the next animation frame, so it cannot switch the intent back to follow-latest. When the user is reading history, Marina restores the first stable message ID to the same viewport offset even if pagination regroups its exchange; when the user is following the bottom, the transcript stays at the latest message.

## Failure Handling

- Provider usage collection is best-effort and never blocks `/mobile/api/state` or transcript polling.
- Invalid, missing, or stale usage data renders as `확인 안 됨` with no fake percentage.
- A provider usage fetch failure keeps the last known value only within its cache freshness window.
- Fable usage is optional because not every Claude account or API response exposes that model-specific window.

## Verification

- Unit tests cover Codex window mapping, Claude cache parsing, Fable fields, stale/missing values, and the existing context usage behavior.
- Mobile HTML tests assert the provider usage rows and scroll intent/anchor functions.
- Browser verification checks that polling while scrolled above the bottom leaves the same exchange visible and that Codex/Claude panels render independently.
