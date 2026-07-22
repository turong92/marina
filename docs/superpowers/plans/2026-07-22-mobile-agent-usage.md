# Mobile Agent Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add source-aware agent token telemetry to Marina Mobile while preserving lazy loading and scoped interruption safety.

**Architecture:** Parse native Codex and Claude JSONL usage into one `agentUsage` shape. Expose it through a selected-session endpoint and render a compact header rail without adding work to the session-list hot path.

**Tech Stack:** Python 3.9, JSONL, `ThreadingHTTPServer`, embedded HTML/CSS/JavaScript, shell regression tests.

## Global Constraints

- Do not scan complete transcripts in `/mobile/api/state`.
- Do not estimate missing context-window limits.
- Do not signal an app process unless the exact selected turn is addressable.

---

### Task 1: Source-Aware Usage Parser

**Files:**
- Modify: `plugin/scripts/marina_sessions.py`
- Test: `plugin/tests/test-agent-usage.sh`

**Interfaces:**
- Produces: `agent_usage(root: Path, source: str, sid: str) -> dict[str, Any]`

- [ ] Add failing Codex and Claude JSONL fixture assertions.
- [ ] Run `bash plugin/tests/test-agent-usage.sh` and confirm the missing parser failure.
- [ ] Implement newest-native-usage parsing and context-limit handling.
- [ ] Re-run the focused test and confirm it passes.

### Task 2: Lazy Mobile API

**Files:**
- Modify: `plugin/scripts/marina_mobile.py`
- Modify: `plugin/scripts/marina_handler.py`
- Test: `plugin/tests/test-mobile-control.sh`
- Test: `plugin/tests/test-mobile-admin-http.sh`

**Interfaces:**
- Produces: `GET /mobile/api/usage?root=...&source=...&sid=...`

- [ ] Add failing route, authorization, and payload assertions.
- [ ] Implement the root-scoped token-protected endpoint.
- [ ] Confirm state remains transcript-lazy.

### Task 3: Mobile Usage Rail

**Files:**
- Modify: `plugin/scripts/marina_mobile.py`
- Test: `plugin/tests/test-mobile-control.sh`

**Interfaces:**
- Consumes: normalized `usedTokens`, `contextWindow`, `remainingTokens`, and `contextPercent` fields.

- [ ] Add failing source assertions for lazy fetch and compact formatting.
- [ ] Render context, cumulative, and remaining values in the selected chat header.
- [ ] Clear stale values immediately when switching sessions.
- [ ] Label working app-owned sessions without enabling unsafe interruption.

### Task 4: Verification

**Files:**
- Test: `plugin/tests/test-agent-usage.sh`
- Test: `plugin/tests/test-mobile-control.sh`
- Test: `plugin/tests/test-mobile-admin-http.sh`
- Test: `plugin/tests/test-agent-history-pagination.sh`

**Interfaces:**
- Produces: verified mobile telemetry and unchanged lazy session loading.

- [ ] Run all focused shell tests.
- [ ] Run Python compilation and `git diff --check`.
- [ ] Restart the dashboard and inspect the selected session in Aside.
- [ ] Commit the completed change without pushing.
