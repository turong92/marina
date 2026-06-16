# Per-project service isolation (stage 3) + docker/native run — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every registered project drive the dashboard's services, ports, log targets, orphan rules, and cache categories from **its own** `marina-services.json` (not just the registry's first project), and document docker as a thin run convention so a service runs by whatever its project needs — docker or native — both per-worktree isolated.

**Architecture:** Replace the import-time global service singletons (`EXTRA_SERVICES`→`SERVICES`/`DEFAULT_PORT_BASE`/`LOG_TARGETS`/`ORPHAN_RULES`, all derived from `_load_extra_services()`'s **first** project) with root-keyed functions that mirror the existing per-project `services_for(root)`. Each consumer passes the `root` it already operates on; the two genuinely system-wide consumers (orphan sweep) use a union across all registered roots. docker needs **zero core change**: `command_for` (`marina.sh`) already substitutes `{port}{session}…` across the whole run string and `exec`s it, so a docker service is just a `marina-services.json` entry whose `run` is a `docker compose up` with those tokens.

**Tech Stack:** Python 3 stdlib single file `plugin/scripts/marina-control.py` (`http.server` daemon, embedded `INDEX_HTML`); bash `plugin/scripts/marina.sh`; standalone bash tests under `plugin/tests/` (run directly, no central runner) using `curl`+`python3` assertions or `importlib` unit tests.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `plugin/scripts/marina-control.py` (lookups) | per-project service state | new `extra_services_for`/`port_base_for`/`log_targets_for`/`orphan_rules_for`/`orphan_rules_all`; `cache_guard_services(cat, root)`; `safe_service(svc, root)` (Task 1) |
| `plugin/scripts/marina-control.py` (consumers) | use per-project state | swap globals at the consumer sites (Task 2) |
| `plugin/scripts/marina-control.py` (import-time) | remove singletons | drop `_load_extra_services` early-return + `EXTRA_SERVICES`/`SERVICES`/`DEFAULT_PORT_BASE`/`LOG_TARGETS`/`ORPHAN_RULES` (Task 3) |
| `plugin/tests/test-multiproject-services.sh` | New | two projects, different service sets, each isolated across sessions/ports (Task 2) |
| `plugin/tests/test-docker-run-tokens.sh` | New | `command_for` substitutes `{port}`/`{session}` into a compose-style `run` (Task 4) |
| `README.md` / `docs/` | docker run convention | document the docker `run` pattern + compose env (Task 4) |
| `homeserver/marina-services.json` *(separate repo `~/IdeaProjects/sumin/homeserver`)* | homeserver services | react native `vite`, kotlin native `gradlew bootRun` (Task 5) |

**Insertion anchors are quoted code, not line numbers** (line numbers drift as earlier tasks edit the 4300-line file). Match on the quoted anchor text.

---

## Conventions for every task

- **Worktree:** all work happens in `~/.config/superpowers/worktrees/marina/multiproject-services` on branch `feature/multiproject-services`. Run git as `git -C <worktree>` or `cd` there first.
- **Commit style:** Conventional Commits, scope `plugin` for code. **No `Co-Authored-By` line. No `Task:` trailer** (CRABS-workspace convention; this repo `turong92/marina` does not use it).
- **Run a test:** `bash plugin/tests/<name>.sh` from the worktree root. Success prints `PASS <name>` and exits 0.
- **After any `marina-control.py` edit:** `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` — Expected: no output, exit 0 (the embedded `INDEX_HTML` string must still parse).
- **Never push to origin.** Local commits only, per task.

---

### Task 1: per-project lookup functions (added alongside the globals)

**Files:**
- Modify: `plugin/scripts/marina-control.py` (new functions; globals left in place for now)
- Test: `plugin/tests/test-multiproject-services.sh` (create — unit portion runs here first)

Add root-keyed lookups mirroring `services_for(root)`. The globals stay until Task 3 so the file keeps working between tasks.

- [ ] **Step 1: Write the failing unit test**

Create `plugin/tests/test-multiproject-services.sh`:

```bash
#!/usr/bin/env bash
# per-project service state: two projects with different service sets stay isolated.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"

PA="$TMP/alpha"; mkdir -p "$PA"
cat > "$PA/marina-services.json" <<'JSON'
{"services":[{"name":"foo","portBase":4100,"cachePaths":["foo/.cache"],"orphanPattern":"foo-daemon"}]}
JSON
PB="$TMP/beta"; mkdir -p "$PB"
cat > "$PB/marina-services.json" <<'JSON'
{"services":[{"name":"bar","portBase":4200},{"name":"baz","portBase":4300}]}
JSON
bash "$SH" add "$PA" >/dev/null
bash "$SH" add "$PB" >/dev/null

# --- unit: per-project lookups (no server) ---
python3 - "$CTRL" "$PA" "$PB" <<'PY' || { echo "FAIL: per-project lookup unit"; exit 1; }
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
a, b = Path(sys.argv[2]), Path(sys.argv[3])
assert mc.services_for(a) == ("foo",), mc.services_for(a)
assert mc.services_for(b) == ("bar","baz"), mc.services_for(b)
assert mc.port_base_for(a) == {"foo":4100}, mc.port_base_for(a)
assert mc.port_base_for(b) == {"bar":4200,"baz":4300}, mc.port_base_for(b)
assert mc.log_targets_for(a) == ("foo","console"), mc.log_targets_for(a)
assert [n for n,_ in mc.orphan_rules_for(a)] == ["marina","foo"], mc.orphan_rules_for(a)
assert [n for n,_ in mc.orphan_rules_for(b)] == ["marina"], mc.orphan_rules_for(b)
allr = [n for n,_ in mc.orphan_rules_all()]
assert "foo" in allr and allr.count("marina") == 1, allr   # union, marina deduped
PY
echo "PASS test-multiproject-services (unit)"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugin/tests/test-multiproject-services.sh`
Expected: FAIL — `AttributeError: module 'mc' has no attribute 'port_base_for'`.

- [ ] **Step 3: Add the lookup functions**

In `plugin/scripts/marina-control.py`, immediately **after** the `services_for()` function (ends `return _BUILTIN_SERVICES + extra`), insert:

```python
def extra_services_for(root: Path) -> list[dict[str, Any]]:
    # root 가 속한 프로젝트의 marina-services.json 서비스 정의 (per-project). 부재/파싱실패 → []
    project = project_for(root)
    proot = Path(project["root"]) if project else root
    try:
        data = json.loads((proot / "marina-services.json").read_text(encoding="utf-8"))
    except Exception:
        return []
    out: list[dict[str, Any]] = []
    for item in data.get("services", []):
        name = str(item.get("name", "")).strip()
        base = item.get("portBase")
        if name and name.isidentifier() and isinstance(base, int) and name not in _BUILTIN_SERVICES:
            caches = [str(c) for c in item.get("cachePaths", []) if isinstance(c, str)]
            orphan = item.get("orphanPattern")
            out.append({
                "name": name, "portBase": base, "cachePaths": caches,
                "orphanPattern": orphan if isinstance(orphan, str) else None,
            })
    return out


def port_base_for(root: Path) -> dict[str, int]:
    return {**_BUILTIN_PORT_BASE, **{s["name"]: s["portBase"] for s in extra_services_for(root)}}


def log_targets_for(root: Path) -> tuple[str, ...]:
    return (*services_for(root), "console")


def orphan_rules_for(root: Path) -> list[tuple[str, "re.Pattern[str]"]]:
    rules: list[tuple[str, re.Pattern[str]]] = list(_BASE_ORPHAN_RULES)
    for svc in extra_services_for(root):
        pat = svc.get("orphanPattern")
        if isinstance(pat, str) and pat:
            try:
                rules.append((str(svc["name"]), re.compile(pat)))
            except re.error:
                pass
    return rules


def orphan_rules_all() -> list[tuple[str, "re.Pattern[str]"]]:
    # 시스템 전역 sweep 용 — 등록된 모든 프로젝트의 규칙 합집합 (패턴 문자열로 dedup).
    seen: set[str] = set()
    rules: list[tuple[str, re.Pattern[str]]] = []
    for name, pat in _BASE_ORPHAN_RULES:
        key = f"{name}:{pat.pattern}"
        if key not in seen:
            seen.add(key); rules.append((name, pat))
    for root in discover_roots():
        for name, pat in orphan_rules_for(root):
            key = f"{name}:{pat.pattern}"
            if key not in seen:
                seen.add(key); rules.append((name, pat))
    return rules
```

- [ ] **Step 4: Add `_BASE_ORPHAN_RULES` (the built-in rule, factored out)**

Find the current global `ORPHAN_RULES` block:

```python
ORPHAN_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("marina", re.compile(r"marina\.sh (?:foreground|start)")),
]
for _svc in EXTRA_SERVICES:
    _pat = _svc.get("orphanPattern")
    if isinstance(_pat, str) and _pat:
        try:
            ORPHAN_RULES.append((str(_svc["name"]), re.compile(_pat)))
        except re.error:
            pass
```

Immediately **before** it, add the factored base (used by the new functions; `ORPHAN_RULES` itself is removed in Task 3):

```python
_BASE_ORPHAN_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("marina", re.compile(r"marina\.sh (?:foreground|start)")),
]
```

- [ ] **Step 5: Verify parse + run the test to pass**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` — Expected: exit 0.
Run: `bash plugin/tests/test-multiproject-services.sh` — Expected: `PASS test-multiproject-services (unit)`.

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-multiproject-services.sh
git commit -m "feat(plugin): per-project service lookups (services/port-base/log-targets/orphan-rules by root)"
```

---

### Task 2: swap consumers to per-project lookups + isolation integration test

**Files:**
- Modify: `plugin/scripts/marina-control.py` (consumer sites)
- Test: `plugin/tests/test-multiproject-services.sh` (extend with a server/payload section)

Each consumer already has (or its caller has) a `root`. Swap the global for the per-project function. The two system-wide orphan consumers use `orphan_rules_all()`.

- [ ] **Step 1: Extend the test with a payload-isolation section (failing)**

Append before the final `echo` is not possible (the unit `echo` is last). Instead, **replace** the last line `echo "PASS test-multiproject-services (unit)"` with the server section + final pass:

```bash
# --- payload: each project's sessions expose only its own services + ports ---
PORT=39715; b="http://127.0.0.1:$PORT"; H=(-H "Origin: http://127.0.0.1:$PORT")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${H[@]}" "$b/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done
curl -s "${H[@]}" "$b/api/sessions" | python3 -c "
import json, sys
d = json.load(sys.stdin)
svc = {s['root'].split('/')[-1]: sorted(x['service'] for x in s.get('services', [])) for s in d['sessions']}
prt = {s['root'].split('/')[-1]: {x['service']: x.get('port') for x in s.get('services', [])} for s in d['sessions']}
assert svc.get('alpha') == ['foo'], svc
assert svc.get('beta') == ['bar','baz'], svc
assert prt['alpha']['foo'] == '4100', prt['alpha']        # alpha gets its OWN port base, not beta's
assert prt['beta']['bar'] == '4200', prt['beta']
" || { echo 'FAIL: per-project payload/ports'; exit 1; }
echo "PASS test-multiproject-services"
```

Run: `bash plugin/tests/test-multiproject-services.sh`
Expected: FAIL — with the stage-1 globals, only the first registered project (`alpha`) has services/ports; `beta`'s assertions fail (empty or alpha's set).

