# Stale Image Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep repeated Compose Start fast while automatically applying `--build` when declared build inputs differ from the last successful build.

**Architecture:** Extend the existing secret-safe build input module with a per-session, service-merged build baseline and a pure build-decision function. Capture at the Compose submit boundary for the Build Timeline and stale decision, then capture again after an effective build. Advance the baseline only when the inputs stayed stable and the resulting local image IDs verify.

**Tech Stack:** Python 3 standard library (`fcntl`, `json`, `tempfile`, `pathlib`), Bash integration tests, Docker Compose command dispatch.

## Global Constraints

- Use only Dockerfile, Compose `develop.watch` entries with `action: rebuild`, and final build args as freshness inputs.
- Do not scan the full build context or infer language-specific manifests.
- Never expose raw build arg values, digests, or HMAC values in logs or public APIs.
- Keep snapshot capture bounded at 500ms; `unknown` must warn and continue without automatic build.
- Update the baseline only after a successful command that actually used `--build`.
- Image-only services do not participate in stale-image decisions.
- Baseline and lock files must use mode `0600`, service-level merge, and atomic replacement.

## Review Hardening Checklist

- [x] Compare the baseline image ref with the current local Docker image ID, including A-to-B-to-A input changes.
- [x] Serialize overlapping builds of the same service while retaining parallelism across different services.
- [x] Use immutable per-invocation overlays so concurrent Compose calls cannot rewrite each other's submitted config.
- [x] Re-capture inputs after build and verify Compose image IDs against their image refs before advancing baseline.
- [x] Pause Marina-owned Compose Watch for an active build generation and restore it after success or failure.
- [x] Keep different services building in parallel with PID-stamped active tokens; serialize only overlapping services.
- [x] Publish Watch locks atomically and verify PID stamp, project, command, and PGID before terminating a watcher.
- [x] Keep an unchanged watcher alive across fast Start and preserve the original Compose exit code if refresh fails.
- [x] Re-check active builds under the Watch lock before spawn and compare resolved Compose model signatures.
- [x] Restore the previous watch service set when post-build Watch refresh cannot query Compose.
- [x] Hash directory contents with unambiguous records, including directory modes and directory symlinks.
- [x] Reject malformed baseline structures and keep timeout/error capture paths best-effort.

---

### Task 1: Build Baseline State And Decision

**Files:**
- Modify: `plugin/scripts/marina_build_inputs.py:98-225`
- Modify: `plugin/tests/test-build-inputs.sh:13-95`

**Interfaces:**
- Consumes: existing snapshot shape with `version`, `status`, and a service-keyed `services` mapping.
- Produces: `build_decision(current, baseline, explicit=False) -> tuple[bool, list[dict[str, str]]]`.
- Produces: `read_build_baseline(path: Path) -> dict[str, Any] | None`.
- Produces: `merge_build_baseline(path: Path, current: dict[str, Any]) -> None`.

- [x] **Step 1: Write failing decision tests**

Add assertions showing that same inputs stay fast, changed Dockerfile/rebuild/build-arg values build, missing service baseline builds once, explicit rebuild always builds, and `unknown` does not auto-build:

```python
should_build, reasons = build_decision(after, before)
assert should_build is True
assert {(item["kind"], item["change"]) for item in reasons} >= {
    ("dockerfile", "changed"),
    ("rebuild-input", "changed"),
    ("build-arg", "changed"),
}
assert build_decision(before, before) == (False, [])
assert build_decision(before, None)[0] is True
assert build_decision(before, before, explicit=True)[0] is True
assert build_decision({"version": 1, "status": "unknown"}, before) == (False, [
    {"kind": "unknown", "service": "", "label": "build 입력 수집 실패", "change": "unknown"}
])
```

- [x] **Step 2: Run the focused test and verify RED**

Run: `bash plugin/tests/test-build-inputs.sh`

Expected: import failure for `build_decision`, `read_build_baseline`, or `merge_build_baseline`.

- [x] **Step 3: Implement the pure decision**

Reuse `compare_build_inputs` so the decision contains only safe projected reasons:

```python
def build_decision(current, baseline, explicit=False):
    reasons = compare_build_inputs(current, baseline, "rebuild" if explicit else "start")
    if explicit:
        return True, reasons
    if current.get("status") != "ok" or not (current.get("services") or {}):
        return False, reasons
    return bool(reasons), reasons
```

- [x] **Step 4: Add failing baseline persistence tests**

Test missing/corrupt reads, `0600` permissions, selective service merge, and concurrent writers preserving all services:

```python
baseline_path = root / "session" / "build-baseline.json"
assert read_build_baseline(baseline_path) is None
merge_build_baseline(baseline_path, before)
assert read_build_baseline(baseline_path) == before
assert baseline_path.stat().st_mode & 0o777 == 0o600

with ThreadPoolExecutor(max_workers=2) as executor:
    list(executor.map(
        lambda snapshot: merge_build_baseline(baseline_path, snapshot),
        [web_snapshot, api_snapshot],
    ))
assert set(read_build_baseline(baseline_path)["services"]) == {"api", "web"}
```

