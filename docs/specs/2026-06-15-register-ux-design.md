# marina — Project Registration UX (design)

- **Date:** 2026-06-15
- **Branch:** `feature/register-ux`
- **Base:** `07ea411`
- **Status:** Design approved; implementation plan pending.

## Problem

Installing the marina plugin registers the SessionStart hook, but the hook only
attaches subrepos for projects **explicitly registered** in
`~/.marina/projects.json` (via `marina add`). A user who installs the plugin and
opens a worktree gets a **silent no-op** until they run `marina add` once.

Three gaps make that first registration hard to discover and run:

1. **No `marina` on `PATH`.** The plugin ships scripts under a version-pinned
   cache dir (`<plugins>/cache/marina-dev/marina/<sha>/scripts/`) and exposes no
   slash command. There is no obvious way to invoke `marina add`.
2. **The cache path carries a version SHA** that changes on every auto-update, so
   a hardcoded alias to it breaks.
3. **The README frames `add` as a normal CLI feature**, not as the required
   first-run step. Nothing states "install alone attaches nothing."

Result: a new user installs the plugin, sees nothing happen, and has no
signposted path to fix it.

## Goals

- Make first-run registration **discoverable and runnable** across the three
  surfaces a user actually touches: in-session (agent), terminal, and the
  dashboard.
- Keep registration logic in **one place** so a change propagates everywhere.
- Do not regress the "install = trusted hook" zero-config attach for
  already-registered projects.

## Non-goals (scope guards)

- **No filesystem auto-scan** in the dashboard. The global daemon has no cwd
  context; scanning for candidate repos risks false positives.
- **No automatic or invasive shim install.** The PATH shim is opt-in only; the
  SessionStart hook never writes to the user's `bin`/`PATH`.
- **No editing of inferred subrepos** in the dashboard preview (v1 confirms as
  inferred; re-register to correct).
- **No PATH binary beyond the opt-in self-resolving shim.**

## Design principle — single source of truth

Registration inference and the `~/.marina/projects.json` write live **only in
`marina.sh`**. Every surface calls into it; none re-implements inference. One
change to the inference rule propagates to all surfaces.

```
                   marina.sh : inference + projects.json write   <- single SoT
                   |- add <path>      register (infer, then write)
                   |- infer <path>    NEW: infer only, print JSON draft (no write)
                   `- rm <id>         unregister
                         ^                ^                  ^
          .--------------'                |                  `----------------.
   /marina:register                 marina add                /api/infer -> add-project
   (slash, in-session)              (shim, any terminal)        (dashboard POST)
   cwd -> main-checkout root         self-resolving              path -> preview -> confirm
```

## Components

### 1. `marina.sh infer <path>` (new — core)

- **What:** run the same inference as `add` (subrepos = first-level subdirs with
  a `.git` *directory*; `worktreeGlobs`) and print the draft entry as JSON to
  stdout. **Does not write** `projects.json`.
- **How used:** the dashboard preview (`/api/infer-project`) shells out to it.
- **Implementation:** extract the inference block currently inline in
  `registry_add` into a shared function; `add` and `infer` both call it. This is
  the bulk of the SoT change.
- **Depends on:** nothing new (existing inference logic).

### 2. Slash command — `/marina:register`, `/marina:ls`

- **What:** plugin `commands/` markdown files. `/marina:register` registers the
  **current project** from an agent session; `/marina:ls` lists the registry.
- **How:** the command runs
  `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" add "<root>"`, where
  `<root>` is resolved from the session cwd. `${CLAUDE_PLUGIN_ROOT}` resolves to
  the current installed version, so this is **version-safe** in-session (no SHA
  problem).
- **Worktree safety:** if cwd is inside a worktree, resolve to the **main
  checkout** root before `add` (reuse the git-common-dir topology already in
  `resolve_source_root` / `attach-detached-subrepos.sh`), so a worktree path is
  never registered as a project root.
- **Depends on:** entrypoint `add`.
- **Caveat:** Claude Code supports `commands/` slash commands; Codex plugin
  slash-command support is unverified (see Open Items). If Codex lacks it, Codex
  users register via the dashboard or shim — no functional loss, only the slash
  surface is absent there.

### 3. CLI shim + `marina install-cli`

- **What:** new `install-cli` / `uninstall-cli` subcommands in
  `marina-entrypoint.sh`. `install-cli` writes a small **self-resolving** shim to
  `~/.local/bin/marina` and checks whether that dir is on `PATH` (warns with the
  exact export line if not).
