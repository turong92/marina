# In-dashboard update notice + one-click restart/enable — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the :3900 dashboard detect when it's not running the latest published marina and offer a one-click **[재시작]** (when files are already downloaded) or **[auto-update 켜기]** (when they aren't), all from inside the dashboard.

**Architecture:** The daemon compares three short SHAs — `serving` (its own `__file__` path), `installed` (`installed_plugins.json`), `origin` (`git ls-remote`, 60s-cached) — into a state (`current`/`stale`/`new`) exposed at `GET /api/update-status`. The client renders a header banner from the existing poll; `POST /api/restart-dashboard` (detached `marina-dashboard.sh restart`) and `POST /api/set-autoupdate` apply the fix. Detection + restart are harness-agnostic; the enable button targets Claude now and Codex after a verification gate.

**Tech Stack:** Python 3 stdlib (`http.server` daemon, single file `marina-control.py`), bash (`marina-dashboard.sh` reused for restart), vanilla JS in `INDEX_HTML`. Tests are standalone bash scripts under `plugin/tests/` (curl + python asserts) + an importlib unit test for the pure state function. UI verified via preview :3901 + Chrome MCP.

**Spec:** `docs/specs/2026-06-16-dashboard-update-notice-design.md`. Branch: `feature/update-notice`.

---

## Test/preview env overrides (refines spec)

State sources each read an env override first, else the real source. This makes `update_status()` fully controllable for tests AND preview (no separate force-state enum):

- `MARINA_SERVING_SHA` → else parse `CONTROL_SCRIPT` path.
- `MARINA_INSTALLED_SHA` → else read `installed_plugins.json`.
- `MARINA_ORIGIN_SHA` → else cached `git ls-remote`.
- `MARINA_UPDATE_TTL` (default `60`) → origin cache TTL seconds.
- `MARINA_RESTART_DRY_RUN=1` → restart logs the command instead of executing.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `plugin/scripts/marina-control.py` (constants) | config dirs | add `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `MARKETPLACE`, `PLUGIN_ID` (T2) |
| `plugin/scripts/marina-control.py` (detection) | update state | `update_state` (pure, T1); `_serving_sha`/`_installed_sha`/`_origin_sha`/`_autoupdate_state`/`update_status` (T2) |
| `plugin/scripts/marina-control.py` (`do_GET`) | status API | `GET /api/update-status` (T2) |
| `plugin/scripts/marina-control.py` (`do_POST`) | actions | `POST /api/restart-dashboard` (T3), `POST /api/set-autoupdate` (T4 Claude, T5 Codex) |
| `plugin/scripts/marina-control.py` (`INDEX_HTML`) | banner UI | CSS + `loadUpdateStatus`/`renderUpdateBanner` + poll hookup + button wiring (T6) |
| `plugin/scripts/marina-dashboard.sh` | restart | reused as-is (`restart` exists); no change |
| `plugin/tests/test-update-status.sh` | New | state fn unit + `/api/update-status` shape (T1, T2) |
| `plugin/tests/test-restart-dashboard.sh` | New | restart endpoint dry-run (T3) |
| `plugin/tests/test-set-autoupdate.sh` | New | Claude settings.json write (T4) |

Anchors are given by surrounding code, not line numbers (they drift). After any `marina-control.py` edit, run `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` — expect no output, exit 0.

**Commit style:** Conventional Commits, scope `plugin` / `spec` / `plan`, no `Co-Authored-By`, no `Task:` trailer. Local commits only; never push to origin unless the user asks. All work on branch `feature/update-notice`.

---

### Task 1: `update_state` pure function

**Files:**
- Modify: `plugin/scripts/marina-control.py` (add `update_state` near `subrepos_of`/`default_attach_of`)
- Test: `plugin/tests/test-update-status.sh` (create — unit portion)

- [ ] **Step 1: Write the failing test** — create `plugin/tests/test-update-status.sh`:

```bash
#!/usr/bin/env bash
# update_state pure fn + /api/update-status shape
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"

