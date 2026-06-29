# compose-kind Dashboard Rendering (Plan B / spec ④) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Rev 3** — incorporates codex review rounds 1+2 (NO-GO → fixed). See "Review changelog".

**Goal:** Make compose-kind worktrees render their live services (from `docker compose ps`), Docker-assigned host ports, and health in the marina dashboard; make `↗` open-web work; and make the existing start/stop/restart buttons actually drive compose services.

**Architecture:** The daemon (`marina-control.py`) gets compose branches in three places: (1) **display** — `session_payload()` builds the per-worktree `services[]` from `docker compose -p <name> ps --all --format json` in the **same dict shape** as native, so the card renderer is reused; (2) **action-name validation** — `log_targets_for()` (used by `safe_service`, which gates `/api/start|stop|restart|logs`) includes the compose service names; (3) **action execution** — `start_service()` already shells `marina.sh` (compose-OK), but `stop_service()`/`stop_all()` are native host-PID kills (no-op for containers) and `restart_service()` calls native stop, so those three branch to shell `marina.sh stop/restart` for compose. The daemon reuses `marina-compose.py`'s `compose_project_name` (via importlib) so the dashboard's `-p` name matches the CLI's exactly. Two small frontend touches: gate the source badge + subrepo/add-service affordances for compose worktrees.

**Tech Stack:** Python 3 stdlib (`marina-control.py`, `ThreadingHTTPServer`), Docker Compose v2 (`docker compose ps --all --format json`), embedded `INDEX_HTML` JS, bash test harness.

**Source of truth:** `docs/specs/2026-06-18-worktree-compose-orchestration-design.md` §④ + Plan A (`docs/superpowers/plans/2026-06-18-compose-orchestration.md`, implemented on this branch).

---

## Scope

Spec **④**: compose worktrees appear in the dashboard with services, external ports, health, working `↗`, and working ▶/■/↻ buttons.

**In scope:** daemon display branch (`session_payload`/`_compose_services`); **action-name validation branch (`log_targets_for`)** so the buttons work; `kind` surfaced to frontend; frontend gating (source badge, subrepo/add-service); preview verify on `:3901`.

**Deferred (documented limits, not built):**
- **Never-started compose** (no containers yet) shows an empty card — `ps` only knows containers that exist. After the first `marina start --all` (CLI) every service has a container (running or stopped via `--all`) and is dashboard-controllable. Follow-on: list defined-but-never-created services from `docker compose config --services`.
- **In-dashboard compose log streaming** (`/api/logs` → `docker compose logs`) — `logRuns:[]`, use CLI `marina logs`.
- **Per-container memory** (`rssMb:null`).
- Rich registration UI (Plan C), LLM starter (Plan D).

**No-regression:** native rendering + native action validation are untouched; compose branches run only when `project["kind"]=="compose"`. Docker is shelled only for compose worktrees. Task 3.2 enforces.

---

## Key facts (verified this session — reading marina-control.py + real docker)

- `safe_service(name, root)` (marina-control.py:1781) raises `"unknown service"` if `name not in log_targets_for(root)`; `log_targets_for` (1662) = `(*services_for(root), "console")` (marina-services only). **So `/api/start|stop|restart` (5517) and `/api/logs` (5260) reject compose names until `log_targets_for` is extended.** ← load-bearing fix #1.
- **Action execution asymmetry:** `start_service` (2026) shells `marina.sh start --<svc>` (→ compose via marina.sh, works). But `stop_service` (1839) is a **native host-PID kill** (`listenerPids`/`trackedPid` via lsof — compose containers have none → no-op), `stop_all` (1874) = `{svc: stop_service(...) for svc in services_for(root)}` (empty for compose → does nothing), and `restart_service` (2059) = native `stop_service` + `start_service`. **So stop/restart/stop-all must branch to shell `marina.sh` for compose.** ← load-bearing fix #2.
- `pillState(svc)` (4331): `if (!svc.running) return OFF; return HEALTH_PILLS[svc.health] ?? ok`. **`running` gates everything** → to show BOOT/ERR, the service must have `running:true`. So set `running = (health is not None)`.
- `makeSvcRow` source badge (4633): `svc.source==='central' ? 'Local' : 'Team'` — **unconditional**, so any compose `source` renders "Team". Must gate the badge on `session.kind==='compose'`.
- `makeSvcRow` edit/del (4664): gated on `svc.def` → `def:null` already hides ✎/✕. ▶/■/↻ (4650) gated on `svc.running` → present/clickable for compose.
- `docker compose ps --format json` (docker 29.1.3): NDJSON rows; `Service`, `State` (running/exited/restarting/created/paused/dead), `Health` (`""`|healthy|starting|unhealthy), `Publishers:[{PublishedPort,...}]`. **`PublishedPort` can be int or string across versions → cast to int before `sorted()`** (codex reproduced a `TypeError`). Without `--all`, stopped containers are hidden.
- Server is `ThreadingHTTPServer` (5634) — concurrent requests OK. `log_targets_for` is called ONLY by `safe_service` (not a poll hot path) → safe to add a docker call there.
- `marina-compose.py` has `compose_project_name(id, session)` (pure, tested). Daemon reuses it; `session_id(root)` exists in both marina-control.py and marina.sh and must agree (Task 1.4 guards).

