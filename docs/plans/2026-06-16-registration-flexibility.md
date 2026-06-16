# Registration Flexibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make explicit registration handle arbitrary layouts — nested projects resolve to the most-specific one (longest-prefix), a directory picker replaces path copy-paste, and subrepos beyond the auto-inferred depth-1 set can be added manually (slash paths allowed).

**Architecture:** Three independent slices on the existing dashboard. (1) Replace first-match prefix resolution with longest-prefix at the 4 project-*selecting* functions (the hook's `is_registered` is a boolean gate — unaffected). (2) A read-only `GET /api/browse` lists subdirectories; a modal browse panel consumes it. (3) The register/edit modal gains a manual-subrepo input, and the edit checklist becomes `union(infer, registered)`.

**Tech Stack:** Bash + Python 3 stdlib (`http.server`), vanilla JS/CSS embedded in `marina-control.py`'s `INDEX_HTML`. Tests are bash + `curl` + `python3 -c` (UI verified on the marina preview).

**Spec:** `docs/specs/2026-06-16-registration-flexibility-design.md`

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `plugin/scripts/marina-control.py` | dashboard server + UI | `project_for` longest-prefix; `GET /api/browse`; modal browse panel + manual-subrepo + edit union |
| `plugin/scripts/attach-detached-subrepos.sh` | worktree attach | longest-prefix in `registry_subrepos_for` + `registry_source_root_for` |
| `plugin/scripts/marina.sh` | launcher + registry CLI | longest-prefix in `registry_subrepos_for` |
| `plugin/tests/test-nested-project-resolution.sh` | new | child-under-parent resolves to child (via `/api/worktrees`) |
| `plugin/tests/test-browse-api.sh` | new | `/api/browse` lists subdirs, flags git repos, hides dotfiles |

**Verification model:** Tasks 1–2 are TDD (bash tests). Tasks 3–4 are UI, verified on the preview (`MARINA_CONTROL_PORT=3901`). Re-grep anchors before editing — `INDEX_HTML` is one large string.

**The longest-prefix transform** (applied identically everywhere): a loop that `break`s on the first project whose root is a prefix of `target` becomes a loop that keeps the project with the **longest** matching root. Drop the `break`; track `best`/`best_len`.

---

## Task 1: Longest-prefix project resolution

**Files:**
- Test: `plugin/tests/test-nested-project-resolution.sh` (create)
- Modify: `marina-control.py` `project_for` (~`:183-196`); `attach-detached-subrepos.sh` (`:41-44`, `:73-76`); `marina.sh` (`:150-153`)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-nested-project-resolution.sh`:

```bash
#!/usr/bin/env bash
# 중첩 등록: 부모(parent) 아래 자식(parent/sub)도 등록되면, sub 의 root 는 sub 로 귀속돼야 한다
# (first-match 면 parent 로 잘못 귀속 — startswith 가 parent 에 먼저 걸림).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39713
base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")

PARENT="$TMP/parent"; SUB="$PARENT/sub"
mkdir -p "$SUB"
git -C "$PARENT" init -q; git -C "$SUB" init -q
bash "$SH" add "$PARENT" >/dev/null
bash "$SH" add "$SUB" >/dev/null

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" "$base/api/worktrees" | python3 -c "
import json, sys, os
d = json.load(sys.stdin)
by = {os.path.basename(w['root']): w['projectId'] for w in d['worktrees']}
assert by.get('sub') == 'sub', by      # 자식이 자식으로 귀속 (first-match 면 'parent')
assert by.get('parent') == 'parent', by
" || { echo 'FAIL: nested resolution'; exit 1; }

echo "PASS test-nested-project-resolution"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-nested-project-resolution.sh`
Expected: FAIL — `by.get('sub')` is `'parent'` (first-match attributes `parent/sub` to `parent`).

- [ ] **Step 3: Fix `project_for` (control.py) to longest-prefix**

In `marina-control.py`, replace the first-match loop in `project_for`:

```python
    for project in projects:
        proot = project["root"].resolve()
        if rroot == proot or str(rroot).startswith(str(proot) + os.sep):
            return project
```
with:
```python
    best = None
    best_len = -1
    for project in projects:
        proot = project["root"].resolve()
        sproot = str(proot)
        if rroot == proot or str(rroot).startswith(sproot + os.sep):
            if len(sproot) > best_len:
                best, best_len = project, len(sproot)
    if best is not None:
        return best
```

(Leave the codex-layout basename match and the `len(projects) == 1` fallback below it unchanged — they apply only when no prefix matched.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-nested-project-resolution.sh`
Expected: `PASS test-nested-project-resolution`

- [ ] **Step 5: Apply the same transform to the bash resolution sites**

The attach script and `marina.sh` resolve a *specific* project from a path the same way. In `attach-detached-subrepos.sh`, in **both** `registry_subrepos_for` and `registry_source_root_for`, replace:

```python
match = None
for p in projects:
    pr = norm(p)
    if root == pr or root.startswith(pr + os.sep):
        match = p; break
```
with:
```python
match = None
best_len = -1
for p in projects:
    pr = norm(p)
    if root == pr or root.startswith(pr + os.sep):
        if len(pr) > best_len:
            match = p; best_len = len(pr)
```

In `marina.sh`, in `registry_subrepos_for`, make the identical replacement (same four-line `for` block → the longest-prefix version above).

> The SessionStart hook's `is_registered` is a boolean membership gate ("registered if ANY registered root is a prefix") — first-vs-longest yields the same yes/no, so it needs no change. The fix lives only in the functions that *select* a project.

- [ ] **Step 6: Smoke-verify the bash sites resolve the child**

The attach script prints the resolved source. Run it against the child with no `SOURCE_ROOT`/`MARINA_SUBREPOS` env so it resolves from the registry:

Run:
```bash
cd ~/IdeaProjects/sumin/marina
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
P="$TMP/parent"; S="$P/sub"; mkdir -p "$S"; git -C "$P" init -q; git -C "$S" init -q
bash plugin/scripts/marina.sh add "$P" >/dev/null
bash plugin/scripts/marina.sh add "$S" >/dev/null
DEST_ROOT="$S" SYNC_IDEA=false bash plugin/scripts/attach-detached-subrepos.sh 2>&1 | grep -E "^source:"
rm -rf "$TMP"
```
Expected: `source:   <.../parent/sub>` (the child), NOT `.../parent`. (With first-match it would print `.../parent`.)

- [ ] **Step 7: Commit**

```bash
cd ~/IdeaProjects/sumin/marina
git add plugin/scripts/marina-control.py plugin/scripts/attach-detached-subrepos.sh plugin/scripts/marina.sh plugin/tests/test-nested-project-resolution.sh
git commit -m "fix(plugin): longest-prefix project resolution — nested projects attribute to the most-specific root"
```

---

## Task 2: `GET /api/browse` directory listing

**Files:**
- Test: `plugin/tests/test-browse-api.sh` (create)
- Modify: `marina-control.py` `do_GET` (add a route alongside the others, e.g. after the `/api/worktrees` block)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-browse-api.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39714
base="http://127.0.0.1:$PORT"; hdr=(-H "Origin: http://127.0.0.1:$PORT")

B="$TMP/browse"; mkdir -p "$B/alpha/.git" "$B/beta" "$B/.hidden"
touch "$B/afile.txt"

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

curl -s "${hdr[@]}" "$base/api/browse?path=$B" | python3 -c "
import json, sys
d = json.load(sys.stdin)
names = {e['name']: e for e in d['entries']}
assert set(names) == {'alpha', 'beta'}, names    # 디렉토리만, dotfile·파일 제외
assert names['alpha']['isGitRepo'] is True, names # .git 있으면 표시
assert names['beta']['isGitRepo'] is False, names
assert d['parent'], d                              # 상위로 올라갈 경로 제공
" || { echo 'FAIL: browse'; exit 1; }

# bad path → 4xx
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "$base/api/browse?path=$B/afile.txt")"
[[ "$code" == 4* ]] || { echo "FAIL: browse non-dir expected 4xx, got $code"; exit 1; }

