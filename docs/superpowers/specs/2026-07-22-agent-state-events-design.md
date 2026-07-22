# Agent State Events

## Goal

Marina should classify Claude and Codex sessions from explicit lifecycle events whenever those events exist, while preserving native transcript parsing as a compatibility fallback. The shared states are `working`, `blocked`, `waiting`, `completed`, `failed`, and `idle`.

This phase improves state accuracy for the existing desktop and mobile Activity Inbox. Closed-page push delivery remains a separate R0.3 phase and will consume the event contract defined here.

## Status Contract

| State | Meaning |
|---|---|
| `working` | The agent is actively processing a user turn. |
| `blocked` | A native event explicitly says user approval or input is required. Marina never infers this state from prose. |
| `waiting` | The turn ended successfully and its resumable Marina terminal is still alive. |
| `completed` | The turn ended successfully and no resumable Marina terminal is alive. |
| `failed` | The native source reports an aborted turn, API error, stream error, or failed stop hook. |
| `idle` | No reliable current event exists. |

`blocked` is intentionally narrow. A normal final response remains `waiting` or `completed`, even when its prose contains a question mark. If Codex does not expose a stable approval or user-input event for a session, Marina leaves the session at its other native state rather than guessing.

## Source Mapping

Claude sessions are identified by canonical worktree root plus `cliSessionId`. Their native transcript remains `~/.claude/projects/<project-slug>/<session-id>.jsonl`.

- `UserPromptSubmit` or a newer user/assistant/tool event maps to `working`.
- `Notification` maps to `blocked` only for an allowlist of permission, idle-input, or elicitation notification types.
- `Stop`, `stop_hook_summary`, or `end_turn` maps to successful turn end.
- `api_error` or a stop hook error maps to `failed`.

Codex sessions are identified by canonical `session_meta.cwd` plus `session_meta.id`. Their native rollout remains `~/.codex/sessions/**/rollout-*.jsonl`.

- `task_started` maps to `working`.
- A stable native approval or request-user-input event maps to `blocked` when present.
- `task_complete` maps to successful turn end.
- `turn_aborted`, `error`, or `stream_error` maps to `failed`.

The current local Codex rollouts expose reliable `task_started`, `task_complete`, and `turn_aborted` events but no consistent blocked event. The implementation therefore keeps blocked detection capability-based and does not parse assistant text.

## Event Journal

Add one fail-open hook recorder shared by supported Claude and Codex lifecycle hooks. It reads JSON from stdin and writes metadata-only JSONL under `~/.marina/agent-events/<source>/<session-id>.jsonl`.

Each row contains only:

```json
{
  "source": "claude",
  "sid": "session-id",
  "root": "/canonical/worktree",
  "event": "blocked",
  "reason": "permission_prompt",
  "ts": 1784682000
}
```

Prompt text, tool input, tool output, transcript content, tokens, and credentials are never copied. The directory is mode `0700`, files are mode `0600`, malformed input produces no row, and every recorder failure exits zero so an agent session is never blocked by Marina. Consecutive duplicate `(root, event, reason)` rows are suppressed and each file retains only the newest 100 rows. Rows are accepted only when their source and session ID match the journal path; foreign, malformed, and more-than-five-minutes-future rows are discarded before retention. Journal reads use a bounded tail so corrupt files cannot grow dashboard polling memory.

Journal traversal is descriptor-relative after the HOME directory is opened: `.marina`, `agent-events`, and the source directory are opened or created one component at a time with `O_DIRECTORY | O_NOFOLLOW`. Permissions are applied with `fchmod` to those retained directory descriptors. Journal, lock, and temporary names are opened relative to the retained source descriptor with `O_NOFOLLOW`; replacement and cleanup use the same directory descriptor. This prevents a concurrent path replacement from redirecting reads, writes, or permission changes to an external target. A reader never creates a missing journal hierarchy; it creates a lock only after finding an existing journal to synchronize with a writer.

Lifecycle hooks stay synchronous for Codex compatibility and event ordering, with a two-second host timeout. The recorder uses a much shorter bounded, nonblocking sidecar-lock retry window and fails open when it cannot acquire the lock, leaving margin for Python startup without stalling an agent turn. `plugin/hooks/hooks.json` remains the Claude configuration and includes its supported `Notification` hook using `CLAUDE_PLUGIN_ROOT`. The Codex manifest explicitly selects `./hooks/codex-hooks.json`, which contains only `SessionStart`, `PreToolUse`, `UserPromptSubmit`, and `Stop` using `PLUGIN_ROOT`; it deliberately omits unsupported `Notification`.

Hook configuration records only events supported by the host. Unknown or absent lifecycle events are harmless because native transcript parsing remains authoritative when no newer journal event exists. Codex project hooks continue to load only in trusted projects, matching Codex's existing hook trust boundary.

## Resolution Order

`agent_status` reads a bounded tail from both the native transcript and the optional Marina journal. It chooses the newest reliable event by timestamp, with this order only when timestamps are equal:

1. explicit hook journal event;
2. explicit native transcript event;
3. recent file mtime fallback;
4. `idle`.

A successful turn-end event first normalizes to an internal ended state. The existing live terminal identity set then renders it as `waiting` when resumable or `completed` otherwise. A newer user-submit or task-start event clears an older `blocked` state. Out-of-order, malformed, missing, or future-dated rows are ignored without breaking the worktree payload.

## UI Behavior

Desktop and mobile treat `blocked` as actionable alongside `waiting`, `completed`, and `failed`. The label is `응답 필요`, it sorts by `statusTs`, participates in the existing unread event key, and opens the existing native session flow. No new page, database, poller, or daemon is added.

The Inbox continues to derive read state in browser local storage. Status truth remains server-side and read state remains presentation-only.

## Security And Compatibility

- No runtime dependency is added; Python standard library and the existing hook mechanism are sufficient.
- Existing installations without the new hooks retain native JSONL and mtime behavior.
- Hook trust and host support are capability boundaries, not reasons to disable the dashboard.
- Journal paths are derived from validated source/session identifiers and never from raw path fragments. Descriptor-relative traversal rejects symlinked journal directories, journal files, and lock files without following them.
- Events older than the native state do not override it.
- Events more than five minutes in the future are ignored.

## Verification

- Fixture tests cover Claude and Codex native mappings, hook precedence, blocked clearing, duplicate suppression, malformed rows, future timestamps, and bounded retention.
- Desktop and mobile contract tests require the `blocked` label and actionable Inbox inclusion.
- Existing agent history, Inbox, mobile control, authentication, and terminal tests remain green.
- Aside browser verification checks desktop and mobile blocked items, unread counts, navigation to the existing session, and no layout overlap.

## Non-Goals

- Inferring questions or blockers from natural-language output.
- Replacing Claude or Codex native transcript discovery.
- Sending Web Push, APNs, email, Slack, or other remote notifications in this phase.
- Persisting Inbox read state on the server.
- Introducing a background watcher or shared event database.
