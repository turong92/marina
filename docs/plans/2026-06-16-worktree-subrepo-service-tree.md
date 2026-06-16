# Worktree subrepo ⊃ service tree + 3-level attach — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the worktree card show the real containment hierarchy (a subrepo row ⊃ the services that run inside it) with a 3-level attach model (universe / default-attach / per-worktree), so a worktree only carries what it needs.

**Architecture:** Registry (`~/.marina/projects.json`, written only via `marina.sh`) gains an optional `defaultAttach` per project. The attach shell script (`attach-detached-subrepos.sh`) resolves new-worktree auto-attach to `defaultAttach` (falling back to the full `subrepos` universe) and gates auto-attach to first-run only. The Python control server (`marina-control.py`) derives per-worktree physical attach state from the filesystem, tags each service with its owning subrepo via **longest-prefix match of the service `cwd` against the registered subrepos**, exposes three new POST endpoints, and rebuilds the flat service list in `INDEX_HTML` as a subrepo⊃service tree whose subrepo toggle means "edit default" on the main card and "physical attach/detach" on a worktree card.

**Tech Stack:** Bash (registry + attach scripts), Python 3 stdlib (`http.server` control daemon, single file), vanilla JS embedded in `INDEX_HTML`. Tests are standalone bash scripts under `plugin/tests/` (run directly, no central runner) using `curl` + `python3` assertions, plus `importlib` unit tests for pure Python helpers. UI is verified live via a preview daemon on `:3901` + Chrome MCP (no JS unit runner exists).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `docs/specs/2026-06-16-worktree-subrepo-service-tree-design.md` | Design spec | One-line update: service→subrepo grouping = longest-prefix (Task 1) |
| `plugin/scripts/marina.sh` | Registry CLI (write SoT) | New `default <id> a,b,c` subcommand + dispatch + usage (Task 2) |
| `plugin/scripts/attach-detached-subrepos.sh` | Physical attach + IDE sync | `registry_default_for`; `resolve_subrepos` prefers `defaultAttach`; first-run auto-attach gate (Task 3) |
| `plugin/scripts/marina-control.py` (data) | Payload + registry read | `load_projects` reads `defaultAttach`; `default_attach_of`, `service_subrepo`, `service_subrepo_map`; `worktree_info` += `attachedSubrepos`/`defaultAttach`; `session_payload` service += `subrepo` (Task 4) |
| `plugin/scripts/marina-control.py` (API) | POST handlers | `attach_subrepo_action`, `detach_subrepo_action` + `/api/attach-subrepo`, `/api/detach-subrepo`, `/api/set-default-attach` (Task 5) |
| `plugin/scripts/marina-control.py` (`INDEX_HTML` CSS) | Tree styling | `.subrepo-row`, `.subrepo-body`, toggles, `.svc.disabled`, nesting (Task 6) |
| `plugin/scripts/marina-control.py` (`INDEX_HTML` JS) | Card render | `makeSvcRow` extraction, `renderServiceTree`, `renderSubrepoHead`, `wireSubrepoToggle`, `updateServiceStates` skip-disabled (Task 7); `setDefaultAttach`/`attachSubrepo`/`detachSubrepo` handlers (Task 8) |
| `plugin/tests/test-default-attach.sh` | New | marina.sh default writer (Task 2) |
| `plugin/tests/test-auto-attach-default.sh` | New | attach honors defaultAttach + first-run gate (Task 3) |
| `plugin/tests/test-subrepo-tree-api.sh` | New | `service_subrepo` longest-prefix unit + payload fields (Task 4) |
| `plugin/tests/test-attach-detach-api.sh` | New | attach/detach/set-default endpoints over a real git worktree (Task 5) |

**Insertion anchors are given by surrounding code, not line numbers** (line numbers drift as earlier tasks edit the file). Match on the quoted anchor text.

---

## Conventions for every task

- **Commit style** (matches repo history, e.g. `feat(plugin): …`): Conventional Commits, scope `plugin` for code / `spec` / `plan`, subject in English or Korean as the existing log mixes. **No `Co-Authored-By` line.** **No `Task:` trailer** (that is a CRABS-workspace convention; this repo `turong92/marina` does not use it).
- **Run a test:** `bash plugin/tests/<name>.sh` from the repo root. Expected on success: prints `PASS <name>` (or the asserted lines) and exits 0.
- **Never push to origin.** Local commits only, per task. Origin push happens only on the user's explicit instruction.
- **Python edits:** after any `marina-control.py` edit, run `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` — Expected: no output, exit 0 (the whole file, incl. the embedded `INDEX_HTML` string, must still parse).

---

### Task 1: Spec one-line update — longest-prefix grouping

**Files:**
- Modify: `docs/specs/2026-06-16-worktree-subrepo-service-tree-design.md`

This is the spec change the user called out: service→subrepo grouping must use **longest-prefix match against registered subrepos**, not "first cwd segment", so slash-containing subrepos like `projects/react-skeleton` map correctly.

- [ ] **Step 1: Update the `service` definition line**

Find this line (in the `## Model — three levels` section):

```markdown
**service** = a process from `marina-services.json`, located by `cwd` whose first segment is its subrepo (or `.` = root). A subrepo holds 0..N services.
```

Replace `whose first segment is its subrepo (or `.` = root)` with:

```markdown
**service** = a process from `marina-services.json`, located by `cwd`; its owning subrepo is the **longest registered subrepo that is a path-prefix of `cwd`** (so `projects/react-skeleton/app` maps to `projects/react-skeleton`, not `projects`), or `.`/empty = root (ungrouped). A subrepo holds 0..N services.
```

- [ ] **Step 2: Update the payload-plumbing bullet**

Find (in `### E. Data plumbing`):

```markdown
- **service payload += `subrepo`** = first segment of that service's `cwd` (via a `service_subrepo_map(root)` helper reading the project `marina-services.json`).
```

Replace with:

```markdown
- **service payload += `subrepo`** = longest-prefix registered subrepo of that service's `cwd` (via a `service_subrepo_map(root)` helper reading the project `marina-services.json`); no registered match and non-root cwd ⇒ first segment (surfaced as an un-toggleable group), `.`/empty ⇒ ungrouped.
```

- [ ] **Step 3: Update the error-handling line**

Find:

```markdown
- Service whose cwd-subrepo isn't registered → grouped under that name without an attach toggle (surfaces inconsistency, no crash).
```

Replace with:

```markdown
- Service whose cwd has no registered longest-prefix match → grouped under its first cwd segment without an attach toggle (surfaces inconsistency, no crash).
```

- [ ] **Step 4: Resolve Open item 1 (re-attach vs user detach) in the spec**

Find the Open item 1 block under `## Open items`. Append the decision (so the plan and spec agree). After the existing `1. **Re-attach idempotency vs user detach:** …` paragraph, add:

```markdown
   **Decided (v1):** the attach script auto-attaches the `defaultAttach` set only on a **fresh** worktree — defined as "no registered subrepo currently attached". If any universe subrepo is already attached, the worktree is considered user-initialized and auto-attach is skipped entirely (it never re-attaches a user-detached default, nor auto-detaches a user-added subrepo). Dashboard single-subrepo attach/detach always passes `MARINA_SUBREPOS` explicitly and bypasses the gate.
```

- [ ] **Step 5: Verify the edits**

Run: `grep -n "longest" docs/specs/2026-06-16-worktree-subrepo-service-tree-design.md`
Expected: at least two matching lines (the `service` definition and the payload bullet).

- [ ] **Step 6: Commit**

```bash
cd /Users/sumin/IdeaProjects/sumin/marina
git add docs/specs/2026-06-16-worktree-subrepo-service-tree-design.md
git commit -m "docs(spec): service→subrepo grouping = longest-prefix; decide auto-attach first-run gate"
```

---

### Task 2: `marina.sh default` registry writer

**Files:**
- Modify: `plugin/scripts/marina.sh` (add `registry_default`, dispatch entry, usage text)
- Test: `plugin/tests/test-default-attach.sh` (create)