echo "PASS test-browse-api"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-browse-api.sh`
Expected: FAIL — `/api/browse` returns 404, JSON parse / assert fails.

- [ ] **Step 3: Add the `/api/browse` route**

In `marina-control.py` `do_GET`, after the `if parsed.path == "/api/worktrees":` block's `return`, add:

```python
            if parsed.path == "/api/browse":
                query = urllib.parse.parse_qs(parsed.query)
                raw = query.get("path", [""])[0]
                try:
                    base = (Path(raw).expanduser() if raw else Path.home()).resolve()
                    if not base.is_dir():
                        raise ValueError(f"디렉토리 아님: {raw or '~'}")
                    entries = []
                    for child in sorted(base.iterdir(), key=lambda p: p.name.lower()):
                        if child.name.startswith("."):
                            continue
                        try:
                            if not child.is_dir():
                                continue
                        except OSError:
                            continue
                        entries.append({
                            "name": child.name,
                            "isDir": True,
                            "isGitRepo": (child / ".git").exists(),
                        })
                    parent = str(base.parent) if base.parent != base else None
                    self.send_json({"path": str(base), "parent": parent, "entries": entries})
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
```

(The shared `/api/` origin gate above this in `do_GET` already restricts it to the dashboard's own port.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-browse-api.sh`
Expected: `PASS test-browse-api`