---

## File structure

**Modified — `plugin/scripts/marina-control.py`:**

| Area | Change |
|------|--------|
| `load_projects()` (~123) | read `kind`/`composeFile`/`composeEnvVar`/`composeEnvDefault` (default `kind="native"`). |
| top helpers | `_mc()` importlib-load `marina-compose.py`. |
| near `service_status` (~1557) | pure `compose_health(state, health)` + `build_compose_services(ps_rows)`. |
| near `services_for` (~1660) | `compose_ps(root, name)` (docker, `--all`, defensive); `compose_service_names(root, project)`. |
| `log_targets_for()` (1662) | branch: compose → `(*compose_service_names, "console")`. |
| `session_payload()` (~1751) | branch services to `_compose_services()`; add `"kind"`. |
| `INDEX_HTML` JS | `makeSvcRow`: gate source badge on `session.kind`; `renderServiceTree`: skip subrepo headers/add-service for compose. |

**New tests:** `test-compose-dash-services.sh` (pure builder+health), `test-compose-dash-sessionid.sh` (daemon/CLI session-id parity), `test-compose-dash-api.sh` (gated: `/api/sessions` shows compose services AND `/api/start` accepts a compose service name).

---

## Phase 1 — Daemon

### Task 1.1: `load_projects()` reads `kind` + compose fields

**Files:** Modify `marina-control.py` `load_projects()`.

- [ ] **Step 1:** `grep -n "def load_projects" plugin/scripts/marina-control.py`; find the `items.append({...})`.
- [ ] **Step 2:** Add four keys to that dict (keep existing):

```python
                "kind": str(entry.get("kind") or "native"),
                "composeFile": str(entry.get("composeFile") or "docker-compose.yml"),
                "composeEnvVar": str(entry.get("composeEnvVar") or ""),
                "composeEnvDefault": str(entry.get("composeEnvDefault") or "local"),
```

- [ ] **Step 3:** `python3 -c "import importlib.util as u;s=u.spec_from_file_location('m','plugin/scripts/marina-control.py');m=u.module_from_spec(s);s.loader.exec_module(m);print('ok')"` → `ok`.
- [ ] **Step 4:** Commit — `git commit -am "feat(compose-dash): load_projects reads kind + compose fields"`

### Task 1.2: pure `compose_health` + `build_compose_services`

