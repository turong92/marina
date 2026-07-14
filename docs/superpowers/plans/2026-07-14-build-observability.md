# Build Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build run별 총 시간, BuildKit·Gradle 단계, cache hit 수, 가장 느린 단계를 marina 로그 탭에서 설명한다.

**Architecture:** 기존 `build` 가상 서비스의 run log를 유지하고, `marina_build.py`가 log와 작은 JSON sidecar를 구조화한다. lifecycle wrapper가 정확한 시작·종료·상태를 sidecar에 원자적으로 기록하고, read-only API가 요청된 run을 mtime cache로 파싱한다. 프론트는 기존 로그 본문 위에 build run일 때만 compact timeline을 표시한다.

**Tech Stack:** Python 3 표준 라이브러리, bash test harness, classic browser JavaScript, 기존 marina HTTP server, CSS, Aside browser verification.

## Global Constraints

- 새 Python·JavaScript dependency를 추가하지 않는다.
- 기존 raw build log, SSE streaming, run rotation, redaction 동작을 변경하지 않는다.
- 이 계획에서는 `docker compose up -d --build` 의미를 변경하지 않는다.
- parser가 모르는 출력은 무시하고 raw log에서 계속 볼 수 있게 한다.
- `/api/sessions` polling에서 전체 build log를 매번 파싱하지 않는다.
- API는 `safe_root`, `safe_service`, `selected_log` 검증을 그대로 사용한다.
- 사용자 표시 문구는 한국어, machine-readable enum과 key는 영어 camelCase를 사용한다.
- UI는 기존 로그 탭 안의 unframed band이며 새 page·card·modal을 만들지 않는다.
- 실제 브라우저 검증은 Chrome plugin 대신 Aside를 우선한다.

---

## File Map

- Create `plugin/scripts/marina_build.py`: metadata sidecar, BuildKit·Gradle parser, mtime cache.
- Modify `plugin/scripts/marina_cli.py`: lifecycle 시작·종료 metadata 기록.
- Modify `plugin/scripts/marina_handler.py`: `GET /api/build-summary` endpoint.
- Modify `plugin/scripts/marina-web/index.html`: build summary mount와 script 등록.
- Create `plugin/scripts/marina-web/app-4b-build.js`: API 요청·race guard·timeline render.
- Modify `plugin/scripts/marina-web/app-4-logs.js`: log 선택 시 build summary hook 호출.
- Modify `plugin/scripts/marina-web/styles.css`: compact timeline layout.
- Modify `plugin/tests/test-build-log.sh`: metadata lifecycle 회귀.
- Create `plugin/tests/test-build-summary.sh`: parser와 cache 계약.
- Create `plugin/tests/test-build-summary-api.sh`: endpoint validation·payload.
- Create `plugin/tests/test-build-summary-ui.sh`: DOM·script·hook 불변식.
- Modify `README.md`: build timeline 사용법과 해석.

### Task 1: Build metadata와 parser

**Files:**
- Create: `plugin/scripts/marina_build.py`
- Create: `plugin/tests/test-build-summary.sh`

**Interfaces:**
- Produces: `write_build_meta(log_path: Path, payload: dict) -> None`
- Produces: `read_build_meta(log_path: Path) -> dict`
- Produces: `build_summary(log_path: Path) -> dict`
- Payload: `{status, op, startedAt, endedAt, durationSec, cacheHits, cacheMisses, steps, bottleneck}`

- [x] **Step 1: Write the failing parser test**

