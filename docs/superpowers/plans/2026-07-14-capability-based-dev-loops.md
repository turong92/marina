# Capability-based Development Loops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compose 표준 Watch와 언어 중립적인 서비스 단위 host prebuild를 결합해 reload, artifact restart, image rebuild 개발 루프를 빠르고 재사용 가능하게 만든다.

**Architecture:** 프로젝트 Compose가 `sync`, `restart`, `rebuild`의 path와 action을 소유하고, `x-marina.prebuild.<service> = {cwd, command}`가 Compose가 실행할 수 없는 host build만 선언한다. Marina는 선택 서비스 해석, prebuild 검증·실행·관측, Watch action별 Compose 버전 검증, watcher 수명만 담당하며 MDC는 별도 repository의 reference fixture로 적용한다.

**Tech Stack:** Python 3 표준 라이브러리, Bash 3.2+, Docker Compose v2.24.4+, Compose Develop Watch, vanilla JavaScript, Node.js VM tests, Docker BuildKit, Gradle, Python/Uvicorn

## Global Constraints

- Marina의 전역 최소 Docker Compose 버전은 `2.24.4`로 유지한다.
- `restart` Watch action은 Compose `2.32.0+`, `sync+exec`의 `exec` 설정은 `2.32.2+`에서만 허용한다.
- Marina 코어에 MDC, Gradle, Spring, Uvicorn, Node 전용 분기를 추가하지 않는다.
- 기존 문자열 `x-marina.prebuild`와 레거시 `prebuild.json`을 계속 지원한다.
- 신규 object prebuild의 `cwd`는 symlink 해석 후에도 worktree root 내부여야 한다.
- Compose가 파일 감시와 컨테이너 action의 SoT이며 `x-marina`에 watch path나 output path를 중복 선언하지 않는다.
- dependency fingerprint, 언어별 input 감지, dev-base image, 상시 host compiler daemon은 추가하지 않는다.
- MDC 변경은 `feature/dev-build-cache` worktree에서만 수행하고 production Dockerfile은 수정하지 않는다.
- 시크릿 값과 환경 파일 내용은 로그, 문서, 테스트 fixture에 기록하지 않는다.
- 브라우저 검증이 필요한 대시보드 변경은 Aside를 우선 사용한다.

## File Structure

### Marina repository

- Create `plugin/scripts/marina_prebuild.py`: prebuild schema 검증, legacy 해석, 서비스 선택 후 job 계획, cwd 격리, host command 실행, 구조화 이벤트 출력.
- Modify `plugin/scripts/marina-compose.py`: start target 해석 재사용, `prebuild-run` CLI, Watch action 버전 검증.
- Modify `plugin/scripts/marina-lib-compose.sh`: inline prebuild 파서를 제거하고 Python CLI를 lifecycle에 연결.
- Modify `plugin/scripts/marina_build.py`: 언어 중립적인 prebuild event를 build timeline step으로 파싱.
- Modify `plugin/scripts/marina_compose_svc.py`: service object와 legacy prebuild를 서비스 구성 payload로 정규화.
- Modify `plugin/scripts/marina-web/app-2c-xmarina-form.js`: legacy string과 service object prebuild의 parse/serialize/form 편집.
- Modify `plugin/scripts/marina-web/app-5c-config.js`: 정규화된 prebuild 정보를 서비스 단위로 표시.
- Modify `plugin/scripts/marina-web/styles.css`: prebuild mode control과 세 필드 행의 안정적인 레이아웃.
- Modify `README.md`: 범용 개발 루프와 신규 prebuild 계약, Compose version capability 문서화.
- Create `plugin/tests/test-prebuild-jobs.sh`: pure planner와 path/schema 검증.
- Create `plugin/tests/test-prebuild-runtime.sh`: CLI/lifecycle 선택, 실패 중단, legacy 호환, 구조화 로그.
- Create `plugin/tests/test-compose-watch-version.sh`: action별 버전 gate.
- Modify `plugin/tests/test-build-summary.sh`: 구조화 prebuild timeline.
- Modify `plugin/tests/test-xmarina-form-roundtrip.sh`: object와 legacy UI roundtrip.
- Modify `plugin/tests/test-compose-dash-api.sh`: 서비스 구성 payload의 object/legacy 표현.

### MDC reference fixture

- Modify `/Users/sumin/.marina/mdc-main/docker-compose.yml`: BE artifact restart, service prebuild, AI source sync/rebuild.
- Modify `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/ai-api/index_api/Dockerfile.local`: dependency 뒤 bootstrap source copy.
- Modify `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/ai-api/search_api/Dockerfile.local`: pip 뒤 optional Node 설치와 bootstrap source copy.
- Create `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/ai-api/tests_e2e/test_local_dockerfiles.py`: local Dockerfile cache boundary 회귀 테스트.
- Modify `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/tasks/dev-build-cache/design.md`: web 전용 설계를 capability mapping으로 확장.
- Modify `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/tasks/dev-build-cache/implementation-plan.md`: BE/AI 검증 결과와 benchmark 기록.
- Modify `docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md`: 프로젝트 설정 체크리스트 결과 갱신.

---

### Task 1: Language-neutral Prebuild Planner

**Files:**
- Create: `plugin/scripts/marina_prebuild.py`
- Create: `plugin/tests/test-prebuild-jobs.sh`

**Interfaces:**
- Consumes: canonical Compose config, `x-marina.prebuild`, optional legacy `prebuild.json`, selected service names, worktree root.
- Produces: `PrebuildJob(id, services, cwd, command, java_key, legacy)` and `plan_prebuild_jobs(...) -> list[PrebuildJob]`.

- [x] **Step 1: Write the failing pure planner test**

Create `plugin/tests/test-prebuild-jobs.sh` with a Python block that imports `marina_prebuild.py` and asserts the public contract:

```python
import sys
from pathlib import Path
from marina_prebuild import PrebuildConfigError, plan_prebuild_jobs

root = Path(sys.argv[1]).resolve()
(root / "be-api").mkdir()
(root / ".workspace/external/ext-api").mkdir(parents=True)
config = {
    "services": {
        "user-api": {"build": {"context": str(root / "be-api/user-api")}},
        "batch": {"build": {"context": str(root / "be-api/batch")}},
        "external": {"build": {"context": str(root / ".workspace/external/ext-api/app")}},
        "web": {"build": {"context": str(root / "web")}},
    }
}
raw = {
    "user-api": {"cwd": "be-api", "command": "./gradlew :user-api:bootJar"},
    "batch": {"cwd": "be-api", "command": "./gradlew :batch:bootJar"},
    "external": {"cwd": ".workspace/external/ext-api", "command": "make build"},
}

jobs = plan_prebuild_jobs(raw, config, ["user-api"], root)
assert [(j.services, j.cwd, j.command) for j in jobs] == [
    (("user-api",), "be-api", "./gradlew :user-api:bootJar")
]

deduped = plan_prebuild_jobs({
    "user-api": {"cwd": "be-api", "command": "make shared"},
    "batch": {"cwd": "be-api", "command": "make shared"},
}, config, ["user-api", "batch"], root)
assert len(deduped) == 1 and deduped[0].services == ("user-api", "batch")

legacy = plan_prebuild_jobs(
    {"be-api": "./gradlew assemble", "other": "false"},
    config,
    ["user-api"],
    root,
)
assert len(legacy) == 1 and legacy[0].legacy and legacy[0].cwd == "be-api"

for invalid in (
    {"ghost": {"cwd": "be-api", "command": "true"}},
    {"user-api": {"cwd": "", "command": "true"}},
    {"user-api": {"cwd": "be-api", "command": ""}},
    {"user-api": ["not", "a", "mapping"]},
):
    try:
        plan_prebuild_jobs(invalid, config, ["user-api"], root)
    except PrebuildConfigError:
        pass
    else:
        raise AssertionError(f"invalid prebuild accepted: {invalid}")

outside = root.parent / "outside"
outside.mkdir(exist_ok=True)
(root / "escape").symlink_to(outside, target_is_directory=True)
try:
    plan_prebuild_jobs(
        {"user-api": {"cwd": "escape", "command": "true"}},
        config,
        ["user-api"],
        root,
    )
except PrebuildConfigError as exc:
    assert "worktree root" in str(exc)
else:
    raise AssertionError("symlink escape accepted")
```

- [x] **Step 2: Run the focused test and verify RED**

Run: `bash plugin/tests/test-prebuild-jobs.sh`

Expected: FAIL because `plugin/scripts/marina_prebuild.py` does not exist.

- [x] **Step 3: Implement the planner and validation boundary**

Create `plugin/scripts/marina_prebuild.py` with these exact public types and responsibilities:

```python
from __future__ import annotations

from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Mapping, Sequence


class PrebuildConfigError(ValueError):
    pass


@dataclass(frozen=True)
class PrebuildJob:
    id: str
    services: tuple[str, ...]
    cwd: str
    command: str
    java_key: str
    legacy: bool = False


def _inside_root(root: Path, rel: str) -> Path:
    if not rel or Path(rel).is_absolute():
        raise PrebuildConfigError(f"prebuild cwd must be a non-empty relative path: {rel!r}")
    resolved = (root / rel).resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as exc:
        raise PrebuildConfigError(f"prebuild cwd escapes worktree root: {rel}") from exc
    if not resolved.is_dir():
        raise PrebuildConfigError(f"prebuild cwd does not exist: {rel}")
    return resolved


def _legacy_subrepo(context: Any, root: Path) -> str:
    raw = context.get("context") if isinstance(context, Mapping) else context
    if not raw:
        return "."
    path = Path(str(raw)).resolve()
    rel = path.relative_to(root.resolve()).parts
    if rel[:2] == (".workspace", "external") and len(rel) >= 3:
        return rel[2]
    return rel[0] if rel else "."


def plan_prebuild_jobs(
    raw: Any,
    config: Mapping[str, Any],
    targets: Sequence[str],
    root: Path,
) -> list[PrebuildJob]:
    if raw in (None, {}):
        return []
    if not isinstance(raw, Mapping):
        raise PrebuildConfigError("x-marina.prebuild must be a mapping")
    services = config.get("services") if isinstance(config.get("services"), Mapping) else {}
    target_set = set(targets)
    legacy_targets: dict[str, list[str]] = {}
    for name in targets:
        if name not in services:
            continue
        subrepo = _legacy_subrepo((services.get(name) or {}).get("build"), root)
        legacy_targets.setdefault(subrepo, []).append(name)
    planned: list[PrebuildJob] = []
    for key, value in raw.items():
        key = str(key)
        if isinstance(value, str):
            command = value.strip()
            if command and key in legacy_targets:
                cwd = f".workspace/external/{key}" if (root / ".workspace/external" / key).is_dir() else key
                _inside_root(root, cwd)
                planned.append(PrebuildJob("", tuple(sorted(legacy_targets[key])), cwd, command, key, True))
            continue
        if not isinstance(value, Mapping):
            raise PrebuildConfigError(f"prebuild.{key} must be a command string or {{cwd, command}} mapping")
        if key not in services:
            raise PrebuildConfigError(f"prebuild service is not defined by Compose: {key}")
        if set(value) != {"cwd", "command"}:
            raise PrebuildConfigError(f"prebuild.{key} requires exactly cwd and command")
        cwd, command = str(value.get("cwd") or "").strip(), str(value.get("command") or "").strip()
        if not cwd or not command:
            raise PrebuildConfigError(f"prebuild.{key} requires non-empty cwd and command")
        if key in target_set:
            _inside_root(root, cwd)
            java_key = Path(cwd).parts[-1] if cwd.startswith(".workspace/external/") else Path(cwd).parts[0]
            planned.append(PrebuildJob("", (key,), cwd, command, java_key, False))
    deduped: list[PrebuildJob] = []
    by_key: dict[tuple[str, str], int] = {}
    for job in planned:
        identity = (str((root / job.cwd).resolve()), job.command)
        if identity in by_key:
            index = by_key[identity]
            current = deduped[index]
            deduped[index] = replace(current, services=tuple(sorted(set(current.services + job.services))))
        else:
            by_key[identity] = len(deduped)
            deduped.append(job)
    return [replace(job, id=f"prebuild-{index}") for index, job in enumerate(deduped, 1)]
```

