# marina — per-project service isolation (stage 3) + docker/native run (design)

- **Date:** 2026-06-16
- **Branch:** `feature/multiproject-services`
- **Status:** Design approved (thin docker + per-project globals); spec for review.
- **Builds on:** phase 4 (`docs/specs/2026-06-16-worktree-subrepo-service-tree-design.md`) — implements the **"stage 3"** that phase 4 left Out of scope (line 103: "Full per-project service/port isolation for >1 project … deferred stage 3").

## Goal

Two changes, surfaced by registering a second project:

1. **Per-project service isolation** — every registered project drives the dashboard's service set, ports, log targets, orphan rules, and cache categories from **its own** `marina-services.json`, not just the registry's first project.
2. **docker/native run parity** — a service runs by whatever its project needs (docker compose *or* a native process), and both isolate per-worktree identically. Delivered as a **thin convention** (run-string + substitution tokens), **zero core change**.

## Problem

A freshly registered project (`homeserver`: subrepos `projects/kotlin-skeleton`, `projects/react-skeleton`) renders **"no svc"** on every subrepo. Two layers:

- **Per-project layer already works** (phase 4): `services_for(root)` / `service_subrepo_map(root)` read `root/marina-services.json` live per request. `homeserver` has no such file → 0 services → "no svc" (correct, but the user wants services).
- **Global service state is import-time, first-project-only** — the real blocker for a *second* project even once it has a file:
  - `_load_extra_services()` (`:58-85`) loops registered roots and **`return`s on the FIRST** with a `marina-services.json`.
  - `EXTRA_SERVICES` (`:88`) → `SERVICES` (`:89`) → `DEFAULT_PORT_BASE` (`:90`) → `LOG_TARGETS` (`:91`); `ORPHAN_RULES` (`:1704-1713`); cache categories (via `EXTRA_SERVICES`) — all derived from that one project (currently `mdc`).

Consumers of these globals therefore see only the first project's services. Net: register `homeserver` + add subrepos ✓, but its services never enter port allocation / log targets / orphan sweep / cache categories.

## Design

### A. Globals → per-project functions

Replace the import-time singletons with root-keyed lookups (mirrors the existing `services_for(root)`):

| Global (today) | → per-project | Derivation |
|---|---|---|
| `_load_extra_services()` first-project `return` | `extra_services_for(root)` | today's body, keyed by `root` (drop the early `return`) |
| `EXTRA_SERVICES` / `SERVICES` | `services_for(root)` *(exists)* | already per-project |
| `DEFAULT_PORT_BASE` | `port_base_for(root)` | `{s.name: s.portBase}` from `extra_services_for(root)` |
| `LOG_TARGETS` | `log_targets_for(root)` | `services_for(root) + ("console",)` |
| `ORPHAN_RULES` | `orphan_rules_for(root)` + `orphan_rules_all()` | per-root from `orphanPattern`; **union across all registered roots** for the system-wide sweep |
| cache categories | `cache_guard_services(category, root)` | from `extra_services_for(root)` |

**Consumer updates** (enclosing function already has `root` unless noted):

- `default_ports_for(root)` (`:801-803`) → `port_base_for(root)`
- `stop_all(root)` (`:1259-1260`) → `services_for(root)`
- `clear_worktree_cache(root)` (`:1627-1634`) → `services_for(root)`
- `fix_port_conflict(root)` (`:1660-1668`) → `port_base_for(root)`
- `cache_paths_by_category(root)` (`:1597-1600`) → `extra_services_for(root)`
- `tracked_pid_groups(snapshot)` (`:1716-1722`) — already loops `for root in discover_roots()`; change inner `for service in SERVICES` → `services_for(root)`. **This alone makes pid-tracking fully per-project.**
- **root-less (3) — resolve via union or threaded root:**
  - `orphan_processes()` / `kill_orphans()` (`:1730`, `:1752`) — system-wide scan, no single root → use `orphan_rules_all()` (union; a stray process is an orphan regardless of which project owns the pattern).
  - `safe_service(service)` (`:1166`, validates against `LOG_TARGETS`) — thread `root` from caller (`do_POST`/log handlers already hold a root) → validate against `log_targets_for(root)`; fallback if no root: union whitelist.
  - `cache_guard_services(category)` (`:1590`) — add `root` param; callers (`clear_worktree_cache`) already have it.

**Caching:** add a small per-root memo for `extra_services_for` / `port_base_for` / `orphan_rules_for`, invalidated by the existing `invalidate_registry_caches()` (`:681`) and on `marina-services.json` mtime change, so per-render lookups stay cheap.

### B. docker/native run — thin convention (zero core change)

`command_for` (`marina.sh:669-675`) already substitutes `{port}{python}{root}{profile}{env_file}{tmp}{session}` across the **whole run string**, then `exec`s it. So both shapes are ordinary `marina-services.json` entries — no new field, no new code path:

```jsonc
// native
{ "name": "web", "portBase": 5173, "cwd": "projects/react-skeleton",
  "run": "exec npx vite --port {port}" }

// docker
{ "name": "api", "portBase": 18080, "cwd": "projects/kotlin-skeleton",
  "run": "exec env HOST_PORT={port} COMPOSE_PROJECT_NAME=hs-api-{session} docker compose up --abort-on-container-exit" }
//   compose.yml:  ports: ["${HOST_PORT}:8080"]
```

