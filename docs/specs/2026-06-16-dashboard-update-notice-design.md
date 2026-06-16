# marina — in-dashboard update notice + one-click restart/enable (design)

- **Date:** 2026-06-16
- **Status:** Design approved (server-side detection + 2-stage states); spec for review.
- **Builds on:** SHA-versioned plugin distribution (version-less manifests = commit SHA), the version-stable launcher (`~/.marina/dashboard-launch.sh`), and the existing dashboard poll loop.

## Goal

The dashboard (:3900) tells the user when it's not running the latest published marina, and lets them fix it in one click — **[재시작]** when the files are already downloaded, or **[auto-update 켜기]** when they're not. Detection and restart live in the dashboard daemon, so they work the same on Claude and Codex.

## Problem

The plugin updates in two independent layers, and nothing surfaced the gap:

1. **Files** (`~/<harness>/plugins/cache/.../marina/<SHA>/`) are updated by the harness — automatically at session start **only if the user enabled auto-update for the `marina-dev` marketplace** (third-party marketplaces default to OFF), otherwise manually via `/plugin`.
2. **The running :3900 daemon** keeps serving whatever SHA it launched from until it's restarted — even after the files update.

Observed live: serving `1ccb934`, installed `e106034`, origin `e58fe3d` — the daemon sat two versions behind and nothing said so (auto-update was OFF). This feature closes that loop from inside the dashboard the user is already looking at.

## Model — three SHAs, two-stage state

The daemon knows three short (12-char) SHAs:

- **serving** — the running code. Parsed from `CONTROL_SCRIPT` (`Path(__file__)`): the `<SHA>` segment in `.../marina/<SHA>/scripts/marina-control.py`. Not in that layout (running from a repo checkout / preview / dev) ⇒ `None`.
- **installed** — the downloaded version. From `installed_plugins.json` `installPath` (search `~/.claude` then `~/.codex`, same as `marina-resolve.sh`).
- **origin** — the latest published `main`. From `git ls-remote https://github.com/turong92/marina main`, cached with a TTL.

State (decide banner by `serving` vs `origin`, then the two-stage branch by `installed` vs `origin`):

| Condition | State | Banner | Action |
|---|---|---|---|
| `serving == origin` | **CURRENT** | (none) | — |
| `serving != origin` and `installed == origin` | **STALE** — files are latest, daemon runs old code | "업데이트 설치됨 — 재시작하면 적용 (`<serving>` → `<installed>`)" | **[재시작]** (daemon can do this now) |
| `serving != origin` and `installed != origin` | **NEW** — a newer version is published than is downloaded | "새 버전 배포됨 (origin `<origin>`, 설치 `<installed>`)" | autoUpdate **ON**: "다음 세션 시작에 자동 업데이트" (info) · **OFF**: **[auto-update 켜기]** button (+ "다음 세션부터 적용" · "지금 받으려면 `/plugin` 업데이트") |

**Lifecycle:** NEW → (next session auto-update, or manual `/plugin`) → STALE → **[재시작]** → CURRENT. After the user enables auto-update once, the steady state is: each session silently refreshes files, and the banner reduces to a single **[재시작]**.

**`serving == None` (dev/preview/repo run) ⇒ no banner** — the feature is inert outside an installed plugin.

## Components / files

All in **`plugin/scripts/marina-control.py`** unless noted.

- **`update_state(serving, installed, origin) -> str`** — pure function returning `"current" | "stale" | "new" | "unknown"` (`unknown` when `serving`/`installed` is `None`). Testable in isolation.
- **`update_status() -> dict`** — gathers `serving` (parse `CONTROL_SCRIPT`), `installed` (read `installed_plugins.json`), `origin` (cached `git ls-remote`), per-harness `autoUpdate` (read Claude `settings.json` / Codex `config.toml`), and `state` (via `update_state`). Returns the payload for `/api/update-status`.
- **`GET /api/update-status`** → `{serving, installed, origin, state, autoUpdate: {claude, codex}, harnesses: [..]}`.
- **`POST /api/restart-dashboard`** → send the response first, then spawn a **detached** (`subprocess.Popen(..., start_new_session=True)`) `bash <plugin>/scripts/marina-dashboard.sh restart`. That existing command does stop(bootout)+start(bootstrap+kickstart) across launchd/systemd/nohup; the launcher re-resolves `installPath` → new code. `MARINA_RESTART_DRY_RUN=1` logs the command instead of executing (for tests).
- **`POST /api/set-autoupdate {harness}`** → write `autoUpdate=true` for `marina-dev` to that harness's config: Claude `~/.claude/settings.json` (`extraKnownMarketplaces."marina-dev".autoUpdate`, JSON edit preserving other keys); Codex `~/.codex/config.toml` (key TBD — **verification-gated**, see Open items). Missing marketplace entry ⇒ return an error with guidance, do not fabricate. Response notes "applies next session".
- **`INDEX_HTML`** — a banner in `<header>` (line ~2043), rendered from `/api/update-status` on the existing poll; reuses the existing pill/chip design tokens. Buttons wired to the two POST endpoints. `MARINA_UPDATE_FORCE_STATE` env forces a state so the banner can be rendered in preview for visual QA (since dev runs have `serving == None`).
- **`plugin/scripts/marina-dashboard.sh`** — reused as-is (`restart` already exists); no change expected.

## Data flow