- [ ] **Step 5: Commit**

```bash
cd ~/IdeaProjects/sumin/marina
git add plugin/scripts/marina-control.py plugin/tests/test-browse-api.sh
git commit -m "feat(plugin): GET /api/browse — read-only subdirectory listing for the register dir picker"
```

---

## Task 3: Directory picker in the register modal (UI)

**Files:**
- Modify `marina-control.py` `INDEX_HTML`: modal markup (`registerPath` row), CSS, JS. Preview-verified.

- [ ] **Step 1: Add the browse button + panel markup**

Replace the path row + error line in the modal:

```html
      <div class="register-path-row">
        <input id="registerPath" class="register-input" placeholder="~/path/to/project" />
        <button id="registerInfer">분석</button>
      </div>
      <div class="register-error" id="registerError" hidden></div>
```
with:
```html
      <div class="register-path-row">
        <input id="registerPath" class="register-input" placeholder="~/path/to/project" />
        <button id="registerBrowse" title="폴더 탐색">찾아보기</button>
        <button id="registerInfer">분석</button>
      </div>
      <div class="register-error" id="registerError" hidden></div>
      <div class="browse-panel" id="browsePanel" hidden>
        <div class="browse-bar"><span class="browse-path" id="browsePath"></span><button id="browseSelect" title="이 폴더 선택">이 폴더 선택</button></div>
        <div class="browse-list" id="browseList"></div>
      </div>
```

- [ ] **Step 2: Add browse-panel CSS**

After the `.register-confirm` rule, add:

```css
    .browse-panel { display: flex; flex-direction: column; gap: 6px; max-height: 40vh; border: 1px solid var(--sys-style-neutral-default); border-radius: 8px; padding: 8px; }
    .browse-bar { display: flex; align-items: center; gap: 6px; }
    .browse-path { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; color: var(--sys-cont-neutral-light); }
    .browse-bar button { height: 26px; padding: 0 10px; border: 1px solid var(--sys-cont-primary-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-primary-default); }
    .browse-list { overflow-y: auto; display: flex; flex-direction: column; }
    .browse-row { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 6px; cursor: pointer; font-size: 13px; color: var(--sys-cont-neutral-default); }
    .browse-row:hover { background: var(--sys-bg-surface-hover); }
    .browse-row .repo-badge { margin-left: auto; font-size: 11px; color: var(--sys-cont-primary-default); }
```

- [ ] **Step 3: Add the browse JS**

After the `registerClose`/backdrop close handlers, add:

```javascript
    let browseCurrent = '';
    async function openBrowse(path) {
      const panel = document.getElementById('browsePanel');
      try {
        const data = await api('/api/browse' + (path ? ('?path=' + enc(path)) : ''));
        browseCurrent = data.path;
        document.getElementById('browsePath').textContent = data.path;
        const list = document.getElementById('browseList');
        list.innerHTML = '';
        if (data.parent) {
          const up = document.createElement('div');
          up.className = 'browse-row'; up.innerHTML = '<span>📁 ..</span>';
          up.onclick = () => openBrowse(data.parent);
          list.appendChild(up);
        }
        for (const e of data.entries) {
          const row = document.createElement('div');
          row.className = 'browse-row';
          row.innerHTML = `<span>📁 ${escapeHtml(e.name)}</span>${e.isGitRepo ? '<span class="repo-badge">git</span>' : ''}`;
          row.onclick = () => openBrowse(data.path.replace(/\/$/, '') + '/' + e.name);
          list.appendChild(row);
        }
        panel.hidden = false;
      } catch (err) {
        const el = document.getElementById('registerError');
        el.textContent = String(err.message || err); el.hidden = false;
      }
    }
    document.getElementById('registerBrowse').onclick = () => {
      const cur = document.getElementById('registerPath').value.trim();
      openBrowse(cur || '');
    };
    document.getElementById('browseSelect').onclick = () => {
      document.getElementById('registerPath').value = browseCurrent;
      document.getElementById('browsePanel').hidden = true;
    };
```