# --- unit: update_state ---
python3 - "$CTRL" <<'PY' || { echo "FAIL: update_state unit"; exit 1; }
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
us = mc.update_state
assert us("abc", "abc", "abc") == "current", us("abc","abc","abc")
assert us("abc", "def", "def") == "stale", us("abc","def","def")          # serving<installed, installed==origin
assert us("abc", "abc", "def") == "new", us("abc","abc","def")            # installed<origin
assert us("abc", "def", "ghi") == "new", us("abc","def","ghi")            # both behind → NEW (newer published)
assert us(None, "abc", "def") == "unknown", us(None,"abc","def")          # serving unknown (dev/repo run)
assert us("abc", None, "def") == "unknown", us("abc",None,"def")          # installed unknown
assert us("abc", "abc", None) == "current", us("abc","abc",None)          # origin unknown, serving==installed → no banner
assert us("abc", "def", None) == "stale", us("abc","def",None)            # origin unknown, serving<installed → restart
PY
echo "PASS test-update-status (unit)"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugin/tests/test-update-status.sh`
Expected: FAIL — `module 'mc' has no attribute 'update_state'`.

- [ ] **Step 3: Implement `update_state`** — in `marina-control.py`, immediately after the `default_attach_of` function, insert:

```python
def update_state(serving: str | None, installed: str | None, origin: str | None) -> str:
    # serving=실행 중 SHA, installed=받아진 SHA, origin=배포된 최신 SHA. 모두 short SHA.
    # serving/installed 모르면 판정 불가(dev/repo 실행) → unknown(배너 없음).
    if not serving or not installed:
        return "unknown"
    # origin 모르면(네트워크 실패) 무네트워크 판정: serving==installed 면 current, 아니면 stale.
    if origin is None:
        return "current" if serving == installed else "stale"
    if serving == origin:
        return "current"
    if installed == origin:
        return "stale"   # 파일은 최신, 데몬만 옛 코드 → 재시작
    return "new"         # 배포된 게 받아진 것보다 최신 → 업데이트(다음 세션/수동) 필요
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash plugin/tests/test-update-status.sh`
Expected: `PASS test-update-status (unit)`

- [ ] **Step 5: Commit**

```bash
cd /Users/sumin/IdeaProjects/sumin/marina
git add plugin/scripts/marina-control.py plugin/tests/test-update-status.sh
git commit -m "feat(plugin): update_state — serving/installed/origin SHA → current/stale/new"
```

---

### Task 2: `update_status()` + `GET /api/update-status`

**Files:**
- Modify: `plugin/scripts/marina-control.py` (constants; detection helpers; `do_GET` branch)
- Test: `plugin/tests/test-update-status.sh` (extend with the endpoint portion)

- [ ] **Step 1: Add the endpoint test** — append before the final `echo` (the `PASS ... (unit)` line stays). Replace that last echo block with:

```bash
echo "PASS test-update-status (unit)"

# --- endpoint: /api/update-status with all three SHAs stubbed via env ---
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
cat > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" <<'JSON'
{"plugins":{"marina@marina-dev":[{"installPath":"/x/marina-dev/marina/aaaaaaaaaaaa"}]}}
JSON
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{"extraKnownMarketplaces":{"marina-dev":{"source":{"source":"github","repo":"turong92/marina"}}}}
JSON
PORT=39730; base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")
# serving=bbbb, installed(env)=aaaa, origin=cccc → NEW; autoUpdate claude = false (key absent)
MARINA_HOME="$TMP/home" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
  MARINA_SERVING_SHA=bbbbbbbbbbbb MARINA_ORIGIN_SHA=cccccccccccc \
  MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 && break; sleep 0.1; done
curl -s "${hdr[@]}" "$base/api/update-status" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['serving']=='bbbbbbbbbbbb', d
assert d['installed']=='aaaaaaaaaaaa', d
assert d['origin']=='cccccccccccc', d
assert d['state']=='new', d
assert d['autoUpdate']['claude'] is False, d
" || { echo "FAIL: update-status endpoint"; exit 1; }

echo "PASS test-update-status"
```

- [ ] **Step 2: Run to verify the endpoint portion fails**

Run: `bash plugin/tests/test-update-status.sh`
Expected: FAIL — the curl gets 404 / no JSON (endpoint not defined). (Unit portion still passes.)

- [ ] **Step 3: Add constants** — in `marina-control.py`, after the `PROJECTS_FILE = MARINA_HOME / "projects.json"` line, insert:

```python
CLAUDE_CONFIG_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))
CODEX_HOME = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
MARKETPLACE = "marina-dev"
PLUGIN_ID = "marina@marina-dev"
```

- [ ] **Step 4: Add detection helpers** — insert immediately after `update_state` (from Task 1):

```python
_SHA_RE = re.compile(r"^([0-9a-f]{7,40}|\d+\.\d+)")
_origin_cache: dict[str, Any] = {}


