# Daemon-driven LLM service registration & edit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dashboard's clipboard copy-paste "register via LLM" workaround with a daemon that directly drives a read-only LLM to analyze a repo, fill the service form, and (in direct mode) register + verify a service end-to-end, with the editable form always the single source of truth.

**Architecture:** All work lives in `plugin/scripts/marina-control.py` (the `:3900` daemon, which already owns service start/stop/health/logs). The LLM is only ever a read-only "config function": the daemon spawns `claude -p` / `codex exec` (read tools only), parses JSON out, and itself owns every side effect (launch, stop, register, roll back). Two new POST endpoints (`/api/llm-analyze`, `/api/llm-register`) and one GET (`/api/llm-status`) back a new service-modal "assist bar". A daemon-driven verify+fix loop (max 2 attempts) commits only on launch success and rolls back on failure.

**Tech Stack:** Python 3.9 stdlib (`http.server`, `subprocess`, `json`), bash CLI (`marina.sh`), bash+curl+`python3 -c` integration tests, embedded HTML/CSS/JS dashboard. Frontend verified live via marina preview on `:3901`.

**Test seams (env, test-only — mirrors existing `MARINA_*_DRY_RUN` pattern):**
- `MARINA_LLM_FAKE=<path>` — when set, the LLM spawn runs this script (prompt on stdin, repo dir as cwd) instead of resolving `claude`/`codex`. Lets tests emit canned JSON.
- `MARINA_FAKE_VERIFY=<csv>` — when set, `_launch_and_verify` returns scripted outcomes per attempt (e.g. `fail,ok`) instead of really launching. Lets the loop's control flow be tested without real processes.
- `MARINA_VERIFY_TIMEOUT`, `MARINA_LLM_TIMEOUT`, `MARINA_LLM_REGISTER_ATTEMPTS` — tunables (via the existing `_env()` helper) so tests run fast.

**Insertion points (current line numbers in `marina-control.py`):**
- New module constants + helper block: immediately after `invalidate_registry_caches()` (ends line 867).
- New GET route: in `do_GET`, alongside the other `/api/` GETs (near line 4551).
- New POST routes: in `do_POST`, right after the `add-service`/`remove-service` block (after line 4808); `root` is already in scope (`root = safe_root(...)` at line 4725).
- Frontend HTML: replace the `svc-modal-llm` block (lines 2430-2433).
- Frontend CSS: add near the existing `.svc-modal-llm*` rules (lines 2131-2134).
- Frontend JS: replace the `svcLlmRegister.onclick` handler (lines 2868-2874) and extend `openServiceModal` (line 2820).

---

## Task 1: JSON extraction + validation + normalization

Pure functions that turn raw LLM text into a validated `services.json` definition. No daemon, no network — the foundation everything else parses through.

**Files:**
- Modify: `plugin/scripts/marina-control.py` (new helper block after line 867)
- Test: `plugin/tests/test-llm-parse.sh` (create)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-llm-parse.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"
python3 - "$CTRL" <<'PY' || { echo "FAIL: test-llm-parse"; exit 1; }
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

# 1. bare object
d = mc._extract_service_json('{"name":"web","portBase":3000,"run":"exec x {port}"}')
assert d["name"] == "web", d

# 2. fenced ```json block with surrounding prose
raw = 'Here is the service:\n```json\n{"name":"be","portBase":8080,"run":"exec y {port}"}\n```\nDone.'
d = mc._extract_service_json(raw)
assert d["name"] == "be" and d["portBase"] == 8080, d

# 3. braces inside string values ({port}) do not confuse the scanner
d = mc._extract_service_json('prose {nope} {"name":"w","portBase":1,"run":"a {port} {profile}"}')
assert d["run"] == "a {port} {profile}", d

# 4. no JSON -> ValueError
try:
    mc._extract_service_json("sorry, I could not find a service")
    assert False, "expected ValueError"
except ValueError: pass

# 5. validate: fills cwd default, keeps optionals, rejects junk
v = mc._validate_service_def({"name":" web ","portBase":3000,"run":" exec x "})
assert v == {"name":"web","portBase":3000,"run":"exec x","cwd":"."}, v
v = mc._validate_service_def({"name":"w","portBase":1,"run":"x","cwd":"sub","cachePaths":["sub/.next"],"orphanPattern":"x"})
assert v["cachePaths"] == ["sub/.next"] and v["orphanPattern"] == "x" and v["cwd"] == "sub", v
for bad in [{"portBase":1,"run":"x"}, {"name":"w","run":"x"}, {"name":"w","portBase":True,"run":"x"}, {"name":"w","portBase":1}]:
    try:
        mc._validate_service_def(bad); assert False, ("accepted bad", bad)
    except ValueError: pass

# 6. normalize: single object OR {"services":[...]}
assert len(mc._normalize_candidates({"name":"w","portBase":1,"run":"x"})) == 1
got = mc._normalize_candidates({"services":[{"name":"a","portBase":1,"run":"x"},{"name":"b","portBase":2,"run":"y"}]})
assert [c["name"] for c in got] == ["a","b"], got
PY
echo "PASS test-llm-parse"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-llm-parse.sh`
Expected: FAIL (AttributeError: module 'mc' has no attribute '_extract_service_json').

- [ ] **Step 3: Write minimal implementation**

In `marina-control.py`, after line 867 (`invalidate_registry_caches`), add:

```python
# ── LLM service registration ────────────────────────────────────────────────
# 데몬이 LLM 을 "읽기 전용 config 함수"로만 호출한다: 레포 파일/에러 로그 → services.json JSON.
# 기동·등록·롤백 등 부수효과는 전부 데몬이 소유한다. (form 이 always single source)

