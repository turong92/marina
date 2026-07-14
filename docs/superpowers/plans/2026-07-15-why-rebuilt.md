# Why Rebuilt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Timeline 아래에 이전 build run과 비교한 Dockerfile, declared rebuild path, build arg 변경 이유를 안전하게 표시한다.

**Architecture:** `marina_build_inputs.py`가 Compose 기반 입력 snapshot과 순수 비교를 소유한다. lifecycle logger가
snapshot을 run meta에 기록하고 `marina_build.py`가 직전 snapshot과 비교해 reasons만 summary에 추가한다.
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
- Produces: `capture_build_inputs(root: Path, args: tuple[str, ...], env: dict[str, str]) -> dict[str, Any]`
- Produces: `compare_build_inputs(current: dict, previous: dict | None, op: str) -> list[dict[str, str]]`

- [ ] **Step 1: Write failing pure-function tests**

Create fixtures with two services and assert Dockerfile, rebuild path, and build arg added/changed/removed reasons. Assert
the serialized snapshot contains neither `hunter2` nor `local-secret`.

- [ ] **Step 2: Verify RED**

Run: `bash plugin/tests/test-build-inputs.sh`  
Expected: FAIL because `marina_build_inputs` does not exist.

- [ ] **Step 3: Implement snapshot collection**

Use `hashlib.sha256` for declared files, a deterministic metadata walk for directories, and
`hmac.new(local_key, canonical_json, hashlib.sha256)` for build arg values. Resolve selected services with
`marina-compose.py`'s `resolved_start_targets` and merge local `build-args.json`/`buildArgsFrom` over Compose args.

- [ ] **Step 4: Implement comparison and verify GREEN**

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

- [ ] **Step 1: Add failing lifecycle/meta tests**

Stub `capture_build_inputs`, run two logged lifecycle calls, and assert each `.meta.json` preserves its snapshot while
the summary of the second run returns changed reasons.

- [ ] **Step 2: Verify RED**

Run: `bash plugin/tests/test-build-log.sh && bash plugin/tests/test-build-summary.sh`; expected FAIL on missing inputs/reasons.

- [ ] **Step 3: Capture inputs without blocking lifecycle**

Call `capture_build_inputs` before `write_build_meta`; catch every exception and store `{version: 1, status: "unknown"}`.
Carry the same snapshot into final success/failure metadata.

- [ ] **Step 4: Compare nearest previous run**

Find the numerically closest earlier `run-*.meta.json` containing `inputs`, call `compare_build_inputs`, and include only
the resulting reasons in the public summary.

- [ ] **Step 5: Verify GREEN**

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

- [ ] **Step 1: Add failing API/UI tests**

Assert API JSON contains redacted reason labels without `inputs`, `digest`, `hmac`, or fixture secrets. Assert UI has
`data-build-reasons`, a `<details>` disclosure, and CSS that wraps long labels on a 560px viewport.

- [ ] **Step 2: Verify RED**

Run API/UI tests; expected FAIL.

- [ ] **Step 3: Implement safe API projection**

Redact each reason `label`, keep only `kind`, `service`, `label`, `change`, and return no snapshot data.

- [ ] **Step 4: Render summary and details**

Show at most three labels in the closed summary. Use Korean labels for first-run, explicit rebuild, Dockerfile,
dependency input, and build arg. Escape every dynamic field.

- [ ] **Step 5: Verify GREEN and browser layout**

Run API/UI tests, then use Aside on desktop and narrow viewport with light/dark themes. Expected: no overlap, details
opens, and raw log remains visible below.

### Task 4: Roadmap and Release Verification

**Files:**
- Modify: `docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md`

**Interfaces:**
- Consumes: completed backend/API/UI behavior.
- Produces: checked P0.2 milestone and verified release commit.

- [ ] **Step 1: Run focused tests**

Run all five build input/summary tests. Expected: all PASS.

- [ ] **Step 2: Run full suite**

Run `for test_file in plugin/tests/test-*.sh; do bash "$test_file"; done`. Expected: zero failures.

- [ ] **Step 3: Update roadmap and commit**

Check P0.2 and record that comparisons are Compose-declared, secret-safe, and scoped to Marina lifecycle runs.