In `openRegisterPanel` and `openSubrepoEdit`, hide the panel on open — add `document.getElementById('browsePanel').hidden = true;` next to the existing `registerPreview.hidden = true;` line in each.

- [ ] **Step 4: Verify in the preview**

Run:
```bash
cd ~/IdeaProjects/sumin/marina
python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read()); print('py OK')"
MARINA_CONTROL_PORT=3901 MARINA_CONTROL_HOST=127.0.0.1 python3 plugin/scripts/marina-control.py >/tmp/mp.log 2>&1 &
echo $! > /tmp/mp.pid; sleep 1.5
```
Open `http://localhost:3901` → switcher → `+ 프로젝트 등록` → **찾아보기**. Expected: a panel listing your home folder's subdirectories (📁), git repos badged `git`, `..` to go up, clicking a folder descends, **이 폴더 선택** fills the path input. Then **분석** runs infer as before. Stop: `kill $(cat /tmp/mp.pid)`.

- [ ] **Step 5: Commit**

```bash
cd ~/IdeaProjects/sumin/marina
git add plugin/scripts/marina-control.py
git commit -m "feat(plugin): directory picker in the register modal (browse instead of path paste)"
```

---

## Task 4: Manual subrepo entry + edit union (UI)

**Files:**
- Modify `marina-control.py` `INDEX_HTML`: checklist markup, CSS, JS (`renderChecklist`, manual-add, `inferAndPreview` union for edit).

- [ ] **Step 1: Add the manual-add row markup**

In the modal's `registerPreview`, after the `registerChecklist` div, add a manual-add row:

```html
        <div class="register-checklist" id="registerChecklist"></div>
        <div class="register-manual">
          <input id="registerManualPath" class="register-input" placeholder="추가 subrepo 상대경로 (예: projects/react-skeleton)" />
          <button id="registerManualAdd">+ 추가</button>
        </div>
        <button id="registerConfirm" class="register-confirm">등록</button>
```

CSS — after `.register-confirm`:
```css
    .register-manual { display: flex; gap: 6px; }
    .register-manual button { height: 30px; padding: 0 12px; border: 1px solid var(--sys-cont-primary-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-primary-default); }
```

- [ ] **Step 2: Manual-add appends a checked row; reuse a single checklist-row helper**

Replace `renderChecklist` so rows are built by a reusable `addChecklistRow`, then wire the manual-add button. Replace the existing `renderChecklist` function:

```javascript
    function addChecklistRow(name, checked) {
      const box = document.getElementById('registerChecklist');
      if ([...box.querySelectorAll('input')].some(c => c.value === name)) return; // dedupe
      const empty = box.querySelector('.register-empty'); if (empty) empty.remove();
      const row = document.createElement('label');
      row.className = 'register-check';
      const cb = document.createElement('input');
      cb.type = 'checkbox'; cb.value = name; cb.checked = checked;
      row.appendChild(cb);
      row.appendChild(document.createTextNode(name));
      box.appendChild(row);
    }
    function renderChecklist(universe, checked) {
      const box = document.getElementById('registerChecklist');
      box.innerHTML = '';
      if (!universe.length && !checked.length) {
        box.innerHTML = '<div class="register-empty">monorepo (subrepos 없음) — 필요하면 아래에 직접 추가</div>';
        return;
      }
      for (const name of universe) addChecklistRow(name, checked.includes(name));
    }
    document.getElementById('registerManualAdd').onclick = () => {
      const input = document.getElementById('registerManualPath');
      const name = input.value.trim().replace(/^\/+|\/+$/g, '');
      const err = document.getElementById('registerError');
      if (!name) return;
      if (name.startsWith('/') || name.split('/').includes('..')) {
        err.textContent = '프로젝트 root 상대경로만 (선행 / 또는 .. 불가)'; err.hidden = false; return;
      }
      err.hidden = true;
      addChecklistRow(name, true);
      input.value = '';
    };
```

