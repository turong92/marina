# marina registration surfaces — Implementation Plan (phase 2)

> **For agentic workers:** Use superpowers:test-driven-development for Task 1. Steps use checkbox (`- [ ]`) tracking.

**Goal:** Make first-run registration reachable in-session (slash command) and from the registry CLI (a no-write `infer`), and document it — the in-session/CLI half of "fresh users can't find `marina add`". (Dashboard registration UI is phase 3.)

**Architecture:** Inference stays the single SoT in `marina.sh`. Refactor it into `registry_infer` (infer → print JSON, no write); `registry_add` consumes it then writes. A `/marina:register` slash command resolves the current project's main checkout and calls the entrypoint via `${CLAUDE_PLUGIN_ROOT}` (substituted by Claude Code per-invocation → version-safe).

**Tech Stack:** bash + `/usr/bin/python3`; Claude Code plugin `commands/*.md`. Reference spec: `docs/specs/2026-06-15-register-ux-design.md` components 1, 2, 6.

**Verified (claude-code-guide):** plugin commands are namespaced `/marina:register`; `${CLAUDE_PLUGIN_ROOT}` is substituted into the command body before the model sees it (like hooks), changing per-invocation to the current install path — so it is version-safe. Command body is a prompt (no auto-run); the agent runs the bash.

---

## File Structure
- **Modify** `plugin/scripts/marina.sh` — extract `registry_infer`; `registry_add` reuses it; add `infer` to the registry CLI dispatch.
- **Modify** `plugin/scripts/marina-entrypoint.sh` — add `infer` to the delegated registry commands.
- **Create** `plugin/commands/register.md`, `plugin/commands/ls.md`.
- **Create** `plugin/tests/test-infer.sh`.
- **Modify** `README.md` — "Getting started / first run" + install-cli + slash + cross-platform auto-restart.

---

### Task 1: `marina.sh infer` (no-write inference, shared by `add`)

**Files:** Modify `plugin/scripts/marina.sh`; Modify `plugin/scripts/marina-entrypoint.sh`; Test `plugin/tests/test-infer.sh`.

- [ ] **Step 1: Write the failing test** `plugin/tests/test-infer.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P/frontend/.git" "$P/backend/.git" "$P/docs"

out="$(bash "$SH" infer "$P")"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["subrepos"]==["backend","frontend"],d; assert d["id"]=="proj",d' \
  || { echo "FAIL: infer json wrong: $out"; exit 1; }
[[ ! -f "$MARINA_HOME/projects.json" ]] || { echo "FAIL: infer wrote projects.json"; exit 1; }

M="$TMP/mono"; mkdir -p "$M/src"
out="$(bash "$SH" infer "$M")"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["subrepos"]==[],d' \
  || { echo "FAIL: mono subrepos not empty: $out"; exit 1; }
echo "PASS test-infer"
```

- [ ] **Step 2: Run → FAIL** (`bash plugin/tests/test-infer.sh`): expect `marina.sh` to reject `infer` (unknown → falls through to launcher context / error).

- [ ] **Step 3: Implement.** In `marina.sh`, add `registry_infer` (the inference currently inline in `registry_add`, but printing instead of writing) and make `registry_add` consume it:
```bash
registry_infer() {
  local path="${1:-}"
  [[ -n "$path" ]] || die "usage: marina.sh infer <project-path>"
  [[ -d "$path" ]] || die "디렉토리 없음: $path"
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  local abs; abs="$(cd "$path" && pwd -P)" || die "경로 해석 실패: $path"
  python3 - "$abs" <<'PY'
import json, os, sys
root = sys.argv[1]
subrepos = sorted(
    n for n in os.listdir(root)
    if not n.startswith(".")
    and os.path.isdir(os.path.join(root, n))
    and os.path.isdir(os.path.join(root, n, ".git"))
)
globs = [".claude/worktrees/*"]
base = os.path.basename(root)
if os.path.isdir(os.path.expanduser("~/.codex/worktrees")):
    globs.append(f"~/.codex/worktrees/*/{base}")
print(json.dumps({"id": base, "root": root, "subrepos": subrepos, "worktreeGlobs": globs}, ensure_ascii=False))
PY
}
```
Replace `registry_add`'s body with:
```bash
registry_add() {
  local entry; entry="$(registry_infer "${1:-}")" || exit $?
  mkdir -p "$MARINA_HOME"
  python3 - "$PROJECTS_FILE" "$entry" <<'PY'
import json, os, sys
projects_file, entry = sys.argv[1], json.loads(sys.argv[2])
try:
    data = json.load(open(projects_file, encoding="utf-8"))
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}
norm = lambda p: os.path.realpath(os.path.expanduser(p))
projects = [p for p in data.get("projects", []) if norm(p.get("root","")) != norm(entry["root"])]
projects.append(entry)
data["projects"] = projects
data.setdefault("schemaVersion", 1)
json.dump(data, open(projects_file, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"added: {entry['id']}  root={entry['root']}")
print(f"  subrepos: {', '.join(entry['subrepos']) or '(none)'}")
print(f"  worktreeGlobs: {', '.join(entry['worktreeGlobs'])}")
PY
}
```
Add `infer` to `marina.sh`'s registry dispatch (the `case "${1:-}" in add) ... esac` near line 112):
```bash
  infer)       shift; registry_infer "$@"; exit $? ;;
```
In `marina-entrypoint.sh`, add `infer` to the delegated set: `add|infer|rm|ls|projects)`.