The registry is the write SoT. `defaultAttach` must be a subset of `subrepos`; an empty CSV clears it to `[]`; a value outside the universe is rejected (non-zero exit, registry unchanged).

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-default-attach.sh`:

```bash
#!/usr/bin/env bash
# marina.sh default <id> a,b,c — writes registry defaultAttach (subset of subrepos)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P/a/.git" "$P/b/.git" "$P/c/.git"
reg="$MARINA_HOME/projects.json"

bash "$SH" add "$P" --subrepos a,b,c >/dev/null
id="$(python3 -c "import json; print(json.load(open('$reg'))['projects'][0]['id'])")"

# subset
bash "$SH" default "$id" a,b >/dev/null
python3 -c "import json; p=json.load(open('$reg'))['projects'][0]; assert p.get('defaultAttach')==['a','b'],p" \
  || { echo "FAIL: default subset"; exit 1; }

# empty clears to []
bash "$SH" default "$id" "" >/dev/null
python3 -c "import json; p=json.load(open('$reg'))['projects'][0]; assert p.get('defaultAttach')==[],p" \
  || { echo "FAIL: default empty"; exit 1; }

# reject value outside universe — non-zero, registry unchanged
if bash "$SH" default "$id" a,zzz >/dev/null 2>&1; then echo "FAIL: accepted non-universe"; exit 1; fi
python3 -c "import json; p=json.load(open('$reg'))['projects'][0]; assert p.get('defaultAttach')==[],p" \
  || { echo "FAIL: rejected write still mutated registry"; exit 1; }

# unknown id → non-zero
if bash "$SH" default nope a >/dev/null 2>&1; then echo "FAIL: accepted unknown id"; exit 1; fi

echo "PASS test-default-attach"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugin/tests/test-default-attach.sh`
Expected: FAIL (non-zero) — `marina.sh` rejects `default` with `error: unknown command: default`.

- [ ] **Step 3: Add the `registry_default` function**

In `plugin/scripts/marina.sh`, immediately **after** the `registry_rm() { … }` function (the block that ends with `PY\n}` right before `registry_ls()`), insert:

```bash
registry_default() {
  local id="${1:-}" csv="${2-}"
  [[ -n "$id" ]] || die "usage: marina.sh default <id> <a,b,c>  (빈 값=전부 비움)"
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  [[ -f "$PROJECTS_FILE" ]] || die "레지스트리 없음: $PROJECTS_FILE"
  python3 - "$PROJECTS_FILE" "$id" "$csv" <<'PY'
import json, sys
projects_file, target, csv = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(projects_file, encoding="utf-8"))
projects = data.get("projects", [])
match = next((p for p in projects if p.get("id") == target), None)
if match is None:
    print(f"not found: {target}", file=sys.stderr); sys.exit(1)
universe = [str(s) for s in match.get("subrepos", [])]
want = [s for s in (x.strip() for x in csv.split(",")) if s]
bad = [s for s in want if s not in universe]
if bad:
    print(f"not in subrepos ({', '.join(universe) or 'none'}): {', '.join(bad)}", file=sys.stderr)
    sys.exit(1)
match["defaultAttach"] = want
with open(projects_file, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
print(f"defaultAttach[{target}]: {', '.join(want) or '(none — 새 worktree 자동 attach 없음)'}")
PY
}
```

- [ ] **Step 4: Add the dispatch entry**

In the registry-CLI `case` block (the one with `add)`, `infer)`, `rm)`, `ls|projects)`), add a `default)` line:

Find:

```bash
  rm)          shift; registry_rm "$@";    exit $? ;;
  ls|projects) registry_ls;               exit $? ;;
```

Replace with:

```bash
  rm)          shift; registry_rm "$@";    exit $? ;;
  default)     shift; registry_default "$@"; exit $? ;;
  ls|projects) registry_ls;               exit $? ;;
```

- [ ] **Step 5: Add usage text**

In `marina-entrypoint.sh`'s `usage()` heredoc (the registry block), find:

```
    marina rm <id>
    marina ls
```

Replace with:

```
    marina rm <id>
    marina default <id> a,b,c     # 새 worktree 가 자동 attach 할 기본 집합(전체 기본). 빈 값=없음
    marina ls
```

Also add `default|` to the entrypoint passthrough `case` so `marina default …` reaches the session script. In `marina-entrypoint.sh` find:

```bash
  add|infer|rm|ls|projects)
    "$SESSION" "$command" "$@"
    ;;
```

Replace with:

```bash
  add|infer|rm|default|ls|projects)
    "$SESSION" "$command" "$@"
    ;;
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash plugin/tests/test-default-attach.sh`
Expected: `PASS test-default-attach`

- [ ] **Step 7: Commit**

```bash
git add plugin/scripts/marina.sh plugin/scripts/marina-entrypoint.sh plugin/tests/test-default-attach.sh
git commit -m "feat(plugin): marina.sh default <id> a,b,c — registry writer for defaultAttach set"
```

---

### Task 3: attach script — `defaultAttach` resolution + first-run gate

**Files:**
- Modify: `plugin/scripts/attach-detached-subrepos.sh` (`registry_default_for`, `resolve_subrepos`, gate in `main`)
- Test: `plugin/tests/test-auto-attach-default.sh` (create)

New-worktree auto-attach (no `MARINA_SUBREPOS`) must attach the project's `defaultAttach` (or full `subrepos` when `defaultAttach` is absent), and must only run on a fresh worktree (zero universe subrepos attached). The dashboard's single-subrepo attach always passes `MARINA_SUBREPOS` and is unaffected.

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-auto-attach-default.sh`:

```bash
#!/usr/bin/env bash
# attach-detached-subrepos.sh auto-attach honors defaultAttach + first-run gate
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ATTACH="$HERE/../scripts/attach-detached-subrepos.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
src="$tmp/source/proj"; dst="$tmp/codex/abcd/proj"; home="$tmp/marina"
mkdir -p "$src" "$dst" "$home"
src="$(cd "$src" && pwd -P)"; dst="$(cd "$dst" && pwd -P)"; home="$(cd "$home" && pwd -P)"
gi() { mkdir -p "$1"; git -C "$1" init -q; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm i; }
for r in a b c; do gi "$src/$r"; done
cat > "$home/projects.json" <<JSON
{"projects":[{"id":"proj","root":"$src","subrepos":["a","b","c"],"defaultAttach":["a"],"worktreeGlobs":["~/.codex/worktrees/*/proj"]}],"schemaVersion":1}
JSON
run() { MARINA_HOME="$home" CODEX_WORKTREES_ROOT="$tmp/codex" DEST_ROOT="$dst" SYNC_IDEA=false "$ATTACH" 2>&1; }

# fresh worktree → only the default set (a) attaches
out="$(run)"; printf '%s\n' "$out"
[[ -e "$dst/a/.git" ]] || { echo "FAIL: default a not attached"; exit 1; }
[[ ! -e "$dst/b/.git" ]] || { echo "FAIL: non-default b attached"; exit 1; }
[[ ! -e "$dst/c/.git" ]] || { echo "FAIL: non-default c attached"; exit 1; }

# second run → a already attached → gate skips, b/c stay absent (user-detached defaults are NOT revived)
out2="$(run)"; printf '%s\n' "$out2"
case "$out2" in *"skip auto-attach"*) ;; *) echo "FAIL: gate did not skip on initialized worktree"; exit 1;; esac
[[ ! -e "$dst/b/.git" ]] || { echo "FAIL: re-run attached b"; exit 1; }

# explicit MARINA_SUBREPOS bypasses the gate (dashboard single attach)
MARINA_SUBREPOS=b MARINA_HOME="$home" CODEX_WORKTREES_ROOT="$tmp/codex" DEST_ROOT="$dst" SYNC_IDEA=false "$ATTACH" >/dev/null 2>&1
[[ -e "$dst/b/.git" ]] || { echo "FAIL: explicit MARINA_SUBREPOS=b did not attach"; exit 1; }

echo "PASS test-auto-attach-default"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugin/tests/test-auto-attach-default.sh`
Expected: FAIL — current `resolve_subrepos` reads the full `subrepos` universe, so `b` and `c` attach on the first run (the `non-default b attached` assertion fails).

- [ ] **Step 3: Add `registry_default_for`**

In `plugin/scripts/attach-detached-subrepos.sh`, immediately **after** the `registry_subrepos_for() { … PY\n}` function and **before** `registry_source_root_for()`, insert (it mirrors `registry_subrepos_for` but returns `defaultAttach` when present, else `subrepos`):

