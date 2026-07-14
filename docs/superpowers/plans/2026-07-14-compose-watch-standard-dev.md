# Compose Watch Standard Dev Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Docker Compose 표준 `develop.watch`를 Marina가 누수 없이 관리하고, 빠른 Start와 명시적 Rebuild를 분리한 뒤 MDC web의 stale `node_modules` volume을 제거한다.

**Architecture:** 프로젝트 Compose가 `sync`/`rebuild` 규칙을 소유한다. Marina는 Compose 설정에서 Watch 선언 서비스만 찾고 서비스별 `docker compose watch --no-up` 프로세스를 관리한다. Start는 기존 이미지를 재사용하고 Rebuild만 `--build`를 전달한다.

**Tech Stack:** Bash, Python 3 stdlib, Docker Compose 2.24.4+, Compose Develop Specification, shell integration tests, Aside browser verification

## Global Constraints

- dependency hash, 시간 기반 volume 이름, `x-marina.dependencyCache`를 추가하지 않는다.
- Watch path/action은 Marina가 재해석하지 않고 Docker Compose에 위임한다.
- MDC web의 `.next` named volume은 유지하고 `web_app_node_modules`만 제거한다.
- local env 파일 값과 컨테이너 환경값을 로그·문서·테스트 출력에 노출하지 않는다.
- Watch 미선언 프로젝트의 lifecycle은 기존과 동일해야 한다.
- Marina와 MDC 저장소 변경은 독립 커밋으로 유지한다.

---

### Task 1: Compose Watch 서비스 판정과 프로세스 수명

**Files:**
- Create: `plugin/tests/test-compose-watch.sh`
- Modify: `plugin/scripts/marina-compose.py`
- Modify: `plugin/scripts/marina.sh`
- Modify: `plugin/scripts/marina-lib-compose.sh`

**Interfaces:**
- Produces: `watchable_services(config, requested) -> list[str]`
- Produces: `watch_argv(stored, overlay, project_dir, project_name, service) -> list[str]`
- Produces: `marina-compose.py watchable ...` and foreground `marina-compose.py watch ...`
- Produces: `<session>/<service>.watch.pid` and `<session>/<service>.watch.log`

- [ ] **Step 1: Write the failing shell integration test**

Create a fake Docker CLI whose config fixture contains `web.develop.watch` and an ordinary `be` service. Assert:

```bash
mrun start --all
[[ -f "$SD/web.watch.pid" ]]
[[ ! -f "$SD/be.watch.pid" ]]
grep -q "watch --no-up web" "$DOCKER_LOG"
```

Run `mrun start --all` twice and assert the first watcher PID is no longer alive and one replacement PID exists. Run service stop/restart and all stop, asserting matching watcher cleanup/recreation.

- [ ] **Step 2: Run the test and verify RED**

Run: `bash plugin/tests/test-compose-watch.sh`

Expected: FAIL because `.watch.pid` is not created and `watch --no-up` is never invoked.

- [ ] **Step 3: Add pure Compose helpers and CLI subcommands**

Add to `marina-compose.py`:

```python
def watchable_services(config: dict, requested: list[str]) -> list[str]:
    services = config.get("services") if isinstance(config.get("services"), dict) else {}
    names = requested or list(services)
    return sorted(
        name for name in names
        if isinstance(services.get(name), dict)
        and isinstance((services[name].get("develop") or {}).get("watch"), list)
        and (services[name].get("develop") or {}).get("watch")
    )

def watch_argv(stored, overlay, project_dir, project_name, service):
    argv = ["docker", "compose", "-f", stored]
    if overlay and os.path.isfile(overlay) and os.path.getsize(overlay) > 0:
        argv += ["-f", overlay]
    return argv + ["--project-directory", project_dir, "-p", project_name,
                   "watch", "--no-up", service]
```

`watchable` prints only service names. `watch` validates that exactly one requested service is watchable, prints the command, then uses `subprocess.call` so Bash can supervise the foreground process.

- [ ] **Step 4: Add watcher PID helpers and lifecycle wiring**

