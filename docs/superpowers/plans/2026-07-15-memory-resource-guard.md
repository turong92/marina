# Memory Resource Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show real Docker/container memory, learn project-service high-water usage, and require explicit confirmation before a start or rebuild that would overcommit available memory.

**Architecture:** A new `marina_memory.py` owns cross-platform host metrics, Docker CLI snapshots, caching, history, prediction, and build-pressure sampling. Session assembly enriches Compose services from labels; lifecycle actions ask the same module for a structured guard decision; the existing dashboard header and service metadata render the result without adding a new page.

**Tech Stack:** Python 3 standard library, Docker CLI JSON output, existing bash test harness, classic browser JavaScript/CSS, Aside browser verification.

## Global Constraints

- Do not add Python or JavaScript dependencies.
- Do not add project-specific service names, image assumptions, or an `x-marina` memory schema.
- Preserve `MIN_FREE_MB`; add `MARINA_DOCKER_RESERVE_MB` as the Docker-specific override.
- Unknown service history must remain unknown and must not be replaced with an invented estimate.
- A forced operation bypasses the guard but must not alter Compose resource limits or stop another worktree.
- Docker failures and timeouts degrade to host-only data and must not break `/api/sessions`.
- `docker stats` refreshes must be cached and single-flight so session polling cannot multiply subprocesses.
- BuildKit usage is reported only as observed host/container pressure, never as an exact BuildKit allocation.
- UI remains compact and uses the existing header and service rows; no new page, modal, nested card, or dependency.
- Browser verification uses Aside before Chrome, in-app Browser, or computer-use.

---

### Task 1: Cross-platform memory snapshot

**Files:**
- Create: `plugin/scripts/marina_memory.py`
- Create: `plugin/tests/test-memory-snapshot.sh`

**Interfaces:**
- Produces: `parse_size_mb(value: str) -> int | None`
- Produces: `host_memory() -> dict[str, Any]`
- Produces: `memory_snapshot(force: bool = False) -> dict[str, Any]`
- Snapshot shape: `{host, docker, containers, stale, partial, error, capturedAt}`.

- [ ] **Step 1: Write the failing unit/command-fake test**

Create a shell test that imports the missing module and asserts IEC/SI parsing, Linux `MemAvailable`, Docker info/stats/ps/inspect aggregation, Compose labels, timeout fallback, stale-cache fallback, and one subprocess refresh under eight concurrent callers. Use an injected module-level `_run(args, timeout)` fake instead of invoking Docker.

```python
assert mm.parse_size_mb("8.93GiB") == 9144
assert mm.parse_size_mb("638MiB") == 638
assert mm.parse_size_mb("1GB") == 953
snapshot = mm.memory_snapshot(force=True)
assert snapshot["docker"]["totalMb"] == 15972
assert snapshot["docker"]["usedMb"] == 9782
assert snapshot["containers"][0]["composeService"] == "web"
assert snapshot["containers"][0]["oomKilled"] is False
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash plugin/tests/test-memory-snapshot.sh`

Expected: failure with `ModuleNotFoundError: No module named 'marina_memory'`.

- [ ] **Step 3: Implement the snapshot module**

Implement bounded command timeouts, macOS/Linux host readers, Docker JSON-lines parsing, label/inspect enrichment cached by container ID, and a condition-variable single-flight cache. Keep the old public host keys in the returned host object for UI compatibility:

```python
def memory_snapshot(force: bool = False) -> dict[str, Any]:
    """Return a cached best-effort host/Docker snapshot; never raise."""

def system_memory() -> dict[str, Any]:
    host = memory_snapshot().get("host") or {}
    return {
        "totalMb": host.get("totalMb"),
        "freeMb": host.get("availableMb"),
        "freePercent": host.get("availablePercent"),
    }
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `bash plugin/tests/test-memory-snapshot.sh`

Expected: `PASS test-memory-snapshot`.

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina_memory.py plugin/tests/test-memory-snapshot.sh
git commit -m "feat(memory): collect host and docker usage"
```

### Task 2: Service mapping and learned high-water history

**Files:**
- Modify: `plugin/scripts/marina_memory.py`
- Modify: `plugin/scripts/marina_sessions.py`
- Modify: `plugin/scripts/marina_compose_svc.py`
- Create: `plugin/tests/test-memory-service-map.sh`

**Interfaces:**
- Consumes: `memory_snapshot()` from Task 1.
- Produces: `enrich_session_memory(root: Path, project: dict, services: list[dict], snapshot: dict) -> None`.
- Produces: `estimate_services(root: Path, service_names: list[str], snapshot: dict) -> tuple[list[dict], list[str]]`.
- History shape: `{version: 1, services: {name: {peakMb, imageId, observedAt}}}` under `MARINA_HOME/<project-id>/memory-history.json`.

- [ ] **Step 1: Write the failing mapping/history test**

Use two fake worktrees with different Compose project labels but one registered project. Assert current stats map only to the matching worktree, history is atomic and bounded, a later lower sample does not reduce the peak, and estimates report `same-image`, `same-service`, or unknown explicitly.

