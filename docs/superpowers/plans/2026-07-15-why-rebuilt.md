# Why Rebuilt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Timeline 아래에 이전 build run과 비교한 Dockerfile, declared rebuild path, build arg 변경 이유를 안전하게 표시한다.

**Architecture:** `marina_build_inputs.py`가 Compose 기반 입력 snapshot과 순수 비교를 소유한다. `marina-compose.py`가
준비 완료 후 `docker compose up` 직전에 이미 해석한 config로 snapshot을 만들고 lifecycle logger에 handoff한다.
수집은 500ms 제한 자식 프로세스에서 best-effort로 수행하고 build run/handoff 경로는 동시 요청에도 원자 할당한다.
`marina_build.py`는 서비스별 가장 가까운 과거 snapshot과 비교해 reasons만 summary에 추가한다.
API는 기존 redaction 경계에서 reasons를 전달하고 UI는 한 줄 요약과 접이식 상세를 렌더한다.

**Tech Stack:** Python 3 표준 라이브러리, Docker Compose config JSON, vanilla JavaScript/CSS, bash tests.

## Global Constraints

- 언어·프레임워크 manifest 이름을 추측하지 않고 Compose `action: rebuild` 경로만 사용한다.
- build arg 원문을 run meta, 로그, API에 저장하지 않는다.
- snapshot 수집 실패는 lifecycle 실행을 막지 않는다.
- digest는 설명용이며 cache key나 Watch trigger가 아니다.
- 기존 build summary의 raw log source-of-truth와 redaction을 유지한다.

---

### Task 1: Build Input Snapshot and Comparison

**Files:**
- Create: `plugin/scripts/marina_build_inputs.py`
- Create: `plugin/tests/test-build-inputs.sh`

**Interfaces:**
- Produces: `build_input_snapshot(...)` and atomic handoff writer/reader
- Produces: `compare_build_inputs(current: dict, previous: dict | None, op: str) -> list[dict[str, str]]`

- [x] **Step 1: Write failing pure-function tests**

Create fixtures with two services and assert Dockerfile, rebuild path, and build arg added/changed/removed reasons. Assert
the serialized snapshot contains neither `hunter2` nor `local-secret`.

- [x] **Step 2: Verify RED**

Run: `bash plugin/tests/test-build-inputs.sh`  
Expected: FAIL because `marina_build_inputs` does not exist.

- [x] **Step 3: Implement snapshot collection**

Use `hashlib.sha256` for declared files, a deterministic metadata walk for directories, and
`hmac.new(local_key, canonical_json, hashlib.sha256)` for build arg values. Resolve selected services with
`marina-compose.py`의 resolved targets와 실제 `--build-arg`를 입력으로 받아 Compose args 위에 병합한다.

- [x] **Step 4: Implement comparison and verify GREEN**

Return only `{kind, service, label, change}` objects. Run `bash plugin/tests/test-build-inputs.sh`; expected PASS.

### Task 2: Run Metadata and Build Summary

**Files:**
- Modify: `plugin/scripts/marina_cli.py`
- Modify: `plugin/scripts/marina_build.py`
- Modify: `plugin/tests/test-build-log.sh`
- Modify: `plugin/tests/test-build-summary.sh`

**Interfaces:**
- Consumes: Task 1 snapshot/comparison functions.
- Produces: `build_summary(log_path)` response with `reasons` and no `inputs` field.

- [x] **Step 1: Add failing lifecycle/meta tests**

Use a fake lifecycle that writes the handoff file, then assert `.meta.json` preserves its snapshot, removes the handoff,
and keeps status/timing fields unchanged. Assert Compose `up` sees the snapshot file already written.

- [x] **Step 2: Verify RED**

Run: `bash plugin/tests/test-build-log.sh && bash plugin/tests/test-build-summary.sh`; expected FAIL on missing inputs/reasons.

- [x] **Step 3: Capture inputs without blocking lifecycle**

Write `pending` in the running meta. After external attach, prebuild, and links are prepared, have `marina-compose.py` write
the snapshot immediately before its Compose `up` subprocess using the already resolved config and effective build args.
Run collection in a child with a 500ms deadline so a stalled directory walk cannot block Compose submission. Atomically
allocate concurrent build run/handoff paths and hold an active file lock until each lifecycle ends so retention never
deletes an open run. The parent consumes and removes the 0600 handoff file; missing, timed-out, or failed handoff becomes
only `{version: 1, status: "unknown"}`.

- [x] **Step 4: Compare nearest previous run**

For each current service, find the numerically closest earlier `run-*.meta.json` containing that service's `inputs`, call
`compare_build_inputs`, and include only the resulting reasons in the public summary.

- [x] **Step 5: Verify GREEN**

Run both tests; expected PASS.

### Task 3: API and Dashboard UI

**Files:**
- Modify: `plugin/scripts/marina_handler.py`
- Modify: `plugin/scripts/marina-web/app-4b-build.js`
- Modify: `plugin/scripts/marina-web/styles.css`
- Modify: `plugin/tests/test-build-summary-api.sh`
- Modify: `plugin/tests/test-build-summary-ui.sh`

**Interfaces:**
- Consumes: `reasons` from Task 2.
- Produces: Build Timeline reason summary and native `<details>` disclosure.

- [x] **Step 1: Add failing API/UI tests**

Assert API JSON contains redacted reason labels without `inputs`, `digest`, `hmac`, or fixture secrets. Assert UI has
`data-build-reasons`, a `<details>` disclosure, and CSS that wraps long labels on a 560px viewport.

- [x] **Step 2: Verify RED**

Run API/UI tests; expected FAIL.

- [x] **Step 3: Implement safe API projection**

Redact each reason `label`, keep only `kind`, `service`, `label`, `change`, and return no snapshot data.

- [x] **Step 4: Render summary and details**

Show at most three labels in the closed summary. Use Korean labels for first-run, explicit rebuild, Dockerfile,
dependency input, and build arg. Escape every dynamic field.

- [x] **Step 5: Verify GREEN and browser layout**

Run API/UI tests, then use Aside on desktop and narrow viewport with light/dark themes. Expected: no overlap, details
opens, and raw log remains visible below.

### Task 4: Roadmap and Release Verification

**Files:**
- Modify: `docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md`

**Interfaces:**
- Consumes: completed backend/API/UI behavior.
- Produces: checked P0.2 milestone and verified release commit.

- [x] **Step 1: Run focused tests**

Run all five build input/summary tests. Expected: all PASS.

- [x] **Step 2: Run full suite**

Run `for test_file in plugin/tests/test-*.sh; do bash "$test_file"; done`. Expected: zero failures.

- [x] **Step 3: Update roadmap and commit**

Check P0.2 and record that comparisons are Compose-declared, secret-safe, and scoped to Marina lifecycle runs.