- **Shim behavior:** at runtime, read the current install path from the harness's
  `installed_plugins.json` (`marina@marina-dev` -> `installPath`) and
  `exec "$installPath/scripts/marina-entrypoint.sh" "$@"`. Because it resolves
  dynamically, **auto-updates (new SHA) do not break it** — write once.
- **Cross-harness:** resolve from the Claude plugins location; fall back to the
  Codex plugins location so a Codex-only user's shim still works.
- **Opt-in only:** never auto-installed; the hook never touches `PATH`.
- **Depends on:** `installed_plugins.json` schema, entrypoint.

### 4. Dashboard API (`marina-control.py`)

- **What:** new POST endpoints, following the existing `do_POST` pattern
  (`/api/start`, `/api/cleanup`, ...):
  - `POST /api/infer-project` — body `{path}` -> returns inferred
    `{id, root, subrepos, worktreeGlobs}`, no write. Shells out to
    `marina.sh infer`.
  - `POST /api/add-project` — body `{path}` -> shells out to `marina.sh add`,
    then refresh the registry.
  - `POST /api/remove-project` — body `{id}` -> shells out to `marina.sh rm`.
- **No duplicated inference:** all three delegate to `marina.sh` (the SoT). The
  dashboard never parses or writes `projects.json` for registration itself.
- **Depends on:** component 1.

### 5. Dashboard UI (`marina-control.py`)

- **What:**
  - **Empty state** (registry empty -> currently a blank dashboard): a "register
    a project to get started" panel with a path input.
  - **Ongoing:** a "+ Add project" control and a per-project remove control.
  - **Flow:** path input -> `POST /api/infer-project` -> show preview (id,
    subrepos, worktreeGlobs) -> confirm -> `POST /api/add-project` -> refresh
    (reuse the existing registry-reload path).
  - **No edit** of the inferred draft in v1 (confirm as-is).
- **Depends on:** component 4. Follows existing dashboard markup/POST conventions.

### 6. README

- **What:** a "Getting started / first run" section stating plainly that install
  registers the hook but **attaches nothing until a project is registered once**;
  then the one-time `register` step shown three ways (slash command, dashboard,
  `marina add` via the shim). Document `install-cli` and the opt-in shim model.
- **Depends on:** the final shapes of components 1–5.

## Data flow

All registration paths converge on `marina.sh` -> `~/.marina/projects.json`. No
surface writes that file except `marina.sh`. The dashboard re-reads the registry
after a write to refresh. The SessionStart hook is unchanged — it continues to
gate attach on registry membership.

## Error handling

- Invalid / non-existent path -> surfaced per surface (CLI stderr, API 4xx +
  message, UI inline error).
- Path with no nested git repos -> registers as a monorepo (`subrepos: []`);
  preview shows "subrepos: (none)". Both nested-repo and monorepo layouts are
  already supported.
- `install-cli`: `~/.local/bin` not on `PATH` -> warn with the exact export line;
  an existing `marina` file -> confirm before overwrite.
- Slash `register` from a non-git directory -> a clear "not a git repository"
  error.

## Testing

Marina has a `plugin/tests/` dir (shell tests, isolated via a temp
`MARINA_HOME`). Add:

- `infer`: nested-git-dir subrepos detected; monorepo -> `[]`; a child dir with a
  `.git` **file** (worktree link) excluded.
- `add` / `rm` idempotency (re-adding the same root replaces; `rm` by id).
- `install-cli`: shim resolves the install path from a mocked
  `installed_plugins.json` and survives a simulated version change.
- API: `infer-project` returns a draft without writing; `add-project` writes;
  `remove-project` removes.
- UI: manual smoke via the dashboard preview port.

## Open items

1. **Codex slash-command support** — verify whether Codex plugins expose
   `commands/` slash commands. If not, document that Codex users register via the
   dashboard or shim. Does not block components 1, 3, 4, 5, 6.
2. **Main-checkout resolution from a worktree** for slash `register` — confirm
   the topology resolution handles both the Claude (`<root>/.claude/worktrees/*`)
   and Codex (`<worktrees>/*/<base>`) layouts.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Surfaces | README + slash + dashboard (+ shim) | Cover in-session, terminal, and GUI |
| Inference location | Single SoT in `marina.sh` | One change propagates everywhere |
| Terminal command | opt-in `install-cli` self-resolving shim | "Anywhere" use, ~0 maintenance, non-invasive |
| Dashboard preview | confirm as-inferred (no edit) | YAGNI; re-register to correct |
| Dashboard discovery | manual path input (no auto-scan) | Global daemon has no cwd; avoid false positives |