```python
mm.enrich_session_memory(root, project, services, snapshot)
assert services[0]["memoryUsageMb"] == 9144
assert services[0]["memoryPeakMb"] == 9144
assert services[0]["oomKilled"] is False
estimated, unknown = mm.estimate_services(other_root, ["web", "new-api"], snapshot)
assert estimated[0] == {"service": "web", "memoryMb": 9144, "confidence": "same-image"}
assert unknown == ["new-api"]
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash plugin/tests/test-memory-service-map.sh`

Expected: failure because `enrich_session_memory` is absent.

- [ ] **Step 3: Implement mapping and history**

Derive the Compose project name with the existing `compose_project_name(project_id, session_id(root))`. Add current/peak/limit/percent/OOM fields to service payloads while retaining `rssMb` as a compatibility alias for rounded `memoryUsageMb`. Use `tempfile.mkstemp` plus `os.replace` for history writes and a process lock for concurrent observations.

- [ ] **Step 4: Integrate with session assembly**

`/api/sessions` must create one memory snapshot, pass it into every `session_payload`, and return that same snapshot summary as `memory`. Do not run `docker stats` once per worktree.

```python
snapshot = memory_snapshot()
sessions = [session_payload(root, memory=snapshot) for root in discover_roots()]
self.send_json({"sessions": sessions, "memory": snapshot})
```

- [ ] **Step 5: Run focused regressions and verify GREEN**

Run:

```bash
bash plugin/tests/test-memory-service-map.sh
bash plugin/tests/test-compose-dash-services.sh
bash plugin/tests/test-compose-dash-api.sh
```

Expected: all print `PASS` or their existing success marker.

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina_memory.py plugin/scripts/marina_sessions.py plugin/scripts/marina_compose_svc.py plugin/scripts/marina_handler.py plugin/tests/test-memory-service-map.sh
git commit -m "feat(memory): map container usage to services"
```

### Task 3: Projected start/rebuild guard

**Files:**
- Modify: `plugin/scripts/marina_memory.py`
- Modify: `plugin/scripts/marina_lifecycle.py`
- Modify: `plugin/scripts/marina_handler.py`
- Create: `plugin/tests/test-memory-guard.sh`
- Modify: `plugin/tests/test-rebuild-action.sh`

**Interfaces:**
- Produces: `memory_guard(root: Path, service_names: list[str], force: bool = False, snapshot: dict | None = None) -> dict[str, Any] | None`.
- Block reasons: `host-critical`, `docker-current`, `docker-projected`.
- `start_all(root: Path, force: bool = False)` gains the same force retry contract as individual start/rebuild.

- [ ] **Step 1: Write the failing policy test**

Cover host critical, current Docker reserve breach, predicted overcommit, unknown-only history, already-running exclusion, start-group selection, environment override, and force bypass.

```python
decision = mm.memory_guard(root, ["web"], snapshot=snapshot)
assert decision["blocked"] == "low-memory"
assert decision["reason"] == "docker-projected"
assert decision["estimatedAdditionalMb"] == 9144
assert decision["projectedFreeMb"] < decision["reserveMb"]
assert mm.memory_guard(root, ["web"], force=True, snapshot=snapshot) is None
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash plugin/tests/test-memory-guard.sh`

Expected: failure because `memory_guard` is absent.

- [ ] **Step 3: Implement guard policy**

Default reserve is `max(4096, round(dockerTotalMb * 0.20))`; an explicit `MARINA_DOCKER_RESERVE_MB` replaces that value. Current usage below reserve blocks even with unknown requested services. Projected usage adds only stopped requested services with known estimates. Return all explanatory fields from the design.

- [ ] **Step 4: Wire every lifecycle path**

Replace the old host-only `memory_block`. Individual `start` and `rebuild` pass one service. `start-all` uses stopped members of `x-marina.startGroup`, or all stopped services when no group exists, and accepts `force` from `/api/start-all`. Restart remains an existing-image restart and is guarded only by current critical pressure, without adding the service estimate twice.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
bash plugin/tests/test-memory-guard.sh
bash plugin/tests/test-rebuild-action.sh
bash plugin/tests/test-start-group.sh
bash plugin/tests/test-lifecycle-busy.sh
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina_memory.py plugin/scripts/marina_lifecycle.py plugin/scripts/marina_handler.py plugin/tests/test-memory-guard.sh plugin/tests/test-rebuild-action.sh
git commit -m "feat(memory): guard projected docker pressure"
```

### Task 4: Build pressure observation

**Files:**
- Modify: `plugin/scripts/marina_memory.py`
- Modify: `plugin/scripts/marina_cli.py`
- Modify: `plugin/scripts/marina_build.py`
- Modify: `plugin/tests/test-build-log.sh`
- Modify: `plugin/tests/test-build-summary.sh`

**Interfaces:**
- Produces: `start_pressure_observation() -> str`.
- Produces: `finish_pressure_observation(token: str) -> dict[str, Any]`.
- Build metadata field: `memoryPressure: {hostAvailableMinMb, containersPeakMb, dockerTotalMb, sampleCount, partial}`.

- [ ] **Step 1: Extend tests before production code**