Keep legacy string filtering based on the selected services' canonical build context. Validate every object entry's type/service/keys, but resolve and require the `cwd` directory only for selected jobs so an optional stopped service cannot block an unrelated start.

- [x] **Step 4: Run the focused test and verify GREEN**

Run: `bash plugin/tests/test-prebuild-jobs.sh`

Expected: `PASS test-prebuild-jobs`.

- [x] **Step 5: Commit the planner**

```bash
git add plugin/scripts/marina_prebuild.py plugin/tests/test-prebuild-jobs.sh
git commit -m "feat(compose): add service-scoped prebuild planner"
```

---

### Task 2: Prebuild Runtime and Build Timeline

**Files:**
- Modify: `plugin/scripts/marina_prebuild.py`
- Modify: `plugin/scripts/marina-compose.py:20-24,283-320,663-780,844-900`
- Modify: `plugin/scripts/marina-lib-compose.sh:39-101,128-160`
- Modify: `plugin/scripts/marina_build.py:11-112`
- Create: `plugin/tests/test-prebuild-runtime.sh`
- Modify: `plugin/tests/test-entrypoint-lifecycle-env.sh`
- Modify: `plugin/tests/test-build-summary.sh`

**Interfaces:**
- Consumes: `plan_prebuild_jobs`, resolved start targets, `MARINA_JAVA_HOMES`, lifecycle environment.
- Produces: `marina-compose.py prebuild-run ...`, `MARINA_PREBUILD_EVENT <json>` log records, language-neutral timeline steps.

- [x] **Step 1: Write failing runtime selection and failure tests**

Create a fake Compose project in `plugin/tests/test-prebuild-runtime.sh` with `startGroup: [web, user-api]` and these declarations:

```yaml
x-marina:
  prebuild:
    user-api: {cwd: be-api, command: "printf user-api >> $CAPTURE"}
    batch: {cwd: be-api, command: "printf batch >> $CAPTURE"}
```

The fake Docker `config --format json` returns canonical contexts. Assert:

```bash
mrun start --user-api >"$TMP/user.log" 2>&1
[[ "$(cat "$CAPTURE")" == "user-api" ]]
grep -q 'MARINA_PREBUILD_EVENT .*"services": \["user-api"\].*"status": "success"' "$TMP/user.log"

: > "$CAPTURE"
mrun start --all >"$TMP/all.log" 2>&1
[[ "$(cat "$CAPTURE")" == "user-api" ]]  # startGroup excludes batch; web has no job

sed -i.bak 's/printf user-api/exit 9 #/' "$PD/docker-compose.yml"
if mrun start --user-api >"$TMP/fail.log" 2>&1; then exit 1; fi
! grep -q ' up -d ' "$DOCKER_LOG"
grep -q '"status": "failed"' "$TMP/fail.log"
```

Add a legacy string fixture and assert it still executes only when a selected service's build context belongs to that subrepo. Keep `test-entrypoint-lifecycle-env.sh` asserting that the selected job receives Dockerfile-derived `JAVA_HOME`.

- [x] **Step 2: Run runtime tests and verify RED**

Run:

```bash
bash plugin/tests/test-prebuild-runtime.sh
bash plugin/tests/test-entrypoint-lifecycle-env.sh
```

Expected: the new runtime test fails because `prebuild-run` and object jobs are unsupported; the legacy environment test remains green.

- [x] **Step 3: Add execution and structured events**

Extend `marina_prebuild.py` with:

```python
import json
import os
import subprocess
import time

EVENT_PREFIX = "MARINA_PREBUILD_EVENT "


def _event(job: PrebuildJob, status: str, duration: float | None = None, exit_code: int | None = None) -> None:
    payload = {
        "id": job.id,
        "services": list(job.services),
        "cwd": job.cwd,
        "command": job.command if status == "started" else "",
        "status": status,
    }
    if duration is not None:
        payload["durationSec"] = round(duration, 3)
    if exit_code is not None:
        payload["exitCode"] = exit_code
    print(EVENT_PREFIX + json.dumps(payload, ensure_ascii=False, sort_keys=True), flush=True)


def run_prebuild_jobs(jobs: Sequence[PrebuildJob], root: Path, environ: Mapping[str, str]) -> int:
    try:
        java_homes = json.loads(environ.get("MARINA_JAVA_HOMES", "{}") or "{}")
    except ValueError:
        java_homes = {}
    for job in jobs:
        env = dict(environ)
        java_home = java_homes.get(job.java_key) or java_homes.get("default")
        if java_home:
            env["JAVA_HOME"] = str(java_home)
        _event(job, "started")
        started = time.monotonic()
        rc = subprocess.call(["bash", "-c", job.command], cwd=root / job.cwd, env=env)
        elapsed = time.monotonic() - started
        _event(job, "success" if rc == 0 else "failed", elapsed, rc)
        if rc:
            return rc
    return 0
```

Do not infer the command's language or parse its stdout in the runner.

- [x] **Step 4: Add shared target resolution and `prebuild-run` CLI**

In `marina-compose.py`, import `marina_prebuild` with the same sibling fallback pattern as `marina_dockerfile`. Extract the existing target logic from `cmd_up`:

```python
def resolved_start_targets(config: dict, xm: dict, requested: list[str]):
    grouped, unknown = start_group_requested(xm, requested, config.get("services") or {})
    startable, skipped = startable_services(config, grouped)
    return startable, skipped, unknown
```

Use this helper in `cmd_up` and add:

```python
def cmd_prebuild_run(a):
    env = _env_with(a.env)
    name = compose_project_name(a.project_id, a.session)
    config = docker_config_json(a.stored, a.project_dir, name, env)
    xm = xmarina_for_stored(a.stored)
    targets, _, unknown = resolved_start_targets(config, xm, list(a.service or []))
    if unknown:
        sys.stderr.write("warning: x-marina.startGroup unknown services: " + ", ".join(unknown) + "\n")
    raw = xm.get("prebuild")
    if not raw and a.legacy_prebuild and os.path.isfile(a.legacy_prebuild):
        try:
            with open(a.legacy_prebuild, encoding="utf-8") as handle:
                raw = json.load(handle)
        except (OSError, ValueError) as exc:
            sys.stderr.write(f"error: legacy prebuild config is unreadable: {exc}\n")
            return 2
    try:
        jobs = marina_prebuild.plan_prebuild_jobs(raw, config, targets, Path(a.project_dir))
    except marina_prebuild.PrebuildConfigError as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 2
    return marina_prebuild.run_prebuild_jobs(jobs, Path(a.project_dir), env)
```

Register `prebuild-run` with `--stored`, `--project-dir`, `--project-id`, `--session`, repeatable `--service`, repeatable `--env`, and `--legacy-prebuild` arguments.

- [x] **Step 5: Replace the Bash inline parser**

Replace `run_prebuild_hooks` with a thin wrapper that preserves all lifecycle environment and selected service args:

```bash
run_prebuild_hooks() {
  local stored="$1" cp="$2" legacy="$3"; shift 3
  python3 "$cp" prebuild-run \
    --stored "$stored" --project-dir "$ROOT" \
    --project-id "$pid" --session "$(session_id)" \
    --legacy-prebuild "$legacy" "$@"
}
```

Build one `prebuild_args` array from the same `svcs` and `envargs` passed to `cmd_up`. Call the wrapper after `ensure_external_worktrees` and before links/Compose `up`. Remove the embedded Python map parser and the legacy “missing subrepo means skip” behavior; selected invalid cwd now fails.

- [x] **Step 6: Parse structured events in the timeline**

In `marina_build.py`, add `_PREBUILD = re.compile(r"^MARINA_PREBUILD_EVENT (?P<payload>\{.*\})$")`. Pair `started` and terminal records by `id`, producing:

```python
{
    "id": event["id"],
    "label": "Pre-build · " + ", ".join(event["services"]),
    "kind": "prebuild",
    "durationSec": float(event.get("durationSec") or 0),
    "cached": False,
    "failed": event.get("status") == "failed",
}
```

Keep the old Gradle regex as fallback only when no structured prebuild terminal event appears, preventing duplicate timeline steps while preserving old logs.

- [x] **Step 7: Verify runtime and timeline GREEN**

Run:

```bash
bash plugin/tests/test-prebuild-jobs.sh
bash plugin/tests/test-prebuild-runtime.sh
bash plugin/tests/test-entrypoint-lifecycle-env.sh
bash plugin/tests/test-build-summary.sh
bash plugin/tests/test-compose-dispatch.sh
```

Expected: every script prints `PASS`; the failed job test proves Compose `up` was not called.

- [x] **Step 8: Commit runtime integration**

```bash
git add plugin/scripts/marina_prebuild.py plugin/scripts/marina-compose.py \
  plugin/scripts/marina-lib-compose.sh plugin/scripts/marina_build.py \
  plugin/tests/test-prebuild-runtime.sh plugin/tests/test-entrypoint-lifecycle-env.sh \
  plugin/tests/test-build-summary.sh
git commit -m "feat(compose): run service prebuilds with structured timing"
```

---

### Task 3: Compose Watch Capability Gate

**Files:**
- Modify: `plugin/scripts/marina-compose.py:601-635,663-780,860-900`
- Modify: `plugin/scripts/marina-lib-compose.sh:112-160`
- Create: `plugin/tests/test-compose-watch-version.sh`
- Modify: `plugin/tests/test-compose-watch.sh`

**Interfaces:**
- Consumes: canonical service Watch rules, selected start targets, current Compose version.
- Produces: `watch_version_errors(config, services, version) -> list[str]` and a prebuild-before-command capability gate.

- [x] **Step 1: Write failing action/version matrix tests**

Create `plugin/tests/test-compose-watch-version.sh` and directly test the pure function:

```python
config = {"services": {
    "web": {"develop": {"watch": [{"action": "sync", "path": ".", "target": "/app"}]}},
    "api": {"develop": {"watch": [{"action": "sync+restart", "path": ".", "target": "/app"}]}},
    "worker": {"develop": {"watch": [{"action": "restart", "path": "./build"}]}},
    "tool": {"develop": {"watch": [{"action": "sync+exec", "path": ".", "target": "/app", "exec": {"command": "true"}}]}},
}}
assert mc.watch_version_errors(config, ["web"], "2.24.4") == []
assert mc.watch_version_errors(config, ["api"], "2.22.0")
assert mc.watch_version_errors(config, ["worker"], "2.31.9")
assert mc.watch_version_errors(config, ["worker"], "2.32.0") == []
assert mc.watch_version_errors(config, ["tool"], "2.32.1")
assert mc.watch_version_errors(config, ["tool"], "2.32.2") == []
assert mc.watch_version_errors(config, ["web"], "v2.40.3-desktop.1") == []
```

Add a fake lifecycle assertion that Compose 2.31.9 rejects `worker` before prebuild/up, while starting only `web` succeeds even when an unselected worker uses `restart`.

- [x] **Step 2: Run and verify RED**

Run: `bash plugin/tests/test-compose-watch-version.sh`

Expected: FAIL because the version helper and lifecycle gate are absent.

- [x] **Step 3: Implement semantic version and capability checks**

Add to `marina-compose.py`:

```python
WATCH_ACTION_MIN = {
    "sync": (2, 22, 0),
    "rebuild": (2, 22, 0),
    "sync+restart": (2, 23, 0),
    "restart": (2, 32, 0),
    "sync+exec": (2, 32, 0),
}


def compose_version_tuple(value: str) -> tuple[int, int, int]:
    numbers = [int(part) for part in re.findall(r"\d+", value or "")[:3]]
    return tuple((numbers + [0, 0, 0])[:3])


def watch_version_errors(config: dict, selected: list[str], version: str) -> list[str]:
    current, errors = compose_version_tuple(version), []
    services = config.get("services") if isinstance(config.get("services"), dict) else {}
    for name in selected:
        rules = (((services.get(name) or {}).get("develop") or {}).get("watch") or [])
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            action = str(rule.get("action") or "")
            required = WATCH_ACTION_MIN.get(action)
            if action == "sync+exec" and "exec" in rule:
                required = max(required or (0, 0, 0), (2, 32, 2))
            if required and current < required:
                need = ".".join(map(str, required))
                errors.append(f"service '{name}' Watch action '{action}' requires Compose {need}+; current {version}")
    return errors
```

Do not rewrite unsupported actions.

- [x] **Step 4: Gate the existing prebuild pass before command execution**

Add required `--compose-version` to `prebuild-run`. After it loads canonical config and resolves actual start targets with `resolved_start_targets`, call `watch_version_errors`, print every error, and return 2 before planning or running a prebuild job.

In `marina-lib-compose.sh`, pass the already-read Compose version into the existing prebuild call:

```bash
run_prebuild_hooks "$stored" "$cp" "$MARINA_HOME/$pid/prebuild.json" "$ver" \
  "${svcs[@]}" "${envargs[@]}" || return 1
```

This keeps capability validation before host commands without adding a third `docker compose config` pass to every start.

- [x] **Step 5: Verify focused and lifecycle tests GREEN**

Run:

```bash
bash plugin/tests/test-compose-watch-version.sh
bash plugin/tests/test-compose-watch.sh
bash plugin/tests/test-compose-dispatch.sh
bash plugin/tests/test-prebuild-runtime.sh
```

Expected: all PASS and fake Compose 2.24 continues to support ordinary sync/rebuild projects.

- [x] **Step 6: Commit the capability gate**

```bash
git add plugin/scripts/marina-compose.py plugin/scripts/marina-lib-compose.sh \
  plugin/tests/test-compose-watch-version.sh plugin/tests/test-compose-watch.sh
git commit -m "feat(compose): gate Watch actions by Compose capability"
```

---

### Task 4: Public Configuration Roundtrip and Display

**Files:**
- Modify: `plugin/scripts/marina_compose_svc.py:427-490`
- Modify: `plugin/scripts/marina-web/app-2c-xmarina-form.js:205-213,300-338,555-584`
- Modify: `plugin/scripts/marina-web/app-5c-config.js:119-126,172-190`
- Modify: `plugin/scripts/marina-web/styles.css:213`
- Modify: `plugin/tests/test-xmarina-form-roundtrip.sh`
- Modify: `plugin/tests/test-compose-dash-api.sh`

**Interfaces:**
- Consumes: mixed legacy/object `x-marina.prebuild` maps.
- Produces: lossless Workbench YAML roundtrip and per-service `{mode, cwd, command}` display payload.

- [x] **Step 1: Extend failing Workbench roundtrip tests**

Change the test fixture to:

```javascript
prebuild: {
  'legacy-api': './gradlew assemble',
  'user-api': { cwd: 'be-api', command: './gradlew :user-api:bootJar' },
},
```

Assert parse → serialize → parse deep equality and serialized nested YAML:

```javascript
check('object prebuild yaml', /  user-api:\n    cwd: be-api\n    command:/.test(blockFull), blockFull);
```

Extend `test-compose-dash-api.sh` with a stored object entry for one service and a legacy entry for a sibling, asserting normalized payloads.

- [x] **Step 2: Run tests and verify RED**

Run:

```bash
bash plugin/tests/test-xmarina-form-roundtrip.sh
bash plugin/tests/test-compose-dash-api.sh
```

Expected: object prebuild is relegated to unsupported raw content or rendered as `[object Object]`, and payload assertions fail.

- [x] **Step 3: Support both shapes in the Workbench parser/serializer**

Replace `xmCoercePrebuild` with validation that accepts either a command string or an object with exactly `cwd` and `command` string fields. Add:

```javascript
function xmDumpPrebuild(prebuild) {
  const lines = ['  prebuild:'];
  for (const key of Object.keys(prebuild)) {
    const value = prebuild[key];
    if (typeof value === 'string') {
      lines.push('    ' + xmQuoteKeyIfNeeded(key) + ': ' + xmQuoteIfNeeded(value));
    } else {
      lines.push('    ' + xmQuoteKeyIfNeeded(key) + ':');
      lines.push('      cwd: ' + xmQuoteIfNeeded(value.cwd));
      lines.push('      command: ' + xmQuoteIfNeeded(value.command));
    }
  }
  return lines;
}
```

Use `xmDumpPrebuild` from `wbSerializeXmarina`.

- [x] **Step 4: Render legacy and service rows without data loss**

In `wbRenderPrebuildCard`, each row gets a two-option segmented mode (`서비스` / `레거시`), key input, optional cwd input, command input, and remove icon. New rows default to service object:

```javascript
xm.prebuild[key] = { cwd: '.', command: '' };
```

Switching mode converts only that row. Keep field dimensions stable in CSS with grid tracks `96px minmax(90px, 1fr) minmax(120px, 2fr) 28px`; at narrow widths use one column so text never overlaps.

- [x] **Step 5: Normalize service configuration payload**

In `compose_resolved_view`, select object by service name first; otherwise select legacy by subrepo:

```python
entry = pb_all.get(name)
if isinstance(entry, dict):
    prebuild = {"mode": "service", "cwd": str(entry.get("cwd") or ""), "command": str(entry.get("command") or "")}
else:
    legacy = pb_all.get(sub_label) if sub_label else None
    prebuild = {"mode": "legacy", "cwd": sub_label or "", "command": legacy} if isinstance(legacy, str) else None
```