```bash
# 새 worktree 자동 attach 집합 = 레지스트리 defaultAttach(명시) → subrepos(부재 시 전체) → 미등록이면 실패(3)
registry_default_for() {
  command -v python3 >/dev/null 2>&1 || return 3
  [[ -f "$PROJECTS_FILE" ]] || return 3
  python3 - "$PROJECTS_FILE" "$1" <<'PY'
import json, os, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(3)
root = os.path.realpath(os.path.expanduser(sys.argv[2]))
codex_wt = os.path.realpath(os.path.expanduser(os.environ.get("CODEX_WORKTREES_ROOT") or "~/.codex/worktrees"))
projects = data.get("projects", [])
norm = lambda p: os.path.realpath(os.path.expanduser(p.get("root", "")))
match = None
best_len = -1
for p in projects:
    pr = norm(p)
    if root == pr or root.startswith(pr + os.sep):
        if len(pr) > best_len:
            match = p; best_len = len(pr)
if match is None and os.path.dirname(os.path.dirname(root)) == codex_wt:
    base = os.path.basename(root)
    for p in projects:
        if os.path.basename(norm(p)) == base:
            match = p; break
if match is None and len(projects) == 1:
    match = projects[0]
if match is None:
    sys.exit(3)
da = match.get("defaultAttach")
subs = da if isinstance(da, list) else match.get("subrepos", [])
print(" ".join(str(s) for s in subs))
PY
}
```

- [ ] **Step 4: Make `resolve_subrepos` prefer the default set**

Find the `resolve_subrepos()` function:

```bash
resolve_subrepos() {
  local from_registry
  if [[ -n "${MARINA_SUBREPOS:-}" ]]; then
    read -r -a SUBREPOS <<< "$MARINA_SUBREPOS"
    return
  fi
  if from_registry="$(registry_subrepos_for "$DEST_ROOT")"; then
    read -r -a SUBREPOS <<< "$from_registry"
    return
  fi
  SUBREPOS=()
}
```

Replace the `registry_subrepos_for` call with `registry_default_for` (auto-attach path resolves the default set, not the whole universe):

```bash
resolve_subrepos() {
  local from_registry
  if [[ -n "${MARINA_SUBREPOS:-}" ]]; then
    read -r -a SUBREPOS <<< "$MARINA_SUBREPOS"
    return
  fi
  # 자동 attach(env 미지정) = defaultAttach 집합 (부재 시 전체 universe). 대시보드 단일 attach 는 위 env 경로.
  if from_registry="$(registry_default_for "$DEST_ROOT")"; then
    read -r -a SUBREPOS <<< "$from_registry"
    return
  fi
  SUBREPOS=()
}
```

- [ ] **Step 5: Add the first-run gate in `main()`**

In the `main()` function, find the `source==dest` skip block:

```bash
  if [[ "$SOURCE_ROOT" == "$DEST_ROOT" ]]; then
    echo "skip: source==dest ($SOURCE_ROOT) — main 체크아웃/단일레포라 attach 대상 없음"
    exit 0
  fi
```

Immediately **after** that block, insert the gate (auto mode only — when `MARINA_SUBREPOS` is unset; checks the full universe so a user-added non-default attach also counts as "initialized"):

```bash
  # 자동 attach(MARINA_SUBREPOS 미지정 = defaultAttach 경로)는 "첫 실행(fresh worktree)"에만.
  # universe 중 하나라도 이미 attach 돼 있으면 사용자가 커스터마이즈한 상태로 보고 건드리지 않는다
  # — detach 한 default 를 세션 시작마다 되살리지 않기 위함 (design open item 1 결정). 대시보드 단일 attach 는 env 로 우회.
  if [[ -z "${MARINA_SUBREPOS:-}" ]]; then
    local universe_str repo
    universe_str="$(registry_subrepos_for "$DEST_ROOT" || true)"
    for repo in $universe_str; do
      if [[ -e "$DEST_ROOT/$repo/.git" ]]; then
        echo "skip auto-attach: worktree already initialized ($repo attached) — 수동 attach 는 대시보드"
        return 0
      fi
    done
  fi
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash plugin/tests/test-auto-attach-default.sh`
Expected: `PASS test-auto-attach-default`

- [ ] **Step 7: Run the existing attach regression to confirm no breakage**

Run: `bash plugin/tests/test-attach-clean-codex-worktree.sh`
Expected: exits 0 — note this project's registry has **no** `defaultAttach`, so `registry_default_for` returns the full `subrepos` (all three attach) on the fresh worktree, matching the old behavior. If it fails, re-check Step 3's fallback (`subs = da if isinstance(da, list) else match.get("subrepos", [])`).

- [ ] **Step 8: Commit**

```bash
git add plugin/scripts/attach-detached-subrepos.sh plugin/tests/test-auto-attach-default.sh
git commit -m "feat(plugin): auto-attach honors defaultAttach + first-run gate (no revive of user-detached subrepos)"
```

---

### Task 4: Python data layer — attach state, default, service→subrepo tagging

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`load_projects`, new `default_attach_of`/`service_subrepo`/`service_subrepo_map`, `worktree_info`, `session_payload`)
- Test: `plugin/tests/test-subrepo-tree-api.sh` (create)

`service_subrepo` is the spec's key change (longest-prefix). The payload gains: per-service `subrepo`, per-worktree `attachedSubrepos`, and `defaultAttach`.

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-subrepo-tree-api.sh`:

```bash
#!/usr/bin/env bash
# service_subrepo longest-prefix unit + payload fields (attachedSubrepos, service.subrepo, defaultAttach)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"

# --- unit: service_subrepo longest-prefix (no server) ---
python3 - "$CTRL" <<'PY' || { echo "FAIL: service_subrepo unit"; exit 1; }
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
ss = mc.service_subrepo
assert ss("web-app-monorepo/apps/web", ["ai-api","be-api","web-app-monorepo"]) == "web-app-monorepo", ss("web-app-monorepo/apps/web", ["ai-api","be-api","web-app-monorepo"])
assert ss("projects/react-skeleton/app", ["projects","projects/react-skeleton"]) == "projects/react-skeleton"
assert ss("ai-api/index_api", ["ai-api"]) == "ai-api"
assert ss(".", ["a"]) == ""
assert ss("", ["a"]) == ""
assert ss("unknown/dir", ["a","b"]) == "unknown"   # no match, non-root → first segment
PY

# --- payload: main checkout with services + partial on-disk subrepos ---
PORT=39713; base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")
P="$TMP/proj"; mkdir -p "$P/a/.git" "$P/b/.git"   # a,b attached on disk; c absent
mkdir -p "$P/c-placeholder"  # keep c out
cat > "$P/marina-services.json" <<'JSON'
{"services":[
  {"name":"asvc","portBase":4100,"cwd":"a/sub"},
  {"name":"bsvc","portBase":4200,"cwd":"b"},
  {"name":"rootsvc","portBase":4300,"cwd":"."}
]}
JSON
bash "$HERE/../scripts/marina.sh" add "$P" --subrepos a,b,c >/dev/null
id="$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
bash "$HERE/../scripts/marina.sh" default "$id" a,b >/dev/null

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# worktrees: registered root is "main" → attachedSubrepos = all universe; defaultAttach = [a,b]
curl -s "${hdr[@]}" "$base/api/worktrees" | python3 -c "
import json, sys
w = next(x for x in json.load(sys.stdin)['worktrees'] if x['root'].endswith('/proj'))
assert w['isMain'] is True, w
assert sorted(w['attachedSubrepos']) == ['a','b','c'], w['attachedSubrepos']
assert w['defaultAttach'] == ['a','b'], w['defaultAttach']
" || { echo "FAIL: worktree payload"; exit 1; }

# sessions: each service tagged with longest-prefix subrepo
curl -s "${hdr[@]}" "$base/api/sessions" | python3 -c "
import json, sys
s = next(x for x in json.load(sys.stdin)['sessions'] if x['root'].endswith('/proj'))
by = {x['service']: x.get('subrepo') for x in s['services']}
assert by == {'asvc':'a','bsvc':'b','rootsvc':''}, by
" || { echo "FAIL: service subrepo tagging"; exit 1; }