- [ ] **Step 2: Swap `default_ports_for`**

Find:

```python
def default_ports_for(root: Path) -> dict[str, str]:
```

In its body replace `DEFAULT_PORT_BASE.items()` with `port_base_for(root).items()`.

- [ ] **Step 3: Swap `stop_all`**

In `stop_all(root)`, replace `for service in SERVICES` with `for service in services_for(root)`.

- [ ] **Step 4: Swap `clear_worktree_cache`**

In `clear_worktree_cache(root, ...)`, replace `if service in SERVICES and` with `if service in services_for(root) and`.

- [ ] **Step 5: Swap `fix_port_conflict`**

In `fix_port_conflict(root)`, replace `for svc, base in DEFAULT_PORT_BASE.items()` with `for svc, base in port_base_for(root).items()`.

- [ ] **Step 6: Swap `cache_paths_by_category` + `cache_guard_services`**

In `cache_paths_by_category(root)`, replace `for svc in EXTRA_SERVICES` with `for svc in extra_services_for(root)`.

Change `cache_guard_services` to take a root:

```python
def cache_guard_services(category: str) -> tuple[str, ...]:
```
→
```python
def cache_guard_services(category: str, root: Path) -> tuple[str, ...]:
```
and in its body replace `for s in EXTRA_SERVICES` with `for s in extra_services_for(root)`. Then update its caller(s): `grep -n "cache_guard_services(" plugin/scripts/marina-control.py` — each call is inside a function with `root` in scope; add `, root` to each call.