Return this object as `prebuild`. In `app-5c-config.js`, display the mode, cwd, and command read-only and remove the ineffective per-subrepo save button from this modal. Editing remains in the Compose Workbench, which preserves the complete shared `x-marina` block.

- [x] **Step 6: Verify tests and browser behavior**

Run:

```bash
bash plugin/tests/test-xmarina-form-roundtrip.sh
bash plugin/tests/test-compose-dash-api.sh
node --check plugin/scripts/marina-web/app-2c-xmarina-form.js
node --check plugin/scripts/marina-web/app-5c-config.js
```

Then use Aside against `http://127.0.0.1:3900`: open the project Compose editor, confirm a service object row shows service/cwd/command without overlap, switch to advanced YAML and back, and verify the nested object remains byte-equivalent after canonical parsing. Open service configuration and confirm the same command is displayed, not `[object Object]`.

- [x] **Step 7: Commit configuration support**

```bash
git add plugin/scripts/marina_compose_svc.py \
  plugin/scripts/marina-web/app-2c-xmarina-form.js \
  plugin/scripts/marina-web/app-5c-config.js plugin/scripts/marina-web/styles.css \
  plugin/tests/test-xmarina-form-roundtrip.sh plugin/tests/test-compose-dash-api.sh
git commit -m "feat(config): support service-scoped prebuild settings"
```

---

### Task 5: Marina Documentation and Full Regression

**Files:**
- Modify: `README.md:30-60,222-305,393-401`
- Modify: `docs/superpowers/specs/2026-07-14-capability-based-dev-loops-design.md` only if verified behavior differs from the approved design.

**Interfaces:**
- Consumes: verified core behavior from Tasks 1-4.
- Produces: user-facing generic configuration contract and a clean Marina test baseline.

- [x] **Step 1: Document the three development loops**

Add a compact table to README:

| Service capability | Compose | `x-marina` | Runtime result |
|---|---|---|---|
| reload | `sync` + manifest `rebuild` | none | source edit without image build |
| artifact | artifact mount + `restart` | service `{cwd, command}` | host build, owning service restart |
| image | `rebuild` | optional prebuild | Dockerfile/dependency image refresh |

Document the object example, legacy string compatibility, startGroup selection, dedupe by resolved cwd+command, and Watch capability versions. Replace statements that prebuild is always stored in `prebuild.json` or always subrepo-wide.

- [x] **Step 2: Run static checks**

```bash
bash -n plugin/scripts/marina-lib-compose.sh
python3 -m py_compile plugin/scripts/marina_prebuild.py plugin/scripts/marina-compose.py \
  plugin/scripts/marina_build.py plugin/scripts/marina_compose_svc.py
node --check plugin/scripts/marina-web/app-2c-xmarina-form.js
node --check plugin/scripts/marina-web/app-5c-config.js
git diff --check
```

Expected: every command exits 0.

- [x] **Step 3: Run all Marina tests**

```bash
set -e
for test in plugin/tests/test-*.sh; do
  bash "$test"
done
```

Expected: every test prints PASS or an explicit environment-based SKIP; no `.watch.pid` points to a live test process afterward.

- [x] **Step 4: Review genericity and compatibility**

Search and inspect:

```bash
rg -n "MDC|Gradle|Spring|Uvicorn|Node" \
  plugin/scripts/marina_prebuild.py plugin/scripts/marina-compose.py plugin/scripts/marina-lib-compose.sh
rg -n "prebuild" README.md plugin/scripts/marina-web/app-2c-xmarina-form.js
```

The first command must find no new project/language-specific runtime branch. Confirm legacy tests, `start --all` startGroup behavior, and Watch-free projects remain unchanged.

- [x] **Step 5: Commit docs**

```bash
git add README.md docs/superpowers/specs/2026-07-14-capability-based-dev-loops-design.md
git commit -m "docs: explain capability-based development loops"
```

Omit the spec path from `git add` when no verified behavior required a spec correction.

---

### Task 6: MDC Backend Artifact Loop

**Files:**
- Modify: `/Users/sumin/.marina/mdc-main/docker-compose.yml`

**Interfaces:**
- Consumes: Marina service object prebuild and Compose `restart` action.
- Produces: independent `user-api`/`batch` host builds and artifact-triggered service restart.

- [x] **Step 1: Back up and validate the current stored Compose**

```bash
cp /Users/sumin/.marina/mdc-main/docker-compose.yml \
  /Users/sumin/.marina/mdc-main/docker-compose.yml.before-capability-loops
docker compose -f /Users/sumin/.marina/mdc-main/docker-compose.yml \
  --project-directory /Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache \
  config --format json >/tmp/mdc-compose-before.json
```

Expected: config exits 0. The backup is local rollback material and must not be committed.

- [x] **Step 2: Replace the shared BE prebuild and add artifact Watch**

Use:

```yaml
services:
  user-api:
    develop:
      watch:
        - action: restart
          path: ./be-api/user-api/build/libs
  batch:
    develop:
      watch:
        - action: restart
          path: ./be-api/batch/build/libs
x-marina:
  prebuild:
    user-api:
      cwd: be-api
      command: ./gradlew :user-api:bootJar --build-cache
    batch:
      cwd: be-api
      command: ./gradlew :batch:bootJar --build-cache
```

Keep both existing JAR directory mounts and all unrelated Compose/x-marina keys unchanged.

- [x] **Step 3: Validate the rendered BE contract**

```bash
docker compose -f /Users/sumin/.marina/mdc-main/docker-compose.yml \
  --project-directory /Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache \
  config --format json >/tmp/mdc-compose-be.json
python3 - /tmp/mdc-compose-be.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for svc in ("user-api", "batch"):
    watch = d["services"][svc]["develop"]["watch"]
    assert [item["action"] for item in watch] == ["restart"], watch
PY
```

- [x] **Step 4: Verify service-scoped build selection**

From the MDC worktree, run `marina restart --user-api` and inspect the current build log. Assert it contains `:user-api:bootJar` and does not contain `:batch:bootJar`. Repeat inversely for `batch`.

Expected: each command builds only its selected artifact; both services can still start from their mounted JAR.