**Files:** Modify `marina-control.py` (add near `service_status`); Test `plugin/tests/test-compose-dash-services.sh`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# build_compose_services: ps 행 → native shape 서비스 dict; running=(health!=None); 포트 int-cast+dedup; health 매핑.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
python3 - "$CTRL" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mctl", sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.compose_health("running","")=="ok"
assert m.compose_health("running","healthy")=="ok"
assert m.compose_health("running","starting")=="starting"
assert m.compose_health("running","unhealthy")=="bad"
assert m.compose_health("restarting","")=="starting"
assert m.compose_health("created","") is None     # 생성됐지만 미기동 → OFF(▶ 표시)
assert m.compose_health("paused","") is None
assert m.compose_health("exited","") is None
assert m.compose_health("dead","") is None
print("ok health")
rows=[
 {"Service":"web","State":"running","Health":"",
  "Publishers":[{"PublishedPort":"54001"},{"PublishedPort":54001}]},   # str+int 혼합 → dedup 54001
 {"Service":"be","State":"running","Health":"healthy","Publishers":[{"PublishedPort":54002}]},
 {"Service":"worker","State":"running","Health":"","Publishers":[]},   # 내부 전용
 {"Service":"db","State":"exited","Health":"","Publishers":[]},        # 정지
 {"Service":"boot","State":"restarting","Health":"","Publishers":[{"PublishedPort":54003}]},
]
s={x["service"]:x for x in m.build_compose_services(rows)}
assert s["web"]["port"]=="54001" and s["web"]["running"] is True and s["web"]["health"]=="ok", s["web"]
for k in ("service","port","running","health","trackedPid","listenerPids","rssMb","log","logRuns","subrepo","source","def"):
    assert k in s["web"], f"missing {k}"
assert s["web"]["subrepo"]=="" and s["web"]["def"] is None and s["web"]["source"]=="compose"
assert s["be"]["port"]=="54002" and s["be"]["health"]=="ok"
assert s["worker"]["port"] is None and s["worker"]["running"] is True   # running+publish없음 → ON, port -
assert s["db"]["running"] is False and s["db"]["health"] is None        # exited → OFF
assert s["boot"]["running"] is True and s["boot"]["health"]=="starting" # restarting → BOOT
print("ok services")
PY
echo "PASS test-compose-dash-services"
```

- [ ] **Step 2: Run → fails:** `bash plugin/tests/test-compose-dash-services.sh`

- [ ] **Step 3: Implement** (add after `service_status`):

```python
def compose_health(state: str, health: str) -> str | None:
    """docker compose ps State/Health → pill 문자열. 정지 상태는 None(OFF).
    healthcheck 없으면 Health='' → running 이면 ok."""
    state = (state or "").lower()
    health = (health or "").lower()
    if state == "running":
        if health == "unhealthy":
            return "bad"
        if health == "starting":
            return "starting"
        return "ok"
    if state == "restarting":
        return "starting"
    return None  # created / paused / exited / dead / removing → OFF (▶ 표시)


def build_compose_services(ps_rows: list) -> list:
    """`docker compose ps --all --format json` 행 → 대시보드 서비스 dict (native service_status shape).
    running = (health is not None) — 프론트 pillState 가 running 으로 health 표시를 게이트하기 때문.
    포트는 PublishedPort(str/int 혼재 가능) int 캐스트·dedup 후 최소값 대표(다중 publish 는 v1 한계)."""
    out = []
    for r in ps_rows:
        if not isinstance(r, dict):
            continue
        svc = r.get("Service") or r.get("Name") or "?"
        pubs = set()
        for p in (r.get("Publishers") or []):
            if isinstance(p, dict) and p.get("PublishedPort"):
                try:
                    pubs.add(int(p["PublishedPort"]))
                except (TypeError, ValueError):
                    pass
        health = compose_health(r.get("State") or "", r.get("Health") or "")
        out.append({
            "service": svc,
            "port": str(min(pubs)) if pubs else None,
            "running": health is not None,
            "health": health,
            "trackedPid": None,
            "trackedAlive": False,
            "listenerPids": [],
            "rssMb": None,
            "log": "",
            "logRuns": [],
            "subrepo": "",
            "source": "compose",
            "def": None,
        })
    out.sort(key=lambda s: s["service"])
    return out
```

- [ ] **Step 4: Run → passes.** **Step 5: Commit** — `git add -A && git commit -m "feat(compose-dash): compose_health + build_compose_services (native shape, running=health-driven)"`

### Task 1.3: `_mc`, `compose_ps`, `compose_service_names`, `_compose_services`

**Files:** Modify `marina-control.py`.

- [ ] **Step 1: `_mc()` loader** — `marina-compose.py` is a sibling of `marina-control.py` = `CONTROL_SCRIPT.parent` (marina-control.py:31; `MARINA_SCRIPT` at :33 uses the same). Add after those constants:

```python
import importlib.util as _ilu
_MC = None
def _mc():
    """marina-compose.py 순수 함수 재사용 (compose_project_name) — CLI 와 동일 -p 이름 보장."""
    global _MC
    if _MC is None:
        spec = _ilu.spec_from_file_location("marina_compose", str(CONTROL_SCRIPT.parent / "marina-compose.py"))
        mod = _ilu.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _MC = mod
    return _MC
