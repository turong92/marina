# Mobile Agent Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show native Codex and Claude work events in collapsible mobile groups while keeping only the latest question and answer expanded.

**Architecture:** Extend selected-session transcript pages with a backward-compatible `timeline` array. Normalize native message and tool events on the server, then derive collapsed previous-conversation and activity sections in the embedded mobile client.

**Tech Stack:** Python 3.9, JSONL/mmap pagination, embedded HTML/CSS/JavaScript, shell and Node regression tests, Playwright browser QA.

## Global Constraints

- Keep `turns` unchanged for desktop and compatibility callers.
- Do not scan transcripts from `/mobile/api/state`.
- Redact and bound every tool input, output, and patch before returning it.
- Keep the latest user prompt and latest assistant answer expanded.
- Keep activity and older conversation collapsed by default.

---

### Task 1: Native Timeline Normalization

**Files:**
- Create: `plugin/tests/test-agent-timeline.sh`
- Modify: `plugin/scripts/marina_sessions.py`

**Interfaces:**
- Produces: `_transcript_page(...)["timeline"] -> list[dict[str, Any]]`
- Preserves: `_transcript_page(...)["turns"] -> list[dict[str, str]]`

- [x] Add fixtures containing Codex `function_call`/`custom_tool_call` and Claude `tool_use`/`tool_result` pairs, including Skill, command, patch, failure, missing result, and a redacted secret.
- [x] Run `bash plugin/tests/test-agent-timeline.sh`; expect failure because `timeline` is absent.
- [x] Add source-aware call/result extraction, stable IDs, activity classification, bounded detail/result fields, and forward correlation after backward page collection.
- [x] Assert chronological ordering, running/completed/failed states, categories, redaction, unique IDs, and unchanged legacy turns.
- [x] Re-run the focused test; expect `PASS test-agent-timeline`.

### Task 2: Pagination Contract

**Files:**
- Modify: `plugin/tests/test-agent-history-pagination.sh`
- Modify: `plugin/scripts/marina_sessions.py`

**Interfaces:**
- Consumes: normalized timeline items from Task 1.
- Produces: pages bounded by message count and activity count with the existing byte cursor.

- [x] Add assertions that tool-heavy pages include their surrounding latest prompt/answer, timeline IDs remain unique across pages, and `/mobile/api/state` remains transcript-lazy.
- [x] Run `bash plugin/tests/test-agent-history-pagination.sh`; the shared Task 1 page implementation already satisfied the new assertions.
- [x] Collect native rows while scanning to the existing message limit, cap returned activities, and preserve cursor progress even for malformed or tool-only rows.
- [x] Re-run timeline and pagination tests; expect both to pass.

### Task 3: Collapsible Mobile Timeline

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Consumes: `page.timeline`, with fallback conversion from `page.turns`.
- Produces: `timelineSections(items)` and collapsible previous-conversation/activity markup.

- [x] Add failing source assertions for a collapsed previous-conversation row, categorized activity summary, independently expandable detail, and latest-pair rendering.
- [x] Run `bash plugin/tests/test-mobile-control.sh`; expect failure on the missing timeline UI.
- [x] Merge timeline pages by stable ID, derive the latest user/assistant pair, move intermediate assistant progress notes into the current activity group, and render older content in one closed `<details>` element.
- [x] Render consecutive work events in closed `<details>` groups with category counts, status, escaped targets, and bounded code/detail blocks.
- [x] Preserve pending-message de-duplication, scroll position, older-page loading, rich links, opened details, and the fixed composer.
- [x] Re-run mobile, timeline, and pagination tests; expect all to pass.

### Task 4: Live Verification And Commit

**Files:**
- Modify: `docs/superpowers/plans/2026-07-22-mobile-agent-timeline.md`

**Interfaces:**
- Produces: verified dashboard behavior at `http://127.0.0.1:3900/mobile`.

- [x] Run `test-agent-timeline.sh`, `test-agent-history-pagination.sh`, `test-mobile-control.sh`, `test-mobile-admin-http.sh`, and `test-agent-inbox.sh`.
- [x] Run Python compilation, shell syntax checks, and `git diff --check`.
- [x] Restart the dashboard from this worktree and verify a real Codex session plus a 390 px mobile viewport.
- [x] Mark this checklist complete and commit the implementation without pushing.
