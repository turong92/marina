# Mobile Agent Timeline Design

## Goal

Make Marina Mobile sessions readable like the native Codex and Claude apps:
keep the latest user prompt and latest assistant answer visible, collapse older
conversation into one summary, and expose tool work such as skills, commands,
file edits, diffs, and subagent calls as compact expandable activity groups.

## User Experience

The selected session shows, in order:

1. One collapsed `Previous conversation` row for all loaded messages before the
   latest user/assistant pair. Its summary includes message and activity counts.
2. The latest user prompt.
3. A collapsed activity row for work performed for that prompt. The summary
   reports the total and useful categories, for example `Work 12 · Skill 2 ·
   Diff 3`.
4. The latest assistant answer, expanded.

Opening an activity row reveals chronological entries. Each entry has a short
label, optional target, and a secondary result preview. Commands and patches use
monospace text. Long input, output, and diff content remains independently
expandable so a large tool result cannot take over the mobile viewport.

When an answer is still in progress, the latest prompt and current collapsed
activity group remain visible. Existing working status and interruption controls
remain unchanged.

## Normalized Data

The native transcript parser adds an ordered mobile timeline while preserving
the existing `turns` response for desktop and compatibility callers.

Each timeline item has a stable byte-offset-derived `id` and one of two shapes:

```json
{"kind":"message","role":"user|assistant","text":"..."}
{"kind":"activity","activityType":"skill|command|diff|file|agent|tool","label":"...","detail":"...","result":"...","status":"completed|running|failed"}
```

Codex normalization reads `function_call`, `custom_tool_call`, matching outputs,
and patch events. Claude normalization reads assistant `tool_use` blocks and
matching user `tool_result` blocks. Explicit Skill calls are categorized as
skills; commands that load a `skills/.../SKILL.md` file are also recognized as
skill use. Patch application and Edit/Write operations are categorized as diffs
or file changes. Unknown tools remain visible under the generic tool category.

Tool calls and results are correlated by their native call ID. Missing results
produce a running entry rather than dropping the call. Failed native results are
marked failed.

## Pagination And Performance

Timeline extraction remains lazy and runs only for the selected session through
`/mobile/api/transcript`. `/mobile/api/state` does not scan transcripts.

Backward pagination continues to use byte cursors. A page is bounded by message
count, activity count, per-field character limits, and total response size so a
tool-heavy turn still returns the surrounding prompt and answer. The client
merges timeline items by stable ID and retains the existing `Previous messages`
pagination control.

## Safety

All labels, inputs, outputs, and patches pass through Marina's existing secret,
token, email, and transcript redaction before leaving the server. Structured
parsing is used for native JSON fields; shell text is displayed but never
executed. HTML is escaped before rich-text or code rendering.

## Compatibility

- Existing desktop transcript viewers continue consuming `turns` unchanged.
- Existing pending-message de-duplication continues to compare message items.
- Subagent details remain in the current subagent sheet; subagent launches also
  appear as lightweight activity entries in the main timeline.
- The context usage rail and session controls keep their current layout.

## Verification

Fixture tests cover Codex and Claude tool/result correlation, skill recognition,
diff/file classification, redaction, missing results, and pagination ordering.
Mobile source tests cover the collapsed previous-conversation row, collapsed
activity groups, latest-pair expansion, and long-detail expansion. Final QA uses
the live dashboard at a 390 px viewport and verifies that opening and closing
groups does not move or cover the composer.