```

- [ ] **Step 2: `compose_ps` + `compose_service_names`** (add near `services_for`):

```python
def compose_ps(root: Path, project_name: str) -> list:
    """docker compose -p <name> ps --all --format json → 행 리스트. docker 없거나 실패 시 [].
    --all 로 정지 컨테이너도 포함(대시보드에서 재기동 가능)."""
    try:
        out = subprocess.check_output(
            ["docker", "compose", "-p", project_name, "ps", "--all", "--format", "json"],
            cwd=str(root), text=True, stderr=subprocess.DEVNULL, timeout=5,
        )
    except Exception:
        return []
    out = out.strip()
    if not out:
        return []
    try:
        v = json.loads(out)
        return v if isinstance(v, list) else [v]
    except json.JSONDecodeError:
        rows = []
        for ln in out.splitlines():
            ln = ln.strip()
            if ln:
                try:
                    rows.append(json.loads(ln))
                except json.JSONDecodeError:
                    pass
        return rows


def compose_service_names(root: Path, project: dict) -> tuple:
    """compose 워크트리의 서비스 이름들 (ps --all 기준) — log_targets_for/safe_service 검증용."""
    name = _mc().compose_project_name(project.get("id", ""), session_id(root))
    return tuple(sorted({(r.get("Service") or r.get("Name") or "")
                         for r in compose_ps(root, name)
                         if isinstance(r, dict) and (r.get("Service") or r.get("Name"))}))
```

- [ ] **Step 3: `_compose_services`** (defensive — never 500 `/api/sessions`):

```python
def _compose_services(root: Path, project: dict) -> list:
    try:
        name = _mc().compose_project_name(project.get("id", ""), session_id(root))
        return build_compose_services(compose_ps(root, name))
    except Exception:
        return []
```

- [ ] **Step 4: Commit** — `git commit -am "feat(compose-dash): compose_ps(--all)/service_names/_compose_services (defensive)"`

### Task 1.4: `session_payload` branch + `log_targets_for` branch

**Files:** Modify `marina-control.py` (`session_payload` ~1751, `log_targets_for` 1662).

- [ ] **Step 1: Branch `log_targets_for`** (action/log validation accepts compose names):

```python
def log_targets_for(root: Path) -> tuple[str, ...]:
    project = project_for(root)
    if project and project.get("kind") == "compose":
        return (*compose_service_names(root, project), "console")
    return (*services_for(root), "console")
```

- [ ] **Step 2: Branch `session_payload`** — replace the `services` assignment + add `"kind"`:

```python
def session_payload(root, snapshot=None, listeners_by_port=None):
    ports = ports_for(root)
    project = project_for(root)
    kind = (project or {}).get("kind", "native")
    services = _compose_services(root, project) if kind == "compose" else _tagged_services(root, ports, snapshot, listeners_by_port)
    return {
        "id": session_id(root),
        "alias": read_meta(root).get("alias", ""),
        "source": root_source(root),
        "root": str(root),
        "ports": ports,
        "kind": kind,
        "config": read_config(root),
        "worktreeStatus": worktree_status_cached(root),
        "services": services,
        "consoleLogRuns": log_run_payload(root, "console"),
    }
