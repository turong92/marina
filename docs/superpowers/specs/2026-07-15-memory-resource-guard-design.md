# Memory Resource Guard

Date: 2026-07-15

Status: design approved, implementation planning pending

## Goal

Marina must show the memory pressure that actually affects local Compose stacks and stop a likely unsafe
start or rebuild before it takes down another worktree. The user can review the warning and explicitly force
the operation.

This is a generic Marina capability. It must work from Docker and Compose metadata without project-specific
service names, image assumptions, or an `x-marina` memory schema.

## Current Problem

The dashboard currently derives host free memory from macOS `memory_pressure` and blocks only when that value
falls below `MIN_FREE_MB` (default 4096). Compose services leave `rssMb` empty, so the dashboard's `dev` total
does not include their real container memory.

On the observed machine the host still had 43% free memory while Docker had a 15.6 GiB VM allocation and the
running containers used about 10.8 GiB. A single `web` container used 8.93 GiB. The existing host-only guard
therefore allowed another stack even though a second comparable service could not fit safely.

## Approaches Considered

### 1. Live metrics only

Show `docker stats` and warn only when current usage crosses a fixed threshold.

This is cheap and accurate for the present moment, but it cannot warn before starting a second large service.
It does not solve the reported multi-worktree failure mode.

### 2. Live metrics plus learned high-water estimates

Observe real container usage, retain a bounded high-water value by registered project and Compose service,
and use that value to estimate the incremental cost of starting a stopped service. This is the selected design.

It remains generic, improves as the team uses Marina, and can explain both the current pressure and the estimate
that triggered a warning. Unknown services remain unknown rather than receiving a fabricated default.

### 3. Generate Compose memory limits

Inject `mem_limit` or deploy resource limits into project overlays.

This would produce deterministic caps, but Marina cannot choose correct application limits and could turn a
warning feature into application OOM failures. Resource-limit authoring stays owned by each project.

## Data Collection

Add a memory module that produces one cached snapshot from standard Docker CLI output:

- Host total and available memory:
  - macOS: existing `sysctl` and `memory_pressure` implementation.
  - Linux: `/proc/meminfo`, using `MemAvailable`.
  - Unsupported hosts: nullable values; memory collection never breaks session polling.
- Docker capacity: `docker info --format '{{json .}}'`, especially `MemTotal`, server OS, and availability.
- Container usage: `docker stats --no-stream --format '{{json .}}'`.
- Container identity: Compose labels from `docker ps`/inspect, including project and service.
- OOM state and configured limit: container inspect state and host config, fetched outside the polling hot path
  and cached by container ID.

IEC and SI Docker size strings are parsed by one tested structured helper. A failed or slow Docker command
returns a stale cached snapshot with an error marker instead of blocking the dashboard indefinitely.

The snapshot cache has a short TTL and a single-flight refresh. Concurrent `/api/sessions` requests must not
launch duplicate `docker stats` commands. A lifecycle guard requests a fresh snapshot with a strict timeout.

## Mapping And History

Running containers are mapped back to Marina sessions with Compose project and service labels. Each service
payload receives:

- `memoryUsageMb`: current Docker-reported working usage.
- `memoryLimitMb`: configured limit when finite, otherwise Docker capacity.
- `memoryPercent`: usage divided by the effective limit.
- `memoryPeakMb`: learned high-water for the registered project/service.
- `oomKilled`: whether the last container exit was an OOM kill.

Observed high-water values are stored atomically under Marina's local state, keyed by registered project ID and
Compose service name. They are local runtime observations, not repository configuration. History is bounded to
known registered projects and stores only numeric usage, timestamp, and image identity; no environment values or
container logs are retained.

An image change does not discard history immediately. The record keeps image identity and confidence so the UI
can explain whether an estimate came from the same image or only the same project/service. Current same-image
observations have the highest confidence.

## Guard Decision

The guard evaluates both host pressure and Docker projected pressure before `start` and `rebuild`:

1. Preserve the existing host-critical rule: available host memory below `MIN_FREE_MB` blocks unless forced.
2. Compute Docker headroom as capacity minus the sum of current container working usage.
3. For each requested stopped service, use the best learned high-water estimate. Already-running services add no
   projected startup cost.