In `marina.sh`, add idempotent `_compose_watch_start`/`_compose_watch_stop` beside logtail helpers. `_compose_watch_start` replaces a live previous PID, truncates the service watch log, launches the supplied foreground Python command under `nohup`, and writes the PID atomically. `_compose_watch_stop` supports one service or all services and always removes stale PID files.

In `marina-lib-compose.sh`, query `watchable` after successful up. Start watchers only for services actually started; stop them before service/all stop; replace them after restart.

- [ ] **Step 5: Verify GREEN and regressions**

Run:

```bash
bash plugin/tests/test-compose-watch.sh
bash plugin/tests/test-compose-logtail.sh
bash plugin/tests/test-compose-dispatch.sh
```

Expected: all PASS, with no leftover fake watcher processes.

- [ ] **Step 6: Commit Task 1**

Stage only the four Task 1 files and commit `feat(compose): 표준 Watch 프로세스 수명 관리`.

### Task 2: Fast Start와 explicit Rebuild 분리

**Files:**
- Modify: `plugin/tests/test-compose-dispatch.sh`
- Create: `plugin/tests/test-rebuild-action.sh`
- Modify: `plugin/scripts/marina-compose.py`
- Modify: `plugin/scripts/marina-lib-compose.sh`
- Modify: `plugin/scripts/marina.sh`
- Modify: `plugin/scripts/marina-entrypoint.sh`
- Modify: `plugin/scripts/marina_lifecycle.py`
- Modify: `plugin/scripts/marina_handler.py`
- Modify: `plugin/scripts/marina-web/app-3-util.js`
- Modify: `plugin/scripts/marina-web/app-5-sessions.js`
- Modify: `plugin/scripts/marina-web/app-5b-actions.js`

**Interfaces:**
- `up_argv(..., build: bool = False)` includes `--build` only when requested.
- CLI: `marina rebuild <service>` and `marina rebuild --all`.
- HTTP: `POST /api/rebuild` with `{root, service, force}`.
- UI: running Compose service offers Rebuild in the overflow menu; Restart remains a no-build restart/reapply.

- [ ] **Step 1: Change dispatch tests first**

Update `test-compose-dispatch.sh` to assert ordinary `start --all` omits `--build`, then invoke `rebuild --all` and assert it includes `--build`. Add `test-rebuild-action.sh` for lifecycle/API routing and frontend source assertions.

- [ ] **Step 2: Verify RED**

Run:

```bash
bash plugin/tests/test-compose-dispatch.sh
bash plugin/tests/test-rebuild-action.sh
```

Expected: dispatch still forces `--build`; rebuild command/API do not exist.

- [ ] **Step 3: Parameterize up and expose rebuild command**

Change `up_argv` to:

```python
def up_argv(stored, overlay, project_dir, project_name, services, build=False):
    argv = ["docker", "compose", "-f", stored]
    if overlay and os.path.exists(overlay) and os.path.getsize(overlay) > 0:
        argv += ["-f", overlay]
    argv += ["--project-directory", project_dir, "-p", project_name, "up", "-d"]
    if build:
        argv.append("--build")
    argv += ["--remove-orphans"]
    return argv + list(services)
```

Add `--build` to the Python `up` subcommand. Route `start` and `restart` without it; route new `rebuild` through the same prebuild/link/overlay path with `--build`.

- [ ] **Step 4: Expose dashboard rebuild without adding a permanent card button**

Add `rebuild_service()` to `marina_lifecycle.py`, `/api/rebuild` to the handler, and a Compose-only `Rebuild` item to the existing service overflow menu. Keep the compact ▶/■/↻ action cluster unchanged. Rebuild uses the existing busy state/log path with `op="rebuild"`.

- [ ] **Step 5: Verify GREEN and all lifecycle tests**

Run:

```bash
bash plugin/tests/test-compose-dispatch.sh
bash plugin/tests/test-rebuild-action.sh
bash plugin/tests/test-lifecycle-busy.sh
bash plugin/tests/test-compose-watch.sh
```

Expected: all PASS. Start command has no `--build`; Rebuild has exactly one `--build`.

- [ ] **Step 6: Commit Task 2**

Stage only Task 2 files and commit `perf(compose): Start와 Rebuild 동작 분리`.