def _serving_sha() -> str | None:
    env = os.environ.get("MARINA_SERVING_SHA")
    if env:
        return env[:12]
    # 설치 레이아웃: .../<marketplace>/marina/<SHA>/scripts/marina-control.py → <SHA> = parent.parent.name
    name = CONTROL_SCRIPT.parent.parent.name
    return name[:12] if _SHA_RE.match(name) else None   # 레포/dev 실행(name='plugin')은 None


def _installed_sha() -> str | None:
    env = os.environ.get("MARINA_INSTALLED_SHA")
    if env:
        return env[:12]
    for mf in (CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json",
               CODEX_HOME / "plugins" / "installed_plugins.json"):
        try:
            data = json.loads(mf.read_text(encoding="utf-8"))
            return Path(str(data["plugins"][PLUGIN_ID][0]["installPath"])).name[:12]
        except Exception:
            continue
    return None


def _marketplace_repo() -> str:
    # settings.json 의 marina-dev source.repo (fork 대응), 없으면 기본.
    try:
        s = json.loads((CLAUDE_CONFIG_DIR / "settings.json").read_text(encoding="utf-8"))
        repo = s["extraKnownMarketplaces"][MARKETPLACE]["source"]["repo"]
        if isinstance(repo, str) and repo:
            return repo
    except Exception:
        pass
    return "turong92/marina"


def _origin_sha() -> str | None:
    env = os.environ.get("MARINA_ORIGIN_SHA")
    if env:
        return env[:12]
    ttl = float(_env("UPDATE_TTL", "60"))
    now = time.time()
    if _origin_cache and now - _origin_cache.get("ts", 0) < ttl:
        return _origin_cache.get("sha")
    sha = _origin_cache.get("sha")  # 실패 시 마지막 값 유지
    try:
        out = subprocess.check_output(
            ["git", "ls-remote", f"https://github.com/{_marketplace_repo()}.git", "main"],
            text=True, timeout=5, stderr=subprocess.DEVNULL,
        )
        if out.strip():
            sha = out.split()[0][:12]
    except Exception:
        pass
    _origin_cache.update({"sha": sha, "ts": now})
    return sha


def _autoupdate_state() -> dict[str, Any]:
    # 하네스별 marina-dev autoUpdate ON/OFF. 마켓플레이스 미등록/판정불가 → None.
    out: dict[str, Any] = {"claude": None, "codex": None}
    try:
        s = json.loads((CLAUDE_CONFIG_DIR / "settings.json").read_text(encoding="utf-8"))
        mk = s.get("extraKnownMarketplaces", {}).get(MARKETPLACE)
        if isinstance(mk, dict):
            out["claude"] = bool(mk.get("autoUpdate"))
    except Exception:
        pass
    # Codex(config.toml)는 검증 게이트(Task 5) 전까지 None 유지.
    return out


def update_status() -> dict[str, Any]:
    serving, installed, origin = _serving_sha(), _installed_sha(), _origin_sha()
    return {
        "serving": serving,
        "installed": installed,
        "origin": origin,
        "state": update_state(serving, installed, origin),
        "autoUpdate": _autoupdate_state(),
        "harnesses": [h for h, p in (("claude", CLAUDE_CONFIG_DIR), ("codex", CODEX_HOME))
                      if (p / "plugins" / "installed_plugins.json").exists()],
    }
```

- [ ] **Step 5: Add the `do_GET` branch** — in `do_GET`, find the `/api/worktrees` branch:

```python
        if parsed.path == "/api/worktrees":
            refresh = parsed.query == "refresh=1"
            self.send_json({"worktrees": [worktree_info(root, refresh) for root in discover_all_roots(refresh)]})
            return
```

Immediately after it, insert:

```python
        if parsed.path == "/api/update-status":
            self.send_json(update_status())
            return
```

- [ ] **Step 6: Verify parse + run the test**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` (expect exit 0), then `bash plugin/tests/test-update-status.sh`
Expected: `PASS test-update-status`

- [ ] **Step 7: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-update-status.sh
git commit -m "feat(plugin): update_status + GET /api/update-status (3-SHA, ls-remote 60s cache)"
```

---

### Task 3: `POST /api/restart-dashboard`

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`do_POST`, no-root section)
- Test: `plugin/tests/test-restart-dashboard.sh` (create)

- [ ] **Step 1: Write the failing test** — create `plugin/tests/test-restart-dashboard.sh`:

```bash
#!/usr/bin/env bash
# POST /api/restart-dashboard — dry-run logs the restart command, responds fast
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
PORT=39731; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
MARINA_RESTART_DRY_RUN=1 MARINA_HOME="$MARINA_HOME" MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" -d '{}' "$base/api/restart-dashboard" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('restarting') is True, d" \
  || { echo "FAIL: restart-dashboard response"; exit 1; }
