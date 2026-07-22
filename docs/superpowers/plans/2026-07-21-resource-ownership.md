# Resource Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans and test-driven-development task-by-task.

**Goal:** Apply project assignment and single-owner isolation to every desktop/mobile resource API.

**Architecture:** Extend `AuthStore` with project/owner operations and put authorization decisions in `marina_access.py`. The HTTP handler filters collection responses and rejects direct resource access before side effects. Admins bypass resource checks; auth-disabled installations retain current behavior.

**Tech Stack:** Python stdlib, SQLite, vanilla JavaScript, bash contract tests.

## Tasks

- [x] Add failing store/policy tests for project assignment, ownership transfer, admin bypass, member fail-closed, and legacy reconciliation.
- [x] Implement `marina_access.py` and transactional `AuthStore` access APIs using canonical project IDs, resolved worktree paths, terminal IDs, and `source:sid` agent IDs.
- [x] Add admin assignment/reassignment HTTP APIs and user-management controls.
- [x] Enforce collection filtering and direct read/write checks across worktrees, sessions, git, logs, services, terminals, agents, and mobile routes.
- [x] Assign newly created worktrees, terminals, and agent sessions to the actor; add redacted audit events.
- [x] Run focused auth, terminal, git, mobile, and handler tests.