```

(Match the file's actual existing return keys — only `services` becomes conditional and `"kind"` is added.)

- [ ] **Step 3: Smoke import** — `python3 -c "import importlib.util as u;s=u.spec_from_file_location('m','plugin/scripts/marina-control.py');m=u.module_from_spec(s);s.loader.exec_module(m);print('ok',callable(m._compose_services),callable(m.compose_service_names))"` → `ok True True`.
- [ ] **Step 4: Commit** — `git commit -am "feat(compose-dash): session_payload serves compose ps; log_targets_for accepts compose service names"`

### Task 1.5: daemon/CLI session-id parity test

**Files:** Test `plugin/tests/test-compose-dash-sessionid.sh`.

- [ ] **Step 1: Write the test** (SOURCE_ROOT = main checkout, ROOT = worktree — the realistic env the daemon/CLI both see):

```bash
#!/usr/bin/env bash
# 대시보드 -p 이름 = CLI -p 이름: marina-control.py session_id(root) == marina.sh session 값.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/proj"; mkdir -p "$SRC/.claude/worktrees/feat-x"; SRC="$(cd "$SRC" && pwd -P)"
WT="$SRC/.claude/worktrees/feat-x"
# marina.sh: ROOT=worktree, SOURCE_ROOT=main → session_id = basename(ROOT)=feat-x
sh_sid="$(cd "$WT" && ROOT="$WT" SOURCE_ROOT="$SRC" MARINA_HOME="$TMP/home" bash "$SH" print-session-dir 2>/dev/null | xargs basename)"
ctl_sid="$(python3 - "$CTRL" "$WT" "$SRC" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mctl", sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
from pathlib import Path
import os; os.environ.setdefault("MARINA_HOME", "/tmp/none")
print(m.session_id(Path(sys.argv[2])))
PY
)"
[[ "$sh_sid" == "$ctl_sid" && -n "$ctl_sid" ]] || { echo "FAIL: sid mismatch sh='$sh_sid' ctl='$ctl_sid'"; exit 1; }
echo "ok sid=$ctl_sid"; echo "PASS test-compose-dash-sessionid"
```

(If the daemon's `session_id(root)` needs SOURCE detection from path topology rather than env, and it diverges from marina.sh, STOP — reconcile before relying on `-p` name match.)

- [ ] **Step 2: Run → PASS.** **Step 3: Commit** — `git add plugin/tests/test-compose-dash-sessionid.sh && git commit -m "test(compose-dash): daemon/CLI session-id parity"`

### Task 1.6: compose action execution — `stop_service`/`restart_service`/`stop_all` branch to `marina.sh`

`/api/start` already shells `marina.sh` (compose-OK). These three are native host-PID kills (no-op for containers) and must branch.

**Files:** Modify `marina-control.py` (`stop_service` ~1839, `stop_all` ~1874, `restart_service` ~2059).

- [ ] **Step 1: helpers** (add near `start_service`/`script`):

```python
def _project_kind(root: Path) -> str:
    p = project_for(root)
    return (p or {}).get("kind", "native")


def _marina_cli(root: Path, *args: str, timeout: float = 120) -> str:
    return subprocess.check_output(
        [str(script(root)), *args], cwd=str(root), text=True,
        stderr=subprocess.STDOUT, env=marina_env(root), timeout=timeout,
    )
```

- [ ] **Step 2: branch `stop_service`** (insert at the very top, before `ports = ports_for(root)`):

```python
def stop_service(root: Path, service: str) -> dict[str, Any]:
    if _project_kind(root) == "compose":
        try:
            out = _marina_cli(root, "stop", f"--{service}")   # compose_main → docker compose stop <svc>
        except subprocess.CalledProcessError as exc:
            raise ValueError(f"stop failed: {(exc.output or '')[-500:]}")
        reset_health(root, service)
        return {"stopped": True, "output": out[-1000:]}
    ports = ports_for(root)
    # ... existing native body unchanged ...
```

- [ ] **Step 3: branch `restart_service`** (top):

```python
def restart_service(root: Path, service: str, force: bool = False) -> dict[str, Any]:
    if _project_kind(root) == "compose":
        try:
            out = _marina_cli(root, "restart", f"--{service}")  # compose_main → docker compose restart <svc>
        except subprocess.CalledProcessError as exc:
            raise ValueError(f"restart failed: {(exc.output or '')[-500:]}")
        reset_health(root, service)
        return {"restarted": True, "output": out[-1000:]}
    stop_result = stop_service(root, service)
    # ... existing native body unchanged ...
```

- [ ] **Step 4: branch `stop_all`**:

```python
def stop_all(root: Path) -> dict[str, Any]:
    if _project_kind(root) == "compose":
        try:
            out = _marina_cli(root, "stop", "--all")           # compose_main → docker compose down --remove-orphans
        except subprocess.CalledProcessError as exc:
            raise ValueError(f"stop-all failed: {(exc.output or '')[-500:]}")
        return {"stoppedAll": True, "output": out[-1000:]}
    return {service: stop_service(root, service) for service in services_for(root)}