- [x] **Step 5: Run the focused test and verify RED**

Run: `bash plugin/tests/test-build-inputs.sh`

Expected: persistence assertions fail because baseline functions do not exist.

- [x] **Step 6: Implement locked atomic baseline merge**

Create the parent directory, lock `<path>.lock` with `fcntl.LOCK_EX`, read a valid existing service map or start empty, merge only current services, and call `write_build_input_snapshot` while holding the lock. Reject `unknown` snapshots without changing the file.

```python
def merge_build_baseline(path: Path, current: dict[str, Any]) -> None:
    if current.get("status") != "ok":
        return
    lock_fd = os.open(str(path) + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.chmod(str(path) + ".lock", 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        previous = read_build_baseline(path) or {"version": 1, "status": "ok", "services": {}}
        merged = dict(previous["services"])
        merged.update(current.get("services") or {})
        write_build_input_snapshot(path, {"version": 1, "status": "ok", "services": merged})
    finally:
        os.close(lock_fd)
```

- [x] **Step 7: Run the focused test and verify GREEN**

Run: `bash plugin/tests/test-build-inputs.sh`

Expected: `PASS test-build-inputs`.

- [x] **Step 8: Commit baseline behavior**

```bash
git add plugin/scripts/marina_build_inputs.py plugin/tests/test-build-inputs.sh
git commit -m "feat(build): track successful build baseline"
```

### Task 2: Compose Conditional Auto-Build

**Files:**
- Modify: `plugin/scripts/marina-compose.py:25-30,806-976`
- Modify: `plugin/tests/test-compose-overlay.sh:56-84`
- Modify: `plugin/tests/test-compose-dispatch.sh:10-80`

**Interfaces:**
- Consumes: `build_decision`, `read_build_baseline`, and `merge_build_baseline` from Task 1.
- Produces: `_capture_build_inputs(a, config, requested, build_args) -> dict` with the existing 500ms bound.
- Produces: `_build_reason_text(reason: dict[str, str]) -> str` containing service/label/change only.
- Keeps: Build Timeline handoff at `MARINA_BUILD_INPUT_SNAPSHOT` using the same captured snapshot.

- [x] **Step 1: Write failing capture-return tests**

Update the direct capture test to assert the captured snapshot is returned and still written to the handoff. Keep the stalled capture assertion and require it to return `unknown` within the bound:

```python
captured = mc._capture_build_inputs(args, config, ["web"], build_args)
assert captured["status"] == "ok"
assert json.load(open(handoff, encoding="utf-8")) == captured

unknown = mc._capture_build_inputs(args, {"services": {}}, [], {})
assert unknown == {"version": 1, "status": "unknown"}
```

- [x] **Step 2: Run the focused test and verify RED**

Run: `bash plugin/tests/test-compose-overlay.sh`

Expected: `AttributeError` because `_capture_build_inputs` does not exist.

- [x] **Step 3: Refactor bounded capture to return one snapshot**

Have the fork write to a private temporary capture path under the session directory, read it in the parent, copy the sanitized payload to the optional Build Timeline handoff, and return the payload. Preserve the 500ms kill/reap behavior and remove the private temporary file in all paths.

- [x] **Step 4: Run the focused test and verify GREEN**

Run: `bash plugin/tests/test-compose-overlay.sh`

Expected: `PASS test-compose-overlay`.

- [x] **Step 5: Write failing dispatch tests for first, repeated, changed, failed, and image-only starts**

Change the fixture to include one build service with a Dockerfile and one image-only service. Assert this sequence:

```bash
mrun start --api      # no baseline: --build
mrun start --api      # baseline exists: no --build
printf '# changed\n' >> "$P/api/Dockerfile"
mrun start --api      # changed: --build and safe reason in output
printf '# changed again\n' >> "$P/api/Dockerfile"
FAIL_UP=1 mrun start --api || true
# same input must still be stale because failed build did not advance baseline
mrun start --api
mrun rebuild --api    # explicit --build even when unchanged
mrun start --db       # image-only: no --build
```

Also assert the build log/output contains no `file:`, `hmac`, or raw build arg values.

- [x] **Step 6: Run the focused dispatch test and verify RED**

Run: `bash plugin/tests/test-compose-dispatch.sh`

Expected: first or changed Start lacks `--build`, and no baseline file is created.

- [x] **Step 7: Implement effective build orchestration**

At the existing submit boundary:

```python
current = _capture_build_inputs(a, config, requested, build_args)
baseline_path = Path(a.session_dir) / "build-baseline.json"
effective_build, reasons = build_decision(
    current, read_build_baseline(baseline_path), explicit=bool(a.build)
)
if current.get("status") != "ok":
    sys.stderr.write("warning: build 입력을 확인하지 못해 기존 이미지로 시작합니다; 문제가 있으면 Rebuild를 실행하세요.\n")
elif effective_build and not a.build:
    for reason in reasons:
        print("stale image: " + _build_reason_text(reason) + "; Start에 --build 자동 적용")
argv = up_argv(
    a.stored, op, a.project_dir, name, requested + sidecars,
    build=effective_build,
)
rc = subprocess.call(argv, env=env)
if rc == 0 and effective_build and current.get("status") == "ok":
    merge_build_baseline(baseline_path, current)
```

Reason formatting must use only `kind`, `service`, `label`, and `change`; explicit Rebuild need not print a stale warning.

- [x] **Step 8: Run focused regression tests and verify GREEN**

Run:

```bash
bash plugin/tests/test-build-inputs.sh
bash plugin/tests/test-compose-overlay.sh
bash plugin/tests/test-compose-dispatch.sh
bash plugin/tests/test-build-log.sh
bash plugin/tests/test-build-summary.sh
bash plugin/tests/test-build-summary-api.sh
```

Expected: each command prints its `PASS` line.

- [x] **Step 9: Commit Compose integration**

```bash
git add plugin/scripts/marina-compose.py plugin/tests/test-compose-overlay.sh plugin/tests/test-compose-dispatch.sh
git commit -m "feat(compose): rebuild stale images on start"
```

### Task 3: Documentation And Full Regression

**Files:**
- Modify: `README.md:210-245,320-330,558-566`
- Modify: `docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md:198-216`
- Modify: `docs/superpowers/specs/2026-07-14-compose-watch-standard-dev-design.md:123-136`

**Interfaces:**
- Consumes: final Start/Rebuild behavior from Task 2.
- Produces: user-facing lifecycle documentation and an updated P0 checklist.

- [x] **Step 1: Update lifecycle documentation**

Document these exact semantics without exposing the internal digest format:

```text
Start/Restart: declared build inputs match the last successful build -> fast up.
Start/Restart: Dockerfile, Compose Watch rebuild path, or build arg changed -> automatic --build.
Rebuild: always evaluates the build.
Unknown capture: starts the existing image with a warning.
```

State that files baked into an image must be declared as Compose Watch `action: rebuild`; Marina does not scan the full context.

- [x] **Step 2: Update roadmap status**

Mark the stale-image pre-start guard complete while leaving Clean Rebuild and memory resource guard pending. Replace the old statement that Watch-off dependency changes always require manual Rebuild.

- [x] **Step 3: Run documentation and full regression checks**

Run:

```bash
git diff --check
for test in plugin/tests/*.sh; do bash "$test"; done
```

Expected: `git diff --check` emits nothing and every test exits zero or reports its documented environment skip.

- [x] **Step 4: Inspect the final diff for secret and scope regressions**

Run:

```bash
git diff --stat origin/main...HEAD
git diff origin/main...HEAD -- plugin/scripts/marina_build_inputs.py plugin/scripts/marina-compose.py README.md
rg -n "TO[D]O|TB[D]|FIX[M]E" docs/superpowers/plans/2026-07-15-stale-image-guard.md docs/superpowers/specs/2026-07-15-stale-image-guard-design.md
```

Expected: only stale-image guard files and previously approved design/plan docs are changed; no placeholder matches.

- [x] **Step 5: Commit docs**

```bash
git add README.md docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md docs/superpowers/specs/2026-07-14-compose-watch-standard-dev-design.md
git commit -m "docs(build): explain automatic stale rebuilds"
```

### Task 4: Review Correctness Hardening

**Files:**
- Modify: `plugin/scripts/marina_build_inputs.py`
- Modify: `plugin/scripts/marina-compose.py`
- Test: `plugin/tests/test-build-inputs.sh`
- Test: `plugin/tests/test-compose-overlay.sh`
- Test: `plugin/tests/test-compose-dispatch.sh`

**Interfaces:**
- Produces: baseline `image: {ref, id}` identity checked before every fast Start.
- Produces: service-keyed build locks held from overlay submission through baseline update.
- Extends: Dockerfile inputs with `dockerfile_inline` and directory inputs with content hashing.

- [x] **Step 1: Reproduce external image ABA and overlapping same-service Start**

- [x] **Step 2: Store and verify actual Compose image identity**

- [x] **Step 3: Serialize overlapping build services with deterministic file locks**

- [x] **Step 4: Reject structurally corrupt baselines and bound capture setup failures**

- [x] **Step 5: Hash inline Dockerfiles and declared rebuild directory contents**

- [x] **Step 6: Run focused Build Timeline, Why Rebuilt, dispatch, and Watch regressions**