# dry-run 로그에 restart 명령 기록 확인
sleep 0.3
grep -q "marina-dashboard.sh restart" "$MARINA_HOME/restart-dry-run.log" \
  || { echo "FAIL: dry-run did not log restart command"; exit 1; }
# 데몬은 여전히 살아있어야 (dry-run 이라 실제 재시작 안 함)
curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 \
  || { echo "FAIL: daemon died on dry-run restart"; exit 1; }

echo "PASS test-restart-dashboard"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugin/tests/test-restart-dashboard.sh`
Expected: FAIL — `/api/restart-dashboard` returns 404 (no JSON with `restarting`).

- [ ] **Step 3: Implement the endpoint** — in `do_POST`, find the no-root `remove-project` branch (ends `self.send_json({"ok": True, "output": out.strip()})` then `return`, just before `root = safe_root(...)`). Immediately after that block (still before `root = safe_root`), insert:

```python
            if self.path == "/api/restart-dashboard":
                # 응답 먼저(연결 flush) → detached 로 재기동(자기 종료 후에도 살아남게 setsid).
                self.send_json({"ok": True, "restarting": True})
                dash = CONTROL_SCRIPT.parent / "marina-dashboard.sh"
                if os.environ.get("MARINA_RESTART_DRY_RUN") == "1":
                    MARINA_HOME.mkdir(parents=True, exist_ok=True)
                    with (MARINA_HOME / "restart-dry-run.log").open("a", encoding="utf-8") as fh:
                        fh.write(f"would run: bash {dash} restart\n")
                    return
                subprocess.Popen(
                    ["bash", "-c", f"sleep 1; exec bash {shlex.quote(str(dash))} restart"],
                    start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                return
```

- [ ] **Step 4: Add the `shlex` import** — at the top of `marina-control.py`, find `import shutil` and add `import shlex` right before it (keep alphabetical-ish with the existing imports):

```python
import shlex
import shutil
```

- [ ] **Step 5: Verify parse + run the test**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` then `bash plugin/tests/test-restart-dashboard.sh`
Expected: `PASS test-restart-dashboard`

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-restart-dashboard.sh
git commit -m "feat(plugin): POST /api/restart-dashboard (detached marina-dashboard.sh restart)"
```

---

### Task 4: `POST /api/set-autoupdate` (Claude)

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`set_autoupdate_claude` helper; `do_POST` branch)
- Test: `plugin/tests/test-set-autoupdate.sh` (create)

- [ ] **Step 1: Write the failing test** — create `plugin/tests/test-set-autoupdate.sh`:

```bash
#!/usr/bin/env bash
# POST /api/set-autoupdate {harness:claude} — writes settings.json autoUpdate, preserves other keys
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export CLAUDE_CONFIG_DIR="$TMP/claude"; mkdir -p "$CLAUDE_CONFIG_DIR"
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{"theme":"dark","extraKnownMarketplaces":{"marina-dev":{"source":{"source":"github","repo":"turong92/marina"}}}}
JSON
PORT=39732; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
MARINA_HOME="$TMP/home" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/update-status" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" -d '{"harness":"claude"}' "$base/api/set-autoupdate" | python3 -c "import json,sys; assert json.load(sys.stdin).get('ok') is True" \
  || { echo "FAIL: set-autoupdate response"; exit 1; }
python3 -c "
import json
s=json.load(open('$CLAUDE_CONFIG_DIR/settings.json'))
assert s['extraKnownMarketplaces']['marina-dev']['autoUpdate'] is True, s
assert s['theme']=='dark', s          # 타 키 보존
assert s['extraKnownMarketplaces']['marina-dev']['source']['repo']=='turong92/marina', s
" || { echo "FAIL: settings.json not updated correctly"; exit 1; }

# 마켓플레이스 항목 없으면 4xx (날조 안 함)
echo '{}' > "$CLAUDE_CONFIG_DIR/settings.json"
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -d '{"harness":"claude"}' "$base/api/set-autoupdate")"
[[ "$code" == 4* ]] || { echo "FAIL: missing marketplace expected 4xx, got $code"; exit 1; }

