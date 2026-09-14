# Docker GC 정책 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 워크트리에 묶이지 않는 도커 산출물(빌드캐시·dangling 이미지·익명 볼륨·e2e 잔재)을 marina 가 정책대로 주기 회수한다.

**Architecture:** 순수 모듈 `marina_docker_gc.py` 가 정책·판정·실행을 쥐고 도커 호출을 `run(args)` 하나로 추상화한다(테스트는 가짜 run). 데몬 스레드·CLI·HTTP API 는 그 모듈을 얇게 감싼다. 대시보드는 헤더 배지 + 팝오버 한 파일(`app-6f-docker-gc.js`). 테스트 하네스는 `MARINA_E2E=1` 로 compose 오버레이에 라벨을 넣어 이후 누수를 정책이 회수하게 한다.

**Tech Stack:** Python 3 stdlib(subprocess/json/threading), bash, vanilla JS/CSS, docker CLI 29.

**Spec:** `docs/superpowers/specs/2026-09-14-docker-gc-policy-design.md`

## Global Constraints

- `marina_lifecycle.py`(remove_worktree/clear_worktree_images) 는 수정 금지 — 별도 세션 범위.
- 모든 `test-*.sh` 는 첫 부분에서 `lib/harness.sh` 를 source. 실 도커를 만지는 테스트는 dry-run 경로만.
- 삭제 명령에 `-f` 금지(`docker rm`, `docker image rm`, `docker network rm`). prune 계열은 `-f` 가 "확인 생략" 의미라 허용.
- 정책 키/기본값: enabled=true, interval_hours=24, build_cache_keep_days=7, dangling_images=true, anonymous_volumes=true, stale_test_artifacts_days=3, stale_test_artifact_names=["marina-*-e2e-*"].
- 파일: `~/.marina/docker-gc.json`(정책), `docker-gc-state.json`(상태), `docker-gc.log`(사람용).
- 라벨: `marina.e2e=1`.

---

### Task 1: 정책 로드/저장 + due 판정 (`marina_docker_gc.py` 1부)

**Files:** Create `plugin/scripts/marina_docker_gc.py`; Test `plugin/tests/test-docker-gc-policy.sh`

**Produces:** `DEFAULT_POLICY`, `POLICY_FILE/STATE_FILE/LOG_FILE`, `load_policy() -> dict`, `set_policy(key, value) -> dict`(ValueError on bad key/value; 문자열→타입 변환), `load_state() -> dict`, `due(policy, state, now) -> bool`, `next_run_at(policy, state) -> float|None`.

- [ ] 테스트: 파일 없음→기본값; 부분 파일 머지; 틀린 타입(`"interval_hours": "abc"`)→기본값+`warnings`; `set_policy("interval_hours","12")`→int, `set_policy("dangling_images","false")`→False, `set_policy("stale_test_artifact_names","a*,b*")`→list, 모르는 키→ValueError, 음수→ValueError; 쓴 뒤 파일이 valid JSON; `due`: enabled=false→False, state 없음→True, lastRun 이 interval 안→False, 밖→True.
- [ ] 실패 확인 → 구현 → 통과 → 커밋.

### Task 2: 판정(plan)·실행(collect)·로그 (`marina_docker_gc.py` 2부)

**Files:** Modify `plugin/scripts/marina_docker_gc.py`; Test `plugin/tests/test-docker-gc-plan.sh`

**Produces:** `plan(policy, now=None, run=None) -> dict(Report)`, `collect(policy, source, dry_run=False, now=None, run=None) -> Report`, `status(run=None) -> dict`, `_docker_run(args) -> str`, `parse_docker_time(s) -> float`, `parse_reclaimed_mb(text) -> int|None`.

가짜 run: dict `{tuple(args)[:N] → output}` 매칭 + 호출 기록. 시나리오는 스펙 "테스트" 절 그대로.

- [ ] 테스트 작성(각 단계의 포함/제외 경계, dry-run 삭제 0회, 실행 명령 순서·`-f` 없음, 단계 실패 계속, reclaimed 파싱, 로그/상태 파일).
- [ ] 실패 확인 → 구현 → 통과 → 커밋.