def _extract_service_json(text: str) -> dict[str, Any]:
    s = (text or "").strip()
    if "```" in s:
        parts = s.split("```")
        if len(parts) >= 3:
            body = parts[1]
            if body.lstrip()[:4].lower() == "json":
                body = body.lstrip()[4:]
            s = body.strip()
    start = s.find("{")
    if start < 0:
        raise ValueError("LLM 출력에 JSON 객체가 없음")
    depth = 0; in_str = False; esc = False; end = -1
    for i in range(start, len(s)):
        c = s[i]
        if in_str:
            if esc: esc = False
            elif c == "\\": esc = True
            elif c == '"': in_str = False
            continue
        if c == '"': in_str = True
        elif c == "{": depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0: end = i + 1; break
    if end < 0:
        raise ValueError("LLM 출력의 JSON 이 불균형(닫는 괄호 없음)")
    try:
        obj = json.loads(s[start:end])
    except json.JSONDecodeError as exc:
        raise ValueError(f"JSON 파싱 실패: {exc}")
    if not isinstance(obj, dict):
        raise ValueError("JSON 루트가 객체가 아님")
    return obj


def _validate_service_def(d: Any) -> dict[str, Any]:
    if not isinstance(d, dict):
        raise ValueError("서비스 정의는 객체여야 함")
    name = d.get("name")
    if not isinstance(name, str) or not name.strip():
        raise ValueError("name(비어있지 않은 문자열) 필수")
    pb = d.get("portBase")
    if isinstance(pb, bool) or not isinstance(pb, int):
        raise ValueError("portBase(정수) 필수")
    run = d.get("run")
    if not isinstance(run, str) or not run.strip():
        raise ValueError("run(비어있지 않은 문자열) 필수")
    out: dict[str, Any] = {"name": name.strip(), "portBase": pb, "run": run.strip()}
    cwd = d.get("cwd", "")
    if cwd and not isinstance(cwd, str):
        raise ValueError("cwd 는 문자열이어야 함")
    out["cwd"] = cwd.strip() if isinstance(cwd, str) and cwd.strip() else "."
    cp = d.get("cachePaths")
    if cp is not None:
        if not isinstance(cp, list) or not all(isinstance(x, str) for x in cp):
            raise ValueError("cachePaths 는 문자열 배열이어야 함")
        if cp:
            out["cachePaths"] = cp
    op = d.get("orphanPattern")
    if op:
        if not isinstance(op, str):
            raise ValueError("orphanPattern 은 문자열이어야 함")
        out["orphanPattern"] = op
    return out


def _normalize_candidates(obj: dict[str, Any]) -> list[dict[str, Any]]:
    raw = obj.get("services") if isinstance(obj.get("services"), list) else [obj]
    return [_validate_service_def(x) for x in raw]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-llm-parse.sh`
Expected: `PASS test-llm-parse`

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-llm-parse.sh
git commit -m "feat(daemon): JSON extraction + service-def validation for LLM output"
```

---

## Task 2: LLM detection, override, argv builder, run seam

Decide which LLM to use (claude-first, then codex; env/config override) and build the read-only spawn command. The `MARINA_LLM_FAKE` seam is added here.

**Files:**
- Modify: `plugin/scripts/marina-control.py` (extend helper block)
- Test: `plugin/tests/test-llm-detect.sh` (create)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-llm-detect.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
python3 - "$CTRL" <<'PY' || { echo "FAIL: test-llm-detect"; exit 1; }
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

# argv: claude is read-only (Read/Glob/Grep), never Write/Edit/Bash
a = mc._llm_argv("claude", "PROMPT")
assert "-p" in a and "PROMPT" in a and "--allowedTools" in a, a
tools = a[a.index("--allowedTools") + 1]
assert tools == "Read,Glob,Grep", tools
assert "Write" not in tools and "Bash" not in tools and "Edit" not in tools, tools

# argv: codex exec under read-only sandbox
c = mc._llm_argv("codex", "PROMPT")
assert "exec" in c and "PROMPT" in c and "read-only" in c, c

# pinned override via env
os.environ["MARINA_LLM"] = "codex"
assert mc._llm_pinned() == "codex"
del os.environ["MARINA_LLM"]

# pinned override via ~/.marina/config.json
import json, pathlib
pathlib.Path(os.environ["MARINA_HOME"], "config.json").write_text(json.dumps({"llmProvider": "claude"}))
assert mc._llm_pinned() == "claude"

# FAKE seam forces provider "fake"
os.environ["MARINA_LLM_FAKE"] = "/bin/true"
assert mc._llm_provider() == "fake"
del os.environ["MARINA_LLM_FAKE"]
PY
echo "PASS test-llm-detect"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-llm-detect.sh`
Expected: FAIL (no attribute `_llm_argv`).

- [ ] **Step 3: Write minimal implementation**

Append to the helper block in `marina-control.py`:

```python
LLM_TIMEOUT = float(_env("LLM_TIMEOUT", "120"))


def _has_bin(name: str) -> bool:
    return _bin(name) != name


def _llm_pinned() -> str | None:
    v = os.environ.get("MARINA_LLM")
    if v in ("claude", "codex"):
        return v
    try:
        d = json.loads((MARINA_HOME / "config.json").read_text(encoding="utf-8"))
        p = d.get("llmProvider")
        if p in ("claude", "codex"):
            return p
    except Exception:
        pass
    return None


def _llm_available() -> list[str]:
    return [name for name in ("claude", "codex") if _has_bin(name)]


def _llm_provider() -> str | None:
    if os.environ.get("MARINA_LLM_FAKE"):
        return "fake"
    pinned = _llm_pinned()
    if pinned and _has_bin(pinned):
        return pinned
    for name in ("claude", "codex"):
        if _has_bin(name):
            return name
    return None


def _llm_argv(provider: str, prompt: str) -> list[str]:
    if provider == "claude":
        return [_bin("claude"), "-p", prompt, "--allowedTools", "Read,Glob,Grep"]
    if provider == "codex":
        return [_bin("codex"), "exec", "--sandbox", "read-only", prompt]
    raise ValueError(f"알 수 없는 LLM provider: {provider}")