```

(`cleanup_session` calls `stop_all` → covered transitively. `start_service` needs no branch — it already shells `marina.sh start --<svc>`; its native `service_status` pre-check returns not-running for compose so it always runs the idempotent `up`.)

- [ ] **Step 5: Smoke import** — `python3 -c "import importlib.util as u;s=u.spec_from_file_location('m','plugin/scripts/marina-control.py');m=u.module_from_spec(s);s.loader.exec_module(m);print('ok')"` → `ok`.
- [ ] **Step 6: Commit** — `git commit -am "feat(compose-dash): stop/restart/stop_all shell marina.sh for compose (action execution)"`

---

## Phase 2 — Frontend (INDEX_HTML)

### Task 2.1: gate source badge + subrepo/add-service for compose

**Files:** Modify `marina-control.py` `INDEX_HTML`.

- [ ] **Step 1: Gate the source badge in `makeSvcRow`** (find `svc.source === 'central'`, ~4633):

Replace:
```javascript
      const src = svc.source === 'central'
        ? '<span class="svc-src central" title="Local override (~/.marina/services) — wins over Team">Local</span>'
        : '<span class="svc-src root" title="Team — shared via marina-services.json in repo">Team</span>';
```
with:
```javascript
      const src = session.kind === 'compose'
        ? ''
        : (svc.source === 'central'
            ? '<span class="svc-src central" title="Local override (~/.marina/services) — wins over Team">Local</span>'
            : '<span class="svc-src root" title="Team — shared via marina-services.json in repo">Team</span>');
```

- [ ] **Step 2: Gate subrepo headers/add-service in `renderServiceTree`** (find `renderServiceTree`, ~4711):

After the `byGroup`/`rootSvcs` split, add `const isCompose = session.kind === 'compose';`. Compose services all have `subrepo:""` → already in `rootSvcs` (rendered ungrouped). Wrap the subrepo-group rendering loop (`for (const name of groups) {...}`) and any top-level "+ 서비스 추가" affordance with `if (!isCompose) { ... }` so compose worktrees show only the flat compose service list.

- [ ] **Step 3: Commit** — `git commit -am "feat(compose-dash): hide source badge + subrepo/add-service UI for compose worktrees"`

### Task 2.2: Live preview verification on `:3901`

**Files:** none (verification) — uses the running `marina-preview` (:3901) + a real compose project + real docker (up).

- [ ] **Step 1:** Register + start a throwaway compose project (default `~/.marina`):

```bash
TMP="$(mktemp -d)"; P="$TMP/dashdemo"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"
cat > "$P/docker-compose.yml" <<'YML'
services:
  web: { image: "python:3-alpine", command: ["python","-m","http.server","8000"], ports: ["8000:8000"] }
  worker: { image: "alpine", command: ["sleep","600"] }
YML
plugin/scripts/marina.sh project add "$P" --compose "$P/docker-compose.yml" --env-var APP_ENV --env-default local
(cd "$P" && plugin/scripts/marina.sh start --all)
```

- [ ] **Step 2:** Bounce `marina-preview` (so the daemon re-reads the registry) via `preview_stop`+`preview_start`, then reload the page.
- [ ] **Step 3:** `preview_screenshot` + `preview_console_logs`. Verify: `dashdemo` card lists `web` (numeric port, `ON`) + `worker` (port `-`, `ON`); no "Team/Local" badge; no ✎/✕; no subrepo sections; no "add service"; selecting `web` shows `↗` → `http://localhost:<web port>/`; ▶/■/↻ present; zero console errors. Click ■ on `web`, re-screenshot → pill flips toward `OFF` (proves action path through `log_targets_for`).
- [ ] **Step 4:** Tear down: `(cd "$P" && plugin/scripts/marina.sh stop --all); plugin/scripts/marina.sh project rm dashdemo; rm -rf "$TMP"`. If bugs found, fix `INDEX_HTML` and re-verify. (No commit — verification.)

---

## Phase 3 — Real-docker API E2E + no-regression