echo "PASS test-subrepo-tree-api"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugin/tests/test-subrepo-tree-api.sh`
Expected: FAIL — `AttributeError: module 'mc' has no attribute 'service_subrepo'` in the unit block.

- [ ] **Step 3: Read `defaultAttach` in `load_projects`**

In `load_projects()`, find the `items.append({…})` dict:

```python
            items.append({
                "id": str(entry.get("id") or root.name),
                "root": root,
                "subrepos": [str(s) for s in entry.get("subrepos", [])],
                "worktreeGlobs": [str(g) for g in entry.get("worktreeGlobs", [])],
            })
```

Replace with (adds `defaultAttach`, preserving `None` when the key is absent — distinct from `[]`):

```python
            _da = entry.get("defaultAttach")
            items.append({
                "id": str(entry.get("id") or root.name),
                "root": root,
                "subrepos": [str(s) for s in entry.get("subrepos", [])],
                "defaultAttach": [str(s) for s in _da] if isinstance(_da, list) else None,
                "worktreeGlobs": [str(g) for g in entry.get("worktreeGlobs", [])],
            })
```

- [ ] **Step 4: Add `default_attach_of` after `subrepos_of`**

Find `subrepos_of()` (ends `return list(project["subrepos"]) if project else list(_DEFAULT_SUBREPOS)`). Immediately after it, insert:

```python
def default_attach_of(root: Path) -> list[str] | None:
    # 전체 기본 attach 집합 (명시값). 부재 시 None → 호출부가 "전체 universe" 로 해석 (backward compatible).
    project = project_for(root)
    if not project:
        return None
    da = project.get("defaultAttach")
    return [str(s) for s in da] if isinstance(da, list) else None
