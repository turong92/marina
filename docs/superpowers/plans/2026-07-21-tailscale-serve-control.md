# Tailscale Serve Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans and test-driven-development task-by-task.

**Goal:** Manage private Tailnet HTTPS access from Marina without overwriting unrelated Tailscale configuration.

**Architecture:** `marina_remote.py` reads Tailscale JSON, persists only Marina-owned mode/backend/status fingerprint, and performs targeted Serve changes. A CLI and admin settings API share the module. Successful enablement persists localhost dashboard bind; failures preserve existing bind and config.

**Tech Stack:** Python stdlib subprocess/JSON/hashlib, Tailscale CLI, vanilla JavaScript, bash tests with a fake CLI.

## Tasks

- [x] Add failing fake-Tailscale tests for missing/offline/empty/Serve/consent/conflict/failure/off states.
- [x] Implement status parsing, 15-second cache, canonical fingerprints, conflict detection, and targeted `serve --https=443 off` cleanup.
- [x] Add `marina remote status|serve|off` CLI and dashboard bind/restart integration.
- [x] Add admin remote APIs and a responsive settings section with diagnostics, address copy/open, and recovery messages.
- [x] Permit the persisted MagicDNS host through host validation only for the trusted local HTTPS proxy path.
- [x] Run focused remote, bind, auth, CLI, and UI tests.
