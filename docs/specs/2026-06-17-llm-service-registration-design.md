# marina — daemon-driven LLM service registration & edit (design)

- **Date:** 2026-06-17
- **Branch:** `claude/busy-faraday-c85a08` (SoT: `~/IdeaProjects/sumin/marina`)
- **Status:** Design approved; spec for review.
- **Relation:** replaces the copy-paste delegation added in `docs/specs/2026-06-17-standard-cli-and-context-injection-design.md`; reuses the service-modal form from `docs/specs/2026-06-16-dashboard-register-ui-design.md` and the analysis procedure documented in `plugin/commands/service.md`.

## Goal

Make dashboard service **registration and editing** intuitive for the target user — someone for whom hand-writing `marina-services.json` (or even a structured form) is a barrier — by having the **daemon directly drive an LLM** to analyze the repo, fill the form, and (optionally) register + verify a service end-to-end, with the editable form always remaining the single source of truth.

## Problem

1. **Copy-paste is the registration path.** The service modal's "✨ 이 subrepo 를 LLM 으로 등록" button (`marina-control.py:2868`) only copies a `/marina:service add <root> <subrepo>` command to the clipboard and tells the user to paste it into a Claude/Codex session. For the exact user who can't/won't write JSON, the copy-paste hop is itself a barrier — unintuitive and easy to abandon.
2. **One-shot output isn't a correctness guarantee.** Even when the LLM produces a definition, a wrong `portBase`/`cwd`/`run` means the service silently won't start, and the user is back to manually fixing fields they didn't understand — the "keep re-doing it" loop.
3. **Register and edit are asymmetric.** Registration has the (copy-paste) LLM path; editing an existing service is manual-form-only. "Change this service's env/port in natural language" has no home.

## Design

### Architecture — one engine, two modes

A single **engine** does the work; the two UX **modes** are thin wrappers over it. The engine lives in the daemon (`:3900`), which already owns service lifecycle (`start_service`/`stop_service`/`service_health`/logs).

```
engine
├─ A. analyze   LLM as a READ-ONLY config function: (repo path [+ NL instruction] [+ current def]) → services.json candidate
└─ B. verify+fix  DAEMON-driven bounded loop: launch candidate → health → on fail, feed log tail back to analyze → fix → retry (≤2)

modes
├─ form-fill (default)  analyze → prefill form → user reviews/edits/saves   (no launch)
└─ direct (toggle)      analyze → verify+fix loop → commit on success / roll back + fall back to form on failure
```

**Core principle:** the LLM is *only ever* a read-only "config function" — it reads repo files and error logs and emits JSON. It never launches, writes, or registers. The daemon owns every side effect (launch, stop, register, roll back). This keeps the loop deterministic and auditable, requires no execution/write permission for the spawned LLM, and preserves "the form (editable JSON) is the single source of truth."

### A. `analyze` — read-only LLM config function

- **Inputs:** worktree `root` (+ optional subrepo `cwd`); optional natural-language instruction; on edit, the service's current definition; on a fix iteration, the failing definition + captured log tail.
- **Spawn (daemon, in the repo dir):**
  - claude: `claude -p "<prompt>"` with `--allowedTools` limited to read tools (`Read`, `Glob`, `Grep`) — no `Write`/`Edit`/`Bash`.
  - codex: `codex exec` under a **read-only sandbox** — no writes.
  - Binaries resolved via the existing `_bin()` helper (`marina-control.py:331`), so the launchd daemon's minimal PATH still finds them. Exact flags confirmed against installed versions during implementation.