- [ ] **Step 7: Swap `tracked_pid_groups` (already loops all roots)**

In `tracked_pid_groups(snapshot)`, the body is `for root in discover_roots(): for service in SERVICES:`. Replace `for service in SERVICES:` with `for service in services_for(root):`. (This alone makes pid-tracking fully per-project.)

- [ ] **Step 8: Swap orphan sweep to the union**

In `orphan_processes()`, replace `for label, pattern in ORPHAN_RULES:` with `for label, pattern in orphan_rules_all():`.
In `kill_orphans()`, replace `for _, pattern in ORPHAN_RULES` with `for _, pattern in orphan_rules_all()`.

- [ ] **Step 9: Thread `root` into `safe_service`**

Change the signature:

```python
def safe_service(service: str) -> str:
```
→
```python
def safe_service(service: str, root: Path) -> str:
```
and in its body replace `LOG_TARGETS` with `log_targets_for(root)`. Then fix callers: `grep -n "safe_service(" plugin/scripts/marina-control.py`. Each call site in `do_POST`/`do_GET` has `root` already validated (via `safe_root`) before the `safe_service(...)` line — pass it: `safe_service(str(body.get("service","")), root)` / `safe_service(qs..., root)`. If a call site resolves `service` *before* `root`, move the `root = safe_root(...)` line above it.