Create `plugin/tests/test-build-summary.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/run-001.log" <<'LOG'
$ marina start --all
BUILD SUCCESSFUL in 13s
#17 [search-api stage-0 3/8] RUN apt-get install ffmpeg
#17 CACHED
#29 [web internal] load build context
#29 transferring context: 775.83kB 5.1s done
#29 DONE 5.1s
#33 [web stage-0 5/5] RUN pnpm install --filter "web..."
#33 DONE 22.9s
#34 [web] exporting to image
#34 exporting layers 45.0s done
#34 unpacking to docker.io/library/web:latest 23.4s done
#34 DONE 68.5s
LOG

python3 - "$HERE/../scripts" "$TMP/run-001.log" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from marina_build import build_summary, write_build_meta

log = Path(sys.argv[2])
write_build_meta(log, {
    "status": "success", "op": "start",
    "startedAt": 100.0, "endedAt": 230.0, "durationSec": 130.0,
})
out = build_summary(log)
assert out["status"] == "success", out
assert out["durationSec"] == 130.0, out
assert out["cacheHits"] == 1, out
assert out["cacheMisses"] == 4, out
assert out["bottleneck"]["durationSec"] == 68.5, out
labels = [step["label"] for step in out["steps"]]
assert "Gradle pre-build" in labels, labels
assert any("pnpm install" in label for label in labels), labels
assert any(step["cached"] for step in out["steps"]), out

# 같은 mtime은 동일 payload를 반환하고, append 후에는 새 결과를 반환한다.
first = build_summary(log)
second = build_summary(log)
assert first == second
log.write_text(log.read_text() + "#40 [web] resolving provenance\n#40 DONE 0.2s\n")
third = build_summary(log)
assert len(third["steps"]) == len(second["steps"]) + 1, (second, third)
print(json.dumps(third, ensure_ascii=False))
PY

echo "PASS test-build-summary"
```

- [x] **Step 2: Run the parser test to verify it fails**

Run:

```bash
bash plugin/tests/test-build-summary.sh
```

Expected: FAIL with `ModuleNotFoundError: No module named 'marina_build'`.

- [x] **Step 3: Implement metadata and parser**

Create `plugin/scripts/marina_build.py` with these contracts:

```python
"""Build run metadata and best-effort BuildKit/Gradle summaries."""
from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

_CACHE: dict[str, tuple[tuple[int, int, int, int], dict[str, Any]]] = {}
_DEF = re.compile(r"^#(?P<id>\d+) \[(?P<label>[^]]+)](?: (?P<command>.+))?$")
_DONE = re.compile(r"^#(?P<id>\d+) DONE (?P<seconds>\d+(?:\.\d+)?)s$")
_CACHED = re.compile(r"^#(?P<id>\d+) CACHED$")
_GRADLE = re.compile(r"^BUILD SUCCESSFUL in (?P<seconds>\d+(?:\.\d+)?)s$")


def build_meta_path(log_path: Path) -> Path:
    return log_path.with_suffix(".meta.json")


def write_build_meta(log_path: Path, payload: dict[str, Any]) -> None:
    path = build_meta_path(log_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def read_build_meta(log_path: Path) -> dict[str, Any]:
    try:
        data = json.loads(build_meta_path(log_path).read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _display_label(label: str, command: str) -> str:
    if "load build context" in label:
        return label.replace(" internal", "")
    if "exporting to image" in label:
        return label
    if command.startswith("RUN "):
        text = command[4:].strip()
        return text if len(text) <= 100 else text[:97] + "..."
    return label


def _parse(text: str) -> list[dict[str, Any]]:
    definitions: dict[str, tuple[str, str]] = {}
    terminal: dict[str, tuple[float, bool]] = {}
    order: list[str] = []
    gradle: list[dict[str, Any]] = []
    for raw in text.splitlines():
        line = raw.strip()
        match = _DEF.match(line)
        if match:
            step_id = match.group("id")
            if step_id not in definitions:
                order.append(step_id)
            definitions[step_id] = (match.group("label"), match.group("command") or "")
            continue
        match = _CACHED.match(line)
        if match:
            terminal[match.group("id")] = (0.0, True)
            continue
        match = _DONE.match(line)
        if match:
            terminal[match.group("id")] = (float(match.group("seconds")), False)
            continue
        match = _GRADLE.match(line)
        if match:
            gradle.append({
                "id": f"gradle-{len(gradle) + 1}", "label": "Gradle pre-build",
                "kind": "prebuild", "durationSec": float(match.group("seconds")),
                "cached": False,
            })
    steps = list(gradle)
    for step_id in order:
        if step_id not in terminal:
            continue
        label, command = definitions[step_id]
        seconds, cached = terminal[step_id]
        steps.append({
            "id": step_id,
            "label": _display_label(label, command),
            "kind": "buildkit",
            "durationSec": seconds,
            "cached": cached,
        })
    return steps


def build_summary(log_path: Path) -> dict[str, Any]:
    log_path = Path(log_path)
    meta_path = build_meta_path(log_path)
    log_stat = log_path.stat()
    try:
        meta_stat = meta_path.stat()
        meta_sig = (meta_stat.st_mtime_ns, meta_stat.st_size)
    except OSError:
        meta_sig = (0, 0)
    signature = (log_stat.st_mtime_ns, log_stat.st_size, meta_sig[0], meta_sig[1])
    key = str(log_path)
    cached = _CACHE.get(key)
    if cached and cached[0] == signature:
        return cached[1]
    text = log_path.read_text(encoding="utf-8", errors="replace")
    meta = read_build_meta(log_path)
    steps = _parse(text)
    misses = [step for step in steps if not step["cached"]]
    bottleneck = max(misses, key=lambda step: step["durationSec"], default=None)
    out = {
        "run": log_path.name,
        "status": meta.get("status", "unknown"),
        "op": meta.get("op", ""),
        "startedAt": meta.get("startedAt"),
        "endedAt": meta.get("endedAt"),
        "durationSec": meta.get("durationSec"),
        "cacheHits": sum(1 for step in steps if step["cached"]),
        "cacheMisses": len(misses),
        "steps": steps,
        "bottleneck": bottleneck,
    }
    _CACHE[key] = (signature, out)
    return out
```