- **Prompt:** mirrors the analysis procedure already written for the slash command (`plugin/commands/service.md` step 2) — inspect `package.json` (scripts.dev/start), `build.gradle*`/`settings.gradle*` (Spring bootRun), `Dockerfile`/`docker-compose.yml`, `pyproject.toml`/`requirements.txt` (uvicorn/flask); derive `name`, `portBase`, `cwd` (root-relative), `run` (using marina tokens `{port}` `{profile}` `{python}` `{root}` `{session}`). The prompt demands **JSON only** matching the schema, no prose.
- **Output parsing (daemon):** extract the JSON (first balanced `{…}` or fenced ```json block) → validate against the `services.json` schema (`name`·`portBase`·`run` required; `cwd`·`cachePaths`·`orphanPattern` optional) → on parse/validation failure, **retry once** with the parse error appended to the prompt. Second failure ⇒ engine reports failure (UI falls back to the manual form).
- **Result:** one or more candidate definitions returned to the caller (form-fill fills the form; direct mode feeds the loop).
- **Cross-service ports:** the daemon passes the worktree's already-registered sibling service names (`services_for(root)`, minus the edited service) into the prompt, and the LLM wires any inter-service URL via the sibling's `{<name>_port}` token (marina's per-worktree sibling-port substitutor) baked into `run` — e.g. `exec env VITE_API_URL=http://localhost:{api_port} npm run dev -- --port {port}` — never a hardcoded port.

### B. `verify+fix` — daemon-driven bounded loop (direct mode)

```
for attempt in 1..N (N=2):
   daemon upserts candidate to central services file        (so the CLI can launch it)
   daemon start_service(root, name)                          (reuses existing launcher)
   poll service_health until "ok"  OR  failure:
        failure = start raised / process died / not "ok" within verify-timeout T (~45–60s)
   if "ok":  success → break
   else:     capture log tail → analyze(failing def + log) → new candidate
final:
   success → leave registered AND running; report "등록·기동 검증 통과 — <name> :<port> 실행 중"
   failure → ROLL BACK registry to prior state (remove if new; restore prior def if edit);
             fall back to the form pre-filled with the best attempt + the error log
```

- **Why a separate verify-timeout `T`:** `service_health` deliberately stays `"starting"` forever for a service that never binds (so cold builds aren't misjudged on the live dashboard). The loop can't wait indefinitely, so it imposes its own timeout `T` for the verify step. `T` is tunable; cold-build-heavy projects may need a higher value.
- **Config-only fixes.** The loop fixes definition errors (`port`/`cwd`/`run`). Environment errors it can't fix from config (e.g. dependencies not installed) are detected from the log and **reported to the user**, not auto-remediated — the daemon never runs `npm install` or other repo side effects.
- **Commit-on-success semantics.** Direct mode mutates the registry only transiently during the loop and **commits only when verify passes**; on final failure it restores the prior state. So a registered service always means "verified working, or user-saved" — no broken definitions linger, and editing a working service can never leave it broken.

### Modes & flows

- **form-fill (default):** modal opens with the manual form (empty for add, current values for edit). User clicks `[분석]` (optionally after typing an NL hint) → `analyze` runs → form is prefilled → user reviews/edits → `저장` (existing `/api/add-service`). No launch. The LLM call happens **only on click**, never automatically on modal open (cost/latency control).
- **direct (toggle):** user checks `직접 등록` and clicks → `analyze` → `verify+fix` loop → commit + leave running on success, or roll back + fall back to form on failure. The toggle choice is remembered (global pref); first-time users get form-fill so the launch side effect is never a surprise.
- **edit via NL:** same modal/bar. Form prefilled with current def; NL placeholder becomes e.g. `"예: 포트 3027로, env에 FOO 추가"`. `analyze` receives the current def + instruction → updates the form. `직접 등록` in edit means "apply NL → re-register → re-verify by launching," with the same rollback-on-failure guarantee.
- **fallback:** LLM not installed / output unparseable after retry / loop exhausted → graceful degrade to the (empty or partially-filled) manual form. The form is always usable on its own.

### LLM detection & override

- **Detection (default):** prefer `claude`, else `codex`, via `_bin()`. If neither resolves, the assist bar is disabled with a hint and the manual form still works.
- **Override:** a global `~/.marina/config.json` key `llmProvider` (`"claude"` | `"codex"`), optionally an env override (`MARINA_LLM`). When pinned, the picker is hidden.
- **Picker (state-adaptive):** show the `claude ▾` dropdown only when ≥2 providers are detected and none is pinned; with one provider show a label; when pinned, hide it.

### UI — service modal assist bar

The existing copy-paste row (`marina-control.py:2430-2433`) is replaced by an **assist bar at the top of the modal**, above the form fields:

- **Row 1:** ✨ icon + optional NL instruction input + `[분석]` button.
- **Row 2:** state-adaptive LLM picker (left) + `직접 등록` toggle with one-line explainer (right).
- **While running, the bar morphs into a progress strip** reflecting engine state: `레포 분석 중…` → `기동 검증 중… 시도 1/2` → `✓ 등록·기동 검증 통과 …` / `✕ N회 실패 — 폼으로 강등` (+ `로그 보기`). A cancel affordance aborts the in-flight call.
- The form below (name/portBase/cwd/run, advanced cachePaths/orphanPattern, team-share, save/cancel) is unchanged. The assist bar shows for both add and edit.

## Components / files

- **`marina-control.py`**
  - `analyze` helper: spawn `claude -p` / `codex exec` (read-only) in the repo dir; JSON extraction + schema validation + one retry.
  - `verify+fix` helper: bounded loop reusing `start_service`/`service_health`/log tail/`stop_service` + transient `service add`/rollback.
  - LLM detection/override (`_bin` + `~/.marina/config.json`).
  - New endpoints: `POST /api/llm-analyze` (returns candidate def(s) for form-fill; supports edit + NL + fix context) and `POST /api/llm-register` (runs direct-mode loop, streams/returns progress + final state). Origin-gated like existing `/api/` routes.
  - Dashboard JS/CSS: replace the copy-paste handler with the assist bar (NL input, `[분석]`, picker, `직접 등록` toggle, progress-strip morph, cancel, form prefill, fail→form fallback).
- **`plugin/commands/service.md`** — keep the slash command as an alternate path, but the dashboard no longer instructs users to paste into a session; reconcile wording.
- **`plugin/tests/`** — analyze JSON parsing (valid / fenced / prose-wrapped / retry-then-fail); schema validation; verify+fix success, fix-then-success, exhausted-then-rollback (add vs edit); env-error reported-not-fixed; detection/override + disabled-when-absent; endpoints origin-gated.

## Data flow

1. **form-fill:** UI `[분석]` → `POST /api/llm-analyze {root, cwd?, instruction?, currentDef?}` → daemon spawns read-only LLM → parses/validates → returns candidate → UI prefills form → user `저장` → existing `/api/add-service` → `marina service add` writes `marina-services.json`.
2. **direct:** UI `직접 등록` → `POST /api/llm-register {root, cwd?, instruction?, editName?}` → daemon runs analyze + verify+fix loop (transient upserts via `marina service add`, launches via existing path, polls health, captures logs, re-analyzes on failure) → commit+running on success / rollback + return best-attempt+error on failure → UI shows result or falls back to form.
3. Registry writes still funnel through `marina.sh service add`/`rm` (central by default, `--root` for team share) — no new persistence path. The candidate is made visible to the CLI by upserting to the central services file during the loop; success keeps it, failure rolls it back.

## Error handling

- **LLM missing / both unresolved:** assist bar disabled + hint; manual form unaffected.
- **Unparseable output:** one retry with the error; second failure ⇒ report + manual-form fallback.
- **Start crash / never-listens / dies:** treated as verify failure → log-fed fix attempt; after N, rollback + form fallback with the error.
- **Environment error (deps, etc.):** detected from log, reported to the user; loop ends without auto-remediation.
- **Cancel mid-run:** abort the spawned process; restore prior registry state if a transient upsert was in flight.
- **Edit safety:** a failed direct-mode edit restores the prior (working) definition — never leaves the service broken.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| v1 scope | engine + both modes (form-fill + direct) + edit-via-NL + self-fix | direct mode is the target user's actual need; the verify loop is what closes the correctness gap, so it's core not optional |
| loop driver | **daemon-driven**; LLM = read-only config function | reuses existing start/stop/health/logs; deterministic + auditable; no exec/write perms for the LLM; keeps form = single source |
| LLM permissions | read tools only (`Read`/`Glob`/`Grep`; codex read-only sandbox) | analysis needs reads only; the daemon does all side effects |
| output | JSON-only prompt → extract → schema-validate → 1 retry | structured, recoverable, no prose parsing fragility |
| self-fix bound | N = 2 attempts | enough to fix common config errors without runaway cost/latency |
| env errors | report, don't auto-fix | avoid repo side effects (no `npm install`); stays config-only |
| default mode | **form-fill**; direct is a remembered toggle | first interaction is transparent before any launch side effect |
| LLM trigger | on click only (not on modal open) | controls cost/latency |
| verify success | leave the service running | already verified up; matches the dashboard's purpose; instant "it's up" feedback |
| direct failure | roll back registry + fall back to form | no lingering broken registrations; editing never breaks a working service |
| detection | claude-first, then codex; global config/env override | use what's installed; pin when wanted |

## Out of scope (v1)

- LLM-driven autonomous registration (agent with Bash/Write) — rejected for permission/determinism reasons.
- Auto-remediating environment errors (running installers, editing repo files).
- A "test 실행" button in form-fill mode (the verify loop is reachable via direct mode; a form-mode test launch can be a fast-follow).
- Splitting central vs root services for team distribution (the `marina-services.json` git-tracking question) — separate concern, separate spec.
- Multi-service detection UX beyond what the form handles (one service per modal save; the LLM may still surface several as a list — exact multi-add UX deferred).
- **Auto-discovering *undeclared* cross-service deps.** The prompt wires siblings the LLM both (a) sees already registered (`services_for(root)`) and (b) infers the app actually calls; it won't invent wiring for an unregistered backend or a dependency undetectable from the repo. Cross-*repo* wiring and non-port env secrets stay manual (`local.env` / helper script). (Sibling-port wiring itself is now supported — see Design §A and resolved Open item #5.)

## Open items (decide during plan / spec review)

1. **Candidate-visibility-for-launch:** transient upsert to the central services file + rollback (recommended, reuses CLI) vs a scratch services file the CLI reads via override (more isolation, new plumbing). Lean: transient upsert + rollback.
2. **Verify-timeout `T`:** fixed default (~45–60s) vs per-project configurable. Lean: a sensible default with an override key for cold-build-heavy projects.
3. **Progress transport:** SSE stream (reuse the log-streaming pattern) vs poll an in-memory job status. Lean: whichever is lighter given the existing SSE infra for logs.
4. **Multi-service output:** if `analyze` returns several services for one repo, do we present a pick-list and add them one-by-one, or loop the register over all? Lean: list + per-service confirm in v1.
5. **Cross-service port/env injection — RESOLVED.** marina's `{<name>_port}` sibling-port token landed (PR #3, merged to main `5c08d79`). `_analyze_prompt` now injects the worktree's registered sibling service names and instructs the LLM to wire inter-service URLs via `{<name>_port}` in `run`. Verified live: claude produced `exec env VITE_API_URL=http://localhost:{api_port} npm run dev -- --port {port}` for a vite frontend with a registered `api` sibling.
