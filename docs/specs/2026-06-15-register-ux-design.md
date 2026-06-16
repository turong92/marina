# marina — Project registration & dashboard launch robustness (design)

- **Date:** 2026-06-15
- **Branch:** `feature/register-ux`
- **Base:** `07ea411`
- **Status:** Design approved; implementation plan pending.

## Scope

Two coupled concerns, both anchored on one **self-resolving launcher**:

- **A. Registration UX** — make first-run project registration discoverable and
  runnable across the surfaces a user touches (in-session, terminal, dashboard).
- **B. Dashboard launch robustness** — make the dashboard daemon launch
  version-stable (survive auto-update) and auto-restart on both macOS and Linux.

They are bundled because both rely on the same self-resolving launcher — resolve
the current plugin install path at runtime, then exec — once for the user
(`marina` on `PATH`) and once for the supervisor (launchd / systemd `ExecStart`).

## Problem

### A. Registration is a hidden manual step

Installing the plugin registers the SessionStart hook, but the hook only attaches
subrepos for projects **explicitly registered** in `~/.marina/projects.json` (via
`marina add`). A fresh user gets a **silent no-op** until they run `marina add`
once. Three gaps make that first registration hard to find and run:

1. **No `marina` on `PATH`.** Scripts live under a version-pinned cache dir
   (`<plugins>/cache/marina-dev/marina/<sha>/scripts/`) and there is no slash
   command.
2. **The cache path carries a version SHA** that changes on every auto-update, so
   a hardcoded alias to it breaks.
3. **The README frames `add` as a normal CLI feature**, not the required
   first-run step. Nothing states "install alone attaches nothing."

### B. Daemon launch is version-pinned and macOS-only

4. **Auto-update and auto-restart do not compose.** `marina-dashboard.sh`
   registers a launchd plist whose `ProgramArguments` point at
   `$SCRIPT_DIR/marina-control.py` — the **SHA-versioned** plugin path. After an
   auto-update (new SHA dir) the plist still points at the old path: auto-restart
   relaunches the **stale** version, and if the old version dir is
   garbage-collected the job **breaks**. Nothing re-runs `dashboard start` to
   refresh it.
5. **Auto-restart is macOS-only.** `use_launchctl` gates on `uname == Darwin`.
   The non-macOS fallback is `nohup`, which does not survive logout/reboot — so
   on **Linux there is no real auto-restart**.

## Goals

- A: discoverable + runnable first-run registration across in-session, terminal,
  and the dashboard.
- B: daemon launch is **version-stable** (picks up the current version on every
  (re)start) and **auto-restarts on macOS and Linux**.
- Keep one inference SoT (`marina.sh`) and one resolution SoT (the self-resolving
  launcher).
- Do not regress zero-config attach for already-registered projects.

## Non-goals (scope guards)

- No dashboard filesystem auto-scan (global daemon has no cwd; avoid false
  positives).
- No automatic or invasive shim install (opt-in only); the hook never touches
  `PATH`.
- No editing of inferred subrepos in the dashboard preview (v1).
- No PATH binary beyond the opt-in self-resolving shim.
- **No system-level (root) services** — user-level launchd / systemd only.

## Design principle — two sources of truth

1. **Inference + registry write** live only in `marina.sh` (`add` / `infer` /
   `rm`).
2. **Version resolution** lives in one shared helper: read the current install
   path from the harness's `installed_plugins.json` and exec. Used by both the
   user shim and the daemon launcher, so **neither hardcodes a SHA**.

```
                   marina.sh : inference + projects.json write   <- inference SoT
                   |- add <path>      register (infer, then write)
                   |- infer <path>    NEW: infer only, print JSON draft (no write)
                   `- rm <id>         unregister
                         ^                ^                  ^
          .--------------'                |                  `----------------.
   /marina:register                 marina add                /api/infer -> add-project
   (slash, in-session)              (shim, any terminal)        (dashboard POST)


   shared resolver (installed_plugins.json -> installPath)   <- resolution SoT
          |                                       |
   ~/.local/bin/marina                  ~/.marina/dashboard-launch.sh
   (user shim, component 3)             (daemon anchor, component 7)
                                                  |
                                  supervisor ExecStart points here (stable)
                                  launchd (mac) / systemd --user (linux) / nohup
                                                  |
                                  marina-control.py  (always the current version)