Keep the parser best-effort: do not infer download counts or duplicate the 45s export sub-line as a separate step when `#34 DONE 68.5s` already represents the whole step.

- [x] **Step 4: Run the parser test to verify it passes**

Run:

```bash
bash plugin/tests/test-build-summary.sh
```

Expected: `PASS test-build-summary`.

- [ ] **Step 5: Commit parser and test**

```bash
git add plugin/scripts/marina_build.py plugin/tests/test-build-summary.sh
git commit -m "feat(build): parse lifecycle build summaries"
```

### Task 2: Lifecycle metadata recording

**Files:**
- Modify: `plugin/scripts/marina_cli.py:201`
- Modify: `plugin/tests/test-build-log.sh:8`

**Interfaces:**
- Consumes: `write_build_meta(log_path, payload)` from Task 1.
- Produces: one `run-NNN.meta.json` beside every build `run-NNN.log`.

- [x] **Step 1: Extend the failing lifecycle test**

In the Python block of `plugin/tests/test-build-log.sh`, add imports and assertions after the successful call:

```python
from marina_build import read_build_meta

run_path = mp.log_runs(root, "build")[0]
meta = read_build_meta(run_path)
assert meta["status"] == "success", meta
assert meta["op"] == "start", meta
assert meta["durationSec"] >= 0, meta
assert meta["endedAt"] >= meta["startedAt"], meta
```

After the failing `/usr/bin/false` call, add:

```python
failed_run = mp.log_runs(root, "build")[0]
failed_meta = read_build_meta(failed_run)
assert failed_meta["status"] == "failed", failed_meta
assert failed_meta["exitCode"] != 0, failed_meta
```

- [x] **Step 2: Run the lifecycle test to verify it fails**

Run:

```bash
bash plugin/tests/test-build-log.sh
```

Expected: FAIL because `read_build_meta()` returns `{}`.

- [x] **Step 3: Record metadata around the existing process**

Import `write_build_meta` inside `_marina_cli_logged` to avoid expanding module import coupling, then preserve the current logging and error behavior:

```python
def _marina_cli_logged(root: Path, *args: str, timeout: float = 120, extra_env: dict | None = None) -> None:
    from marina_build import write_build_meta
    from marina_paths import next_log_path

    log_path = next_log_path(root, "build")
    env = marina_env(root)
    if extra_env:
        env.update(extra_env)
    argv = [str(script(root)), *args]
    started_at = time.time()
    op = args[0] if args else ""
    meta = {"status": "running", "op": op, "startedAt": started_at}
    write_build_meta(log_path, meta)
    rc = None
    timed_out = False
    try:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(f"$ marina {' '.join(args)}\n")
            fh.flush()
            proc = subprocess.Popen(argv, cwd=str(root), env=env, stdout=fh,
                                    stderr=subprocess.STDOUT, text=True)
            try:
                rc = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                proc.kill()
                proc.wait(5)
                raise
    finally:
        ended_at = time.time()
        final = {
            **meta,
            "status": "timeout" if timed_out else ("success" if rc == 0 else "failed"),
            "endedAt": ended_at,
            "durationSec": round(max(0.0, ended_at - started_at), 3),
        }
        if rc is not None:
            final["exitCode"] = rc
        write_build_meta(log_path, final)
    if rc != 0:
        tail = ""
        try:
            size = os.path.getsize(log_path)
            with open(log_path, "rb") as fh:
                fh.seek(max(0, size - 4096))
                tail = fh.read().decode("utf-8", "replace")
        except OSError:
            pass
        raise subprocess.CalledProcessError(rc, argv, output=tail)
```

- [x] **Step 4: Run lifecycle and parser regression tests**

Run:

```bash
bash plugin/tests/test-build-log.sh
bash plugin/tests/test-build-summary.sh
```

Expected: both print `PASS`.

- [ ] **Step 5: Commit metadata recording**

```bash
git add plugin/scripts/marina_cli.py plugin/tests/test-build-log.sh
git commit -m "feat(build): record lifecycle timing metadata"
```

### Task 3: Build Summary API

**Files:**
- Modify: `plugin/scripts/marina_handler.py:20`
- Create: `plugin/tests/test-build-summary-api.sh`

**Interfaces:**
- Consumes: `build_summary(log_path: Path) -> dict` from Task 1.
- Produces: `GET /api/build-summary?root=<root>&run=<current|run-NNN.log>`.
- Returns: the exact `build_summary()` payload.

- [x] **Step 1: Write the failing endpoint test**

Create `plugin/tests/test-build-summary-api.sh` using the existing dashboard server pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
mkdir -p "$P/.workspace/marina/main/logs/build"
cat > "$P/.workspace/marina/main/logs/build/run-001.log" <<'LOG'
#1 [web] RUN pnpm install
#1 DONE 4.2s
LOG
ln -s "logs/build/run-001.log" "$P/.workspace/marina/main/build.log"
cat > "$MARINA_HOME/projects.json" <<JSON
{"schemaVersion":1,"projects":[{"id":"proj","root":"$P","subrepos":[],"worktreeGlobs":[]}]}
JSON

PORT=39714
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!; trap 'kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/api/worktrees" >/dev/null 2>&1 && break
  sleep 0.1
done

curl -sf "http://127.0.0.1:$PORT/api/build-summary?root=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$P")&run=current" |
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["run"] == "run-001.log", d; assert d["bottleneck"]["durationSec"] == 4.2, d'

code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/build-summary?root=/tmp/not-registered&run=current")"
[[ "$code" == "400" ]]
echo "PASS test-build-summary-api"
```

- [x] **Step 2: Run the endpoint test to verify it fails**

Run:

```bash
bash plugin/tests/test-build-summary-api.sh
```

Expected: FAIL with HTTP 404.

- [x] **Step 3: Add the read-only endpoint**

Add `from marina_build import build_summary` near the handler imports. Before the existing `/api/logs` block, add:

```python
if parsed.path == "/api/build-summary":
    query = urllib.parse.parse_qs(parsed.query)
    try:
        root = safe_root(query.get("root", [""])[0])
        safe_service("build", root)
        run = query.get("run", ["current"])[0]
        path = selected_log(root, "build", run)
        self.send_json(build_summary(path))
    except Exception as exc:
        self.send_json({"error": str(exc)}, 400)
    return
