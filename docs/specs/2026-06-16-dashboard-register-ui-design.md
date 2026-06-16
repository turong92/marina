# marina — dashboard project switcher + registration UI (phase 3 design)

- **Date:** 2026-06-16
- **Branch:** `feature/register-dashboard`
- **Base:** `e106034`
- **Status:** Design approved; implementation plan pending.

## Goal

Replace the current all-projects-stacked sidebar with a **vertical project switcher** (scales to many projects), scope the dashboard to **one project at a time**, and add in-dashboard **registration with editable subrepo curation** — plus a CLI `--subrepos` flag so the same curation works from the terminal.

## Problem

1. **Sidebar doesn't scale.** `marina-control.py` renders every registered project's worktrees as stacked `.project-group` sections in the left `<aside>`. With 2+ projects it's cramped; horizontal tabs would fail past ~5.
2. **No GUI registration**, and `marina add` over-infers. `/marina:register` on a project with many nested git repos recorded all of them as subrepos when only a few were wanted — `add` writes the inferred set with no chance to curate. The user needs the usual subset, plus case-by-case additions.

## Design

### A. Project switcher (nav + at-a-glance + register entry)
- A vertical dropdown in the sidebar header, on the **same row as the existing aside collapse toggle** (`asideToggle`). Collapsing the aside hides it with the sidebar — acceptable (collapse = logs full-screen).
- **Closed:** current project name + chevron.
- **Open:** every registered project as a row with **status chips** (`N ON` / `N 충돌` / `idle`) derived from existing worktree/service state; click a row to scope the dashboard to it. Bottom row: `+ 프로젝트 등록`.
- Scrollable. **No search box in v1** (add when the list grows — YAGNI). The switcher's status list IS the "at-a-glance overview" — no separate overview page.

### B. Per-project scoped view
- Selecting a project filters the sidebar to **that project's worktrees only** — the existing **vertical** worktree-card layout, scoped. Main area (logs/detail) unchanged. This replaces the `.project-group`-stacked rendering. Worktrees stay vertical (never a horizontal grid).

### C. Register flow (`+ 프로젝트 등록`)
- Path input → `marina infer <path>` → preview: project `id`, a **subrepo checklist** (every detected nested-git repo, **default all checked**, toggle to exclude), and `worktreeGlobs`. Confirm → `marina add <path> --subrepos <checked>` → switch to the new project.
- Empty registry → the register panel is the default view.

### D. Subrepo curation (CLI + dashboard, one mechanism)
- **`marina.sh add <path> [--subrepos a,b,c]`**: flag absent → infer all (unchanged); flag present → record exactly that set.
- **CLI:** `marina add ~/proj --subrepos frontend,backend` curates directly from the terminal.
- **Dashboard:** the register checklist and a project's "subrepos 편집" both shell out to `marina add <root> --subrepos <selected>`. `add` upserts by `realpath(root)`, so **re-calling = updating**. No separate `set` command; the dashboard never writes `projects.json` directly.
- **Edit later (case-by-case):** "subrepos 편집" → `marina infer <root>` for the current universe + the project's current selection → checklist → save. (Keep the usual subset, check an extra repo when needed, uncheck after.)

### E. Dashboard API (`marina-control.py` `do_POST`)
- `POST /api/infer-project` `{path}` → `marina infer` → `{id, subrepos (universe), worktreeGlobs}`, no write.
- `POST /api/add-project` `{path, subrepos[]}` → `marina add <path> --subrepos <subrepos>` → refresh.
- `POST /api/remove-project` `{id}` → `marina rm <id>` → refresh.
- All follow the existing `do_POST` pattern; all writes go through `marina.sh`.

## Components / files

- **`plugin/scripts/marina.sh`** — `registry_add` parses an optional `--subrepos a,b,c` (CSV) and, when present, skips inference for the subrepo field (uses the explicit list); `registry_infer` unchanged as the universe source. `usage()` documents the flag.
- **`plugin/scripts/marina-control.py`** — switcher UI (replaces project-group stacking) + scoped worktree rendering + register panel (path + checklist) + "subrepos 편집" + the three `do_POST` endpoints.
- **`plugin/tests/`** — `marina.sh add --subrepos` (explicit set recorded verbatim; absent = infer all; upsert updates subrepos); API endpoints (infer no-write, add with curated set, remove); UI smoke via the marina preview.

## Data flow

All registry writes flow through `marina.sh` (`add [--subrepos]` / `rm`). The dashboard reads `projects.json` + live worktree/service status, and writes only by shelling out. Switcher status chips reuse the existing `worktree_info` / service-health / port-conflict computation, aggregated per project.

## Error handling

- Invalid path / not a dir → register panel inline error (API 4xx).
- `infer` on a path with no nested git repos → empty checklist + "monorepo (subrepos 없음)"; confirm registers `subrepos: []`.
- All subrepos unchecked → registers `subrepos: []` (valid — monorepo).
- `--subrepos` with a name that isn't a detected nested-git repo → marina.sh records it as given (caller's responsibility); the dashboard only ever sends names from the inferred universe.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Multi-project nav | vertical switcher dropdown w/ status | scales (scroll); no horizontal tabs/grid; status = at-a-glance "관리" |
| Switcher placement | sidebar header, same row as collapse toggle | reuses existing header line |
| Drill-in layout | vertical worktree list, scoped to one project | user: "가로로 쌓는 건 아니다" |
| Register preview | editable subrepo checklist, default all checked | fixes over-inference; reverses the earlier "confirm as-is" decision |
| Curation persistence | `marina add --subrepos` flag | one mechanism for CLI + slash + dashboard; marina.sh stays write SoT |
| Overview page | none — switcher status list covers it | YAGNI; user lives in one project day-to-day |

## Out of scope (v1)

- Switcher search box (add when many projects).
- A dedicated "all projects" overview page.
- Reordering / pinning projects.
- Subrepos that aren't nested git repos (a subrepo must be a git repo to attach a worktree).

## Open items

1. Exact per-project status aggregation (how many `ON`/`conflict` across that project's worktrees) — reuse existing service-health + `/api/fix-port-conflict` detection.
2. Whether "subrepos 편집" is a per-project gear/menu vs reusing the register panel pre-filled — decide during the plan after reading the current `render()`.
