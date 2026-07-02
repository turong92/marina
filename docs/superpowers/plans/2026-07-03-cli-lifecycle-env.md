# CLI Lifecycle Env Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make direct `marina start|stop|restart|status|ports|logs` use the same project-aware environment calculation as dashboard lifecycle actions.

**Architecture:** Add a small `exec` subcommand to `plugin/scripts/marina_cli.py` that resolves the current project root, builds `marina_env(root)`, and execs the existing `marina.sh`. Route lifecycle/status commands in `marina-entrypoint.sh` through that helper so direct CLI and dashboard share JAVA_HOME, PATH, SOURCE_ROOT, and MARINA_SUBREPOS behavior.

**Tech Stack:** Bash entrypoint, Python stdlib subprocess/os/pathlib, existing Marina shell tests.

## Global Constraints

- Do not move Gradle prebuild into Docker in this change.
- Preserve existing `marina.sh` compose behavior; only normalize the environment for direct CLI entry.
- Prove the direct CLI prebuild receives `JAVA_HOME` and `MARINA_JAVA_HOMES` inferred from Dockerfile `FROM eclipse-temurin:21`.

---

### Task 1: Direct CLI Env Wrapper

**Files:**
- Modify: `plugin/scripts/marina_cli.py`
- Modify: `plugin/scripts/marina-entrypoint.sh`
- Test: `plugin/tests/test-entrypoint-lifecycle-env.sh`

**Interfaces:**
- Consumes: `marina_env(root: Path) -> dict[str, str]`, `script(root: Path) -> Path`
- Produces: `marina_cli.py exec <marina.sh args...>` that replaces the Python process with `marina.sh` under `marina_env(root)`

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-entrypoint-lifecycle-env.sh` that registers a temporary compose project with `x-marina.prebuild.be-api`, fake SDKMAN JDK 21, and fake Docker. The prebuild records `JAVA_HOME` and `MARINA_JAVA_HOMES`, then exits nonzero to stop before real Docker compose.

- [ ] **Step 2: Run test to verify it fails**

Run: `plugin/tests/test-entrypoint-lifecycle-env.sh`

Expected before implementation: FAIL because direct `marina-entrypoint.sh restart user-api` bypasses `marina_env`, so the prebuild records the shell Java instead of the Dockerfile-derived JDK 21.

- [ ] **Step 3: Implement minimal wrapper**

Add root resolution and an `exec` CLI branch in `marina_cli.py`. Update `marina-entrypoint.sh` to route lifecycle/status commands through `python3 marina_cli.py exec ...`.

- [ ] **Step 4: Run focused tests**

Run:

```bash
plugin/tests/test-entrypoint-lifecycle-env.sh
plugin/tests/test-entrypoint-routing.sh
plugin/tests/test-marina-env-path.sh
```

Expected after implementation: all three print `PASS`.

- [ ] **Step 5: Run actual CLI verification**

Run direct CLI from `/Users/sumin/IdeaProjects/crabs/mdc-main` with a shell Java that would otherwise be too old, and verify the prebuild log includes `[JAVA_HOME=21.0.5-tem]`, `user-api` reaches health `UP`, and containers are stopped afterward.