```

- [x] **Step 4: Run endpoint and log regressions**

Run:

```bash
bash plugin/tests/test-build-summary-api.sh
bash plugin/tests/test-compose-dash-logruns.sh
bash plugin/tests/test-build-log.sh
```

Expected: all print `PASS`.

- [ ] **Step 5: Commit the API**

```bash
git add plugin/scripts/marina_handler.py plugin/tests/test-build-summary-api.sh
git commit -m "feat(build): expose run summaries in dashboard API"
```

### Task 4: Build Timeline UI

**Files:**
- Modify: `plugin/scripts/marina-web/index.html:68`
- Create: `plugin/scripts/marina-web/app-4b-build.js`
- Modify: `plugin/scripts/marina-web/app-4-logs.js:313`
- Modify: `plugin/scripts/marina-web/styles.css:656`
- Create: `plugin/tests/test-build-summary-ui.sh`

**Interfaces:**
- Consumes: `GET /api/build-summary` from Task 3.
- Produces: global `loadBuildSummary(root: string, run: string): Promise<void>`.
- Mount: `#buildSummary`, visible only when `selected.service === "build"`.

- [x] **Step 1: Write the failing UI invariant test**

Create `plugin/tests/test-build-summary-ui.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
rg -q 'id="buildSummary"' "$WEB/index.html"
rg -q 'app-4b-build.js' "$WEB/index.html"
rg -q 'function loadBuildSummary' "$WEB/app-4b-build.js"
rg -q 'loadBuildSummary\(root, run\)' "$WEB/app-4-logs.js"
rg -q '\.build-summary' "$WEB/styles.css"
rg -q 'data-build-step' "$WEB/app-4b-build.js"
echo "PASS test-build-summary-ui"
```

- [x] **Step 2: Run the UI test to verify it fails**

Run:

```bash
bash plugin/tests/test-build-summary-ui.sh
```

Expected: FAIL on the first missing invariant.

- [x] **Step 3: Add mount and script order**

In `index.html`, add this between `.log-head` and `#olderBar`:

```html
<div class="build-summary" id="buildSummary" hidden aria-live="polite"></div>
```

Load the new file immediately after `app-4-logs.js`:

```html
<script src="/web/app-4-logs.js"></script>
<script src="/web/app-4b-build.js"></script>
```

- [x] **Step 4: Implement race-safe summary rendering**

Create `app-4b-build.js`:

```javascript
// Build run summary — raw log remains the source of truth below this compact band.
let buildSummaryRequest = 0;

function fmtBuildSeconds(value) {
  if (value == null || !Number.isFinite(Number(value))) return '-';
  const seconds = Number(value);
  return seconds >= 60 ? `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s` : `${seconds.toFixed(seconds < 10 ? 1 : 0)}s`;
}

function buildStepHtml(step, maxSeconds) {
  const seconds = Number(step.durationSec) || 0;
  const pct = step.cached ? 2 : Math.max(2, Math.round((seconds / Math.max(maxSeconds, 0.1)) * 100));
  const state = step.cached ? 'cache' : 'run';
  return `<div class="build-step" data-build-step data-state="${state}">
    <span class="build-step-name" title="${escapeHtml(step.label || '')}">${escapeHtml(step.label || '-')}</span>
    <span class="build-step-track" aria-hidden="true"><span style="width:${pct}%"></span></span>
    <span class="build-step-time">${step.cached ? 'cache' : fmtBuildSeconds(seconds)}</span>
  </div>`;
}

function renderBuildSummary(data) {
  const el = document.getElementById('buildSummary');
  const steps = Array.isArray(data.steps) ? data.steps : [];
  const maxSeconds = Math.max(0.1, ...steps.filter(step => !step.cached).map(step => Number(step.durationSec) || 0));
  const status = {running: '진행 중', success: '완료', failed: '실패', timeout: '시간 초과'}[data.status] || '기록 없음';
  const bottleneck = data.bottleneck ? `가장 오래 걸림 · ${escapeHtml(data.bottleneck.label)} ${fmtBuildSeconds(data.bottleneck.durationSec)}` : '측정 단계 없음';
  el.innerHTML = `<div class="build-summary-head">
      <span class="build-summary-status" data-state="${escapeHtml(data.status || 'unknown')}">${status}</span>
      <strong>${fmtBuildSeconds(data.durationSec)}</strong>
      <span>${bottleneck}</span>
      <span class="build-summary-cache">cache ${Number(data.cacheHits) || 0} · run ${Number(data.cacheMisses) || 0}</span>
    </div>
    <div class="build-steps">${steps.map(step => buildStepHtml(step, maxSeconds)).join('')}</div>`;
  el.hidden = false;
}

async function loadBuildSummary(root, run) {
  const el = document.getElementById('buildSummary');
  const request = ++buildSummaryRequest;
  if (!selected || selected.service !== 'build') {
    el.hidden = true;
    el.innerHTML = '';
    return;
  }
  el.hidden = false;
  el.innerHTML = '<div class="build-summary-head"><span>빌드 분석 중...</span></div>';
  try {
    const data = await api(`/api/build-summary?root=${enc(root)}&run=${enc(run)}`);
    if (request !== buildSummaryRequest || !selected || selected.root !== root || selected.run !== run || selected.service !== 'build') return;
    renderBuildSummary(data);
  } catch (error) {
    if (request !== buildSummaryRequest) return;
    el.innerHTML = `<div class="build-summary-head"><span>빌드 요약을 읽지 못했어요 · ${escapeHtml(error.message || String(error))}</span></div>`;
  }
}
```

At the end of `selectLog()` after `renderSelection()`, add:

```javascript
if (typeof loadBuildSummary === 'function') loadBuildSummary(root, run);
```

- [x] **Step 5: Add compact responsive styles**

Append near the existing log styles:

```css
.build-summary { padding: 8px 16px 10px; border-bottom: 1px solid var(--sys-style-neutral-light); background: var(--sys-bg-surface); }
.build-summary-head { display: flex; align-items: center; gap: 8px 12px; flex-wrap: wrap; color: var(--sys-cont-neutral-default); }
.build-summary-head > span:not(.build-summary-status) { color: var(--sys-cont-neutral-light); }
.build-summary-status { font-weight: 600; }
.build-summary-status[data-state="success"] { color: var(--st-run); }
.build-summary-status[data-state="failed"], .build-summary-status[data-state="timeout"] { color: var(--st-err); }
.build-summary-status[data-state="running"] { color: var(--st-boot); }
.build-summary-cache { margin-left: auto; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
.build-steps { display: grid; gap: 4px; margin-top: 8px; }
.build-step { display: grid; grid-template-columns: minmax(110px, 220px) minmax(80px, 1fr) 54px; gap: 8px; align-items: center; min-width: 0; }
.build-step-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.build-step-track { height: 4px; background: var(--sys-style-neutral-light); overflow: hidden; }
.build-step-track > span { display: block; height: 100%; background: var(--st-boot); }
.build-step[data-state="cache"] .build-step-track > span { background: var(--st-run); }
.build-step-time { text-align: right; color: var(--sys-cont-neutral-light); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
@media (max-width: 560px) {
  .build-summary-cache { margin-left: 0; }
  .build-step { grid-template-columns: minmax(90px, 1fr) 72px 48px; }
}
```

Use the existing marina tokens `--st-run`, `--st-err`, `--st-boot`, `--sys-cont-neutral-light`, and `--sys-style-neutral-light`; do not introduce a duplicate palette.

- [x] **Step 6: Run UI and backend tests**

Run:

```bash
bash plugin/tests/test-build-summary-ui.sh
bash plugin/tests/test-build-summary-api.sh
bash plugin/tests/test-build-summary.sh
```