### Task 3: 데몬 루프

**Files:** Modify `plugin/scripts/marina_handler.py` (main 의 스레드 시작부), `plugin/scripts/marina_docker_gc.py`(`daemon_tick(port) -> str`); Test `plugin/tests/test-docker-gc-daemon-loop.sh`

**Produces:** `daemon_tick(port, now=None, run=None, primary=None) -> "skipped:not-primary"|"skipped:not-due"|"ran"|"failed:<msg>"` — 예외를 삼키고 문자열로 보고. `main()` 이 `_gc_loop` 스레드(60s 지연, 600s 주기)를 띄운다.

- [ ] 테스트: due 아니면 collect 안 부름; due 면 부름; collect 가 raise 해도 "failed:" 반환; primary=False 면 skipped.
- [ ] 구현·통과·커밋.

### Task 4: CLI `marina docker gc`

**Files:** Create `plugin/scripts/marina_docker_gc_cli.py`; Modify `plugin/scripts/marina-entrypoint.sh`(`docker)` 분기 + usage); Test `plugin/tests/test-docker-gc-cli.sh`

- [ ] 테스트: `policy` 출력에 기본키; `policy interval_hours 12` 후 파일 반영; `policy nope 1` → exit 2; `--dry-run --json`(PATH 앞에 가짜 docker 스크립트) → `dryRun:true`, steps 4개; `status --json` 에 policy/state/disk; enabled=false 에서 인자 없는 `gc` 는 실행 안 하고 안내(exit 0).
- [ ] 구현·통과·커밋.

### Task 5: HTTP API

**Files:** Modify `plugin/scripts/marina_handler.py`(GET `/api/docker-gc`, POST `/api/docker-gc/run`·`/api/docker-gc/policy`, `_ADMIN_POST_PATHS`); Test `plugin/tests/test-docker-gc-api.sh`

- [ ] 테스트: 데몬 띄워(가짜 docker PATH, 격리 MARINA_HOME) GET → policy.enabled true; POST policy {key:"interval_hours",value:6} → 6; POST run {dryRun:true} → dryRun true, 가짜 docker 로그에 rm/prune 0회.
- [ ] 구현·통과·커밋.

### Task 6: 대시보드 배지·팝오버

**Files:** Modify `plugin/scripts/marina-web/index.html`(헤더 `#dgc` + script 태그), `styles.css`; Create `plugin/scripts/marina-web/app-6f-docker-gc.js`; Test `plugin/tests/test-docker-gc-ui.sh`

- [ ] 테스트(관례: grep 존재 검사): `id="dgc"`, `id="dgcBtn"`, `id="dgcMenu"`, `app-6f-docker-gc.js` 로드, `function loadDockerGc`, `/api/docker-gc/run`, `/api/docker-gc/policy`, `.dgc` css, `withBusy`.
- [ ] 구현 → `marina-preview`(:3901) 실측 스크린샷 → 커밋.

### Task 7: 테스트 하네스 라벨

**Files:** Modify `plugin/tests/lib/harness.sh`(`export MARINA_E2E=1`), `plugin/scripts/marina-compose.py`(`build_overlay(..., extra_labels=None)` + up 에서 env 읽기), `plugin/tests/test-compose-weave-e2e.sh`(`docker run --label marina.e2e=1`); Test `plugin/tests/test-docker-gc-overlay-labels.sh`, `plugin/tests/test-docker-gc-e2e-label.sh`; Modify `plugin/tests/test-harness-isolation.sh` 의 "leaked" 검사가 `MARINA_E2E` 를 허용하도록.

- [ ] 테스트: overlay 에 `labels:`/`build: labels:`/`networks: default: labels:`; extra_labels 없으면 문자열에 `marina.e2e` 0회; external 네트워크엔 안 붙음. 스위트 전체의 `docker run` 라벨 강제.
- [ ] 구현·통과(기존 test-harness-isolation·compose 오버레이 테스트 포함)·커밋.

### Task 8: 마무리

- [ ] `plugin/tests/run-affected.sh --deep` 통과 확인, `docker gc --dry-run` 실 도커 실측, code-reviewer 에이전트 리뷰·반영, 메모리 갱신.