echo "PASS test-set-autoupdate"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugin/tests/test-set-autoupdate.sh`
Expected: FAIL — `/api/set-autoupdate` 404 (no `ok`).

- [ ] **Step 3: Implement the Claude helper** — in `marina-control.py`, immediately after `update_status()` (Task 2), insert:

```python
def set_autoupdate_claude() -> dict[str, Any]:
    path = CLAUDE_CONFIG_DIR / "settings.json"
    try:
        s = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ValueError(f"settings.json 읽기 실패: {exc}")
    mk = s.get("extraKnownMarketplaces")
    if not isinstance(mk, dict) or not isinstance(mk.get(MARKETPLACE), dict):
        raise ValueError(f"{MARKETPLACE} 마켓플레이스 항목이 settings.json 에 없음 — /plugin 에서 켜줘")
    mk[MARKETPLACE]["autoUpdate"] = True
    path.write_text(json.dumps(s, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True, "harness": "claude", "note": "다음 세션부터 자동 업데이트됩니다"}
```

- [ ] **Step 4: Add the `do_POST` branch** — immediately after the `/api/restart-dashboard` block from Task 3 (still before `root = safe_root`), insert:

```python
            if self.path == "/api/set-autoupdate":
                harness = str(body.get("harness", "")).strip()
                if harness == "claude":
                    self.send_json(set_autoupdate_claude())
                elif harness == "codex":
                    raise ValueError("Codex auto-update 켜기는 아직 미지원 — 수동으로 켜줘 (검증 후 추가 예정)")
                else:
                    raise ValueError("harness must be 'claude' or 'codex'")
                return
```

> The Codex branch raises a clear "not yet" error until Task 5 verifies and implements it. The UI (Task 6) hides the Codex button until then and shows guidance instead.

- [ ] **Step 5: Verify parse + run the test**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` then `bash plugin/tests/test-set-autoupdate.sh`
Expected: `PASS test-set-autoupdate`

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-set-autoupdate.sh
git commit -m "feat(plugin): POST /api/set-autoupdate (Claude settings.json), Codex gated"
```

---

### Task 5: Codex verification gate + Codex enable (impl or degrade)

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`set_autoupdate_codex`, `_autoupdate_state` codex read) — only if verification passes
- Test: extend `plugin/tests/test-set-autoupdate.sh` — only if implemented

This task is a **verification gate**, not blind code. Do the research first; the outcome decides whether code is written.

- [ ] **Step 1: Verify Codex's per-marketplace auto-update mechanism**

Investigate (read-only): how Codex enables auto-update for a marketplace in `~/.codex/config.toml`, and whether it applies at session startup. Sources/steps:
- Inspect a real `~/.codex/config.toml` if present: `python3 -c "import tomllib,os; print(tomllib.load(open(os.path.expanduser('~/.codex/config.toml'),'rb')))"` (Python 3.11+; if `tomllib` missing, read the raw file) — look for `[marketplaces]`/`[plugins]` tables and any `auto_update`/`autoUpdate` key.
- Check Codex plugin docs (`developers.openai.com/codex` plugin/marketplace pages) for the exact key name and whether startup auto-applies.
- Record the finding in the task notes.

- [ ] **Step 2: Decide and act**

**If verified** (key + startup-apply confirmed AND a safe TOML write is feasible):
- Implement `set_autoupdate_codex()` writing the confirmed key to `CODEX_HOME / "config.toml"` (preserve other content — use `tomllib` to read + a minimal targeted text edit, or `tomli_w` only if already available; do NOT add a new runtime dependency — if no safe writer exists, treat as "not verified").
- Update `_autoupdate_state()` to read the codex key into `out["codex"]`.
- Replace the Codex branch in `do_POST` (`raise ValueError("...아직 미지원...")`) with `self.send_json(set_autoupdate_codex())`.
- Add a `test-set-autoupdate.sh` case: temp `CODEX_HOME/config.toml` → POST `{harness:codex}` → assert the key written + others preserved.
- Run: `bash plugin/tests/test-set-autoupdate.sh` → expect `PASS`.

**If NOT verified** (uncertain key, no startup-apply, or no safe stdlib TOML writer):
- Leave the Codex branch raising the "아직 미지원" error.
- In the UI (Task 6), the Codex enable button stays hidden; show guidance text instead ("Codex: `/hooks`·config.toml 에서 marina-dev auto-update 수동 설정").
- Note the degrade decision in the spec's Open items #1 and in the commit message.

- [ ] **Step 3: Commit (either outcome)**

```bash
git add -A
# verified:
git commit -m "feat(plugin): set-autoupdate Codex (config.toml) — verified <key>"
# degraded:
git commit -m "docs(plugin): Codex auto-update enable unverified — guidance-only, button deferred"
```

---

### Task 6: UI — banner, poll hookup, button wiring

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`INDEX_HTML`: CSS, banner element, JS render + poll + buttons)

No JS unit runner exists; verify via parse + preview (Task 7). The three SHA env overrides force any banner state in preview.

- [ ] **Step 1: Add CSS** — in the `<style>` block, after the `.ghost-chip.alert {...}` rule (near the header/toolbar styles), insert:

```css
    .update-banner { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 8px 16px; background: hsl(36, 90%, 94%); color: hsl(30, 80%, 30%); border-bottom: 1px solid var(--sys-style-neutral-light); font-size: 13px; }
    .update-banner.stale { background: hsl(215, 90%, 95%); color: hsl(215, 70%, 35%); }
    .update-banner .ub-msg { font-weight: 700; }
    .update-banner .ub-sha { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; opacity: 0.8; }
    .update-banner .ub-actions { display: flex; gap: 6px; margin-left: auto; flex-wrap: wrap; }
    .update-banner button { height: 26px; padding: 0 10px; font-size: 12px; font-weight: 700; }
    .update-banner .ub-note { font-size: 12px; opacity: 0.85; }
```

- [ ] **Step 2: Add the banner element** — find the header close + orphan panel:

```html
  </header>
  <div class="orphan-pop" id="orphanPanel" hidden></div>
```

Replace with (insert the banner between them):

```html
  </header>
  <div class="update-banner" id="updateBanner" hidden></div>
  <div class="orphan-pop" id="orphanPanel" hidden></div>
```

- [ ] **Step 3: Add `loadUpdateStatus` + `renderUpdateBanner`** — in the `<script>`, immediately after the `async function load(...)` function (it ends `}` before `document.getElementById('orphanChip').onclick`), insert:

```javascript
    let updateBusy = false;
    async function loadUpdateStatus() {
      let s;
      try { s = await api('/api/update-status'); } catch { return; }
      renderUpdateBanner(s);
    }

    function renderUpdateBanner(s) {
      const el = document.getElementById('updateBanner');
      if (!s || s.state === 'current' || s.state === 'unknown') { el.hidden = true; el.innerHTML = ''; return; }
      el.classList.toggle('stale', s.state === 'stale');
      if (s.state === 'stale') {
        el.innerHTML = `<span class="ub-msg">업데이트 설치됨 — 재시작하면 적용</span>
          <span class="ub-sha">${escapeHtml(s.serving || '?')} → ${escapeHtml(s.installed || '?')}</span>
          <span class="ub-actions"><button data-restart class="primary">재시작</button></span>`;
      } else { // new
        const acts = [];
        for (const h of (s.harnesses || [])) {
          const on = s.autoUpdate?.[h];
          if (on === true) acts.push(`<span class="ub-note">${h}: 다음 세션 시작에 자동 업데이트</span>`);
          else if (on === false) acts.push(`<button data-enable="${h}">auto-update 켜기 (${h})</button>`);
          // on === null (미등록/미지원) → 버튼 없음 (안내는 아래 codex 폴백)
        }
        if ((s.autoUpdate?.codex ?? null) === null && (s.harnesses || []).includes('codex')) {
          acts.push(`<span class="ub-note">codex: config.toml 에서 수동 설정</span>`);
        }
        el.innerHTML = `<span class="ub-msg">새 버전 배포됨</span>
          <span class="ub-sha">origin ${escapeHtml(s.origin || '?')} · 설치 ${escapeHtml(s.installed || '?')}</span>
          <span class="ub-actions">${acts.join('')}</span>`;
      }
      const restartBtn = el.querySelector('[data-restart]');
      if (restartBtn) restartBtn.onclick = () => doRestartDashboard(restartBtn);
      for (const b of el.querySelectorAll('[data-enable]')) {
        b.onclick = () => doEnableAutoUpdate(b.dataset.enable, b);
      }
    }

    async function doRestartDashboard(btn) {
      if (updateBusy) return;
      if (!confirm('대시보드를 재시작해 새 코드로 띄울까요?\n(dev 서버는 그대로 유지됩니다 · 약 1초)')) return;
      updateBusy = true;
      btn.disabled = true; btn.textContent = '재시작 중…';
      try {
        await api('/api/restart-dashboard', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
      } catch {}
      // 데몬이 ~1초 내 돌아옴 — 폴링이 자동 재연결, 배너는 다음 update-status 에서 사라짐.
      setTimeout(() => { updateBusy = false; loadUpdateStatus().catch(() => {}); }, 3000);
    }

    async function doEnableAutoUpdate(harness, btn) {
      btn.disabled = true; btn.textContent = '…';
      try {
        const r = await api('/api/set-autoupdate', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({harness})});
        if (r?.error) { alert(`auto-update 켜기 실패: ${r.error}`); btn.disabled = false; return; }
        alert(`${harness} auto-update 켜짐 — 다음 세션부터 자동 업데이트됩니다.`);
      } catch (e) { alert(e); btn.disabled = false; return; }
      loadUpdateStatus().catch(() => {});
    }
