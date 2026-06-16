# marina — registration flexibility: nested projects, dir picker, manual subrepos (design)

- **Date:** 2026-06-16
- **Branch:** `feature/register-dashboard`
- **Status:** Design approved; spec for review.
- **Relation:** precedes phase 4 (`docs/specs/2026-06-16-worktree-subrepo-service-tree-design.md`); shares the **longest-prefix** rule with it.

## Goal

Make explicit project/subrepo registration handle **arbitrary repo layouts**, not just the depth-1 mdc shape. Three changes:

1. **Nested projects** — a project registered *under* another registered project (e.g. `homeserver/projects` under `homeserver`) resolves to the most-specific one, not the first.
2. **Directory picker** — register by browsing folders, not pasting an absolute path.
3. **Manual subrepos** — add subrepos `infer` doesn't surface (any relative path, slash allowed), on top of the auto-detected depth-1 set.

Projects stay **explicitly registered** (no auto-registration). `infer` (depth-1 `.git`) remains the convenient default; manual entry is the escape hatch for everything else.

## Problem

1. **First-match mis-attribution.** Project resolution uses first-match prefix (`root == pr or root.startswith(pr + os.sep)`, return first). A registered parent (`homeserver`) is a prefix of everything beneath it, so a child project's worktree (`homeserver/projects/react-skeleton/...`) is attributed to `homeserver`. Verified: `project_for(".../homeserver/projects/react-skeleton/.claude/worktrees/foo")` → `homeserver` (should be `react-skeleton`). Same pattern at 5 sites (control.py, the hook, the attach script ×2, marina.sh).
2. **Path-only registration.** The register modal has a single text input — you paste an absolute path. No way to browse.
3. **infer-only subrepos.** The register/edit checklist is built solely from `infer` (depth-1 `.git`). A repo nested deeper (`projects/react-skeleton`) or not-yet-cloned can't be added from the UI, even though `marina add --subrepos projects/react-skeleton` already accepts it on the CLI.

## Design

### A. Longest-prefix project resolution (shared rule)

Replace "return the first registered project whose root is a prefix of `target`" with "return the registered project whose **root is the longest prefix** of `target`." Codex-layout basename match and the single-project fallback are unchanged and still apply only when no prefix matches.

Applied identically at all 5 sites:

| Site | Function |
|---|---|
| `marina-control.py:185` | `project_for` |
| `marina-session-start-hook.sh:34` | `is_registered` |
| `attach-detached-subrepos.sh:43` | `registry_subrepos_for` |
| `attach-detached-subrepos.sh:75` | `registry_source_root_for` |
| `marina.sh:170` | `registry_subrepos_for` |

This is the **same longest-prefix rule** phase 4 uses for service→subrepo grouping — one concept, two uses. With it, `homeserver` (infra) and `homeserver/projects` (apps) coexist as distinct projects.

### B. Directory picker in the register modal

- **Server:** `GET /api/browse?path=<dir>` → `{path, parent, entries:[{name, isDir, isGitRepo}]}` listing the directory's immediate subdirectories (dirs only; `isGitRepo` = has `.git`). No `path` ⇒ start at `~`. Names only, never file contents. Origin-gated like other `/api/` GETs (dashboard's own port — CSRF-safe). It lists the user's own filesystem via their own dashboard, so arbitrary navigation is acceptable; dotfiles hidden by default.
- **UI:** the modal's path row gets a **찾아보기** button → a browse panel: breadcrumb of the current path, `..` to ascend, a list of subfolders (📁, git repos badged) to descend, and **이 폴더 선택** to pick. Selecting fills the path input; then **분석** (infer) runs as today. Typing a path by hand still works.

### C. Manual subrepo entry (register + edit)

- Below the infer checklist: an input + **추가** button. Type a project-root-relative path (e.g. `projects/react-skeleton`, slash allowed) → appends a **checked** row to the checklist as a manual entry. Confirm sends inferred-checked + manual entries together to `marina add --subrepos ...`.
- **Validation:** must be a relative path under the root (no leading `/`, no `..`). The server may mark whether it's currently a git repo (reusing the browse/`.git` check) and show ✓/⚠, but the user can add it regardless — pre-declaring a not-yet-cloned subrepo is valid (the attach script already no-ops on a missing source).
- **Edit pre-fill correctness:** the edit checklist is the **union of (infer depth-1 universe) and (currently-registered subrepos)**, with registered ones checked. So a previously manual/deep subrepo (e.g. `projects/react-skeleton`) still shows — checked and editable — even though `infer` doesn't surface it.

## Components / files

- **`marina-control.py`** — longest-prefix in `project_for`; `GET /api/browse`; the register modal JS (browse panel + manual-add row + edit union). `subrepos_of`/payload already carry the registered set (phase 3) — manual/deep subrepos flow through unchanged.
- **`marina-session-start-hook.sh`** — longest-prefix in `is_registered`.
- **`attach-detached-subrepos.sh`** — longest-prefix in `registry_subrepos_for` + `registry_source_root_for`.
- **`marina.sh`** — longest-prefix in `registry_subrepos_for`. (`registry_add --subrepos` already records arbitrary names incl. slashes — no change.)
- **`plugin/tests/`** — longest-prefix nested resolution (parent+child registered → child wins) across py + the bash sites; `/api/browse` (lists subdirs, flags git repos, hides dotfiles, origin-gated); register/edit with a manual slash subrepo (recorded verbatim; edit shows it checked).

## Data flow

Registry writes still go through `marina.sh` (`add --subrepos`, already slash-tolerant). `/api/browse` is read-only filesystem listing. No new persisted state. The longest-prefix rule is pure resolution logic — no schema change.

## Error handling

- `/api/browse` on a non-dir / unreadable path → 400 with message; the panel shows it inline and stays at the last good path.
- Manual subrepo with leading `/` or `..` → rejected inline ("프로젝트 root 상대경로만").
- Manual subrepo that isn't a git repo → allowed, marked ⚠ "git repo 아님(미클론?)"; attach later no-ops if still missing.
- Nested resolution when parent and child both match → longest wins (deterministic); exact-equal roots can't both register (`add` upserts by realpath).

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| project resolution | **longest-prefix** at all 5 sites | nested projects (homeserver ⊃ homeserver/projects); same rule as phase-4 grouping |
| subrepo depth | **arbitrary (slash allowed)**, infer = depth-1 default | flexible for any layout; common case stays one-click; register deeper only when wanted |
| auto-registration | **none** — projects stay explicit | keeps "only registered runs" philosophy; avoids unregister/re-register churn |
| browse scope | user's own fs, names only, origin-gated | local dashboard listing own machine; no content exposure |
| manual subrepo not-a-repo | allow + warn | pre-declare is valid; attach no-ops on missing source |
| edit checklist | union(infer, registered) | deep/manual registered subrepos must stay visible + editable |

## Out of scope (v1)

- Auto-registering projects on session start (explicit only).
- Custom project `id` (stays `basename(root)`; `homeserver/projects` ⇒ id `projects`).
- Browsing/selecting *files* (directories only).
- Remote/non-local filesystem browsing.

## Open items (decide during plan / spec review)

1. `/api/browse` start root and reach: `~` default, allow ascending to `/`? Lean: start `~`, allow `..` up to `/` (user's machine).
2. Manual-subrepo git-repo validation: live server check (✓/⚠ badge) vs accept-as-typed only. Lean: live check for the badge, but never block.
3. Dotfile dirs in browse: hidden with a "숨김 표시" toggle vs always hidden. Lean: hidden, no toggle (v1).