- **Cadence:** `origin` is cached with TTL **60s default, `MARINA_UPDATE_TTL` overridable** (matching `STALE_DAYS`/`HEALTH_BAD_AFTER`). Lazy: `git ls-remote` runs only when an `/api/update-status` request arrives **and** the cache is older than the TTL. `serving`/`installed`/`autoUpdate` are cheap file reads computed each request. ⇒ dashboard closed = zero network; open and polling = one `ls-remote` per ~60s. A push is reflected within ~1 min.
- **Client:** the existing poll loop also `GET /api/update-status`; `state != current` ⇒ render the header banner, else hide it.
- **[재시작]:** light confirm → `POST /api/restart-dashboard` → show "재시작 중…" → the existing poll auto-reconnects (~1s) → banner clears (now CURRENT).
- **[auto-update 켜기]:** `POST /api/set-autoupdate {harness}` → inline "다음 세션부터 자동 업데이트" → banner updates (NEW with autoUpdate now ON shows the info line, not the button). If both harnesses are installed and OFF, one button per harness.

## Error handling

- `git ls-remote` fails (offline / timeout / git absent) → keep last cached `origin` or `None`; with no `origin`, fall back to no-network STALE detection only (`serving` vs `installed`) and never show a false NEW. No error spam.
- `serving == None` (repo/dev/preview) → skip the check entirely; no banner.
- `installed_plugins.json` missing/unreadable → `installed = None` → state `unknown` → no banner (not an error).
- `set-autoupdate`: parse config, set only the nested key, preserve the rest; marketplace entry absent ⇒ error + guidance (no fabrication); write failure ⇒ surface the reason, don't corrupt the file.
- `restart`: response already sent; if the daemon doesn't return, the tab stays on "재시작 중…"; `marina-dashboard.sh`'s launchd→nohup fallback mitigates; log to `dashboard.log`.
- Self-restart race: the restart runner must survive the daemon's own termination — `start_new_session=True` (setsid) dissociates it from the launchd job's process group; verified by a test.

## Testing

- **`update_state`** — importlib unit test: feed serving/installed/origin permutations → assert `current`/`stale`/`new`/`unknown`.
- **`/api/update-status`** (`test-update-status.sh`) — fake `installed_plugins.json` + fake serving path; `origin` injected via `MARINA_UPDATE_ORIGIN_SHA` env (no network in tests); assert JSON shape + computed state + autoUpdate read.
- **`/api/set-autoupdate`** (`test-set-autoupdate.sh`) — write to a temp Claude `settings.json` (configurable path), assert `autoUpdate=true` and other keys preserved; missing-entry → 4xx.
- **`/api/restart-dashboard`** — `MARINA_RESTART_DRY_RUN=1`; assert it responds fast and logs the intended `marina-dashboard.sh restart` invocation; plus a setsid-survival check for the runner.
- **UI** — preview :3901 + Chrome MCP, `MARINA_UPDATE_FORCE_STATE` to render each banner state; verify buttons hit the right endpoints; console errors 0.

## Out of scope (v1)

- The daemon downloading/installing files itself (that stays the harness's job — auto-update / `/plugin`). The dashboard only detects + restarts + flips the auto-update setting.
- Showing "N commits behind" counts (would need extra git calls); v1 shows SHAs only.
- A background timer that checks origin while the dashboard is closed (lazy-on-request only — no idle network).
- Notifying outside the dashboard (no OS notifications / Slack).
- Distinguishing `installed` **ahead** of `origin` (fork / pre-release): SHAs carry no ordering, so an installed-ahead-of-origin state also reads as NEW. Acceptable for single-branch `turong92/marina`; fork users would see a spurious NEW.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Where detection runs | **server-side** (daemon), exposed via `/api/update-status` | no GitHub-from-browser (CORS/rate-limit), one place for caching + 3-SHA compare, curl-testable, harness-agnostic |
| What "behind" compares | `serving` vs `origin`, two-stage by `installed` | matches the user's mental model and tells them exactly what *they* can do now (restart vs enable) |
| origin source | `git ls-remote` | git protocol = no API rate limit, fetches one ref |
| TTL | **60s**, `MARINA_UPDATE_TTL` overridable, lazy | fast enough (push reflected ≤1 min), cheap, zero network when idle |
| restart mechanism | reuse `marina-dashboard.sh restart`, detached | already cross-supervisor (launchd/systemd/nohup) + version-stable launcher |
| enable button scope | Claude now (verified), **Codex after verification** | Codex `config.toml` autoUpdate key + startup-apply behavior is unverified (memory) |
| dev/preview | `serving == None` ⇒ inert | the feature only makes sense for an installed plugin |

## Open items / verification gate

1. **Codex auto-update verification (blocks the Codex enable button only):** confirm how Codex enables per-marketplace auto-update in `~/.codex/config.toml` (exact key) and whether it applies at startup. If confirmed → implement the Codex branch of `set-autoupdate`. If not → degrade to "Claude button + Codex guidance" and say so in the banner. Detection + restart work on Codex regardless.

   **Verified (2026-06-16) → DEGRADED:** Codex has **no per-marketplace auto-update mechanism**. `codex plugin marketplace` exposes only `add` / `list` / `upgrade` (manual git-snapshot refresh) / `remove` — no autoUpdate toggle or flag; `~/.codex/config.toml` `[marketplaces.marina-dev]` has only `last_updated`/`source_type`/`source` (no `auto_update` key anywhere). (Also the local `python3` is 3.9 — no stdlib `tomllib`/`tomli_w` to write TOML safely.) ⇒ **No Codex enable button**; the NEW-state banner shows Codex guidance "`codex plugin marketplace upgrade` 로 수동 갱신". The `set-autoupdate {harness:codex}` endpoint returns a clear error (not implemented). Detection + restart still work on Codex.
2. **Claude `settings.json` live-reload:** assume enabling auto-update takes effect **next session** (the UI says so); no attempt to make the current session re-read it.