- [x] **Step 5: Verify external artifact restart**

Start `user-api`, record container ID and `StartedAt`, then run:

```bash
cd /Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/be-api
./gradlew :user-api:bootJar --build-cache
```

Wait for `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/.workspace/marina/dev-build-cache/user-api.watch.log` to report the restart. Assert container ID remains associated with `user-api`, `StartedAt` advances, and `batch` does not restart.

- [x] **Step 6: Roll back on instability**

If Gradle's multi-file replacement causes repeated restart loops, remove only the two `restart` rules and retain service-scoped prebuild. Record the observed event sequence before changing the design; do not add a Marina file debounce or language-specific watcher in this task.

---

### Task 7: MDC AI Bootstrap Source and Cache Boundary

**Files:**
- Modify: `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/ai-api/index_api/Dockerfile.local`
- Modify: `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/ai-api/search_api/Dockerfile.local`
- Create: `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/ai-api/tests/test_local_dockerfiles.py`

**Interfaces:**
- Consumes: both local Dockerfile texts.
- Produces: runnable bootstrap images whose dependency layers are not invalidated by source or optional Node changes.

- [x] **Step 1: Write the failing Dockerfile source test**

Create a stdlib `unittest` that asserts:

```python
class LocalDockerfileTest(unittest.TestCase):
    def test_index_copies_source_after_pip(self):
        text = (ROOT / "index_api/Dockerfile.local").read_text()
        self.assertGreater(text.index("COPY . ."), text.index("pip install -r"))

    def test_search_keeps_pip_before_optional_node_and_source(self):
        text = (ROOT / "search_api/Dockerfile.local").read_text()
        pip = text.index("pip install -r")
        node = text.index("ARG INSTALL_HYPERFRAMES_NODE")
        browser = text.index("ARG INSTALL_HYPERFRAMES_CHROMIUM")
        source = text.index("COPY . .")
        self.assertLess(pip, node)
        self.assertLess(node, browser)
        self.assertLess(browser, source)

    def test_source_copy_stays_after_all_dependency_install_steps(self):
        for rel in ("index_api/Dockerfile.local", "search_api/Dockerfile.local"):
            text = (ROOT / rel).read_text()
            self.assertEqual(text.count("COPY . ."), 1)
            self.assertGreater(text.index("COPY . ."), text.rindex("RUN "))
```

- [x] **Step 2: Run the test and verify RED**

Run from the AI repository: `python3 tests/test_local_dockerfiles.py`

Expected: FAIL because neither Dockerfile copies source and search installs optional Node before pip.

- [x] **Step 3: Reorder search dependencies and add source bootstrap**

In `search_api/Dockerfile.local`, keep apt first, then requirements copy/pip install, then the existing optional Node block, then the existing optional Chromium block, then `COPY . .`. In `index_api/Dockerfile.local`, add `COPY . .` immediately after pip install. Update comments from “source is runtime bind mount” to “image source is startup bootstrap; Compose Watch sync owns live edits.”

Do not change ffmpeg, Node/Chromium default args, requirements, CMD, ports, or production Dockerfiles.

- [x] **Step 4: Verify static and BuildKit checks**

```bash
python3 tests/test_local_dockerfiles.py
docker buildx build --check -f index_api/Dockerfile.local .
docker buildx build --check -f search_api/Dockerfile.local .
git diff --check
```

Expected: unittest OK and both Dockerfile checks exit 0.

- [x] **Step 5: Commit the AI Dockerfiles**

```bash
git add index_api/Dockerfile.local search_api/Dockerfile.local tests/test_local_dockerfiles.py
git commit -m "perf(local): preserve AI dependency layers for source sync"
```

---

### Task 8: MDC AI Sync/Reload Loop

**Files:**
- Modify: `/Users/sumin/.marina/mdc-main/docker-compose.yml`

**Interfaces:**
- Consumes: bootstrap AI images from Task 7 and Marina watcher lifecycle.
- Produces: source sync/reload and service-specific dependency rebuild without full source bind mounts.

- [x] **Step 1: Replace AI source binds with Watch declarations**

Remove `./ai-api:/ai-api` from both AI services. Add a full-root source sync to `/ai-api` with `initial_sync: true`. Declare this standard YAML anchor once at top level:

```yaml
x-ai-watch-ignore: &ai-watch-ignore
  - .git/
  - .github/
  - .venv/
  - '**/.venv/'
  - node_modules/
  - '**/node_modules/'
  - __pycache__/
  - '**/__pycache__/'
  - '*.pyc'
  - tmp/
  - index_api/logs/
  - search_api/logs/
  - '**/requirements*.txt'
  - index_api/Dockerfile.local
  - search_api/Dockerfile.local
```

Add service-specific rebuild paths:

```yaml
index-api:
  develop:
    watch:
      - action: sync
        path: ./ai-api
        target: /ai-api
        initial_sync: true
        ignore: *ai-watch-ignore
      - action: rebuild
        path: ./ai-api/index_api/requirements_local.txt
      - action: rebuild
        path: ./ai-api/index_api/Dockerfile.local
search-api:
  develop:
    watch:
      - action: sync
        path: ./ai-api
        target: /ai-api
        initial_sync: true
        ignore: *ai-watch-ignore
      - action: rebuild
        path: ./ai-api/search_api/requirements.txt
      - action: rebuild
        path: ./ai-api/search_api/Dockerfile.local
```

- [x] **Step 2: Validate canonical Compose paths/actions/mounts**

Render config JSON and assert for each AI service:

```python
assert not any(v.get("target") == "/ai-api" for v in service.get("volumes", []))
actions = [rule["action"] for rule in service["develop"]["watch"]
assert actions == ["sync", "rebuild", "rebuild"]
assert service["develop"]["watch"][0]["initial_sync"] is True
```

Also assert web Watch and BE artifact rules are still present.

- [x] **Step 3: Rebuild and verify bootstrap startup**