```

- [ ] **Step 4: Hook into the poll loop** — find the poll `setInterval`:

```javascript
      pollTimer = setInterval(() => {
        pollTick += 1;
        load({passive: true}).catch(console.error);
        if (pollTick % 2 === 0) loadOrphans().catch(console.error);
        // 60초마다 — 서버 10분 캐시를 타서 비용 ~0, 배지(삭제 권장)·디스크 표시 신선도 유지
        if (pollTick % 12 === 0) loadWorktrees().catch(console.error);
      }, 5000);
```

Replace with (add update-status every 2 ticks = 10s; server caches origin at 60s so this is cheap):

```javascript
      pollTimer = setInterval(() => {
        pollTick += 1;
        load({passive: true}).catch(console.error);
        if (pollTick % 2 === 0) loadOrphans().catch(console.error);
        if (pollTick % 2 === 0) loadUpdateStatus().catch(console.error);
        // 60초마다 — 서버 10분 캐시를 타서 비용 ~0, 배지(삭제 권장)·디스크 표시 신선도 유지
        if (pollTick % 12 === 0) loadWorktrees().catch(console.error);
      }, 5000);
```

- [ ] **Step 5: Initial load + visibility resume** — find the initial bootstrap where `loadWorktrees()` is first called alongside `load()`. There are two spots: the `visibilitychange` handler and the startup sequence. In the `visibilitychange` handler:

```javascript
      load({passive: true}).catch(console.error);
      loadOrphans().catch(console.error);
      loadWorktrees().catch(console.error);
      startPolling();