- [ ] **Step 4: Run → PASS** (`bash plugin/tests/test-infer.sh` → `PASS test-infer`). Also run `test-install-cli.sh` (it shells the entrypoint) to confirm no regression, and `bash -n` both scripts.

- [ ] **Step 5: Commit** `feat(plugin): add marina infer (no-write inference shared with add)`.

---

### Task 2: Slash commands `/marina:register`, `/marina:ls`

**Files:** Create `plugin/commands/register.md`, `plugin/commands/ls.md`.

- [ ] **Step 1: Create `plugin/commands/register.md`:**
```markdown
---
description: Register the current project with marina so its worktrees auto-attach
allowed-tools: Bash
---
Register the current git project with marina (infers subrepos + worktree globs). Run exactly this and report the result:

```bash
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "not a git repository — cd into your project first"; exit 1; }
"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" add "$(dirname "$common")"
```

This resolves the main checkout (even if run from a worktree) and registers it. Confirm the printed project id and inferred subrepos look right; if a subrepo is missing or extra, tell the user they can re-run after fixing, or edit `~/.marina/projects.json`.
```

- [ ] **Step 2: Create `plugin/commands/ls.md`:**
```markdown
---
description: List the projects registered with marina
allowed-tools: Bash
---
Show marina's registered projects. Run this and present the output:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" ls
```
```

- [ ] **Step 3: Verify the embedded bash is correct** (the slash invocation itself is agent-driven, not unit-testable). Standalone-check the resolution + entrypoint call against this repo's scripts: from a worktree and from a main checkout, `dirname "$(git rev-parse --path-format=absolute --git-common-dir)"` must equal the main repo root; and `<scripts>/marina-entrypoint.sh ls` must run. Record both outputs.

- [ ] **Step 4: Commit** `feat(plugin): add /marina:register and /marina:ls slash commands`.

---

### Task 3: README — first-run + surfaces

**Files:** Modify `README.md`.

- [ ] **Step 1:** Add a "Getting started / first run" section near the top (after 설치) stating plainly: installing the plugin registers the SessionStart hook, but **it attaches nothing until you register a project once**. Show the one-time step three ways: `/marina:register` (in a Claude session), `marina add <path>` (terminal — after `marina install-cli`), and (coming) the dashboard. Document `marina install-cli` / `uninstall-cli` and the opt-in self-resolving shim. Update the auto-restart note to mention the cross-platform behavior (launchd on macOS, systemd-user + linger on Linux, nohup fallback with a warning). Keep the README's existing Korean style.

- [ ] **Step 2:** Re-read for accuracy against the shipped commands (`add`/`infer`/`rm`/`ls`/`install-cli`/`dashboard`). No placeholders.

- [ ] **Step 3: Commit** `docs: document first-run registration, install-cli, and cross-platform auto-restart`.

---

## Final
- [ ] Run `test-infer.sh`, `test-install-cli.sh`, `test-resolve.sh`, `test-dashboard-launch.sh` — all PASS.
- [ ] Final review of the diff, then offer publish (separate user gate — do not push without an explicit ask).

## Self-Review
- Spec coverage: infer (component 1) = Task 1; slash (component 2) = Task 2; README (component 6) = Task 3. Dashboard API/UI (4/5) explicitly deferred to phase 3.
- No placeholders: all code and command files are concrete; the slash format is the claude-code-guide-verified `${CLAUDE_PLUGIN_ROOT}` substitution.
- Consistency: `registry_infer` is the single inference; `registry_add` and `infer` both use it; the dashboard API (phase 3) will shell `marina.sh infer`.