### Task 3.1: gated `/api/sessions` + `/api/start` E2E

**Files:** Test `plugin/tests/test-compose-dash-api.sh`.

- [ ] **Step 1: Write the gated test**

```bash
#!/usr/bin/env bash
# /api/sessions 가 compose 서비스를 native shape 로 돌려주고, /api/start 가 compose 서비스명을 수락한다. 데몬 없으면 SKIP.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"; CTRL="$HERE/../scripts/marina-control.py"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-dash-api (docker 데몬 미가용)"; exit 0; }
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"
cat > "$P/docker-compose.yml" <<'YML'
services:
  web: { image: "python:3-alpine", command: ["python","-m","http.server","8000"], ports: ["8000:8000"] }
YML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" start --all >/dev/null)
PORT=39713
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
cleanup(){ kill "$SRV" 2>/dev/null||true; (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" stop --all >/dev/null 2>&1)||true; rm -rf "$TMP"; }
trap cleanup EXIT
H="-H Origin:http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do curl -sf $H "http://127.0.0.1:$PORT/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done
# NOTE: `curl | python3 - <<PY` 는 heredoc 이 stdin 을 덮어 깨진다 → JSON 캡처 후 python3 -c (stdin=파이프).
printf '%s' "$(curl -sf $H "http://127.0.0.1:$PORT/api/sessions")" | python3 -c '
import json,sys
d=json.load(sys.stdin)
cs=[s for s in d["sessions"] if s.get("kind")=="compose"]
assert cs, "no compose session"
web=next((sv for s in cs for sv in s["services"] if sv["service"]=="web"), None)
assert web and str(web["port"]).isdigit() and web["running"] and web["health"]=="ok", web
print("ok sessions web", web["port"])
'
# /api/start 가 compose 서비스명 수락 (unknown service 400 아님)
code="$(curl -s -o /dev/null -w '%{http_code}' $H -X POST -H 'Content-Type: application/json' \
  -d "{\"root\":\"$P\",\"service\":\"web\"}" "http://127.0.0.1:$PORT/api/start")"
[[ "$code" != "400" ]] || { echo "FAIL: /api/start rejected compose service (log_targets_for)"; exit 1; }
echo "ok start accepted ($code)"
# /api/stop 가 실제로 compose 컨테이너를 내린다 (native no-op 아님 — Task 1.6)
scode="$(curl -s -o /dev/null -w '%{http_code}' $H -X POST -H 'Content-Type: application/json' \
  -d "{\"root\":\"$P\",\"service\":\"web\"}" "http://127.0.0.1:$PORT/api/stop")"
[[ "$scode" == "200" ]] || { echo "FAIL: /api/stop status $scode"; exit 1; }
printf '%s' "$(curl -sf $H "http://127.0.0.1:$PORT/api/sessions")" | python3 -c '
import json,sys
d=json.load(sys.stdin)
web=next((sv for s in d["sessions"] if s.get("kind")=="compose" for sv in s["services"] if sv["service"]=="web"), None)
assert web is not None and web["running"] is False, f"web should be stopped after /api/stop: {web}"
print("ok /api/stop drove compose down")
'
echo "PASS test-compose-dash-api"
```

- [ ] **Step 2: Run → PASS / SKIP.** **Step 3: Commit** — `git commit -am "test(compose-dash): /api/sessions + /api/start compose E2E (gated)"`

### Task 3.2: native no-regression + full suite + README

- [ ] **Step 1:** Native daemon/API tests unchanged: `for t in test-registry-api test-multiproject-services test-config-observe test-llm-status-api test-subrepo-tree-api test-attach-detach-api; do bash plugin/tests/$t.sh >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done` → all PASS.
- [ ] **Step 2:** Full suite: `for f in plugin/tests/test-*.sh; do bash "$f" >/dev/null 2>&1 || echo "FAIL $(basename $f)"; done; echo "done"` → no FAIL.
- [ ] **Step 3:** README — one line under compose-kind: "대시보드(:3900)에도 compose 워크트리의 서비스·외부포트·상태가 뜨고 `↗`·▶/■/↻ 가 동작한다(서비스 목록은 `docker compose ps --all` 라이브; 한 번도 안 띄운 스택은 `marina start --all` 후 표시)."
- [ ] **Step 4:** Commit — `git commit -am "docs(readme): compose-kind in dashboard"`