### Task 3: MDC web Compose Watch 적용과 실 Docker 검증

**Files:**
- Modify local project config: `~/.marina/mdc-main/docker-compose.yml`
- Modify: `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/tasks/dev-build-cache/design.md`
- Modify: `/Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache/tasks/dev-build-cache/implementation-plan.md`

**Interfaces:**
- `web.develop.watch` owns source sync and dependency rebuild triggers.
- `.env` and `.env.ssm.local` are explicit file mounts.
- `web_app_next` remains; `web_app_node_modules` is absent.

- [ ] **Step 1: Back up and edit only the stored MDC Compose config**

Before editing, save a temporary copy outside Git for rollback. Apply the approved Watch block, remove the app directory bind and node_modules volume, add the two env file mounts, and keep `.next`.

- [ ] **Step 2: Validate config before starting containers**

Run:

```bash
docker compose -f ~/.marina/mdc-main/docker-compose.yml \
  --project-directory /Users/sumin/IdeaProjects/crabs/mdc-main/.claude/worktrees/dev-build-cache \
  config --quiet
```

Expected: exit 0. Render JSON and assert `web.develop.watch` actions, no `/app/apps/web/node_modules` mount, and retained `/app/apps/web/.next` mount without printing environment values.

- [ ] **Step 3: Start through Marina and verify runtime**

Run `marina start web`, wait for Next Ready, and assert:

- web container uses current worktree paths
- app-level dependency links resolve to `/app/node_modules/.pnpm`
- `web_app_node_modules` is not mounted
- `.next` named volume is mounted
- `web.watch.pid` points to a live process

- [ ] **Step 4: Verify source sync without build**

Edit a harmless visible marker in an existing web page, confirm the watcher log reports sync but not rebuild, and verify the marker in Aside. Revert only that temporary marker. Record elapsed sync-to-render time.

- [ ] **Step 5: Verify dependency trigger without retaining the edit**

Touch or make/revert a semantically neutral manifest change while Watch is live. Confirm Compose reports `rebuild`, the web container is replaced, Next becomes Ready, and dependency resolution still succeeds. Ensure the manifest is byte-identical afterward.

- [ ] **Step 6: Verify Stop/Rebuild and cleanup**

Run service stop and confirm watcher PID is gone. Run `marina rebuild web`, confirm Docker executes a build and starts a fresh watcher. Stop the test stack and remove only test-created containers/networks/volumes.

- [ ] **Step 7: Record measurements and commit MDC docs**

Update task docs with Start, source sync, dependency rebuild, and rollback evidence. Commit with:

```text
docs(build): Compose Watch 검증 결과 기록

Task: dev-build-cache
```

Push the MDC root feature branch as required by its workflow. No protected branch push.

### Task 4: Marina documentation, full verification, and review

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md`
- Modify: `docs/superpowers/specs/2026-07-14-compose-watch-standard-dev-design.md` only if verified behavior differs

- [ ] **Step 1: Document verified command semantics**

Document `Start`, `Restart`, `Rebuild`, Watch opt-in, and the offline-Watch limitation. Mark the roadmap project-setting and P0.3 checklist items only to the level actually completed.

- [ ] **Step 2: Run Marina test suite**

Run all `plugin/tests/test-*.sh` scripts using the repository's established loop. Expected: all PASS or an explicitly documented pre-existing/environmental SKIP.

- [ ] **Step 3: Run syntax and leak checks**

Run `bash -n` on changed shell scripts, `python3 -m py_compile` on changed Python files, and verify no `.watch.pid` points to a live test process after tests.

- [ ] **Step 4: Request independent code review**

Review for watcher process leaks, quoting/env loss, service/all lifecycle asymmetry, accidental cache deletion, and UI/API mismatch. Resolve every P1/P2 finding and rerun targeted tests.

- [ ] **Step 5: Commit final Marina docs**

Stage only Marina documentation changes and commit `docs(compose): Watch와 Rebuild 사용법 정리`.

- [ ] **Step 6: Final verification summary**

Report measured timings, files/commits, local project config impact, test count, and any remaining limitation. Do not promote protected branches without a new explicit user request.
