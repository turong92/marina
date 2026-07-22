# Tailscale Funnel Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans and test-driven-development task-by-task.

**Goal:** Allow an administrator to explicitly publish Marina through Funnel only after all public-access safeguards pass.

**Architecture:** Extend the remote controller with readiness checks, password reauthentication, safe Serve/Funnel transitions, rollback, and targeted shutdown. The UI exposes blockers and a compact PUBLIC indicator. Automated tests use a fake CLI and never publish the developer machine.

**Tech Stack:** Python stdlib, existing auth/session guard, Tailscale CLI, vanilla JavaScript, bash/e2e tests.

## Tasks

- [x] Add failing tests for readiness blockers, admin-only mutation, password confirmation, consent URL, transition rollback, and non-destructive off.
- [x] Implement readiness checks for auth enabled, active admin, localhost bind, auth guard self-check, and rate-limit policy.
- [x] Implement password-confirmed `funnel` activation and fingerprint-safe Serve/Funnel transitions.
- [x] Add remote API/CLI Funnel commands, readiness diagnostics, confirmation UI, and PUBLIC header state.
- [x] Verify desktop/mobile admin/member behavior, then run every repository test and browser e2e.