(`registerConfirm` already collects `#registerChecklist input:checked` — manual rows flow through unchanged.)

- [ ] **Step 3: Edit checklist = union(infer, registered)**

So a previously manual/deep subrepo stays visible+checked on edit. In `inferAndPreview`, after computing `universe`, merge in any `checkedDefault` names not present:

Replace:
```javascript
        const universe = info.subrepos || [];
        renderChecklist(universe, checkedDefault === null ? universe : checkedDefault);
```
with:
```javascript
        const inferred = info.subrepos || [];
        const checked = checkedDefault === null ? inferred : checkedDefault;
        // edit: 등록돼 있지만 infer 가 못 잡은(깊은/수동) subrepo 도 universe 에 포함 → 체크된 채 보이게
        const universe = [...inferred, ...checked.filter(n => !inferred.includes(n))];
        renderChecklist(universe, checked);
```

- [ ] **Step 4: Verify in the preview**

Run (reuse Task 3's preview launch, or restart):
```bash
cd ~/IdeaProjects/sumin/marina
python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read()); print('py OK')"
kill "$(cat /tmp/mp.pid 2>/dev/null)" 2>/dev/null; sleep 0.5
MARINA_CONTROL_PORT=3901 MARINA_CONTROL_HOST=127.0.0.1 python3 plugin/scripts/marina-control.py >/tmp/mp.log 2>&1 &
echo $! > /tmp/mp.pid; sleep 1.5
mkdir -p /tmp/manual-fix/projects/react-skeleton/.git
```
In `http://localhost:3901`: `+ 프로젝트 등록` → path `/tmp/manual-fix` → **분석** → checklist empty (no depth-1 repo) → type `projects/react-skeleton` in the manual input → **+ 추가** → a checked row appears → **등록** → `bash plugin/scripts/marina.sh ls` shows `manual-fix` with `subrepos: projects/react-skeleton`. Then switcher → `⚙` on `manual-fix` → the edit checklist shows `projects/react-skeleton` **checked** (union keeps it though infer misses it). Cleanup: `bash plugin/scripts/marina.sh rm manual-fix && rm -rf /tmp/manual-fix; kill $(cat /tmp/mp.pid)`.

- [ ] **Step 5: Full regression + commit**

Run: `for t in plugin/tests/test-*.sh; do bash "$t" >/dev/null 2>&1 && echo "✓ $(basename $t)" || echo "✗ $(basename $t)"; done`
Expected: all `✓` (incl. `test-nested-project-resolution`, `test-browse-api`).

```bash
cd ~/IdeaProjects/sumin/marina
git add plugin/scripts/marina-control.py
git commit -m "feat(plugin): manual subrepo entry + edit checklist union(infer, registered)"
```

---

## Self-Review

**1. Spec coverage:**
- Design A (longest-prefix, 4 selecting sites; hook excluded) → Task 1.
- Design B (`/api/browse` + modal picker) → Tasks 2–3.
- Design C (manual subrepo, slash allowed; edit union) → Task 4.
- Error handling: browse non-dir → 4xx (Task 2 test); manual leading-`/`/`..` → inline reject (Task 4 Step 2); not-a-repo allowed (manual-add never blocks on repo status).

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". The hook-exclusion is stated explicitly (Task 1 Step 5 note) rather than left ambiguous. Every code step shows complete code.

**3. Type/name consistency:** `addChecklistRow`/`renderChecklist`/`inferAndPreview`/`openBrowse`/`browseCurrent` defined once and reused. `/api/browse` response keys (`path`/`parent`/`entries`/`name`/`isDir`/`isGitRepo`) match between Task 2 (server) and Task 3 (client). The longest-prefix `best`/`best_len` transform is identical across control.py + the two bash files.

**Out of scope (not implemented):** auto-registration, custom project id, file (non-dir) selection, remote fs.

## Execution Handoff

Plan saved to `docs/plans/2026-06-16-registration-flexibility.md`. Tasks 1–2 are TDD (bash tests); Tasks 3–4 are UI verified on the `MARINA_CONTROL_PORT=3901` preview. Dependencies: Task 3 needs Task 2's endpoint; otherwise independent. Execute in order with a verification checkpoint after each.