def _llm_run(provider: str, prompt: str, cwd: Path) -> str:
    fake = os.environ.get("MARINA_LLM_FAKE")
    if fake:
        return subprocess.check_output([fake], input=prompt, text=True, cwd=str(cwd), timeout=LLM_TIMEOUT)
    return subprocess.check_output(
        _llm_argv(provider, prompt), text=True, cwd=str(cwd),
        stderr=subprocess.STDOUT, timeout=LLM_TIMEOUT,
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-llm-detect.sh`
Expected: `PASS test-llm-detect`

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-llm-detect.sh
git commit -m "feat(daemon): LLM provider detection/override + read-only spawn argv + fake seam"
```

---

## Task 3: `llm_analyze` — prompt build + parse + one retry

Spawn the read-only LLM in the repo dir, parse its output, retry once on parse failure. Tested entirely through `MARINA_LLM_FAKE`.

**Files:**
- Modify: `plugin/scripts/marina-control.py` (extend helper block)
- Test: `plugin/tests/test-llm-analyze.sh` (create)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-llm-analyze.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/proj"; mkdir -p "$P"

# fake LLM: emits the contents of $MARINA_HOME/out-<callcount>, falling back to out-1
cat > "$TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
c="$MARINA_HOME/calls"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
f="$MARINA_HOME/out-$n"; [[ -f "$f" ]] || f="$MARINA_HOME/out-1"; cat "$f"
EOF
chmod +x "$TMP/fake.sh"; export MARINA_LLM_FAKE="$TMP/fake.sh"

# valid on first call
printf '%s' '```json\n{"name":"web","portBase":5173,"run":"exec npm run dev -- --port {port}"}\n```' > "$MARINA_HOME/out-1"
rm -f "$MARINA_HOME/calls"
python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: analyze valid"; exit 1; }
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
got = mc.llm_analyze(Path(sys.argv[2]))
assert got[0]["name"] == "web" and got[0]["portBase"] == 5173, got
PY

# garbage on call 1, valid on call 2 -> retry succeeds (exactly 2 calls)
printf '%s' 'no json here' > "$MARINA_HOME/out-1"
printf '%s' '{"name":"be","portBase":8080,"run":"exec x {port}"}' > "$MARINA_HOME/out-2"
rm -f "$MARINA_HOME/calls"
python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: analyze retry"; exit 1; }
import importlib.util, sys, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
got = mc.llm_analyze(Path(sys.argv[2]))
assert got[0]["name"] == "be", got
assert open(os.path.join(os.environ["MARINA_HOME"], "calls")).read().strip() == "2"
PY

# garbage on both calls -> ValueError (no third call)
printf '%s' 'nope' > "$MARINA_HOME/out-1"; rm -f "$MARINA_HOME/out-2" "$MARINA_HOME/calls"
python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: analyze giveup"; exit 1; }
import importlib.util, sys, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
try:
    mc.llm_analyze(Path(sys.argv[2])); assert False, "expected ValueError"
except ValueError: pass
assert open(os.path.join(os.environ["MARINA_HOME"], "calls")).read().strip() == "2"
PY
echo "PASS test-llm-analyze"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-llm-analyze.sh`
Expected: FAIL (no attribute `llm_analyze`).

- [ ] **Step 3: Write minimal implementation**

Append to the helper block:

```python
def _analyze_prompt(root: Path, cwd: str, instruction: str,
                    current_def: dict[str, Any] | None, fix_log: str | None) -> str:
    target = (root / cwd) if cwd else root
    lines = [
        "You are configuring a marina dev service. Output ONLY one JSON object — no prose, no markdown fences.",
        f"Project root: {root}",
        f"Service working dir (cwd, root-relative): {cwd or '.'} (absolute: {target})",
        "",
        "Inspect that dir for the runnable dev service: package.json (scripts.dev/start), "
        "build.gradle*/settings.gradle* (Spring bootRun), Dockerfile/docker-compose.yml, "
        "pyproject.toml/requirements.txt (uvicorn/flask).",
        "Emit a JSON object with keys: name (identifier), portBase (integer default port), "
        'cwd (root-relative, "." for root), run (single shell command). '
        "Optional: cachePaths (array of root-relative paths), orphanPattern (regex).",
        "In run, use marina substitution tokens: {port} {profile} {python} {root} {session}. "
        "Prefix long-running commands with exec. Example: exec npm run dev -- --port {port}",
    ]
    if current_def:
        lines += ["", "Current definition (edit this):", json.dumps(current_def, ensure_ascii=False)]
    if instruction:
        lines += ["", f"User instruction: {instruction}"]
    if fix_log:
        lines += ["", "The previous definition FAILED to start. Fix it. Error log tail:", fix_log[-2000:]]
    lines += ["", "Output the JSON object now:"]
    return "\n".join(lines)


def llm_analyze(root: Path, cwd: str = "", instruction: str = "",
                current_def: dict[str, Any] | None = None,
                fix_log: str | None = None) -> list[dict[str, Any]]:
    provider = _llm_provider()
    if not provider:
        raise ValueError("LLM 미설치 (claude/codex 없음)")
    target = (root / cwd) if cwd else root
    prompt = _analyze_prompt(root, cwd, instruction, current_def, fix_log)
    last_err = ""
    for attempt in range(2):
        p = prompt if attempt == 0 else (
            prompt + f"\n\nYour previous output could not be parsed ({last_err}). Output ONLY the JSON object.")
        raw = _llm_run(provider, p, target)
        try:
            return _normalize_candidates(_extract_service_json(raw))
        except ValueError as exc:
            last_err = str(exc)
    raise ValueError(f"LLM 출력 파싱 실패: {last_err}")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-llm-analyze.sh`
Expected: `PASS test-llm-analyze`

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-llm-analyze.sh
git commit -m "feat(daemon): llm_analyze — read-only repo analysis with one parse retry"
```

---

## Task 4: Verify helpers — health-await, log tail, central-file ops, launch seam

The pieces the loop stitches together. `_await_service_ok` is tested against a real `http.server`; `_launch_and_verify` gets the `MARINA_FAKE_VERIFY` seam so the loop (Task 5) is deterministic.

**Files:**
- Modify: `plugin/scripts/marina-control.py` (extend helper block)
- Test: `plugin/tests/test-llm-verify-helpers.sh` (create)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-llm-verify-helpers.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""; cleanup(){ [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"; bash "$SH" project add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"

# real http.server on a free port -> _await_service_ok True; dead port -> False (fast via short timeout)
PORT=39811; python3 -m http.server "$PORT" >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done
python3 - "$CTRL" "$P" "$PORT" "$id" <<'PY' || { echo "FAIL: verify-helpers"; exit 1; }
import importlib.util, sys, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
root = Path(sys.argv[2]); port = sys.argv[3]
ok, _ = mc._await_service_ok(root, "x", port, 5.0); assert ok, "live port should be ok"
ok, why = mc._await_service_ok(root, "x", "39812", 1.0); assert not ok and why, ("dead port", why)

# central-file ops: add, read, rm
proj = mc.project_for(root)
mc._service_add_central(proj, {"name":"web","portBase":3000,"cwd":".","run":"x"})
assert mc._central_def(proj, "web")["portBase"] == 3000
mc._service_rm_central(proj, "web"); assert mc._central_def(proj, "web") is None

# launch seam: MARINA_FAKE_VERIFY scripts outcomes per attempt
os.environ["MARINA_FAKE_VERIFY"] = "fail,ok"
assert mc._launch_and_verify(root, "web", 1.0, 1)[0] is False
assert mc._launch_and_verify(root, "web", 1.0, 2)[0] is True
PY
echo "PASS test-llm-verify-helpers"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-llm-verify-helpers.sh`
Expected: FAIL (no attribute `_await_service_ok`).

- [ ] **Step 3: Write minimal implementation**

Append to the helper block:

```python
VERIFY_TIMEOUT = float(_env("VERIFY_TIMEOUT", "60"))
LLM_REGISTER_MAX_ATTEMPTS = int(_env("LLM_REGISTER_ATTEMPTS", "2"))


def _await_service_ok(root: Path, service: str, port: str | None, timeout: float) -> tuple[bool, str]:
    deadline = time.time() + timeout
    started = False
    while time.time() < deadline:
        cur_port = port or ports_for(root).get(service)
        st = service_status(root, service, cur_port)
        if st.get("running"):
            started = True
            if cur_port and probe_http(cur_port):
                return True, ""
        elif started:
            return False, "프로세스가 종료됨"
        time.sleep(0.5)
    return False, f"{int(timeout)}초 내 미기동"


def _service_log_tail(root: Path, service: str, n: int = 2000) -> str:
    try:
        return selected_log(root, service, None).read_text(encoding="utf-8", errors="replace")[-n:]
    except Exception:
        return ""


def _central_file(proj: dict[str, Any]) -> Path:
    return MARINA_HOME / "services" / f"{proj['id']}.json"


def _central_def(proj: dict[str, Any], name: str | None) -> dict[str, Any] | None:
    if not name:
        return None
    try:
        for s in json.loads(_central_file(proj).read_text(encoding="utf-8")).get("services", []):
            if s.get("name") == name:
                return s
    except Exception:
        pass
    return None


def _service_add_central(proj: dict[str, Any], svc: dict[str, Any]) -> None:
    run_marina_registry("service", "add", proj["id"], json.dumps(svc, ensure_ascii=False))


def _service_rm_central(proj: dict[str, Any], name: str) -> None:
    try:
        run_marina_registry("service", "rm", proj["id"], name)
    except subprocess.CalledProcessError:
        pass


def _launch_and_verify(root: Path, service: str, timeout: float, attempt: int) -> tuple[bool, str]:
    fake = os.environ.get("MARINA_FAKE_VERIFY")
    if fake is not None:
        outcomes = [o.strip() for o in fake.split(",")]
        o = outcomes[min(attempt - 1, len(outcomes) - 1)]
        return (o == "ok", "" if o == "ok" else "fake fail log")
    try:
        stop_service(root, service)
    except Exception:
        pass
    try:
        start_service(root, service)
    except ValueError as exc:
        return False, str(exc)
    ok, reason = _await_service_ok(root, service, ports_for(root).get(service), timeout)
    if ok:
        return True, ""           # 성공 시 정지하지 않음 — 띄운 채로 둔다
    log = _service_log_tail(root, service) or reason
    try:
        stop_service(root, service)
    except Exception:
        pass
    return False, log
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-llm-verify-helpers.sh`
Expected: `PASS test-llm-verify-helpers`

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-llm-verify-helpers.sh
git commit -m "feat(daemon): verify helpers — health-await, log tail, central ops, launch seam"
```

---

## Task 5: `llm_register_loop` — analyze → verify+fix → commit/rollback

The engine for direct mode. Commits to the central services file only on launch success; on exhaustion, rolls back (removes a new service; restores the prior def for an edit).

**Files:**
- Modify: `plugin/scripts/marina-control.py` (extend helper block)
- Test: `plugin/tests/test-llm-register-loop.sh` (create)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-llm-register-loop.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"; bash "$SH" project add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
f="$MARINA_HOME/services/$id.json"

# fake LLM emits out-<callcount> (fallback out-1)
cat > "$TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
c="$MARINA_HOME/calls"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
g="$MARINA_HOME/out-$n"; [[ -f "$g" ]] || g="$MARINA_HOME/out-1"; cat "$g"
EOF
chmod +x "$TMP/fake.sh"; export MARINA_LLM_FAKE="$TMP/fake.sh"
mkdir -p "$MARINA_HOME/services"

run_loop() { python3 - "$CTRL" "$P" "$@" <<'PY'
import importlib.util, sys, json
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
edit = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
print(json.dumps(mc.llm_register_loop(Path(sys.argv[2]), edit_name=edit)))
PY
}

# 1) success on first verify -> committed + ok
printf '%s' '{"name":"web","portBase":3000,"cwd":".","run":"exec x {port}"}' > "$MARINA_HOME/out-1"
rm -f "$MARINA_HOME/calls"; MARINA_FAKE_VERIFY="ok" run_loop "" | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['ok'] and r['name']=='web', r"
python3 -c "import json;s=json.load(open('$f'))['services'];assert any(x['name']=='web' for x in s), s" || { echo "FAIL: success not committed"; exit 1; }
bash "$SH" service rm "$id" web >/dev/null

# 2) fix-then-success: attempt1 verify fails, analyze#2 yields good def, attempt2 ok -> committed
printf '%s' '{"name":"web","portBase":3000,"cwd":".","run":"exec bad {port}"}' > "$MARINA_HOME/out-1"
printf '%s' '{"name":"web","portBase":3001,"cwd":".","run":"exec good {port}"}' > "$MARINA_HOME/out-2"
rm -f "$MARINA_HOME/calls"; MARINA_FAKE_VERIFY="fail,ok" run_loop "" | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['ok'] and r['attempts']==2, r"
python3 -c "import json;s={x['name']:x for x in json.load(open('$f'))['services']};assert s['web']['portBase']==3001, s" || { echo "FAIL: fix not committed"; exit 1; }
bash "$SH" service rm "$id" web >/dev/null

# 3) exhausted on ADD -> rolled back (web absent)
printf '%s' '{"name":"web","portBase":3000,"cwd":".","run":"exec bad {port}"}' > "$MARINA_HOME/out-1"; rm -f "$MARINA_HOME/out-2"
rm -f "$MARINA_HOME/calls"; MARINA_FAKE_VERIFY="fail,fail" run_loop "" | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['ok'] is False, r"
python3 -c "import json,os;p='$f';s=json.load(open(p))['services'] if os.path.exists(p) else [];assert not any(x['name']=='web' for x in s), s" || { echo "FAIL: add not rolled back"; exit 1; }

# 4) exhausted on EDIT -> prior def restored
bash "$SH" service add "$id" '{"name":"api","portBase":8080,"cwd":".","run":"exec orig {port}"}' >/dev/null
printf '%s' '{"name":"api","portBase":9090,"cwd":".","run":"exec broken {port}"}' > "$MARINA_HOME/out-1"
rm -f "$MARINA_HOME/calls"; MARINA_FAKE_VERIFY="fail,fail" run_loop "" api | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['ok'] is False, r"
python3 -c "import json;s={x['name']:x for x in json.load(open('$f'))['services']};assert s['api']['portBase']==8080 and 'orig' in s['api']['run'], s" || { echo "FAIL: edit not restored"; exit 1; }
echo "PASS test-llm-register-loop"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-llm-register-loop.sh`
Expected: FAIL (no attribute `llm_register_loop`).

- [ ] **Step 3: Write minimal implementation**

Append to the helper block:

```python
def llm_register_loop(root: Path, cwd: str = "", instruction: str = "",
                      edit_name: str | None = None) -> dict[str, Any]:
    proj = project_for(root)
    if not proj:
        raise ValueError("미등록 프로젝트")
    prior = _central_def(proj, edit_name)          # 롤백 기준 (편집 시 현재 central 정의)
    context_def = prior                            # LLM 편집 컨텍스트
    fix_log: str | None = None
    cand: dict[str, Any] | None = None
    reason = ""
    for attempt in range(1, LLM_REGISTER_MAX_ATTEMPTS + 1):
        cand = llm_analyze(root, cwd, instruction, context_def, fix_log)[0]
        name = cand["name"]
        _service_add_central(proj, cand)
        invalidate_registry_caches()
        ok, reason = _launch_and_verify(root, name, VERIFY_TIMEOUT, attempt)
        if ok:
            return {"ok": True, "service": cand, "name": name,
                    "port": ports_for(root).get(name), "attempts": attempt}
        fix_log = reason
        context_def = cand
    # 소진 → 롤백
    name = cand["name"] if cand else (edit_name or "")
    if prior:
        _service_add_central(proj, prior)
    elif name:
        _service_rm_central(proj, name)
    invalidate_registry_caches()
    return {"ok": False, "candidate": cand, "attempts": LLM_REGISTER_MAX_ATTEMPTS,
            "error": reason, "log": fix_log}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-llm-register-loop.sh`
Expected: `PASS test-llm-register-loop`

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-llm-register-loop.sh
git commit -m "feat(daemon): llm_register_loop — verify+fix with commit-on-success / rollback"
```

---

## Task 6: HTTP endpoints — `/api/llm-analyze` + `/api/llm-register`

Expose the engine over HTTP, origin-gated like the existing routes.

**Files:**
- Modify: `plugin/scripts/marina-control.py` (do_POST, after line 4808)
- Test: `plugin/tests/test-llm-api.sh` (create)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-llm-api.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""; cleanup(){ [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"; bash "$SH" project add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
cat > "$TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
cat "$MARINA_HOME/out"
EOF
chmod +x "$TMP/fake.sh"; mkdir -p "$MARINA_HOME/services"
printf '%s' '{"name":"web","portBase":3000,"cwd":".","run":"exec x {port}"}' > "$MARINA_HOME/out"

PORT=39730; b="http://127.0.0.1:$PORT"; H=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
MARINA_LLM_FAKE="$TMP/fake.sh" MARINA_FAKE_VERIFY="ok" MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 50); do curl -sf "${H[@]}" "$b/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done

# analyze -> candidates
curl -s "${H[@]}" -d "{\"root\":\"$P\"}" "$b/api/llm-analyze" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'] and r['candidates'][0]['name']=='web', r" || { echo "FAIL: llm-analyze"; exit 1; }

# register (verify ok) -> committed
curl -s "${H[@]}" -d "{\"root\":\"$P\"}" "$b/api/llm-register" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'] and r['name']=='web', r" || { echo "FAIL: llm-register"; exit 1; }
python3 -c "import json;s=json.load(open('$MARINA_HOME/services/$id.json'))['services'];assert any(x['name']=='web' for x in s), s" || { echo "FAIL: register not committed"; exit 1; }

# cross-origin POST rejected
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Origin: http://evil.test" -H "content-type: application/json" -d "{\"root\":\"$P\"}" "$b/api/llm-analyze")
[[ "$code" == "403" ]] || { echo "FAIL: origin not enforced ($code)"; exit 1; }
echo "PASS test-llm-api"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-llm-api.sh`
Expected: FAIL (`llm-analyze` returns 404/error — route absent).

- [ ] **Step 3: Write minimal implementation**

In `do_POST`, immediately after the `add-service`/`remove-service` block (after line 4808), add:

```python
            if self.path == "/api/llm-analyze":
                if not project_for(root):
                    raise ValueError("미등록 프로젝트")
                current = body.get("currentDef")
                cands = llm_analyze(
                    root,
                    str(body.get("cwd", "")).strip(),
                    str(body.get("instruction", "")).strip(),
                    current if isinstance(current, dict) else None,
                )
                self.send_json({"ok": True, "candidates": cands})
                return

            if self.path == "/api/llm-register":
                edit_name = str(body.get("editName", "")).strip() or None
                result = llm_register_loop(
                    root,
                    str(body.get("cwd", "")).strip(),
                    str(body.get("instruction", "")).strip(),
                    edit_name,
                )
                invalidate_registry_caches()
                self.send_json(result)
                return
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-llm-api.sh`
Expected: `PASS test-llm-api`

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-llm-api.sh
git commit -m "feat(daemon): /api/llm-analyze + /api/llm-register endpoints"
```

---

## Task 7: HTTP endpoint — `/api/llm-status`

Tells the UI which providers are available and whether one is pinned, so the picker renders state-adaptively.

**Files:**
- Modify: `plugin/scripts/marina-control.py` (do_GET, near line 4551)
- Test: `plugin/tests/test-llm-status-api.sh` (create)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-llm-status-api.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""; cleanup(){ [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
echo '{"llmProvider":"codex"}' > "$MARINA_HOME/config.json"
PORT=39740; b="http://127.0.0.1:$PORT"; H=(-H "Origin: http://127.0.0.1:$PORT")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 50); do curl -sf "${H[@]}" "$b/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done
curl -s "${H[@]}" "$b/api/llm-status" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert 'providers' in r and isinstance(r['providers'],list);assert r['pinned']=='codex', r" \
  || { echo "FAIL: llm-status"; exit 1; }
echo "PASS test-llm-status-api"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-llm-status-api.sh`
Expected: FAIL (route absent).

- [ ] **Step 3: Write minimal implementation**

In `do_GET`, near the other `/api/` GET routes (e.g. after the `/api/update-status` block around line 4554), add:

```python
        if parsed.path == "/api/llm-status":
            self.send_json({"providers": _llm_available(), "pinned": _llm_pinned()})
            return
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-llm-status-api.sh`
Expected: `PASS test-llm-status-api`

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-llm-status-api.sh
git commit -m "feat(daemon): /api/llm-status — provider availability + pin for the UI"
```

---

## Task 8: Frontend — assist bar HTML + CSS (replace copy-paste row)

Swap the clipboard button for the assist bar: NL input + 분석 button, picker + 직접 등록 toggle, and a progress strip. Verified live on the preview.

**Files:**
- Modify: `plugin/scripts/marina-control.py` (HTML lines 2430-2433; CSS near lines 2131-2134)

- [ ] **Step 1: Replace the assist-row HTML**

Replace lines 2430-2433 (the `svc-modal-llm` block) with:

```python
      <div class="svc-modal-llm" id="svcLlmRow">
        <div class="svc-llm-input">
          <span class="svc-llm-spark" aria-hidden="true">✨</span>
          <input id="svcLlmInstruction" placeholder="예: vite 앱 포트 5173 — 비우면 자동 분석" />
          <button class="svc-llm-go" id="svcLlmAnalyze" type="button">분석</button>
        </div>
        <div class="svc-llm-meta">
          <span class="svc-llm-picker" id="svcLlmPicker" hidden></span>
          <label class="svc-llm-direct"><input type="checkbox" id="svcLlmDirect" /> 직접 등록 (분석→기동검증→등록)</label>
        </div>
        <div class="svc-llm-progress" id="svcLlmProgress" hidden></div>
      </div>
```

- [ ] **Step 2: Add CSS**

After line 2134 (`.svc-modal-llm-hint { ... }`), add:

```python
    .svc-llm-input { display: flex; gap: 8px; align-items: center; }
    .svc-llm-spark { font-size: 15px; }
    .svc-llm-input input { flex: 1; height: 32px; padding: 0 8px; font-size: 13px; }
    .svc-llm-go { height: 32px; padding: 0 14px; border-radius: 8px; border: 1px solid var(--sys-cont-primary-default); background: var(--sys-bg-surface); color: var(--sys-cont-primary-default); font: inherit; font-size: 13px; font-weight: 700; cursor: pointer; white-space: nowrap; }
    .svc-llm-go:hover { background: var(--sys-bg-surface-hover); }
    .svc-llm-go:disabled { opacity: 0.6; cursor: default; }
    .svc-llm-meta { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding-left: 23px; }
    .svc-llm-picker { font-size: 12px; color: var(--sys-cont-neutral-light); cursor: pointer; }
    .svc-llm-direct { font-size: 12px; color: var(--sys-cont-neutral-light); display: inline-flex; align-items: center; gap: 6px; cursor: pointer; }
    .svc-llm-progress { display: flex; align-items: center; gap: 8px; font-size: 13px; padding: 8px 10px; border-radius: 8px; }
    .svc-llm-progress.run { background: hsl(210, 90%, 96%); color: hsl(210, 70%, 38%); }
    .svc-llm-progress.ok { background: hsl(145, 55%, 94%); color: hsl(150, 65%, 28%); }
    .svc-llm-progress.err { background: hsl(358, 70%, 96%); color: var(--sys-cont-negative-default); }
    .svc-llm-progress .svc-llm-log { margin-left: auto; font-size: 12px; text-decoration: underline; cursor: pointer; }
```

- [ ] **Step 3: Verify on the preview**

Start/reload the preview on `:3901` (`marina-control.py` via the preview tooling), open a session card, click a subrepo's **+** (add service) to open the modal. Confirm the assist bar renders: NL input + 분석 button on row 1, the 직접 등록 checkbox on row 2. Use `preview_snapshot` to confirm `#svcLlmInstruction`, `#svcLlmAnalyze`, `#svcLlmDirect` exist; `preview_screenshot` for the layout. No console errors.

- [ ] **Step 4: Commit**

```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(dashboard): replace clipboard register row with LLM assist bar (markup+css)"
```

---

## Task 9: Frontend — picker render + form-fill wiring + edit placeholder

Wire 분석 → `/api/llm-analyze` → fill the form. Render the picker from `/api/llm-status`. Adapt the NL placeholder for edit.

**Files:**
- Modify: `plugin/scripts/marina-control.py` (JS: extend `openServiceModal` line 2820; add handlers near 2868)

- [ ] **Step 1: Add LLM-status fetch + picker render, and reset the bar on open**

Inside `openServiceModal` (after the `showServiceModal(true);` at line 2854 is set up — place this just before it), add:

```javascript
      // assist bar 초기화 (열 때마다 깨끗하게)
      document.getElementById('svcLlmInstruction').value = '';
      document.getElementById('svcLlmInstruction').placeholder = svc
        ? '예: 포트 3027로, env에 FOO 추가'
        : '예: vite 앱 포트 5173 — 비우면 자동 분석';
      document.getElementById('svcLlmDirect').checked = svcLlmDirectPref;
      const prog = document.getElementById('svcLlmProgress');
      prog.hidden = true; prog.className = 'svc-llm-progress';
      renderLlmPicker();
```

The `svcLlmRow` is shown for both add and edit now — delete the line that hid it for edit. Replace line 2826:

```javascript
      document.getElementById('svcLlmRow').hidden = !!svc;
```

with:

```javascript
      document.getElementById('svcLlmRow').hidden = false;
```

- [ ] **Step 2: Add picker state + the renderer/handlers**

Replace the old clipboard handler (lines 2868-2874, `svcLlmRegister.onclick = ...`) with:

```javascript
    let svcLlmStatus = null;          // {providers:[], pinned}
    let svcLlmDirectPref = false;     // 직접 등록 토글 기억 (세션 내)
    let svcLlmBusy = false;

    async function renderLlmPicker() {
      const picker = document.getElementById('svcLlmPicker');
      const analyzeBtn = document.getElementById('svcLlmAnalyze');
      if (!svcLlmStatus) {
        try { svcLlmStatus = await api('/api/llm-status'); } catch { svcLlmStatus = {providers: [], pinned: null}; }
      }
      const provs = svcLlmStatus.providers || [];
      if (!provs.length) {
        picker.hidden = true;
        analyzeBtn.disabled = true; analyzeBtn.title = 'claude/codex 미설치 — 수동 입력만 가능';
        document.getElementById('svcLlmDirect').disabled = true;
        return;
      }
      analyzeBtn.disabled = false; analyzeBtn.title = '';
      document.getElementById('svcLlmDirect').disabled = false;
      const active = svcLlmStatus.pinned || provs[0];
      if (svcLlmStatus.pinned || provs.length < 2) {
        picker.hidden = !!svcLlmStatus.pinned ? true : (provs.length < 2 ? false : true);
        if (provs.length < 2 && !svcLlmStatus.pinned) { picker.hidden = false; picker.textContent = active; picker.style.cursor = 'default'; picker.onclick = null; }
      } else {
        picker.hidden = false; picker.style.cursor = 'pointer';
        picker.textContent = active + ' ▾';
        picker.onclick = () => {
          const i = provs.indexOf(svcLlmStatus.pinned || provs[0]);
          svcLlmStatus.pinned = provs[(i + 1) % provs.length];
          renderLlmPicker();
        };
      }
    }

    function setLlmProgress(kind, text, logText) {
      const prog = document.getElementById('svcLlmProgress');
      prog.hidden = false;
      prog.className = 'svc-llm-progress ' + kind;
      prog.innerHTML = '<span>' + escapeHtml(text) + '</span>';
      if (logText) {
        const a = document.createElement('span');
        a.className = 'svc-llm-log'; a.textContent = '로그 보기';
        a.onclick = () => alert(logText);
        prog.appendChild(a);
      }
    }

    function fillServiceForm(def) {
      document.getElementById('svcName').value = def.name || '';
      document.getElementById('svcPortBase').value = def.portBase ?? '';
      if (def.cwd && def.cwd !== '.') document.getElementById('svcCwd').value = def.cwd;
      document.getElementById('svcRun').value = def.run || '';
      document.getElementById('svcCachePaths').value = (def.cachePaths || []).join(', ');
      document.getElementById('svcOrphanPattern').value = def.orphanPattern || '';
    }

    document.getElementById('svcLlmDirect').onchange = (e) => { svcLlmDirectPref = e.target.checked; };

    document.getElementById('svcLlmAnalyze').onclick = async () => {
      if (svcLlmBusy || !svcModalTarget) return;
      const {root, subrepo, editName} = svcModalTarget;
      const instruction = document.getElementById('svcLlmInstruction').value.trim();
      const direct = document.getElementById('svcLlmDirect').checked;
      const provider = (svcLlmStatus && (svcLlmStatus.pinned || (svcLlmStatus.providers || [])[0])) || '';
      svcLlmBusy = true;
      document.getElementById('svcLlmAnalyze').disabled = true;
      try {
        if (direct) {
          await runDirectRegister(root, subrepo, editName, instruction);
        } else {
          setLlmProgress('run', '레포 분석 중… (' + provider + ', 수십 초 소요)');
          const r = await api('/api/llm-analyze', {
            method: 'POST', headers: {'content-type': 'application/json'},
            body: JSON.stringify({root, cwd: subrepo || '', instruction, currentDef: currentDefForEdit(editName)}),
          });
          const cands = r.candidates || [];
          if (cands.length) fillServiceForm(cands[0]);
          setLlmProgress('ok', cands.length > 1
            ? (cands.length + '개 감지 — 첫 번째를 채웠어요 (필요하면 수정)')
            : '폼을 채웠어요 — 확인하고 저장하세요');
        }
      } catch (e) {
        setLlmProgress('err', String(e.message || e).slice(0, 200));
      } finally {
        svcLlmBusy = false;
        document.getElementById('svcLlmAnalyze').disabled = false;
      }
    };

    function currentDefForEdit(editName) {
      if (!editName || !svcModalTarget) return null;
      const m = serviceMeta(svcModalTarget.root, editName);
      return m && m.service && m.service.def ? m.service.def : null;
    }
```

(Note: `runDirectRegister` is added in Task 10; the 직접 등록 branch will throw "not defined" until then — acceptable between tasks, but do not ship Task 9 alone.)

- [ ] **Step 3: Verify form-fill on the preview**

To exercise without a real LLM, run the preview daemon with `MARINA_LLM_FAKE` pointing at a script that echoes a canned service JSON (see Task 6's fake). Open the add-service modal, click 분석, confirm: progress shows "레포 분석 중…" then "폼을 채웠어요", and the name/portBase/run fields populate. Open an existing service (edit) and confirm the NL placeholder reads "예: 포트 3027로, env에 FOO 추가". `preview_console_logs` shows no errors.

- [ ] **Step 4: Commit**

```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(dashboard): LLM picker + form-fill (분석) wiring + edit NL placeholder"
```

---

## Task 10: Frontend — direct register loop + progress + fallback + cleanup

Wire 직접 등록 → `/api/llm-register`, show progress, and on failure fall back to the pre-filled form. Remove the now-unused `svcLlmRegister` element reference.

**Files:**
- Modify: `plugin/scripts/marina-control.py` (JS near the Task 9 handlers)

- [ ] **Step 1: Add the direct-register driver**

After the `svcLlmAnalyze.onclick` handler (from Task 9), add:

```javascript
    async function runDirectRegister(root, subrepo, editName, instruction) {
      setLlmProgress('run', '분석 → 기동 검증 중… (수십 초~1분 소요)');
      const r = await api('/api/llm-register', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({root, cwd: subrepo || '', instruction, editName: editName || ''}),
      });
      if (r.ok) {
        setLlmProgress('ok', '등록·기동 검증 통과 — ' + r.name + (r.port ? (' :' + r.port) : '') + ' 실행 중');
        await load({force: true});
        setTimeout(() => showServiceModal(false), 1200);
      } else {
        if (r.candidate) fillServiceForm(r.candidate);
        setLlmProgress('err', (r.attempts || 0) + '회 시도 실패 — 폼으로 강등했어요', r.log || r.error || '');
      }
    }
```

- [ ] **Step 2: Confirm no dangling reference to the removed button**

Run: `grep -n "svcLlmRegister" plugin/scripts/marina-control.py`
Expected: no matches (the old handler was replaced in Task 9; the old `id="svcLlmRegister"` button was removed in Task 8). If any remain, delete them.

- [ ] **Step 3: Verify direct register on the preview**

Run the preview daemon with `MARINA_LLM_FAKE` (canned JSON) and `MARINA_FAKE_VERIFY=ok`. Open the add modal, check 직접 등록, click 분석. Confirm: progress shows "분석 → 기동 검증 중…" then "등록·기동 검증 통과 …", the modal closes, and the service appears in the card. Then restart the preview daemon with `MARINA_FAKE_VERIFY=fail` and repeat: confirm the progress ends in "…시도 실패 — 폼으로 강등했어요", a 로그 보기 link appears, and the form is populated with the candidate so the user can fix + save manually. `preview_console_logs` clean.

- [ ] **Step 4: Commit**

```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(dashboard): direct-register loop with progress + form fallback"
```

---

## Task 11: Reconcile slash command + full regression

Align `service.md` wording (dashboard no longer instructs paste-into-session) and run the whole suite.

**Files:**
- Modify: `plugin/commands/service.md`
- Test: full `plugin/tests` run

- [ ] **Step 1: Update `service.md`**

In `plugin/commands/service.md`, the `add` procedure stays valid as a CLI/slash path, but remove any implication that it's the dashboard's only LLM route. Edit the description line and step 5 to note the dashboard now registers directly (no copy-paste). Concretely, change step 5's tail from telling the user to refresh, to: "The dashboard's ✨ assist bar performs this same analysis directly — this slash command is the terminal/CLI equivalent." Keep the analysis procedure (step 2) intact — it is the canonical prompt the daemon mirrors.

- [ ] **Step 2: Run the full test suite**

Run: `for t in plugin/tests/test-*.sh; do echo "== $t"; bash "$t" || { echo "FAILED: $t"; break; }; done`
Expected: every line ends in `PASS …`, including the six new tests (`test-llm-parse`, `test-llm-detect`, `test-llm-analyze`, `test-llm-verify-helpers`, `test-llm-register-loop`, `test-llm-api`, `test-llm-status-api`).

- [ ] **Step 3: Final preview smoke test**

On the `:3901` preview with a real `claude` or `codex` available (no fake seam): open the add-service modal on a real subrepo, click 분석, and confirm the form fills from genuine repo analysis. Screenshot for the record. If no LLM is installed locally, confirm instead that the assist bar disables 분석 with the "미설치" hint and the manual form still saves.

- [ ] **Step 4: Commit**

```bash
git add plugin/commands/service.md
git commit -m "docs(service): dashboard registers via daemon LLM directly; slash command is the CLI equivalent"
```

---

## Self-review notes

- **Spec coverage:** analyze read-only function (Tasks 1-3) · verify+fix daemon loop with commit-on-success/rollback (Tasks 4-5) · endpoints (Tasks 6-7) · form-fill default + direct toggle + edit-via-NL (Tasks 8-10) · detection/override + state-adaptive picker (Tasks 2,7,9) · fallback to manual form (Tasks 9-10) · leave-running on success (Task 4 `_launch_and_verify`) · env-error reported not fixed (loop only re-analyzes config; never runs installers) · copy-paste removed (Tasks 8,11). All spec sections map to a task.
- **Open items resolved in-plan:** candidate visibility = transient central upsert + rollback (Task 5); verify-timeout = `MARINA_VERIFY_TIMEOUT` via `_env` default 60 (Task 4); progress transport = synchronous endpoint + coarse client-side staged labels, granular live SSE deferred (Tasks 6,10 — noted as a fast-follow, matches spec open item 3); multi-service output = backend returns all, form fills first + count hint (Task 9), rich per-service add deferred.
- **Type consistency:** `_extract_service_json`/`_validate_service_def`/`_normalize_candidates` (Task 1) → `llm_analyze` (Task 3) → `_launch_and_verify`/`_central_def`/`_service_add_central` (Task 4) → `llm_register_loop` (Task 5) → endpoints (Task 6). Frontend `fillServiceForm`/`setLlmProgress`/`renderLlmPicker`/`runDirectRegister`/`currentDefForEdit` are all defined before use (Tasks 9-10); Task 9 explicitly flags `runDirectRegister` lands in Task 10.
- **Known cross-task gap:** Task 9 references `runDirectRegister` (Task 10) and `svcLlmDirectPref` is read in `openServiceModal` (Task 9 Step 1) but declared in Task 9 Step 2 — ensure the `let svcLlmDirectPref` declaration (Step 2) is placed above `openServiceModal` in source, or hoist it; JS `var`/`let` at module scope is fine since handlers run post-load. Do not ship Tasks 8/9 without 10.