`{port}` = `portBase` + per-worktree offset, `{session}` = per-worktree id → docker isolates **per-worktree exactly like native** (distinct host port + distinct compose project name, so concurrent worktrees don't collide).

Lifecycle reuses what exists:
- **running** = `tracked_alive or listeners` (`:1035`) — `docker compose up` (foreground) is the tracked pid; container port-mapping also shows as a listener.
- **stop** = `TERM` → 5s → `KILL` on the process group (`marina.sh:732`, `marina-control:1224`) — `compose up` receiving `TERM` stops its containers.

Documented (README / `docs/`), not coded: the docker run pattern + that compose must take `${HOST_PORT}` / `COMPOSE_PROJECT_NAME` for per-worktree isolation.

### C. Service definition location — root or central

`services_file_for(root)` resolves the service-definition file in priority order: **(1)** the project root's `marina-services.json` if present (team-committable; mdc uses this, gitignored), **(2)** else `$MARINA_HOME/services/<project-id>.json` (central, default `~/.marina/services/<id>.json`), **(3)** else none (0 services). Both the Python dashboard (the three readers `services_for`/`extra_services_for`/`service_subrepo_map`) and the bash launcher (`marina.sh` `SERVICES_FILE` resolution) honor this, so a centrally-defined project both **displays and runs**. Central placement keeps the project repo untouched (no committed marina file — the homeserver case); root-first preserves existing team-shared/committed setups.

## Components / files

- **`plugin/scripts/marina-control.py`** — globals → `extra_services_for` / `port_base_for` / `log_targets_for` / `orphan_rules_for` + `orphan_rules_all` / `cache_guard_services(…, root)`; update the consumers listed in §A; per-root memo + invalidation.
- **`plugin/scripts/marina.sh`** — `SERVICES_FILE` resolution gains a central fallback (root → source-root → `$MARINA_HOME/services/<id>.json` via registry id match); plus a `print-command` accessor used by the docker-token smoke test.
- **README / `docs/`** — docker run convention (tokens + compose env) and the per-project-services note.
- **`plugin/tests/`** — see Testing.
- **(central, not committed to any repo) `~/.marina/services/homeserver.json`** — `react-skeleton` native `vite` (`web`); `kotlin-skeleton` native `gradlew :apps:api:bootRun` (`api`). Kept central so the homeserver repo stays untouched.

## Testing

- **Multi-project isolation:** register two temp projects with **different** service sets; assert each renders/operates only its own services (extends `test-per-project-services.sh`).
- **Per-project facets:** `port_base_for`, `log_targets_for`, `cache_guard_services`, `orphan_rules_for` return per-root; `orphan_rules_all` = union.
- **`tracked_pid_groups`** counts each root's own pids only.
- **docker run smoke:** a compose-style `run` with `{port}`/`{session}` substitutes correctly (token expansion only — no real container in CI).
- **Regression:** existing single-project (`mdc`) behavior unchanged.

## Error handling

- Project with no `marina-services.json` → 0 services everywhere for that root (no crash); other projects unaffected.
- root-less consumer with no root resolvable → union fallback (never another project's set in isolation).
- docker forced `KILL` (>5s graceful) → container may linger; orphan sweep matches the **process**, not the container (documented limit; future `kind=docker`).

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| globals scope | per-project functions keyed by `root` | stage-1 pinned everything to the first project; `services_for` already proved the pattern |
| docker integration | thin: run-string + `{port}`/`{session}` tokens, no `kind` field | `command_for` already substitutes + `exec`s; YAGNI; doesn't block a future `kind=docker` |
| docker stop | rely on `TERM` → compose stops containers | marina already sends TERM-first to the process group |
| orphan sweep | union of all registered roots' rules | a stray process is an orphan regardless of owning project; sweep is system-wide |
| schema | unchanged (`name/portBase/cwd/run/cachePaths/orphanPattern`) | docker is a run convention, not a new type |
| service def location | root file first, else central `~/.marina/services/<id>.json` | central keeps the project repo untouched (homeserver); root-first preserves committed/team setups (mdc) |
| homeserver run mode | native (`vite` / `gradlew bootRun`) default | worktree dev; `{port}` isolates cleanly; docker doc'd as alternative |

## Out of scope (v1)

- **`kind=docker` first-class lifecycle** (status=`compose ps`, stop=`down`, logs=`compose logs`, container orphan reaping) — add when the thin `KILL`/orphan limit actually bites.
- **Cross-project port-collision arbitration** (two projects sharing a `portBase`) — per-worktree offset + existing `free_port_near`/`fix_port_conflict` already shift; global cross-project planning deferred.
- **homeserver service definitions** beyond the two skeletons.

## Open items (decide during plan)

1. **`safe_service` root threading** — enumerate its callers; confirm each holds a `root` (log/console handlers in `do_POST`). If any genuinely can't, use the union whitelist for just that path.
2. **Per-root memo invalidation** — reuse `invalidate_registry_caches()` vs add a `marina-services.json`-mtime guard; pick the cheaper that stays correct on edit.
3. **homeserver `kotlin-skeleton`** — confirm `gradlew :apps:api:bootRun` server-port flag + a base port that avoids `caddy`/its own docker; decide whether to also ship the docker compose variant as a live example.