- [ ] **Step 10: Verify parse + tests pass**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` — exit 0.
Run: `bash plugin/tests/test-multiproject-services.sh` — Expected: `PASS test-multiproject-services`.
Run: `bash plugin/tests/test-per-project-services.sh` — Expected: `PASS` (regression).

- [ ] **Step 11: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-multiproject-services.sh
git commit -m "feat(plugin): consumers use per-project service state; orphan sweep = union of all projects"
```

---

### Task 3: remove the import-time singletons

**Files:**
- Modify: `plugin/scripts/marina-control.py` (delete dead globals + `_load_extra_services` early return)

With every consumer swapped (Task 2), the globals are dead. Remove them so no future code re-introduces the first-project leak.

- [ ] **Step 1: Confirm no remaining consumers**

Run: `grep -n "\bSERVICES\b\|EXTRA_SERVICES\|DEFAULT_PORT_BASE\|LOG_TARGETS\|\bORPHAN_RULES\b" plugin/scripts/marina-control.py`
Expected: only the **definition** lines (around `:88-91`, the old `ORPHAN_RULES` block) and `_BUILTIN_SERVICES`/`_BUILTIN_PORT_BASE` (those stay). No usage sites. If a usage remains, fix it (it was missed in Task 2) before deleting.

- [ ] **Step 2: Delete the singleton block**

Find and delete:

```python
EXTRA_SERVICES = _load_extra_services()
SERVICES = _BUILTIN_SERVICES + tuple(s["name"] for s in EXTRA_SERVICES)
DEFAULT_PORT_BASE = {**_BUILTIN_PORT_BASE, **{s["name"]: s["portBase"] for s in EXTRA_SERVICES}}
LOG_TARGETS = (*SERVICES, "console")
```

- [ ] **Step 3: Delete the old `ORPHAN_RULES` build block**

Find and delete (the `_BASE_ORPHAN_RULES` added in Task 1 stays):