Inject deterministic samples and assert two concurrent observation tokens share one sampler, each receives its own interval summary, and `_marina_cli_logged` writes the final summary for success, failure, and timeout.

```python
meta = mb.read_build_meta(success_log)
assert meta["memoryPressure"]["sampleCount"] >= 1
assert meta["memoryPressure"]["hostAvailableMinMb"] == 3800
summary = mb.build_summary(success_log)
assert summary["memoryPressure"] == meta["memoryPressure"]
```

- [ ] **Step 2: Run tests and verify RED**

Run: `bash plugin/tests/test-build-log.sh && bash plugin/tests/test-build-summary.sh`

Expected: failure on missing `memoryPressure`.

- [ ] **Step 3: Implement shared sampler and metadata threading**

Use one daemon sampler guarded by a condition/lock. It samples host availability frequently and reuses the Docker snapshot cache for normal-container totals. Register/unregister tokens without starting one thread per build. Always finish the token in `_marina_cli_logged`'s `finally` block and include the result in final metadata.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
bash plugin/tests/test-build-log.sh
bash plugin/tests/test-build-summary.sh
bash plugin/tests/test-build-summary-api.sh
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina_memory.py plugin/scripts/marina_cli.py plugin/scripts/marina_build.py plugin/tests/test-build-log.sh plugin/tests/test-build-summary.sh
git commit -m "feat(memory): record build pressure"
```

### Task 5: Dashboard display and confirmation flow

**Files:**
- Modify: `plugin/scripts/marina-web/index.html`
- Modify: `plugin/scripts/marina-web/app-3-util.js`
- Modify: `plugin/scripts/marina-web/app-5b-actions.js`
- Modify: `plugin/scripts/marina-web/styles.css`
- Create: `plugin/tests/test-memory-ui.sh`
- Modify: `plugin/tests/test-build-summary-ui.sh`

**Interfaces:**
- Consumes: structured memory snapshot and lifecycle block response.
- Produces: compact Docker usage, host availability, service current/peak/OOM labels, and force retry for both service and start-all actions.

- [ ] **Step 1: Write failing DOM/contract tests**

Assert the old ambiguous `dev ... 시스템 ...` string is removed, the header has Docker and host fields, service rows render `memoryUsageMb`, OOM state reaches `stateReason`, and both `action` and `sessionAction` retry with `force=true` only after confirmation.

- [ ] **Step 2: Run the UI test and verify RED**

Run: `bash plugin/tests/test-memory-ui.sh`

Expected: failure because the new fields and confirmation formatter are absent.

- [ ] **Step 3: Implement compact rendering**

Use `Docker 10.8 / 15.6 GB` and `Host available 15.8 GB`; fall back to host-only copy when Docker is unavailable. The confirmation must name the reason, projected free/reserve, largest estimates, and unknown services without showing `undefined`/`NaN`. Service rows show current memory in the existing right metadata slot and expose peak/limit/OOM in a title.

- [ ] **Step 4: Add build pressure to existing summary band**

Render observed host minimum and container peak only when `memoryPressure.sampleCount > 0`, labeled as observed pressure rather than BuildKit allocation.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
bash plugin/tests/test-memory-ui.sh
bash plugin/tests/test-build-summary-ui.sh
bash plugin/tests/test-dash-state-ui.sh
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina-web/index.html plugin/scripts/marina-web/app-3-util.js plugin/scripts/marina-web/app-5b-actions.js plugin/scripts/marina-web/styles.css plugin/tests/test-memory-ui.sh plugin/tests/test-build-summary-ui.sh
git commit -m "feat(memory): explain runtime pressure in dashboard"
```

### Task 6: Documentation and end-to-end verification

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md`

- [ ] **Step 1: Document controls and interpretation**

Document `MIN_FREE_MB`, `MARINA_DOCKER_RESERVE_MB`, force confirmation, local learned history, Docker-unavailable fallback, and the distinction between observed build pressure and exact BuildKit memory.

- [ ] **Step 2: Verify real Docker mapping**

With the running local stack, call `/api/sessions` and compare one service's `memoryUsageMb` with `docker stats --no-stream`. Confirm Compose project/service labels map the value to the correct worktree and that the 8+ GiB web service appears in the UI.

- [ ] **Step 3: Verify projected block without starting a duplicate heavy stack**

Run the policy function against the live snapshot and a temporary history fixture; assert the structured `docker-projected` decision. Do not actually start a second heavy web container for this test.

- [ ] **Step 4: Verify browser behavior with Aside**

Restart only the Marina dashboard, then use `snapshot(page, {interactive: true})` plus ref-id interactions at desktop and narrow viewport in light/dark themes. Confirm header text, service memory, warning confirmation, no overlap, and no console errors.

- [ ] **Step 5: Run the full suite**

Run every `plugin/tests/test-*.sh` and require `fail=0`. Confirm the live gateway PID/config/listener remain unchanged across the suite.

- [ ] **Step 6: Update roadmap and commit**

Mark P0.9 complete only after all checks pass and record the real measurements without claiming exact BuildKit allocation.

```bash
git add README.md docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md
git commit -m "docs(memory): document resource guard"
```