---

## Self-review

| Spec ④ / fix | Covered by |
|--------------|-----------|
| 서비스(=compose ps) 표시 | `compose_ps --all`+`build_compose_services` (1.2/1.3), API E2E (3.1) |
| 외부포트 표시 | `build_compose_services` port (int-cast, dedup) (1.2); preview (2.2) |
| 상태 표시 (running→ON/BOOT/ERR, 정지→OFF) | `compose_health`+`running=health-not-None` (1.2) |
| 카드/헬스 패턴 재사용 | same dict shape → `makeSvcRow`/`HEALTH_PILLS` unchanged |
| `↗` web 열기 | existing handler (shape match); preview (2.2) |
| ▶/■/↻ 동작 (compose) | name accept: `log_targets_for` branch (1.4); **execution: stop/restart/stop_all shell marina.sh (1.6)**; preview ■ click (2.2); API start-accept + stop-drives-down (3.1) |
| -p 이름 = CLI 일치 | `compose_project_name` reuse + session-id parity (1.5) |
| source badge / subrepo UI 오표시 방지 | frontend gate (2.1) |
| dashboard UX 원칙·:3901 검증 | Task 2.2 (`marina-dashboard-ux-preferences`) |
| native 무회귀 | kind-gated; Task 3.2 |

**Placeholders:** none — code complete; the two frontend edits show exact before/after + guard. **Names consistent:** `compose_health`/`build_compose_services`/`compose_ps`/`compose_service_names`/`_compose_services`/`_mc`, payload key `kind`, service-dict keys mirror `service_status`.

**Documented v1 limits:** never-started compose → empty card (bootstrap via `marina start --all`); no in-dashboard compose logs (`logRuns:[]`); no compose memory (`rssMb:null`); multi-published-port service shows the min port; docker-down on a compose project → empty card (CLI gives the clear error).

## Open question (non-blocking)

- **Poll cost:** `/api/sessions` shells `docker compose ps --all` per compose worktree (timeout 5s, ThreadingHTTPServer so non-blocking globally). Fine for a few; if many compose worktrees, batch via one `docker ps --filter label=com.docker.compose.project --format json` grouped by project. **Recommendation:** ship per-worktree for v1; optimize if it bites.

## Review changelog

**rev 2 → rev 3** (codex round 2, NO-GO): **(blocker)** stop/restart didn't drive compose — `/api/stop`→native `stop_service` (host-PID kill, no-op for containers), `/api/restart`→native stop, `/api/stop-all`→native `services_for`. New **Task 1.6** branches `stop_service`/`restart_service`/`stop_all` to shell `marina.sh stop/restart` for compose. **(blocker)** `_mc()` used nonexistent `SCRIPT_DIR` → fixed to `CONTROL_SCRIPT.parent`. **(nit)** `created`/`paused` → OFF (was BOOT) so ▶ shows for not-running containers. API test now also asserts `/api/stop` drives the container down.

**rev 1 → rev 2** (codex round 1, NO-GO) fixes: **(A)** `log_targets_for` now branches for compose so `/api/start|stop|restart|logs` accept compose service names (the action path did NOT "just work"); source badge gated on `session.kind` (was rendering "Team"). **(D)** `PublishedPort` int-cast before `sorted()` (fixes reproduced `TypeError`); min-port representative + multi-port limit documented. **(E)** `running = (health is not None)` so transitional containers show BOOT not OFF; `compose_health` covers restarting/created/paused/dead. **(C)** session-id parity test fixed (SOURCE_ROOT = main checkout, not worktree). **(F)** subrepo/add-service gated for compose. **(G)** `ps` timeout 5s; batching noted. **(H)** `ps --all` (stopped containers show → startable); `_compose_services` try/except (no 500); never-started/docker-down limits documented. API test now also asserts `/api/start` accepts a compose service name.

## Workflow reminders

- TDD, mktemp fixtures; docker tests gated (`docker info`). Conventional Commits, no trailers. Preview (:3901) for the frontend change (2.2). Push/deploy require 형 approval.