```

- [ ] **Step 5: Add `service_subrepo` + `service_subrepo_map` after `services_for`**

Find `services_for()` (ends `return _BUILTIN_SERVICES + extra`). Immediately after it (and before `def session_payload(`), insert:

```python
def service_subrepo(cwd: str, subrepos: list[str]) -> str:
    # 서비스 cwd → 소속 subrepo. 등록 subrepo 중 cwd 의 longest-prefix 매치
    #   (projects/react-skeleton 같은 슬래시 subrepo 대응 — '첫 세그먼트' 룰의 한계 보완).
    # 매치 없음: root('.'/빈값) → "" (ungrouped, 카드 상단). 그 외 → 첫 세그먼트(미등록 그룹, 토글 없이 노출).
    norm = cwd.strip().strip("/")
    if not norm or norm == ".":
        return ""
    best = ""
    for s in subrepos:
        if (norm == s or norm.startswith(s + "/")) and len(s) > len(best):
            best = s
    return best or norm.split("/", 1)[0]


def service_subrepo_map(root: Path) -> dict[str, str]:
    # {서비스명: 소속 subrepo} — 프로젝트 marina-services.json 의 cwd 기준.
    project = project_for(root)
    proot = Path(project["root"]) if project else root
    subs = subrepos_of(root)
    try:
        data = json.loads((proot / "marina-services.json").read_text(encoding="utf-8"))
    except Exception:
        return {}
    out: dict[str, str] = {}
    for item in data.get("services", []):
        name = str(item.get("name", "")).strip()
        if name and name.isidentifier():
            out[name] = service_subrepo(str(item.get("cwd", "")), subs)
    return out
```

- [ ] **Step 6: Add `attachedSubrepos` + `defaultAttach` to `worktree_info`**

In `worktree_info()`, find the `is_main = is_source_checkout(root)` line near the top. Immediately after it, add:

```python
    subs = subrepos_of(root)
    # 물리 attach 상태(fs 판정). main 체크아웃은 원본 클론이라 전부 attach 로 본다.
    attached_subrepos = list(subs) if is_main else [s for s in subs if (root / s / ".git").exists()]
    default_explicit = default_attach_of(root)
```

Then, in the `info = {…}` dict, find:

```python
        "subrepos": list(project["subrepos"]) if project else [],
        "isMain": is_main,
```

Replace with:

```python
        "subrepos": list(project["subrepos"]) if project else [],
        # 이 worktree 에 물리 attach 된 subrepo (fs 판정; main 은 전부). 클라이언트 트리 attach 상태원.
        "attachedSubrepos": attached_subrepos,
        # 전체 기본 attach 집합 — 명시값 없으면 universe(=전부). main 카드 "기본" 토글 프리필.
        "defaultAttach": default_explicit if default_explicit is not None else list(subs),
        "isMain": is_main,
```

- [ ] **Step 7: Tag services with `subrepo` in `session_payload`**

In `session_payload()`, find:

```python
        "services": [service_status(root, svc, ports.get(svc), snapshot, listeners_by_port) for svc in services_for(root)],
```

Replace with (build the map once, tag each service):

```python
        "services": _tagged_services(root, ports, snapshot, listeners_by_port),
```

And add this helper immediately **before** `def session_payload(`:

```python
def _tagged_services(
    root: Path,
    ports: dict[str, str],
    snapshot: list[dict[str, Any]] | None,
    listeners_by_port: dict[str, list[int]] | None,
) -> list[dict[str, Any]]:
    smap = service_subrepo_map(root)
    out: list[dict[str, Any]] = []
    for svc in services_for(root):
        st = service_status(root, svc, ports.get(svc), snapshot, listeners_by_port)
        st["subrepo"] = smap.get(svc, "")
        out.append(st)
    return out
```

- [ ] **Step 8: Verify the file still parses**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"`
Expected: no output, exit 0.

- [ ] **Step 9: Run the test to verify it passes**

Run: `bash plugin/tests/test-subrepo-tree-api.sh`
Expected: `PASS test-subrepo-tree-api`

- [ ] **Step 10: Run the per-project services regression**

Run: `bash plugin/tests/test-per-project-services.sh`
Expected: `PASS test-per-project-services` (service list shape unchanged; only a `subrepo` key added per service).

- [ ] **Step 11: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-subrepo-tree-api.sh
git commit -m "feat(plugin): payload subrepo tagging (longest-prefix) + attachedSubrepos/defaultAttach"
```

---

### Task 5: Python API — attach / detach / set-default endpoints

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`attach_subrepo_action`, `detach_subrepo_action`, three `do_POST` branches)
- Test: `plugin/tests/test-attach-detach-api.sh` (create)

All registry writes go through `marina.sh` (`set-default-attach` shells `marina.sh default`). Physical attach reuses `attach-detached-subrepos.sh` via `MARINA_SUBREPOS=<one>`; detach is `git worktree remove` with stop-first / confirm-on-dirty guards and branch preservation. The main card rejects physical attach/detach.

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-attach-detach-api.sh` (sets up a real source repo + a real `git worktree` so attach/detach exercise git):

```bash
#!/usr/bin/env bash
# /api/attach-subrepo · /api/detach-subrepo · /api/set-default-attach over a real worktree
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39714; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
post() { curl -s "${hdr[@]}" -d "$2" "$base/api/$1"; }

gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm i; }

# main checkout: a root/container git repo + two nested subrepo clones a,b (mdc-main 과 동일 구조)
SRC="$TMP/src"; gi "$SRC"; gi "$SRC/a"; gi "$SRC/b"
cat > "$SRC/marina-services.json" <<'JSON'
{"services":[{"name":"asvc","portBase":4100,"cwd":"a"},{"name":"bsvc","portBase":4200,"cwd":"b"}]}
JSON
# worktree = real git worktree of the root repo (루트에 .git → discover 됨). 서브레포는 아래 API 로 attach.
WT="$TMP/wt/feature-x"; mkdir -p "$TMP/wt"
git -C "$SRC" worktree add -q --detach "$WT" HEAD
bash "$SH" add "$SRC" --subrepos a,b >/dev/null
# point worktreeGlobs at our wt dir so it's discovered
python3 - "$MARINA_HOME/projects.json" "$TMP/wt/*" <<'PY'
import json, sys
f, glob = sys.argv[1], sys.argv[2]
d = json.load(open(f)); d["projects"][0]["worktreeGlobs"] = [glob]
json.dump(d, open(f, "w"), ensure_ascii=False, indent=2)
PY

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# set-default-attach on main → registry defaultAttach written
post set-default-attach "{\"root\":\"$SRC\",\"subrepos\":[\"a\"]}" >/dev/null
python3 -c "import json,os; p=json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]; assert p['defaultAttach']==['a'],p" \
  || { echo "FAIL: set-default-attach write"; exit 1; }

# set-default-attach rejects subrepo outside universe → 4xx
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -d "{\"root\":\"$SRC\",\"subrepos\":[\"zzz\"]}" "$base/api/set-default-attach")"
[[ "$code" == 4* ]] || { echo "FAIL: set-default-attach bad subrepo expected 4xx, got $code"; exit 1; }

# attach b into the worktree (idempotent: run twice)
post attach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\"}" >/dev/null
post attach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\"}" >/dev/null
[[ -e "$WT/b/.git" ]] || { echo "FAIL: attach b did not create worktree"; exit 1; }

# main card physical attach is rejected → 4xx
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -d "{\"root\":\"$SRC\",\"subrepo\":\"a\"}" "$base/api/attach-subrepo")"
[[ "$code" == 4* ]] || { echo "FAIL: main attach expected 4xx, got $code"; exit 1; }

# detach clean b → removed, branch preserved
out="$(post detach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\"}")"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('detached')=='b' or 'removed' in d, d" \
  || { echo "FAIL: detach clean b: $out"; exit 1; }
[[ ! -e "$WT/b/.git" ]] || { echo "FAIL: b still attached after detach"; exit 1; }

# dirty detach → needsConfirm, then force
post attach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\"}" >/dev/null
echo dirty > "$WT/b/uncommitted.txt"
out="$(post detach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\"}")"
echo "$out" | python3 -c "import json,sys; assert json.load(sys.stdin).get('needsConfirm') is True" \
  || { echo "FAIL: dirty detach expected needsConfirm: $out"; exit 1; }
post detach-subrepo "{\"root\":\"$WT\",\"subrepo\":\"b\",\"force\":true}" >/dev/null
[[ ! -e "$WT/b/.git" ]] || { echo "FAIL: force detach did not remove b"; exit 1; }

echo "PASS test-attach-detach-api"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugin/tests/test-attach-detach-api.sh`
Expected: FAIL — `set-default-attach` returns 404/400 (`not found`), so the registry assertion fails.

- [ ] **Step 3: Add the action helpers**

In `plugin/scripts/marina-control.py`, immediately **after** the `remove_worktree()` function (it ends with `return results`) and before `def memory_block(`, insert:

```python
def attach_subrepo_action(root: Path, subrepo: str) -> dict[str, Any]:
    # 단일 subrepo 물리 attach — 기존 attach 스크립트 재사용(MARINA_SUBREPOS=<하나>). idempotent + yml/env/venv 동기화.
    source = source_root_for(root)
    if source.resolve() == root.resolve():
        raise ValueError("원본 체크아웃에는 attach 대상이 없습니다")
    env = {
        **os.environ,
        "DEST_ROOT": str(root),
        "SOURCE_ROOT": str(source),
        "MARINA_SUBREPOS": subrepo,
        "SYNC_IDEA": os.environ.get("SYNC_IDEA", "false"),
    }
    try:
        out = subprocess.check_output([str(MARINA_ATTACH)], text=True, stderr=subprocess.STDOUT, env=env)
    except subprocess.CalledProcessError as exc:
        raise ValueError((exc.output or "").strip() or str(exc))
    _worktree_info_cache.pop(str(root), None)
    _status_cache.pop(str(root), None)
    return {"ok": True, "attached": subrepo, "output": out.strip()}


def detach_subrepo_action(root: Path, subrepo: str, force: bool = False, stop_services: bool = False) -> dict[str, Any]:
    target = root / subrepo
    if not (target / ".git").exists():
        return {"ok": True, "detached": subrepo, "note": "already detached"}
    # 1) 이 subrepo 의 구동 중 서비스 — 살아있는 프로세스가 디렉토리를 점유하므로 먼저 정지.
    smap = service_subrepo_map(root)
    ports = ports_for(root)
    running = [
        svc for svc in services_for(root)
        if smap.get(svc) == subrepo and service_status(root, svc, ports.get(svc))["running"]
    ]
    if running and not stop_services:
        return {"needsStop": running}
    for svc in running:
        stop_service(root, svc)
    # 2) dirty working tree — clean 이면 지금 제거, 미커밋 변경 있으면 confirm 후 --force.
    status = worktree_status(root)
    entry = next((r for r in status["repos"] if r["name"] == subrepo), None)
    if entry and entry.get("dirty") and not force:
        return {"needsConfirm": True, "changes": entry.get("changes", [])}
    source_repo = source_root_for(root) / subrepo
    if not source_repo.exists():
        return {"error": f"source repo not found: {source_repo}"}
    # 브랜치는 보존(worktree remove 만) — 미머지 커밋 안전, 재attach 시 재사용.
    res = remove_git_worktree(source_repo, target, force=force)
    _worktree_info_cache.pop(str(root), None)
    _status_cache.pop(str(root), None)
    if "error" in res:
        return res
    return {"ok": True, "detached": subrepo, **res}
```

- [ ] **Step 4: Add the three `do_POST` branches**

In `do_POST`, find the `fix-port-conflict` branch:

```python
            if self.path == "/api/fix-port-conflict":
                self.send_json(fix_port_conflict(root))
                return
```

Immediately **after** it (and before `service = safe_service(str(body.get("service", "")))`), insert:

```python
            if self.path == "/api/set-default-attach":
                project = project_for(root)
                if not project:
                    raise ValueError("미등록 프로젝트")
                # main/project 카드 전용 — worktree 에서 호출 거부.
                if not (project["root"].resolve() == root.resolve() or is_source_checkout(root)):
                    raise ValueError("기본 attach 편집은 main 카드에서만 가능합니다")
                subs = body.get("subrepos")
                if not isinstance(subs, list) or not all(isinstance(s, str) for s in subs):
                    raise ValueError("subrepos must be a list of strings")
                universe = set(subrepos_of(root))
                bad = [s for s in subs if s not in universe]
                if bad:
                    raise ValueError(f"등록되지 않은 subrepo: {', '.join(bad)}")
                try:
                    out = run_marina_registry("default", project["id"], ",".join(subs))
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                self.send_json({"ok": True, "output": out.strip()})
                return

            if self.path in ("/api/attach-subrepo", "/api/detach-subrepo"):
                subrepo = str(body.get("subrepo", "")).strip()
                if subrepo not in subrepos_of(root):
                    raise ValueError("등록되지 않은 subrepo")
                project = project_for(root)
                is_main_card = (project and project["root"].resolve() == root.resolve()) or is_source_checkout(root)
                if is_main_card:
                    raise ValueError("main 체크아웃은 물리 attach/detach 하지 않습니다 (기본 attach 편집만)")
                if self.path == "/api/attach-subrepo":
                    self.send_json(attach_subrepo_action(root, subrepo))
                else:
                    self.send_json(detach_subrepo_action(
                        root, subrepo,
                        force=bool(body.get("force")),
                        stop_services=bool(body.get("stopServices")),
                    ))
                return
```

> Note: `root = safe_root(...)` already runs earlier in `do_POST` (the line `root = safe_root(str(body.get("root", "")))`), so all three branches have a validated `root`.

- [ ] **Step 5: Verify the file still parses**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"`
Expected: no output, exit 0.

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash plugin/tests/test-attach-detach-api.sh`
Expected: `PASS test-attach-detach-api`

- [ ] **Step 7: Commit**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-attach-detach-api.sh
git commit -m "feat(plugin): /api/attach-subrepo · /api/detach-subrepo · /api/set-default-attach"
```

---

### Task 6: UI CSS — subrepo tree styling

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`INDEX_HTML` `<style>` block)

Add styling for subrepo group rows, their collapsible service body, the toggle controls, and disabled (non-attached) service rows. Reuse existing design tokens (`var(--sys-…)`).

- [ ] **Step 1: Add the CSS rules**

Find the existing `.svc` rule block in `INDEX_HTML`:

```css
    .svc-list { display: grid; }
    .session.collapsed .svc-list, .session.collapsed [data-config-details], .session.collapsed .root { display: none; }
    .session.collapsed .session-head { border-bottom: 0; }
    .svc { display: grid; grid-template-columns: 86px 72px minmax(0, 1fr); gap: 8px; align-items: center; padding: 10px 12px; border-top: 1px solid var(--sys-style-neutral-light); cursor: pointer; }
    .svc:hover, .svc.selected { background: var(--sys-bg-surface-hover); }
```

Immediately **after** the `.svc:hover, .svc.selected { … }` line, insert:

```css
    /* subrepo ⊃ service 트리 */
    .subrepo-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 12px; border-top: 1px solid var(--sys-style-neutral-light); background: var(--sys-bg-base); }
    .subrepo-row.detached { opacity: 0.72; }
    .subrepo-main { display: flex; align-items: center; gap: 8px; min-width: 0; cursor: pointer; flex: 1; }
    .subrepo-name { font-size: 13px; font-weight: 700; line-height: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .subrepo-count { color: var(--sys-cont-neutral-lightest); font-size: 11px; white-space: nowrap; }
    .subrepo-count.muted { font-style: italic; }
    .subrepo-ctl { display: flex; align-items: center; gap: 8px; flex-shrink: 0; }
    .subrepo-chip { display: inline-flex; align-items: center; height: 20px; padding: 0 8px; border-radius: 6px; font-size: 11px; font-weight: 700; background: var(--sys-style-neutral-light); color: var(--sys-cont-neutral-light); }
    .subrepo-chip.on { background: hsl(148, 55%, 94%); color: var(--sys-cont-positive-default); }
    .subrepo-chip.warn { background: hsl(36, 90%, 94%); color: hsl(30, 80%, 38%); }
    .subrepo-toggle { display: inline-flex; align-items: center; gap: 5px; font-size: 11px; font-weight: 700; color: var(--sys-cont-neutral-light); cursor: pointer; }
    .subrepo-toggle input { margin: 0; cursor: pointer; }
    .subrepo-act { height: 24px; padding: 0 10px; font-size: 11px; font-weight: 700; }
    .subrepo-body { display: grid; }
    .subrepo-body .svc { padding-left: 30px; }   /* nested 들여쓰기 */
    .svc.disabled { cursor: default; opacity: 0.5; }
    .svc.disabled:hover { background: transparent; }
    .svc.disabled .actions { display: none; }
```

- [ ] **Step 2: Verify the file still parses**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add plugin/scripts/marina-control.py
git commit -m "style(plugin): CSS for subrepo⊃service tree (group rows, toggles, disabled svc)"
```

---

### Task 7: UI render — subrepo⊃service tree

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`INDEX_HTML` JS: add `subrepoOpen` state, `makeSvcRow`, `renderServiceTree`, `renderSubrepoHead`; replace the flat svc-list loop; patch `updateServiceStates`)

Replace the flat `for (const svc of session.services)` loop with a tree: ungrouped (root cwd) services at top, then each subrepo group as a header row + collapsible service body. Services under a non-attached subrepo render disabled. Toggle wiring is added in Task 8 (a placeholder no-op `wireSubrepoToggle` is added here so the render is self-contained).

- [ ] **Step 1: Add `subrepoOpen` module state**

Find the state declaration:

```javascript
    const openConfigRoots = new Set();
    const expandedRoots = new Set();
```

Replace with:

```javascript
    const openConfigRoots = new Set();
    const expandedRoots = new Set();
    const subrepoOpen = new Map();   // `${root}::${subrepo}` → bool (펼침). 미설정이면 attached=펼침 기본.
```

- [ ] **Step 2: Replace the flat svc-list loop with a tree call**

Find the loop at the end of the card build (it starts with `const list = card.querySelector('.svc-list');` and ends just before `sessionsEl.appendChild(card);`):

```javascript
        const list = card.querySelector('.svc-list');

        for (const svc of session.services) {
          const row = document.createElement('div');
          row.className = 'svc';
          row.title = '클릭하면 이 서비스의 로그를 우측에 표시';
          row.dataset.serviceKey = `${session.root}::${svc.service}`;
          const state = pillState(svc);
          row.innerHTML = `
            <div><div class="svc-name">${svc.service}</div><div class="svc-port"><span data-port>${svc.port ?? '-'}</span><span data-rss>${svc.running && svc.rssMb ? ` · ${svc.rssMb}MB` : ''}</span></div></div>
            <div class="pill ${state.cls}" data-state title="${escapeHtml(state.title)}">${state.text}</div>
            <div class="actions"></div>
          `;
          row.onclick = () => selectLog(session.root, svc.service, 'current', 'service');
          const actions = row.querySelector('.actions');
          const busyLabels = {start: '…', stop: '…', restart: '…'};
          const actionTitles = {
            start: 'Start — 기동. 포트 점유 시 빈 포트로 자동 이동, 가용 메모리 부족 시 차단',
            stop: 'Stop — 프로세스 그룹 정지 (TERM→KILL)',
            restart: 'Restart — 정지 후 재기동',
          };
          // 상태 적응형: 정지 상태엔 ▶ 만, 구동 중엔 ■·↻ 만 — updateServiceStates 가 토글
          for (const [label, type, cls] of [['▶', 'start', 'primary'], ['■', 'stop', 'danger'], ['↻', 'restart', '']]) {
            const btn = document.createElement('button');
            btn.textContent = label;
            btn.title = actionTitles[type];
            btn.dataset.act = type;
            if (cls) btn.className = cls;
            btn.hidden = type === 'start' ? svc.running : !svc.running;
            btn.onclick = (event) => {
              event.stopPropagation();
              withBusy(btn, busyLabels[type], () => action(type, session.root, svc.service), actions.querySelectorAll('button'));
            };
            actions.appendChild(btn);
          }
          list.appendChild(row);
        }
        sessionsEl.appendChild(card);
```

Replace the whole loop (everything from `const list = …` through the `}` that closes the `for (const svc …)` loop, but **keep** the final `sessionsEl.appendChild(card);`) with:

```javascript
        renderServiceTree(card.querySelector('.svc-list'), session, wt);
        sessionsEl.appendChild(card);