```python
ORPHAN_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("marina", re.compile(r"marina\.sh (?:foreground|start)")),
]
for _svc in EXTRA_SERVICES:
    _pat = _svc.get("orphanPattern")
    if isinstance(_pat, str) and _pat:
        try:
            ORPHAN_RULES.append((str(_svc["name"]), re.compile(_pat)))
        except re.error:
            pass
```

- [ ] **Step 4: Delete `_load_extra_services` (now unused)**

`grep -n "_load_extra_services" plugin/scripts/marina-control.py` → if `extra_services_for` fully replaced it (Task 1) and no caller remains, delete the whole `def _load_extra_services(...)` function (`:58-85`). If anything still calls it, stop and re-check.

- [ ] **Step 5: Verify parse + full regression**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` — exit 0.
Run each: `bash plugin/tests/test-multiproject-services.sh`, `bash plugin/tests/test-per-project-services.sh`, `bash plugin/tests/test-subrepo-tree-api.sh`, `bash plugin/tests/test-registry-api.sh` — all Expected: `PASS`.

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina-control.py
git commit -m "refactor(plugin): drop import-time service singletons (stage-1 first-project leak removed)"
```

---

### Task 4: docker run convention — token smoke test + docs

**Files:**
- Test: `plugin/tests/test-docker-run-tokens.sh` (create)
- Modify: `README.md` (and/or `docs/`) — docker `run` pattern

No core code changes. Prove `command_for` expands tokens inside a compose-style `run`, then document the pattern.

- [ ] **Step 1: Write the smoke test**

Create `plugin/tests/test-docker-run-tokens.sh`:

```bash
#!/usr/bin/env bash
# command_for substitutes {port}/{session} into a docker-compose-style run string.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"api","portBase":18080,"cwd":".",
  "run":"exec env HOST_PORT={port} COMPOSE_PROJECT_NAME=hs-api-{session} docker compose up"}]}
JSON
bash "$SH" add "$P" >/dev/null
# command_for is an internal function; invoke marina.sh's dry-run/print path for the service command.
cmd="$(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" print-command api 2>/dev/null)" \
  || { echo "SKIP: marina.sh has no print-command (add it or assert via start log)"; exit 0; }
case "$cmd" in
  *"HOST_PORT=18080"*) ;; *) echo "FAIL: {port} not substituted: $cmd"; exit 1;; esac
case "$cmd" in
  *"COMPOSE_PROJECT_NAME=hs-api-"*) ;; *) echo "FAIL: {session} not substituted: $cmd"; exit 1;; esac
case "$cmd" in
  *"{port}"*|*"{session}"*) echo "FAIL: raw token left in: $cmd"; exit 1;; esac
echo "PASS test-docker-run-tokens"
```

- [ ] **Step 2: Run it — discover the assertion path**

Run: `bash plugin/tests/test-docker-run-tokens.sh`
If it prints `SKIP`, `marina.sh` has no command-printing subcommand. Add a minimal one: in `marina.sh`'s registry/dispatch `case`, add `print-command) shift; command_for "$1" "$(port_offset "$1" 2>/dev/null || echo 0)"; echo; exit 0 ;;` (use the existing offset helper name — check `grep -n "offset" plugin/scripts/marina.sh`). Re-run until `PASS`. This print path is also useful for debugging.

- [ ] **Step 3: Document the docker run pattern**

In `README.md`, in the `marina-services.json` section (find the services schema description), add a subsection:

````markdown
#### Running a service under docker

`run` is any shell command, so docker compose works with **zero special support** — pass marina's
tokens into the container so each worktree stays isolated:

```jsonc
{ "name": "api", "portBase": 18080, "cwd": "projects/kotlin-skeleton",
  "run": "exec env HOST_PORT={port} COMPOSE_PROJECT_NAME=svc-{session} docker compose up --abort-on-container-exit" }
```

```yaml
# the service's compose.yml must take the host port + project name from the env:
services:
  api:
    ports: ["${HOST_PORT}:8080"]
```

`{port}` = `portBase` + per-worktree offset, `{session}` = per-worktree id → concurrent worktrees get
distinct host ports and compose project names, exactly like a native service. Stop sends `SIGTERM`
first, which makes `compose up` stop its containers. (Limit: a container that needs >5s to stop is
force-killed and may linger; orphan detection matches the process, not the container.)
````

