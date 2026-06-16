# marina — worktree subrepo ⊃ service tree + 3-level attach (phase 4 design)

- **Date:** 2026-06-16
- **Branch:** `feature/register-dashboard`
- **Status:** Design approved (hierarchical model + 3-level attach); spec for review.
- **Builds on:** phase 3 (project switcher + registration), `docs/specs/2026-06-16-dashboard-register-ui-design.md`

## Goal

Two linked changes to the worktree card:

1. **Show the real containment hierarchy — a subrepo contains the services that run inside it** — instead of subrepos (hidden in the switcher ⚙) and services (flat card rows) reading as unrelated siblings.
2. **3-level subrepo attach** so a worktree only carries (and indexes/runs) what it needs: a per-project **default attach set** that new worktrees inherit, editable on the main card, with **per-worktree override**.

## Problem

1. **subrepo and service read as two disconnected concepts.** A service's `cwd` (in `marina-services.json`) already lives inside a subrepo — `web`→`web-app-monorepo`, `be`→`be-api`, `index`/`search`/`audio`→`ai-api` (1 subrepo : N services). `marina.sh` even derives the subrepo from the service cwd (`subrepo="${svc_cwd%%/*}"`). But the dashboard shows services flat and subrepos only in the switcher edit, with look-alike names (`web`↔`web-app-monorepo`) — so the containment is invisible.
2. **New worktrees attach everything.** A worktree gets the project's whole subrepo set at creation, so a worktree where you only touch `be-api` still checks out and IDE-indexes `ai-api`+`web-app-monorepo`. There's no per-project default and no per-worktree attach/detach.

## Model — three levels

- **universe** = the project's registered `subrepos` (phase 3). Every one is physically cloned in the **main** checkout (the source the worktrees branch from). Edited via the switcher ⚙ "subrepos 편집".
- **default attach set (전체 기본)** = a per-project subset of the universe that **new worktrees auto-attach**. New optional registry field `defaultAttach`; absent ⇒ the whole universe (backward compatible). Edited on the **main** card.
- **per-worktree attach state** = which subrepos are physically attached in a given worktree. Filesystem-derived (`<worktree>/<subrepo>/.git` exists). Initialized from the default at creation; freely overridden (attach any universe subrepo, detach any) on that worktree's card.

**service** = a process from `marina-services.json`, located by `cwd` whose first segment is its subrepo (or `.` = root). A subrepo holds 0..N services. subrepo and service are different axes (code vs process) and are **not merged** — the UI nests services under their subrepo.

**main is never physically detached.** Its toggles edit the *default set*, not its clones — the source always stays whole (chosen over destructive source removal: that would cascade-break every worktree using the subrepo and risk unpushed branches).

## Design

### A. Card renders a subrepo ⊃ service tree (replaces the flat `svc-list`)

```
▾ be-api              [기본 ✓ / attached ✓]   ← subrepo row (toggle meaning depends on card, see B)
   └ be    :8081  [OFF ▶]                      ← service row: existing start/stop/restart/logs
▾ ai-api              [기본 ✓ / attached ✓]
   ├ index  :8000 [OFF ▶]
   ├ search :8002 [OFF ▶]
   └ audio  :8080 [OFF ▶]
▸ web-app-monorepo    [기본 ✗ / detached]      ← collapsed; services greyed/unstartable
```