```

## Components

### 1. `marina.sh infer <path>` (new — core)

- **What:** run the same inference as `add` (subrepos = first-level subdirs with a
  `.git` *directory*; `worktreeGlobs`) and print the draft entry as JSON. **Does
  not write** `projects.json`.
- **How used:** the dashboard preview (`/api/infer-project`) shells out to it.
- **Implementation:** extract the inference block currently inline in
  `registry_add` into a shared function; `add` and `infer` both call it.
- **Depends on:** nothing new.

### 2. Slash command — `/marina:register`, `/marina:ls`

- **What:** plugin `commands/` markdown files. `/marina:register` registers the
  **current project** from a session; `/marina:ls` lists the registry.
- **How:** runs `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" add
  "<root>"`. `${CLAUDE_PLUGIN_ROOT}` resolves to the current version -> version-safe
  in-session.
- **Worktree safety:** if cwd is inside a worktree, resolve to the **main checkout**
  root before `add` (reuse the git-common-dir topology in `resolve_source_root`),
  so a worktree path is never registered as a project root.
- **Depends on:** entrypoint `add`.
- **Caveat:** Claude supports `commands/`; Codex support is unverified (Open
  Items). If absent, Codex users register via dashboard or shim.

### 3. CLI shim + `marina install-cli`

- **What:** `install-cli` / `uninstall-cli` subcommands in `marina-entrypoint.sh`.
  `install-cli` writes a **self-resolving** shim to `~/.local/bin/marina` and warns
  if that dir is not on `PATH` (with the exact export line).
- **Shim behavior:** at runtime resolve the current install path via the **shared
  resolver** (component 3 ↔ 7 share it) and `exec
  "$installPath/scripts/marina-entrypoint.sh" "$@"`. Dynamic resolution -> survives
  auto-update; write once.
- **Cross-harness:** resolve from the Claude plugins location, fall back to the
  Codex plugins location.
- **Opt-in only:** never auto-installed; the hook never touches `PATH`.
- **Depends on:** the shared resolver, `installed_plugins.json` schema, entrypoint.

### 4. Dashboard API (`marina-control.py`)

- **What:** new POST endpoints, following the existing `do_POST` pattern:
  - `POST /api/infer-project` — `{path}` -> inferred draft, no write (shells out to
    `marina.sh infer`).
  - `POST /api/add-project` — `{path}` -> `marina.sh add`, then refresh.
  - `POST /api/remove-project` — `{id}` -> `marina.sh rm`.
- **No duplicated inference:** all delegate to `marina.sh`. The dashboard never
  writes `projects.json` itself.
- **Depends on:** component 1.

### 5. Dashboard UI (`marina-control.py`)

- **What:** empty-state "register a project" panel (when registry empty) + a
  "+ Add project" control + per-project remove. Flow: path input -> `/api/infer-project`
  -> preview (id, subrepos, worktreeGlobs) -> confirm -> `/api/add-project` -> refresh.
  **No edit** of the draft in v1.
- **Depends on:** component 4. Follows existing dashboard markup/POST conventions.

### 6. README

- **What:** a "Getting started / first run" section stating that install registers
  the hook but **attaches nothing until a project is registered once**; the one-time
  `register` step shown three ways (slash, dashboard, `marina add` via the shim);
  `install-cli` and the opt-in shim model; and the cross-platform auto-restart
  behavior (component 7).
- **Depends on:** the final shapes of 1–5, 7.

### 7. Cross-platform daemon launch (new)

- **Stable launcher:** `marina-dashboard.sh` writes a daemon-owned launcher at
  `~/.marina/dashboard-launch.sh` that resolves the current install path (the
  **shared resolver**) and execs `marina-control.py` in the **foreground**. It lives
  in `~/.marina` (not the versioned dir) -> survives auto-update. The supervisor's
  `ExecStart` points at this launcher, never at a versioned `marina-control.py`.
- **macOS:** launchd plist `ProgramArguments` -> the stable launcher; `RunAtLoad`
  true (existing mechanism, retargeted).
- **Linux:** systemd **user** service at
  `~/.config/systemd/user/marina-dashboard.service` (`ExecStart` -> stable launcher),
  `systemctl --user enable --now marina-dashboard`, plus `loginctl enable-linger`
  so it runs without an active login session.
- **Fallback:** `nohup` only when neither launchd nor systemd is available; log a
  clear "auto-restart not configured" warning (no silent degradation).
- **Branching:** `marina-dashboard.sh` selects via `uname` + `command -v systemctl`.
- **Depends on:** the shared resolver (component 3).

## Data flow

- **Registration:** every path converges on `marina.sh` -> `~/.marina/projects.json`.
  No surface writes that file except `marina.sh`. The dashboard re-reads the
  registry after a write.
- **Daemon:** supervisor -> `~/.marina/dashboard-launch.sh` -> shared resolver ->
  current `marina-control.py`. Every (re)start re-resolves, so an auto-update is
  picked up on the next restart with no manual step.

## Error handling

- Invalid / non-existent path -> per-surface error (CLI stderr, API 4xx, UI inline).
- Path with no nested git repos -> registers as a monorepo (`subrepos: []`); preview
  shows "subrepos: (none)".
- `install-cli`: `~/.local/bin` not on `PATH` -> warn with the exact export line;
  existing `marina` file -> confirm before overwrite.
- Slash `register` from a non-git directory -> clear "not a git repository" error.
- **No supervisor available** (no launchd, no systemd) -> nohup + explicit
  "auto-restart off" warning.
- **Stale supervisor config** pointing at a removed version -> structurally avoided:
  the supervisor only ever points at the stable launcher, which re-resolves.

## Testing

Marina has `plugin/tests/` (shell tests, isolated via a temp `MARINA_HOME`). Add:

- `infer`: nested-git-dir subrepos detected; monorepo -> `[]`; a child dir with a
  `.git` **file** (worktree link) excluded.
- `add` / `rm` idempotency.
- **Shared resolver:** returns the current install path from a mocked
  `installed_plugins.json`; survives a simulated version bump.
- `install-cli`: writes the user shim; the shim resolves via the shared resolver.
- API: `infer-project` returns a draft without writing; `add-project` writes;
  `remove-project` removes.
- **Daemon launch:** `marina-dashboard.sh` writes `~/.marina/dashboard-launch.sh`,
  and the launchd plist / systemd unit `ExecStart` points at it (not a versioned
  path); OS branch selection (`Darwin`->launchd, Linux+`systemctl`->systemd,
  else->nohup) via a mocked `uname` / `command`.
- (Manual) macOS start -> `launchctl` job present; restart after a simulated update
  picks up the new version.

## Open items

1. **Codex slash-command support** — verify whether Codex plugins expose
   `commands/` slash commands. If not, document the dashboard/shim path for Codex.
2. **Main-checkout resolution from a worktree** for slash `register` — confirm
   topology handling for both Claude (`<root>/.claude/worktrees/*`) and Codex
   (`<worktrees>/*/<base>`) layouts.
3. **systemd specifics** — confirm `loginctl enable-linger` is the right
   reboot-survival mechanism; confirm `systemctl --user` exists in target
   environments (some minimal containers lack a user systemd -> nohup fallback).

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Surfaces | README + slash + dashboard (+ shim) | Cover in-session, terminal, GUI |
| Inference location | Single SoT in `marina.sh` | One change propagates everywhere |
| Terminal command | opt-in `install-cli` self-resolving shim | "Anywhere" use, ~0 maintenance, non-invasive |
| Dashboard preview | confirm as-inferred (no edit) | YAGNI; re-register to correct |
| Dashboard discovery | manual path input (no auto-scan) | Global daemon has no cwd; avoid false positives |
| Daemon launch | via a stable self-resolving launcher in `~/.marina` | Auto-update + auto-restart compose; no SHA in supervisor config |
| Cross-platform restart | launchd (mac) / systemd user + linger (Linux) / nohup fallback | Real auto-restart on both; nohup only as last resort |
| Resolution location | one shared resolver helper | User shim and daemon launcher never duplicate or hardcode |