- [ ] **Step 4: Commit**

```bash
git add plugin/tests/test-docker-run-tokens.sh README.md plugin/scripts/marina.sh
git commit -m "test+docs(plugin): docker run convention via {port}/{session} tokens (zero core change)"
```

---

### Task 5: homeserver service definitions (separate repo)

**Files:**
- Create: `~/IdeaProjects/sumin/homeserver/marina-services.json`

This is the original ask. The two registered subrepos run natively (worktree dev); docker is documented as an alternative. **Confirm details first** (Open item 3): kotlin run module/port, react default port, and whether either port collides with homeserver's caddy/docker.

- [ ] **Step 1: Confirm run commands**

- kotlin: `grep -rn "server.port\|server:" ~/IdeaProjects/sumin/homeserver/projects/kotlin-skeleton/apps/api/src/main/resources/ 2>/dev/null` (default 8080 if none); runnable module is `:apps:api` (from `settings.gradle.kts`).
- react: vite default 5173 (no explicit port in `vite.config.*`).
- collision: `grep -rn "8080\|5173\|18080" ~/IdeaProjects/sumin/homeserver/docker-compose.yml ~/IdeaProjects/sumin/homeserver/caddy 2>/dev/null` — pick non-colliding `portBase`s.

- [ ] **Step 2: Write `marina-services.json`**

Create `~/IdeaProjects/sumin/homeserver/marina-services.json` (adjust ports per Step 1):

```jsonc
{
  "services": [
    {
      "name": "web",
      "portBase": 5173,
      "cwd": "projects/react-skeleton",
      "cachePaths": ["projects/react-skeleton/node_modules/.vite", "projects/react-skeleton/dist"],
      "orphanPattern": "node_modules/\\.bin/vite|vite/bin/vite",
      "run": "exec npx vite --port {port} --strictPort"
    },
    {
      "name": "api",
      "portBase": 18080,
      "cwd": "projects/kotlin-skeleton",
      "cachePaths": ["projects/kotlin-skeleton/**/build"],
      "orphanPattern": ":apps:api:bootRun|org\\.gradle\\.launcher\\.daemon",
      "run": "exec ./gradlew :apps:api:bootRun --args='--server.port={port}'"
    }
  ]
}
```

- [ ] **Step 3: Verify in the dashboard**

Restart the dashboard daemon so it re-discovers (services_for reads live, but a restart is the clean check):
`bash ~/.config/superpowers/worktrees/marina/multiproject-services/plugin/scripts/marina-entrypoint.sh dashboard` (or the user's running daemon). Open the dashboard, confirm `homeserver` subrepos now show `1 svc` each (not `no svc`) and `mdc` still shows its 5.

- [ ] **Step 4: Commit (in the homeserver repo)**

```bash
cd ~/IdeaProjects/sumin/homeserver
git add marina-services.json
git commit -m "chore: marina-services.json — react (vite) + kotlin (gradlew bootRun) dev services"
```

---

## Self-Review

- **Spec coverage:** §A globals→per-project = Tasks 1–3; §B docker thin convention = Task 4; homeserver artifact = Task 5; testing = per-task tests + regressions. ✓
- **Open items:** (1) `safe_service` callers — Task 2 Step 9 enumerates + threads root. (2) memo invalidation — deferred (lookups read live like `services_for`; add caching only if profiling shows cost — noted, not blocking). (3) homeserver kotlin port — Task 5 Step 1 confirms. ✓
- **Type consistency:** `extra_services_for`/`port_base_for`/`log_targets_for`/`orphan_rules_for`/`orphan_rules_all` names used identically across Tasks 1–3; `cache_guard_services(category, root)` and `safe_service(service, root)` signatures updated with their callers in the same task. ✓
- **No placeholders:** every code step shows the code; consumer swaps quote the exact anchor.

## Out of scope (per spec)

- `kind=docker` first-class lifecycle (status/stop/logs via docker CLI, container orphan reaping).
- Cross-project port-collision arbitration beyond the existing `free_port_near`/`fix_port_conflict` shift.
- Per-root memo/caching (add only if needed).