```

- [ ] **Step 3: Add `makeSvcRow`, `renderServiceTree`, `renderSubrepoHead`, placeholder `wireSubrepoToggle`**

Immediately **after** the `render()` function's closing brace (the function that ends with `renderSelection();\n    }`), insert these helpers:

```javascript
    function makeSvcRow(session, svc, disabled) {
      const row = document.createElement('div');
      row.className = 'svc nested' + (disabled ? ' disabled' : '');
      row.dataset.serviceKey = `${session.root}::${svc.service}`;
      const state = pillState(svc);
      row.title = disabled ? 'subrepo 미attach — attach 후 사용 가능' : '클릭하면 이 서비스의 로그를 우측에 표시';
      row.innerHTML = `
        <div><div class="svc-name">${svc.service}</div><div class="svc-port"><span data-port>${svc.port ?? '-'}</span><span data-rss>${svc.running && svc.rssMb ? ` · ${svc.rssMb}MB` : ''}</span></div></div>
        <div class="pill ${disabled ? 'stop' : state.cls}" data-state title="${escapeHtml(disabled ? 'subrepo 미attach' : state.title)}">${disabled ? '—' : state.text}</div>
        <div class="actions"></div>
      `;
      if (disabled) return row;
      row.onclick = () => selectLog(session.root, svc.service, 'current', 'service');
      const actions = row.querySelector('.actions');
      const busyLabels = {start: '…', stop: '…', restart: '…'};
      const actionTitles = {
        start: 'Start — 기동. 포트 점유 시 빈 포트로 자동 이동, 가용 메모리 부족 시 차단',
        stop: 'Stop — 프로세스 그룹 정지 (TERM→KILL)',
        restart: 'Restart — 정지 후 재기동',
      };
      for (const [label, type, cls] of [['▶', 'start', 'primary'], ['■', 'stop', 'danger'], ['↻', 'restart', '']]) {
        const btn = document.createElement('button');
        btn.textContent = label;
        btn.title = actionTitles[type];
        btn.dataset.act = type;
        if (cls) btn.className = cls;
        btn.hidden = type === 'start' ? svc.running : !svc.running;
        btn.onclick = (event) => {
          event.stopPropagation();
          withBusy(btn, busyLabels[type], () => action(type, session.root, svc.service), actions.querySelectorAll('button'));
        };
        actions.appendChild(btn);
      }
      return row;
    }

    function renderSubrepoHead(name, o) {
      const chev = o.count ? `<span class="chev">${o.open ? '▾' : '▸'}</span>` : '<span class="chev"></span>';
      let control = '';
      if (!o.inUniverse) {
        control = '<span class="subrepo-chip warn" title="서비스 cwd 가 가리키는 subrepo 가 레지스트리에 없음 — ⚙ 에서 등록하면 attach 가능">미등록</span>';
      } else if (o.isMain) {
        control = `<label class="subrepo-toggle" title="새 worktree 자동 attach 대상(전체 기본). 체크 해제해도 main 의 클론은 보존돼"><input type="checkbox" data-default-toggle ${o.isDefault ? 'checked' : ''}/> 기본</label>`;
      } else if (o.isAttached) {
        control = '<button class="subrepo-act" data-detach title="이 worktree 에서 detach (git worktree remove) — 브랜치·미머지 커밋은 보존">detach</button>';
      } else {
        control = '<button class="subrepo-act primary" data-attach title="이 worktree 에 attach (git worktree add) — 같은 이름 브랜치 있으면 재사용">attach</button>';
      }
      const stateChip = o.isMain ? '' : `<span class="subrepo-chip ${o.isAttached ? 'on' : ''}">${o.isAttached ? 'attached' : 'detached'}</span>`;
      return `
        <div class="subrepo-main">
          ${chev}
          <span class="subrepo-name">${escapeHtml(name)}</span>
          ${o.count ? `<span class="subrepo-count">${o.count} svc</span>` : '<span class="subrepo-count muted">no svc</span>'}
        </div>
        <div class="subrepo-ctl">${stateChip}${control}</div>
      `;
    }

    function renderServiceTree(list, session, wt) {
      list.innerHTML = '';
      const universe = wt?.subrepos ?? [];
      const isMain = !!wt?.isMain;
      const attached = new Set(wt?.attachedSubrepos ?? universe);
      const defaults = new Set(wt?.defaultAttach ?? universe);

      // 서비스 → subrepo 그룹핑 (svc.subrepo 태그). 빈 태그 = root cwd → ungrouped.
      const byGroup = new Map();
      const rootSvcs = [];
      for (const svc of session.services) {
        const g = svc.subrepo || '';
        if (!g) { rootSvcs.push(svc); continue; }
        if (!byGroup.has(g)) byGroup.set(g, []);
        byGroup.get(g).push(svc);
      }
      // 그룹 순서: universe 순서 + 서비스만 참조하는 미등록 그룹은 뒤에.
      const groups = [...universe];
      for (const g of byGroup.keys()) if (!groups.includes(g)) groups.push(g);

      // 1) 루트(cwd '.') 서비스 — 카드 상단 ungrouped.
      for (const svc of rootSvcs) list.appendChild(makeSvcRow(session, svc, false));

      // 2) subrepo ⊃ service.
      for (const name of groups) {
        const inUniverse = universe.includes(name);
        const isAttached = isMain || attached.has(name);
        const isDefault = defaults.has(name);
        const svcs = byGroup.get(name) ?? [];
        const key = `${session.root}::${name}`;
        const open = subrepoOpen.has(key) ? subrepoOpen.get(key) : isAttached;

        const head = document.createElement('div');
        head.className = 'subrepo-row' + (isAttached ? '' : ' detached');
        head.innerHTML = renderSubrepoHead(name, {isMain, isAttached, isDefault, inUniverse, open, count: svcs.length});
        list.appendChild(head);

        const body = document.createElement('div');
        body.className = 'subrepo-body';
        body.hidden = !open;
        for (const svc of svcs) body.appendChild(makeSvcRow(session, svc, !isAttached));
        list.appendChild(body);

        head.querySelector('.subrepo-main').onclick = () => {
          subrepoOpen.set(key, !open);
          render();
        };
        wireSubrepoToggle(head, session, wt, name, {isMain, isAttached, isDefault, inUniverse});
      }
    }

    // Task 8 에서 attach/detach/set-default 핸들러 연결. 그 전까지는 no-op (트리 렌더만 검증).
    function wireSubrepoToggle(head, session, wt, name, o) {}
