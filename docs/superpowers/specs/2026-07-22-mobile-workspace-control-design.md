# Mobile Workspace Control Design

## Goal

Make Marina Mobile usable as the primary remote control for local development: switch projects and agent sources without navigation churn, inspect and control Compose services, follow and steer long-running sessions, and read long transcripts comfortably on a phone.

## Product Shape

Marina Mobile remains a compact operational surface, not a second desktop dashboard. The persistent shell has two dense rows:

```text
[Marina/back] [project selector]                 [services 4/6]
[All] [Codex] [Claude] [Terminal]
```

The same context controls remain available in the session list and chat. Opening a service, model selector, or session-specific subagent list uses a bottom sheet so the chat does not lose its place.

## Navigation

- Selecting a project or source updates the visible sessions immediately; it does not introduce an intermediate page.
- Opening a chat pushes an in-app history entry. Browser back from chat returns to the Marina session list.
- The first browser back from the main list is intercepted and shows `한 번 더 누르면 Marina를 나갑니다`. A second back within two seconds is allowed to leave.
- Browser APIs cannot guarantee that every platform gesture is cancellable; installed/PWA display remains the strongest containment.
- Re-entering a session and focusing the composer both move immediately to the latest message.

## Services

- The shell shows the current project's running/defined service count.
- Tapping it opens a bottom sheet with current state and Start, Stop, Restart, and Open actions.
- Controls reuse Marina's existing Compose lifecycle implementation and gateway-first URL resolution. Mobile adds only an authenticated, project-scoped adapter where the desktop response shape cannot be reused directly.
- Actions are restricted to services discovered for the selected Marina root. Arbitrary Compose arguments or filesystem paths are not accepted from the browser.

## Chat Lifecycle

- The app uses a visual-viewport-sized shell. The transcript is the only scrolling region; the composer is a normal final grid row rather than page-fixed content.
- `VisualViewport`, `100dvh`, and safe-area insets keep the composer above iOS and Android virtual keyboards.
- Status above the composer distinguishes sending, working with elapsed time, waiting for input, complete, interrupted, and failed.
- While an agent has a live Marina PTY, sending another message writes to that PTY as steering. Otherwise it starts the normal resume flow.
- Stop sends Ctrl-C to the live PTY and preserves the underlying Claude/Codex session. It never kills the whole agent session.

## Session Settings

- A compact control shows source, model, and effort for the selected session.
- Claude resume receives `--model` and `--effort`; Codex resume receives `--model` and `-c model_reasoning_effort=...`.
- Settings are persisted by session and restored on reconnect. The CLI/default configuration remains authoritative until the user chooses an override.
- A setting changed while work is active applies to the next resume/turn and is labelled accordingly; it does not mutate the in-flight process.
- Model choices come from locally discoverable CLI/session metadata with a manual value fallback. Effort choices are constrained to values supported by the selected source/model when that metadata is available.

## Transcript Presentation

- Markdown is rendered for headings, emphasis, lists, block quotes, links, inline code, and fenced code blocks.
- Rendering is offline and sanitized. No remote CDN is required; raw HTML and unsafe URL schemes are removed.
- Short messages stay expanded. Older long messages default to a four-line preview; the latest user/assistant exchange and an active response stay expanded.
- Collapsed long bodies are rendered lazily. Code blocks expose a copy action and horizontal scrolling.
- Subagents are scoped to their parent session. A compact session row summarizes counts and state; individual subagents and their turns remain collapsed until opened.

## Removed Or Relocated Controls

- The ambiguous notification action is removed. Foreground status remains visible without promising background push delivery.
- The global `작업 에이전트` menu item is removed. Subagent activity appears only in the owning session and only when records exist.
- The hamburger is no longer the primary route for project, source, services, or session actions.

## Verification

- Contract tests cover service scope, lifecycle commands, steering, Ctrl-C interruption, model/effort argument construction, and persisted overrides.
- HTML behavior tests cover navigation guard, viewport handling, Markdown sanitization, lazy collapse, and session-scoped subagents.
- Aside verifies a phone viewport: chat opens at the bottom, keyboard leaves the composer visible, context switching is immediate, sheets are usable without overlap, and service/session controls report visible state changes.