```

Replace with:

```javascript
      load({passive: true}).catch(console.error);
      loadOrphans().catch(console.error);
      loadWorktrees().catch(console.error);
      loadUpdateStatus().catch(console.error);
      startPolling();
```

Then find the startup sequence (the initial `load()`/`loadWorktrees()` calls that kick things off on page load — search for the first `startPolling()` call or the IIFE/init that calls `loadWorktrees()`). Add `loadUpdateStatus().catch(console.error);` alongside the initial `loadWorktrees()` call so the banner shows on first paint.

- [ ] **Step 6: Verify parse + serve smoke**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` then:
```bash
MARINA_HOME="$(mktemp -d)" MARINA_CONTROL_PORT=39778 MARINA_CONTROL_HOST=127.0.0.1 python3 plugin/scripts/marina-control.py >/tmp/ub-smoke.log 2>&1 &
SM=$!; sleep 1
curl -s -H "Origin: http://127.0.0.1:39778" http://127.0.0.1:39778/ | grep -c "renderUpdateBanner"
kill $SM 2>/dev/null
```
Expected: prints `1`+, no traceback in `/tmp/ub-smoke.log`.

- [ ] **Step 7: Commit**

```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(plugin): header update banner — restart / enable-auto-update buttons + poll hookup"
```

---

### Task 7: Preview verification + review + final commit

**Files:** none (verification)

- [ ] **Step 1: Launch preview with a forced NEW state** — the three env overrides force the banner (preview runs from the repo so `serving` would otherwise be `None`):

```bash
MARINA_CONTROL_PORT=3901 MARINA_CONTROL_HOST=127.0.0.1 \
  MARINA_SERVING_SHA=1111111111aa MARINA_INSTALLED_SHA=2222222222bb MARINA_ORIGIN_SHA=2222222222bb \
  python3 /Users/sumin/IdeaProjects/sumin/marina/plugin/scripts/marina-control.py >/tmp/marina-preview-3901.log 2>&1 &
```
This yields `serving != installed == origin` → **STALE** → the [재시작] banner. Confirm: `curl -s -H "Origin: http://127.0.0.1:3901" http://127.0.0.1:3901/api/update-status` shows `"state":"stale"`.