```

- [ ] **Step 4: Patch `updateServiceStates` to skip disabled rows**

The polling refresh (`updateServiceStates`) must not overwrite the `—` pill of disabled (non-attached) rows. Find:

```javascript
        for (const svc of session.services) {
          const row = document.querySelector(`[data-service-key="${CSS.escape(`${session.root}::${svc.service}`)}"]`);
          if (!row) continue;
          const port = row.querySelector('[data-port]');
```

Replace with (add the `disabled` guard):

```javascript
        for (const svc of session.services) {
          const row = document.querySelector(`[data-service-key="${CSS.escape(`${session.root}::${svc.service}`)}"]`);
          if (!row) continue;
          if (row.classList.contains('disabled')) continue;   // 미attach subrepo 의 서비스 — 라이브 상태로 덮지 않음
          const port = row.querySelector('[data-port]');
```

- [ ] **Step 5: Verify the file still parses**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"`
Expected: no output, exit 0.

- [ ] **Step 6: Smoke-check the page serves and the script has no syntax error**

Run:
```bash
MARINA_HOME="$(mktemp -d)" MARINA_CONTROL_PORT=39777 MARINA_CONTROL_HOST=127.0.0.1 python3 plugin/scripts/marina-control.py >/tmp/marina-smoke.log 2>&1 &
SMOKE=$!; sleep 1
curl -s -H "Origin: http://127.0.0.1:39777" http://127.0.0.1:39777/ | grep -c "renderServiceTree"
kill $SMOKE 2>/dev/null
```
Expected: prints `1` or more (the function is present in the served HTML), and `/tmp/marina-smoke.log` has no traceback.

- [ ] **Step 7: Commit**

```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(plugin): render worktree card as subrepo⊃service tree (grouping, collapse, disabled rows)"
```

---

### Task 8: UI toggles — attach / detach / set-default handlers

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`INDEX_HTML` JS: `setDefaultAttach`/`attachSubrepo`/`detachSubrepo` + real `wireSubrepoToggle`)

Wire the subrepo toggle controls to the Task 5 endpoints, with the two-step confirm flow for detach (`needsStop` → "정지하고 detach", `needsConfirm` → discard dirty).

- [ ] **Step 1: Add the action helpers**

Immediately **after** the `sessionAction` function (it ends with `await load({force: true});\n    }`), insert:

```javascript
    async function setDefaultAttach(session, wt, name, want) {
      const cur = new Set(wt?.defaultAttach ?? wt?.subrepos ?? []);
      if (want) cur.add(name); else cur.delete(name);
      const r = await api('/api/set-default-attach', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root, subrepos: [...cur]}),
      });
      if (r?.error) { alert(`기본 attach 변경 실패: ${r.error}`); }
      await loadWorktrees(true);
      render();
    }

    async function attachSubrepo(session, name) {
      const r = await api('/api/attach-subrepo', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root, subrepo: name}),
      });
      if (r?.error) { alert(`attach 실패: ${r.error}`); return; }
      await loadWorktrees(true);
      await load({force: true});
    }

    async function detachSubrepo(session, name) {
      const body = {root: session.root, subrepo: name};
      const send = () => api('/api/detach-subrepo', {
        method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(body),
      });
      let r = await send();
      if (r?.needsStop) {
        if (!confirm(`${name} 에서 구동 중인 서비스(${r.needsStop.join('·')})를 정지하고 detach 할까?`)) return;
        body.stopServices = true;
        r = await send();
      }
      if (r?.needsConfirm) {
        if (!confirm(`${name} 에 미커밋 변경분이 있어. detach 하면 변경·untracked 가 폐기돼 (브랜치·커밋은 보존). 폐기하고 detach 할까?`)) return;
        body.force = true;
        r = await send();
      }
      if (r?.error) { alert(`detach 실패: ${r.error}`); return; }
      await loadWorktrees(true);
      await load({force: true});
    }
```

- [ ] **Step 2: Replace the placeholder `wireSubrepoToggle` with the real one**

Find the placeholder added in Task 7:

```javascript
    // Task 8 에서 attach/detach/set-default 핸들러 연결. 그 전까지는 no-op (트리 렌더만 검증).
    function wireSubrepoToggle(head, session, wt, name, o) {}
```

Replace with:

```javascript
    function wireSubrepoToggle(head, session, wt, name, o) {
      if (o.isMain && o.inUniverse) {
        const cb = head.querySelector('[data-default-toggle]');
        if (cb) cb.onchange = () => withBusy(cb, '…', () => setDefaultAttach(session, wt, name, cb.checked));
      }
      const attachBtn = head.querySelector('[data-attach]');
      if (attachBtn) attachBtn.onclick = (e) => { e.stopPropagation(); withBusy(attachBtn, '등록 중…', () => attachSubrepo(session, name)); };
      const detachBtn = head.querySelector('[data-detach]');
      if (detachBtn) detachBtn.onclick = (e) => { e.stopPropagation(); withBusy(detachBtn, '…', () => detachSubrepo(session, name)); };
    }
```

- [ ] **Step 3: Verify the file still parses**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"`
Expected: no output, exit 0.

- [ ] **Step 4: Re-run the full backend test suite**

Run:
```bash
for t in test-default-attach test-auto-attach-default test-subrepo-tree-api test-attach-detach-api test-per-project-services test-registry-api test-attach-clean-codex-worktree; do
  bash plugin/tests/$t.sh || { echo "FAILED: $t"; break; }
done
```
Expected: each prints its `PASS …` line; no `FAILED:`.

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(plugin): wire subrepo toggles — attach/detach (stop/confirm flows) + default-attach checkbox"
```

---

### Task 9: Live preview verification (Chrome MCP) + final review

**Files:** none (verification + optional follow-up fixes)

UI cannot be unit-tested here; verify it live against the real mdc registry on the preview port `:3901`, per the user's instruction. The mdc project is already registered (`~/.marina/projects.json`: `mdc-main` with subrepos `ai-api, be-api, web-app-monorepo`).

- [ ] **Step 1: Launch the preview daemon on :3901**

Run (foreground-safe background launch; the daemon reads the real `~/.marina` registry):
```bash
MARINA_CONTROL_PORT=3901 MARINA_CONTROL_HOST=127.0.0.1 python3 /Users/sumin/IdeaProjects/sumin/marina/plugin/scripts/marina-control.py >/tmp/marina-preview-3901.log 2>&1 &
```
Then confirm it answers:
```bash
sleep 1 && curl -s -H "Origin: http://127.0.0.1:3901" http://127.0.0.1:3901/api/worktrees | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['worktrees']),'worktrees'); [print(w['projectId'], w['isMain'], w.get('attachedSubrepos'), w.get('defaultAttach')) for w in d['worktrees'][:8]]"
```
Expected: prints the worktree count and, for each, `attachedSubrepos`/`defaultAttach` arrays (mdc-main should list the three subrepos).

- [ ] **Step 2: Drive Chrome MCP to the preview**

Navigate Chrome (via the `mcp__Claude_in_Chrome__*` tools) to `http://127.0.0.1:3901/`, select the `mdc-main` project in the switcher, expand a worktree card, and take a screenshot. **Verify visually:**
  - The main `mdc-main` card shows three subrepo group rows (`ai-api`, `be-api`, `web-app-monorepo`), each with a "기본" checkbox; `ai-api` nests three services (`index`, `search`, `audio`), `be-api` nests `be`, `web-app-monorepo` nests `web`. No service appears ungrouped (mdc has no root-cwd service).
  - A non-main worktree card (if one exists) shows `attached`/`detached` chips and an attach/detach button per subrepo; a detached subrepo's services render greyed/disabled with a `—` pill and collapse by default.
  - Clicking a subrepo header toggles collapse; the chevron flips.

- [ ] **Step 3: Functionally exercise the toggles (against a disposable worktree only)**

If a non-main mdc worktree exists and is safe to mutate: click `detach` on a subrepo whose services are stopped and tree is clean → confirm the card re-renders with that subrepo `detached` and its services disabled; click `attach` → confirm it returns to `attached` with live service rows. On the main card, toggle a "기본" checkbox → confirm `~/.marina/projects.json` gains/loses the entry:
```bash
python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.marina/projects.json')))['projects'])" | grep -o "defaultAttach[^]]*]"
```
**Do not** detach a subrepo with uncommitted work you care about — the dirty path discards on confirm. If no disposable worktree exists, rely on the `test-attach-detach-api.sh` integration test (Task 5) for the attach/detach behavior and verify only rendering + the main-card default checkbox live.

- [ ] **Step 4: Stop the preview daemon**

Run: `pkill -f "marina-control.py" || true` (or kill the specific PID from Step 1). Confirm `:3901` is free: `lsof -ti :3901 || echo free`.

- [ ] **Step 5: Run `code-reviewer` on the full diff**

Per CRABS `Do Not` (changed code present before a "완료/리뷰" report): dispatch the `code-reviewer` agent over the branch diff (`git diff main...HEAD` in the marina repo). Address any blockers (re-commit fixes per the touched task's scope), then report.

- [ ] **Step 6: Confirm the branch state and report**

Run: `git log --oneline main..HEAD` and `git status -sb`
Expected: the per-task commits from Tasks 1–8 present, working tree clean. Report the result to the user. **Do not push to origin** unless the user explicitly asks in their current message.

---

## Self-Review

**1. Spec coverage** (each spec section → task):
- A (card = subrepo⊃service tree) → Tasks 6–7. ✓
- B (main toggle = defaultAttach; worktree toggle = physical attach/detach; detach stop-first/confirm/branch-preserved) → Task 5 (backend) + Task 8 (UI). ✓
- C (new-worktree auto-attach honors default + first-run-only resolution) → Task 3. ✓
- D (3 POST endpoints with validation) → Task 5. ✓
- E (registry `defaultAttach`; `worktree_info.attachedSubrepos`; service `subrepo`; client builds tree) → Task 2 (writer), Task 4 (payload), Task 7 (client). ✓
- Error handling (attach missing source no-op; detach running→needsStop / dirty→needsConfirm→force / not-attached no-op; subrepo not in universe→400; main physical attach rejected; unregistered-cwd group without toggle) → Task 5 + Task 7 `renderSubrepoHead` (`미등록`). ✓
- Spec one-line update (longest-prefix) + Open item 1 decision → Task 1. ✓

**2. Placeholder scan:** every code step contains full code. The only intentional placeholder is `wireSubrepoToggle` no-op in Task 7, explicitly replaced in Task 8 — flagged in both tasks. No `TBD`/`handle edge cases`/"similar to". ✓

**3. Type/name consistency** (defined → used):
- `defaultAttach` registry key: written by `marina.sh default` (T2), read by `registry_default_for` (T3) and `load_projects` (T4), exposed as `worktree_info.defaultAttach` (T4), consumed by `renderServiceTree`/`setDefaultAttach` (T7/T8). ✓
- `attachedSubrepos`: produced in `worktree_info` (T4), consumed in `renderServiceTree` (T7). ✓
- service `subrepo`: `service_subrepo`/`_tagged_services` (T4) → `svc.subrepo` in `renderServiceTree` (T7), `service_subrepo_map` reused in `detach_subrepo_action` (T5). ✓
- endpoints `/api/attach-subrepo`·`/api/detach-subrepo`·`/api/set-default-attach`: defined in `do_POST` (T5), called by `attachSubrepo`/`detachSubrepo`/`setDefaultAttach` (T8). ✓
- `attach_subrepo_action`/`detach_subrepo_action`: defined T5, called from `do_POST` T5. ✓
- `makeSvcRow`/`renderSubrepoHead`/`renderServiceTree`/`wireSubrepoToggle`/`subrepoOpen`: defined T7, `wireSubrepoToggle` body filled T8. ✓
- detach response keys `needsStop`/`needsConfirm`/`error`/`detached`: produced in `detach_subrepo_action` (T5), branched on in `detachSubrepo` (T8) and asserted in `test-attach-detach-api.sh` (T5). ✓

No gaps found.
