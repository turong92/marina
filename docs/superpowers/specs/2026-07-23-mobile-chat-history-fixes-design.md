# Mobile Chat History Fixes Design

## Goal

Make Marina Mobile chat use the available viewport, preserve the reader's
position during polling, and keep paginated questions and answers visible while
collapsing only the work performed between them.

## History Model

Marina keeps the existing byte-cursor transcript API and 40-message page size.
It does not fetch the complete transcript when a chat opens.

The client combines only the pages it has loaded, then partitions their ordered
timeline at user messages. Each partition becomes one exchange containing:

1. the user question;
2. activity emitted after that question; and
3. assistant messages up to the next user question.

Every loaded user question is always visible as a right-aligned bubble. Its
final assistant answer is always visible as a left-aligned bubble. Commands,
skills, diffs, tool calls, progress messages, and other activity between them
are grouped into one collapsed work row. Expanding that row reveals individual
activity details. Neither an exchange-level accordion nor a catch-all
`Previous conversation` container is used.

When the reader scrolls to the top, Marina fetches one previous page and prepends
it. The same partitioning runs over the combined loaded pages, so an exchange
split at a page boundary joins naturally after the older page arrives. A compact
loading row appears only while that request is active. The old `Previous
messages` button is removed.

## Scroll Ownership

The transcript element is the only scrolling surface. Conversation sequences
and activity details use `flex: 0 0 auto` so opening work increases transcript scroll height
instead of shrinking and clipping their content.

Before prepending a history page, the client records the first visible exchange,
its first stable message ID, and their viewport offsets. After rendering, it
prefers the message anchor so a page-boundary regroup can change the exchange ID
without moving the reader. This avoids jumps while loading older pages.

Polling never opts the reader back into bottom-follow mode. Bottom-follow is an
explicit state:

- enabled when entering a session, sending a message, tapping `New messages`, or
  manually scrolling fully to the bottom;
- disabled as soon as the user scrolls away from the bottom;
- while disabled, polling preserves the current anchor and only shows the `New
  messages` affordance.

Focusing the composer does not force a bottom jump unless bottom-follow is
already enabled.

## Compact Chat Header

List mode keeps the project strip, source tabs, and service status. Chat mode
hides all three and uses one compact row:

- back button;
- truncated session title;
- token-usage icon button.

The duplicate title, subtitle, and permanent usage rail inside the chat are
removed. Pressing the usage button opens a small anchored panel containing
context percentage, used tokens, remaining tokens, and the existing progress
bar. It closes on a second press, outside press, back navigation, or session
change.

## Error Handling

A failed previous-page request leaves existing exchanges untouched and shows a
small inline failure status at the top. Scrolling to the top again retries it.
Usage fetch failures leave the panel values as dashes without affecting chat.

## Compatibility And Safety

- Server transcript and usage endpoints remain unchanged.
- Desktop transcript rendering remains unchanged.
- Activity detail redaction and size limits remain unchanged.
- Pending-message de-duplication, native links, agent controls, and composer
  behavior remain available.

## Verification

Regression tests cover always-visible question/answer bubbles, activity-only
collapse, page-boundary exchange joining, old-button removal, single-surface
scrolling, bottom-follow transitions, anchor restoration, compact chat mode,
and usage-panel toggling. Browser QA uses a live working Codex session at 390 x
844 and verifies opening middle activity, loading one older page, polling while
scrolled up, keyboard focus, and composer non-overlap.