- **Groups** = union of (registered subrepos) and (subrepos referenced by services' cwd). A registered subrepo with no service still shows. Services with cwd root (`.`) render ungrouped at the top.
- **Service rows** keep all existing behavior; only their grouping changes. A service under a non-attached subrepo is disabled (greyed, no ▶) with hint "subrepo 미attach".

### B. Subrepo toggle — meaning differs by card

- **main card → edits the default set (전체 기본).** Toggle = "is this subrepo in `defaultAttach`" (i.e. do new worktrees auto-attach it). main's physical clones are untouched; a subrepo toggled off on main still exists there as source, it just won't auto-attach to new worktrees. Writes go through `marina.sh` (registry).
- **worktree card → physical attach/detach** for that worktree:
  - **Attach** → reuse `attach-detached-subrepos.sh` with `MARINA_SUBREPOS="<one subrepo>"` + `SOURCE_ROOT`/`DEST_ROOT`. Idempotent, syncs local yml/env/venv, reuses the subrepo's branch if it still exists. No new attach logic.
  - **Detach** → `git -C <source>/<subrepo> worktree remove <worktree>/<subrepo>`. Safety:
    1. **Running services first:** any running service in that subrepo ⇒ refuse with `needsStop` → UI "정지하고 detach" → stop, then proceed (a live process holds the dir open).
    2. **Dirty working tree:** clean ⇒ remove now; uncommitted changes ⇒ refuse with `needsConfirm` → UI confirm → `--force`. **Unmerged commits are preserved** (the branch survives; re-attach reuses it).

### C. New-worktree auto-attach honors the default

The attach path (session-start hook → `attach-detached-subrepos.sh`) attaches the project's **`defaultAttach`** set for a fresh worktree, not the whole universe. Resolution order for "what to auto-attach": `MARINA_SUBREPOS` env (explicit) → registry `defaultAttach` → registry `subrepos` (when `defaultAttach` absent) → none. A worktree the user later customizes is filesystem state and isn't re-expanded to the default on subsequent hook runs (attach is idempotent / additive only for missing-and-in-default; it never auto-detaches what the user attached, and never re-attaches what the user detached — see Open item 1).

### D. Dashboard API (`marina-control.py` `do_POST`)

- `POST /api/attach-subrepo` `{root, subrepo}` → worktree only; `safe_root`, `subrepo` ∈ `subrepos_of(root)`; shell attach with `MARINA_SUBREPOS=<subrepo>`; invalidate root's worktree-info cache.
- `POST /api/detach-subrepo` `{root, subrepo, force, stopServices}` → worktree only; running-in-subrepo & not `stopServices` ⇒ `{needsStop:[svc...]}`; dirty & not `force` ⇒ `{needsConfirm:true}`; else (stop if asked) + `git worktree remove [--force]`; invalidate cache.
- `POST /api/set-default-attach` `{root, subrepos}` → main/project only; `subrepos` ⊆ `subrepos_of(root)`; shell `marina.sh` to write `defaultAttach`; invalidate registry caches. (mirrors phase-3 `add --subrepos`, which writes the universe.)
- All follow the existing `do_POST` pattern; all registry writes go through `marina.sh`.

### E. Data plumbing (payload + registry)

- **registry**: new optional `defaultAttach: [..]` per project (subset of `subrepos`); `marina.sh` gains a writer (e.g. `marina.sh default <id> a,b,c` / `--default` on `add`) — `registry_*` stays the write SoT.
- **`worktree_info(root)` += `attachedSubrepos`** = `[s for s in subrepos_of(root) if (root/s/'.git').exists()]`. `isMain` ⇒ all subrepos attached. Universe stays `subrepos` (phase 3); main also exposes `defaultAttach`.
- **service payload += `subrepo`** = first segment of that service's `cwd` (via a `service_subrepo_map(root)` helper reading the project `marina-services.json`).
- Client builds the tree from `session.services` (now `subrepo`-tagged) + `wt.subrepos` (universe) + `wt.attachedSubrepos` (worktree) / `wt.defaultAttach` (main).

## Components / files

- **`plugin/scripts/marina.sh`** — registry writer for `defaultAttach`; `registry_subrepos_for` (or a new `registry_default_for`) so the attach path resolves the default.
- **`plugin/scripts/attach-detached-subrepos.sh`** — `resolve_subrepos` falls back to `defaultAttach` before `subrepos` for new-worktree auto-attach. Single-subrepo dashboard attach still via `MARINA_SUBREPOS`.
- **`plugin/scripts/marina-control.py`** — `worktree_info` `attachedSubrepos`; `service_subrepo_map` + service `subrepo`; expose `defaultAttach`; `do_POST` `/api/attach-subrepo` · `/api/detach-subrepo` · `/api/set-default-attach`; `INDEX_HTML` card rebuilt as the subrepo⊃service tree with card-specific subrepo toggles + confirm/stop flows + disabled rows.
- **`plugin/tests/`** — `marina.sh default` write; attach (idempotent single) / detach (clean / dirty→confirm / running→stop); new-worktree honors `defaultAttach`; payload (`attachedSubrepos`, service `subrepo`, `defaultAttach`); UI smoke via preview.

## Error handling

- Attach when source subrepo missing → script no-ops; state stays detached.
- Detach + running services → `needsStop`; + dirty → `needsConfirm`→`--force` (branch preserved); not-attached → no-op success.
- `subrepo`/`subrepos` not ⊆ `subrepos_of(root)` → 400.
- main-card physical attach/detach attempt → rejected (main toggles only write `defaultAttach`).
- Service whose cwd-subrepo isn't registered → grouped under that name without an attach toggle (surfaces inconsistency, no crash).

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| subrepo vs service | separate configs, **nest in UI** | different axes, 1:N (ai-api→3 services); merge impossible |
| attach levels | **universe / default(전체 기본) / per-worktree** | new worktrees attach only what's needed; per-worktree override |
| main card toggle | edits `defaultAttach`, **source preserved** | main subrepos are source clones; physical removal cascades + risks unpushed branches |
| `defaultAttach` absent | = whole universe | backward compatible with existing projects |
| worktree attach state | filesystem (`<subrepo>/.git`) | no stale config; worktree removal self-cleans |
| detach + running / dirty | stop-first / confirm→`--force`, branch kept | live process holds dir; unmerged commits safe on branch |
| single-subrepo attach | reuse `attach-detached-subrepos.sh` via `MARINA_SUBREPOS` | already idempotent + syncs; zero new attach code |

## Out of scope (v1)

- Full per-project **service/port isolation** for >1 project with different service sets (deferred "stage 3"; per-project *rendering* via `services_for(root)` already stops cross-project leakage).
- Physically adding/removing subrepo **source clones on main** (Model B) — main toggles only edit the default.
- Attaching subrepos outside the project's registered universe (register first via phase-3 ⚙).
- Reordering subrepos/services.

## Open items (decide during plan / spec review)

1. **Re-attach idempotency vs user detach:** the session-start hook must not re-attach a subrepo the user deliberately detached from a worktree, nor auto-detach one they added. Lean: hook only attaches *missing* subrepos that are in `defaultAttach` **and** were never explicitly detached — track "explicitly detached" via a per-worktree marker, or simpler v1: the hook attaches `defaultAttach` only on **first** run (no marina state dir yet) and never touches attach state after. Decide in plan.
2. Root-level services (`cwd="."`): ungrouped at top vs a "(root)" node — lean: ungrouped at top.
3. Attach progress: per-subrepo spinner (`등록 중…` pattern) for the few-second `worktree add` + syncs.
4. Detached subrepo's service rows: shown-disabled (lean) vs hidden.
5. `marina.sh` default-set writer surface: `marina.sh default <id> a,b,c` vs `add --default a,b,c` — lean: dedicated `default` subcommand (keeps `add` focused).