Expected: all print `PASS`.

- [ ] **Step 7: Commit the UI**

```bash
git add plugin/scripts/marina-web/index.html plugin/scripts/marina-web/app-4b-build.js plugin/scripts/marina-web/app-4-logs.js plugin/scripts/marina-web/styles.css plugin/tests/test-build-summary-ui.sh
git commit -m "feat(dashboard): show build run timeline"
```

### Task 5: Documentation, full regression, and real-browser verification

**Files:**
- Modify: `README.md:386`
- Modify: `docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md`

**Interfaces:**
- Consumes: completed Build Summary API and UI.
- Produces: checked P0.1 roadmap item and user-facing interpretation guide.

- [x] **Step 1: Document the feature without promising Smart Build**

Add under the dashboard log viewer documentation:

```markdown
- 빌드 로그를 선택하면 run 총 시간, BuildKit·Gradle 단계, cache hit 수, 가장 오래 걸린 단계를 먼저 보여준다.
  요약은 진단용이며 원문 로그는 그대로 남는다. `시작`은 아직 항상 Compose `--build`를 사용한다.
```

- [x] **Step 2: Run focused tests**

Run:

```bash
bash plugin/tests/test-build-summary.sh
bash plugin/tests/test-build-log.sh
bash plugin/tests/test-build-summary-api.sh
bash plugin/tests/test-build-summary-ui.sh
bash plugin/tests/test-compose-dash-logruns.sh
bash plugin/tests/test-lifecycle-busy.sh
```

Expected: every command prints `PASS`.

- [x] **Step 3: Run the full shell test suite**

Run:

```bash
set -e
for test_file in plugin/tests/test-*.sh; do
  bash "$test_file"
done
```

Expected: no `FAIL`; environment-dependent tests may print their existing explicit `SKIP` messages.

- [x] **Step 4: Verify a real build run**

Use a disposable or already-stopped registered worktree. Run one build with a known cache miss and one immediate repeat. Verify:

- First run shows non-zero `run` count and a bottleneck.
- Second run increases `cache` count and has a shorter total duration.
- ffmpeg and Playwright are described from actual log state, not package-name guesses.
- Switching from build log to a service log hides `#buildSummary`.
- Changing run selector refreshes the summary without showing a stale response.

- [x] **Step 5: Verify the dashboard with Aside**

Read the `aside-browser` skill, then use the Aside MCP `repl` tool. Fallback only if the MCP server is unavailable:

```bash
~/.local/bin/aside repl '<Playwright-compatible JavaScript>'
```

Verify with `snapshot(page, { interactive: true })` and ref-id locators:

- Desktop 1440x900: summary header and every step label/time fit without overlap.
- Narrow 390x844: rows reflow without horizontal page overflow.
- Dark and light themes: status, tracks, and text remain readable.
- Build run switching and service-log switching update visibility correctly.
- Raw log scrolling, filtering, run selector, and follow mode still work.

- [x] **Step 6: Update the master checklist**

In `docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md`, change:

```markdown
- [ ] **P0.1 Build Timeline**
```

to:

```markdown
- [x] **P0.1 Build Timeline**
```

Only do this after Steps 2-5 pass.

- [ ] **Step 7: Final commit**

```bash
git add README.md docs/superpowers/specs/2026-07-14-orca-comparison-and-roadmap-design.md
git commit -m "docs(build): document build timeline workflow"
```

## Plan Self-Review

- Spec coverage: implements only P0.1, the required evidence-gathering milestone before lifecycle semantics change.
- Scope exclusions: P0.2-P0.7 and all Agent UX items remain separate reviewer-sized plans.
- Parser failure mode: unknown lines remain available in raw logs and do not fail the build.
- Data flow: lifecycle writes metadata, parser reads log+metadata, API validates root/run, UI renders only build logs.
- Test layers: pure parser, lifecycle integration, HTTP endpoint, UI invariants, full regressions, real Docker run, Aside browser QA.
- No dependency or storage migration is introduced.