- [ ] **Step 2: Chrome MCP — verify STALE banner** — navigate to `http://127.0.0.1:3901/`, screenshot. Verify the blue "업데이트 설치됨 — 재시작하면 적용 `1111…` → `2222…`" banner with a [재시작] button under the header. (Don't click — preview's restart would bounce the preview daemon, not the installed one.)

- [ ] **Step 3: Restart preview with a forced NEW + autoUpdate-off state** — stop the preview (`lsof -ti tcp:3901 | xargs kill`), relaunch with origin ahead of installed:

```bash
MARINA_CONTROL_PORT=3901 MARINA_CONTROL_HOST=127.0.0.1 \
  MARINA_SERVING_SHA=1111111111aa MARINA_INSTALLED_SHA=1111111111aa MARINA_ORIGIN_SHA=3333333333cc \
  python3 /Users/sumin/IdeaProjects/sumin/marina/plugin/scripts/marina-control.py >/tmp/marina-preview-3901.log 2>&1 &
```
`serving == installed != origin` → **NEW**. Chrome MCP screenshot: verify the amber "새 버전 배포됨 origin `3333…` · 설치 `1111…`" banner. The enable button appears only for harnesses with `autoUpdate:false` (depends on the real `~/.claude/settings.json` the preview reads — it will reflect your machine's marina-dev autoUpdate state). Confirm console errors = 0 via `read_console_messages`.

- [ ] **Step 4: Stop preview**

Run: `lsof -ti tcp:3901 | xargs kill 2>/dev/null; lsof -ti tcp:3901 >/dev/null 2>&1 && echo "still up" || echo "free"`

- [ ] **Step 5: Full backend test sweep**

```bash
for t in test-update-status test-restart-dashboard test-set-autoupdate; do bash plugin/tests/$t.sh || { echo "FAILED $t"; break; }; done
```
Expected: each prints its `PASS …`.

- [ ] **Step 6: `code-reviewer` on the branch diff**

Dispatch `code-reviewer` over `git diff main...HEAD` in the marina repo (focus: correctness/safety of the restart self-termination, settings.json write safety, ls-remote failure handling, XSS in the banner via escapeHtml). Address blockers, re-commit per touched task.

- [ ] **Step 7: Report**

Run `git log --oneline main..HEAD` and `git status -sb`. Report. **Do not push** unless the user asks in their current message.

---

## Self-Review

**1. Spec coverage:**
- 3-SHA model + states → T1 (`update_state`), T2 (`update_status`). ✓
- `GET /api/update-status` (incl. autoUpdate per harness, harnesses list) → T2. ✓
- 60s lazy TTL cache, ls-remote, repo-from-marketplace → T2 (`_origin_sha`, `_marketplace_repo`). ✓
- `POST /api/restart-dashboard` (detached, dry-run) → T3. ✓
- `POST /api/set-autoupdate` Claude → T4; Codex gated/verified → T5. ✓
- Banner (STALE/NEW, autoUpdate-aware, next-session note), poll hookup, buttons → T6. ✓
- Error handling: serving/installed None → unknown/no-banner (T1, tested); ls-remote fail keeps last (T2); settings missing-entry 4xx (T4, tested); restart response-first + setsid (T3). ✓
- dev/preview inert (`serving==None`) + 3-env force for preview → T2, T6, T7. ✓
- Tests: state unit, endpoint shape, restart dry-run, set-autoupdate write → T1–T4. ✓

**2. Placeholder scan:** No TBD/TODO in code steps. The only conditional is T5 (verification gate) — explicitly two-outcome (implement or degrade), not a placeholder. ✓

**3. Type consistency:** `update_state(serving, installed, origin)` signature identical across T1 test + T2 caller. `update_status()` keys (`serving/installed/origin/state/autoUpdate/harnesses`) match the T2 test asserts + T6 `renderUpdateBanner` reads (`s.state`, `s.serving`, `s.installed`, `s.origin`, `s.autoUpdate?.[h]`, `s.harnesses`). Endpoints `/api/update-status` (GET), `/api/restart-dashboard` + `/api/set-autoupdate` (POST, no-root section) consistent between server (T2/T3/T4) and client (T6). `MARINA_SERVING_SHA`/`MARINA_INSTALLED_SHA`/`MARINA_ORIGIN_SHA`/`MARINA_UPDATE_TTL`/`MARINA_RESTART_DRY_RUN` consistent across helpers + tests + preview. ✓

No gaps found.