4. Keep a Docker reserve of `MARINA_DOCKER_RESERVE_MB`, defaulting to the larger of 4096 MiB or 20% of Docker
   capacity.
5. Block when projected headroom falls below that reserve.
6. If some requested services have no estimate, report them as unknown. Unknown data alone never blocks; current
   Docker headroom can still trigger the reserve rule.

The response is machine-readable and explanatory:

```json
{
  "blocked": "low-memory",
  "reason": "docker-projected",
  "hostFreeMb": 15800,
  "dockerTotalMb": 15972,
  "dockerUsedMb": 11060,
  "estimatedAdditionalMb": 9144,
  "reserveMb": 4096,
  "projectedFreeMb": -4232,
  "estimatedServices": [{"service": "web", "memoryMb": 9144, "confidence": "same-image"}],
  "unknownServices": []
}
```

The dashboard confirmation names the pressure source and the largest estimated services. Confirming repeats the
same operation with `force=true`; Marina never silently changes Compose limits or stops another worktree.

## Build Peak

BuildKit memory is not reliably exposed as a normal container with every Docker driver. Marina therefore must not
label the sum of `docker stats` as complete BuildKit VM usage.

During a dashboard-triggered build or rebuild, a shared low-frequency sampler records:

- minimum observed host available memory;
- maximum observed normal-container memory;
- Docker capacity and baseline usage;
- sampling interval and whether samples were partial.

These values are written into the existing build metadata sidecar and shown as observed pressure, not as an exact
BuildKit allocation. On Linux the host minimum captures Docker build pressure directly; on Docker Desktop it is a
host-level safety signal. The sampler is shared across concurrent builds so it does not multiply `docker stats`
processes.

## Dashboard

Replace the ambiguous header text with two compact readings when available:

- `Docker 10.8 / 15.6 GB`
- `Host available 15.8 GB`

Service rows use the existing compact metadata area to show current memory. A detail tooltip or existing service
detail surface shows current, learned peak, limit, and OOM state. No new page or nested card is introduced.

Memory severity uses neutral, warning, and critical states. It is based on headroom and limits, not a project name
or service category. If Docker metrics are unavailable, the UI explicitly falls back to host-only data.

## Failure And Performance Rules

- Docker unavailable: retain host-only behavior and expose `docker.available=false`.
- `docker stats` timeout: serve the last snapshot as stale; never stall all session polling.
- Parse failure for one container: omit that container and mark the snapshot partial.
- No history: show current usage and `estimate unavailable`; do not invent a number.
- Concurrent starts: each guard refreshes under a single-flight lock and evaluates against the newest snapshot.
- Forced operation: bypasses both host and Docker blocks but still records the warning decision in build metadata.
- Existing `MIN_FREE_MB` remains supported; the new Docker reserve has its own environment variable.

## Testing

- Unit tests for Docker byte parsing, host fallbacks, aggregation, history, confidence, and projected headroom.
- Command-fake tests for timeout, stale cache, partial stats, OOM, and Docker-unavailable behavior.
- Lifecycle tests proving a predicted overcommit blocks and `force=true` proceeds.
- `--all` tests proving running services are not double-counted and unknown services are reported.
- API/UI contract tests for Docker/host display and service memory fields.
- Aside verification on desktop and narrow viewports, light and dark themes.
- Real Docker smoke test confirming container usage maps to the correct worktree and service.

## Non-Goals

- Automatically editing Compose resource limits.
- Killing or pausing other worktrees to make room.
- Claiming exact BuildKit memory when the Docker driver does not expose it.
- Uploading team memory history or adding a Marina-specific project schema.
- Solving application-level memory leaks; Marina identifies the service and pressure so the project can fix them.

## Completion Criteria

- Compose service memory is non-null for running containers when Docker exposes stats.
- The dashboard distinguishes Docker usage from host availability.
- Starting another service comparable to the observed 8.93 GiB `web` is blocked when projected Docker headroom is
  below reserve, and explicit confirmation proceeds.
- OOM-killed containers are labeled as OOM rather than generic failure.
- Docker metric collection does not materially slow normal session polling and degrades safely when unavailable.
- The Orca roadmap marks P0.9 complete only after unit, lifecycle, UI, and real Docker verification pass.