Run `marina rebuild --index-api` and `marina rebuild --search-api`. Confirm each Uvicorn process reaches ready state before relying on a source sync event. Verify `/ai-api/index_api/app.py` or `/ai-api/search_api/app.py` exists inside the corresponding image/container without a source bind.

- [x] **Step 4: Verify source sync without Docker build**

Create `index_api/.marina-watch-probe.py`, wait for the index watcher log to show sync, and assert the file appears in `/ai-api/index_api/` inside the container. Confirm no `Building`/BuildKit step appears in that watcher event. Delete the probe and verify container deletion sync. Repeat for search.

- [x] **Step 5: Verify dependency event isolation**

Touch `index_api/requirements_local.txt` without changing content, wait for the index watcher to rebuild/recreate, and assert the search watcher did not rebuild. Record whether all dependency layers are cached. Repeat with `search_api/requirements.txt` only if the index check proves the event path is stable and the expected cached build cost is acceptable.

- [x] **Step 6: Verify API health and clean probes**

Resolve dynamic ports with `marina ports`, then use `curl` against each FastAPI `/docs` endpoint. Expected: HTTP 200. Confirm the AI repository is clean except for Task 7's committed changes and no probe remains.

- [x] **Step 7: Apply the per-service rollback criteria**

If initial sync, Uvicorn reload, or ignored local configuration fails for one service, restore that service's source bind and remove only its Watch rules. Keep the other verified service and record the exact ignored path or startup failure; do not introduce a Marina-specific sync engine.

---

### Task 9: Benchmarks, Documentation, and Final Cross-repository Verification

**Files:**
- Modify: `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/tasks/dev-build-cache/design.md`
- Modify: `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/tasks/dev-build-cache/implementation-plan.md`
- Modify: `docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md`
- Modify: `docs/superpowers/specs/2026-07-14-capability-based-dev-loops-design.md` to append verified results.

**Interfaces:**
- Consumes: Marina core, MDC BE/AI runtime, build logs, Watch logs.
- Produces: measured cold/warm/edit evidence, checked roadmap, clean repository states.

- [x] **Step 1: Capture comparable timings without global cache deletion**

Measure and record:

| path | command/event | required evidence |
|---|---|---|
| BE selected start | `marina restart --user-api` | only user artifact build, elapsed time |
| BE warm selected start | repeat command | Gradle cache/up-to-date behavior |
| BE artifact edit | manual `:user-api:bootJar` | owning service restart only |
| AI first rebuild | Task 7 image rebuild | pip/Node/ffmpeg cache status and total |
| AI repeated start | `marina start --index-api` | Docker build 0회 |
| AI source edit | probe sync | image build 0회, sync-to-container elapsed |
| AI manifest event | requirements touch | owning service rebuild only |

Do not run `docker builder prune`, delete unrelated images/volumes, or print environment values.

- [x] **Step 2: Update MDC task documentation**

Expand the design from web-only cache boundaries to the three capability paths and mark completed Task 6-8 checks in `implementation-plan.md`. Include actual numbers and any rollback used; do not write estimated values.

- [x] **Step 3: Update Marina roadmap and design verification**

Check off search optional Node layer reordering only after Task 7 passes. Keep runtime profiles and registry cache unchecked. Append a verification table to the capability design with Compose version, service selection, source sync, artifact restart, and measured timings.

- [x] **Step 4: Run final Marina verification**

```bash
set -e
bash -n plugin/scripts/marina-lib-compose.sh
python3 -m py_compile plugin/scripts/marina_prebuild.py plugin/scripts/marina-compose.py \
  plugin/scripts/marina_build.py plugin/scripts/marina_compose_svc.py
for test in plugin/tests/test-*.sh; do bash "$test"; done
git diff --check
git status --short
```

Expected: static checks exit 0, every test PASS/SKIP, no leaked watcher process, and only Task 9 docs are uncommitted.

- [x] **Step 5: Run final MDC verification**

```bash
python3 /Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/ai-api/tests_e2e/test_local_dockerfiles.py
docker compose -f /Users/sumin/.marina/mdc-main/docker-compose.yml \
  --project-directory /Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache config >/dev/null
git -C /Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/ai-api diff --check
git -C /Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache status --short
git -C /Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/ai-api status --short
git -C /Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/be-api status --short
```

Expected: Dockerfile tests/config pass; AI and BE nested repos have no uncommitted task changes; MDC root shows only known nested repository entries plus Task 9 docs before commit.

- [x] **Step 6: Commit documentation in each owning repository**

In the MDC root:

```bash
git add tasks/dev-build-cache/design.md tasks/dev-build-cache/implementation-plan.md
git commit -m "docs(build): record capability-based dev loop results"
```

In Marina:

```bash
git add docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md \
  docs/superpowers/specs/2026-07-14-capability-based-dev-loops-design.md
git commit -m "docs(build): record multi-service dev loop verification"
```

- [x] **Step 7: Final review**

Review all task commits for accidental project-specific branches in Marina, secret leakage, unrelated metadata churn, Watch process leaks, stale local backups in git, and multi-repository ownership. Do not push or merge any branch without a separate explicit request.

## Plan Self-Review

- Spec coverage: sync/reload, artifact/restart, image/rebuild, object/legacy prebuild, startGroup selection, dedupe, cwd isolation, version gate, structured logging, UI roundtrip, MDC BE/AI mapping, benchmarks, rollback are each assigned to a task.
- Scope: one sequential feature across Marina core and its reference fixture; every MDC task depends on the generic core and remains independently reversible.
- Type consistency: `PrebuildJob`, `plan_prebuild_jobs`, `run_prebuild_jobs`, `resolved_start_targets`, `watch_version_errors`, `prebuild-run`, and `MARINA_PREBUILD_EVENT` names are consistent across producer and consumer tasks.
- Backward compatibility: legacy string maps, `prebuild.json`, Gradle log fallback, Watch-free projects, and the global Compose 2.24.4 floor all have explicit tests.
- Placeholder scan: all implementation steps name files, commands, expected results, schema, and rollback behavior; measurement fields are explicitly produced by Task 9 rather than prefilled.
