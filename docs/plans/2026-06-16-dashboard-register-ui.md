# Dashboard project switcher + registration UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the all-projects-stacked sidebar with a vertical project switcher (one project scoped at a time), add in-dashboard registration with an editable subrepo checklist, and add a `marina.sh add --subrepos` flag so the same curation works from the CLI.

**Architecture:** `marina.sh` stays the single write SoT for the registry (`add [--subrepos]` / `rm`); `registry_infer` stays the read-only inference SoT. `marina-control.py` gains three thin `do_POST` endpoints that shell out to `marina.sh` (never writes `projects.json` directly), plus a switcher/scoped-view/register-panel UI in the embedded `INDEX_HTML`. The dashboard always sends an explicit `--subrepos` set (possibly empty); the CLI omits it to infer all.

**Tech Stack:** Bash + Python 3 stdlib (`http.server`), vanilla JS/CSS embedded as a string literal in `marina-control.py`. Tests are bash + `curl` + `python3 -c` assertions (no JS test runner — UI verified via the marina preview server).

**Source spec:** `docs/specs/2026-06-16-dashboard-register-ui-design.md`

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `plugin/scripts/marina.sh` | registry CLI (`add`/`infer`/`rm`/`ls`) + worktree launcher | `registry_add` parses optional `--subrepos`; `usage()` documents it |
| `plugin/scripts/marina-control.py` | dashboard server + embedded UI | `run_marina_registry()` + `invalidate_registry_caches()` helpers; 3 `do_POST` endpoints; switcher + scoped render + register panel + subrepos-edit + remove in `INDEX_HTML` |
| `plugin/tests/test-add-subrepos.sh` | new | marina.sh `add --subrepos` behavior (absent=infer, set=verbatim, empty=`[]`, upsert) |
| `plugin/tests/test-registry-api.sh` | new | the 3 endpoints against a live server on `CONTROL_PORT` |

**Verification model:** Tasks 1–2 are TDD (bash tests). Tasks 3–5 are UI; they are verified by running the dashboard on the preview port and exercising it in the browser (the repo has no JS unit harness — the spec calls for "UI smoke via the marina preview"). Each UI task ends with an explicit preview-verification step with concrete expected observations.

**Anchors (current line numbers, re-grep before editing — the file is one large string):**
- `registry_add()` — `marina.sh:49`; `usage()` add line — `marina.sh:296`
- `do_POST` — `marina-control.py:3334`; insert new endpoints after the `kill-orphans` block (`:3350`), BEFORE `root = safe_root(...)` (`:3352`)
- helper insertion point — after `run_marina()` (`marina-control.py:652`)
- cache globals — `_projects_cache:94`, `_root_sources:223`, `_roots_cache:224`, `_session_id_cache:302`, `_source_root_cache` (cleared at `:238`), `_worktree_info_cache:1297`
- `.sessions-bar` markup — `marina-control.py:1828`; CSS — `:1658`
- `.project-group` CSS — `marina-control.py:1701-1704`
- JS state block — `marina-control.py:1871-1886`
- `loadWorktrees` — `:2016`; `render()` — `:2680`; project-group injection to remove — `:2692-2699`
- rail toggle (localStorage pattern reference) — `:3034`; init calls — `:3202-3208`

---

## Task 1: marina.sh — `add [--subrepos a,b,c]` flag

**Files:**
- Test: `plugin/tests/test-add-subrepos.sh` (create)
- Modify: `plugin/scripts/marina.sh:49-70` (`registry_add`) and `:296` (`usage()` `add` line)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-add-subrepos.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P/frontend/.git" "$P/backend/.git" "$P/extra/.git" "$P/docs"
reg="$MARINA_HOME/projects.json"

# no flag → infer all (sorted)
bash "$SH" add "$P" >/dev/null
python3 -c "import json; p=json.load(open('$reg'))['projects'][0]; assert p['subrepos']==['backend','extra','frontend'],p" \
  || { echo "FAIL: add without flag should infer all"; exit 1; }

# --subrepos curated subset + upsert (still one project)
bash "$SH" add "$P" --subrepos backend,frontend >/dev/null
python3 -c "import json; d=json.load(open('$reg')); assert len(d['projects'])==1,d; assert d['projects'][0]['subrepos']==['backend','frontend'],d['projects'][0]" \
  || { echo "FAIL: --subrepos curated set / upsert"; exit 1; }

# --subrepos "" explicit empty (monorepo)
bash "$SH" add "$P" --subrepos "" >/dev/null
python3 -c "import json; assert json.load(open('$reg'))['projects'][0]['subrepos']==[]" \
  || { echo "FAIL: --subrepos empty should record []"; exit 1; }

# whitespace + stray names tolerated (trimmed, blanks dropped)
bash "$SH" add "$P" --subrepos " backend , frontend ," >/dev/null
python3 -c "import json; assert json.load(open('$reg'))['projects'][0]['subrepos']==['backend','frontend']" \
  || { echo "FAIL: --subrepos should trim and drop blanks"; exit 1; }

echo "PASS test-add-subrepos"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-add-subrepos.sh`
Expected: FAIL — current `registry_add` ignores extra args, so `--subrepos backend,frontend` is dropped and `subrepos` stays the inferred `['backend','extra','frontend']` → "FAIL: --subrepos curated set / upsert".

- [ ] **Step 3: Implement the flag in `registry_add`**

Replace `registry_add()` (`marina.sh:49-70`) with:

```bash
registry_add() {
  local path="" subrepos_csv="" have_subrepos=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subrepos)
        have_subrepos=1
        if [[ $# -ge 2 ]]; then subrepos_csv="$2"; shift 2; else subrepos_csv=""; shift; fi
        ;;
      --subrepos=*)
        have_subrepos=1; subrepos_csv="${1#--subrepos=}"; shift ;;
      *)
        [[ -z "$path" ]] || die "add: 인자 과다 ('$1')"
        path="$1"; shift ;;
    esac
  done
  local entry; entry="$(registry_infer "$path")" || exit $?
  mkdir -p "$MARINA_HOME"
  python3 - "$PROJECTS_FILE" "$entry" "$have_subrepos" "$subrepos_csv" <<'PY'
import json, os, sys
projects_file, entry = sys.argv[1], json.loads(sys.argv[2])
have_subrepos, subrepos_csv = sys.argv[3] == "1", sys.argv[4]
# 플래그 존재 시 추론 대신 명시 집합(빈 값이면 []=모노레포). 부재 시 추론 그대로.
if have_subrepos:
    entry["subrepos"] = [s for s in (x.strip() for x in subrepos_csv.split(",")) if s]
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

Note: `registry_infer` already `die`s on a missing/non-dir path, so an empty `path` (e.g. only `--subrepos` given) fails there with the existing usage error — no extra guard needed.

- [ ] **Step 4: Document the flag in `usage()`**

In `usage()` (`marina.sh:296`), change the `add` line:

```
    marina.sh add <project-path>     # 서브레포·worktreeGlobs 자동 추론 후 등록
```
to:
```
    marina.sh add <project-path> [--subrepos a,b,c]   # 등록. --subrepos 생략=자동 추론, 명시=정확히 그 집합(빈 값=모노레포)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash plugin/tests/test-add-subrepos.sh`
Expected: `PASS test-add-subrepos`

Also re-run the inference test to confirm no regression:
Run: `bash plugin/tests/test-infer.sh`
Expected: `PASS test-infer`

- [ ] **Step 6: Commit**

```bash
cd ~/IdeaProjects/sumin/marina
git add plugin/scripts/marina.sh plugin/tests/test-add-subrepos.sh
git commit -m "feat(plugin): marina.sh add --subrepos curates the recorded set"
```

---

## Task 2: control.py — registry shell-out helpers + 3 POST endpoints

**Files:**
- Test: `plugin/tests/test-registry-api.sh` (create)
- Modify: `plugin/scripts/marina-control.py` — add helpers after `run_marina()` (`:652`); add endpoints in `do_POST` after the `kill-orphans` block (`:3350`)

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-registry-api.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"
SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39711
P="$TMP/proj"; mkdir -p "$P/frontend/.git" "$P/backend/.git" "$P/docs"
reg="$MARINA_HOME/projects.json"
base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# infer-project — returns universe, writes nothing
out="$(curl -s "${hdr[@]}" -d "{\"path\":\"$P\"}" "$base/api/infer-project")"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["subrepos"]==["backend","frontend"],d; assert d["id"]=="proj",d' \
  || { echo "FAIL: infer-project json: $out"; exit 1; }
[[ ! -f "$reg" ]] || { echo "FAIL: infer-project wrote registry"; exit 1; }

# add-project — curated subset
curl -s "${hdr[@]}" -d "{\"path\":\"$P\",\"subrepos\":[\"frontend\"]}" "$base/api/add-project" >/dev/null
python3 -c "import json; p=json.load(open('$reg'))['projects'][0]; assert p['subrepos']==['frontend'],p" \
  || { echo "FAIL: add-project curated"; exit 1; }

# add-project — empty set upserts to monorepo
curl -s "${hdr[@]}" -d "{\"path\":\"$P\",\"subrepos\":[]}" "$base/api/add-project" >/dev/null
python3 -c "import json; d=json.load(open('$reg')); assert len(d['projects'])==1,d; assert d['projects'][0]['subrepos']==[],d" \
  || { echo "FAIL: add-project upsert empty"; exit 1; }

# remove-project
id="$(python3 -c "import json; print(json.load(open('$reg'))['projects'][0]['id'])")"
curl -s "${hdr[@]}" -d "{\"id\":\"$id\"}" "$base/api/remove-project" >/dev/null
python3 -c "import json; assert json.load(open('$reg'))['projects']==[]" \
  || { echo "FAIL: remove-project"; exit 1; }

# bad path → 4xx, no write
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -d "{\"path\":\"$TMP/nope\"}" "$base/api/add-project")"
[[ "$code" == 4* ]] || { echo "FAIL: add-project bad path expected 4xx, got $code"; exit 1; }

echo "PASS test-registry-api"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-registry-api.sh`
Expected: FAIL — the server returns 404 (`{"error":"not found"}`) for `/api/infer-project`, so the first assertion fails to parse / asserts.

- [ ] **Step 3: Add the helpers**

Insert after `run_marina()` (`marina-control.py:652`):

```python
def run_marina_registry(*args: str) -> str:
    # 레지스트리 CLI(add/infer/rm)는 위치 무관 — worktree ROOT/MARINA_SUBREPOS env 없이 전역 런처 호출.
    return subprocess.check_output(
        [str(MARINA_SCRIPT), *args],
        text=True,
        stderr=subprocess.STDOUT,
    )


def invalidate_registry_caches() -> None:
    # 레지스트리 변경(add/rm) 후 파생 캐시 무효화 — 다음 폴링/요청이 projects.json 을 재로드.
    _projects_cache.clear()
    _roots_cache.clear()
    _root_sources.clear()
    _source_root_cache.clear()
    _session_id_cache.clear()
    _worktree_info_cache.clear()
```

- [ ] **Step 4: Add the three endpoints**

In `do_POST` (`marina-control.py`), insert immediately after the `kill-orphans` block (after `:3350`, before `root = safe_root(...)` at `:3352`):

```python
            if self.path == "/api/infer-project":
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not str(target) or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                try:
                    out = run_marina_registry("infer", str(target))
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                self.send_json(json.loads(out.strip().splitlines()[-1]))
                return

            if self.path == "/api/add-project":
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not str(target) or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                subrepos = body.get("subrepos", [])
                if not isinstance(subrepos, list) or not all(isinstance(s, str) for s in subrepos):
                    raise ValueError("subrepos must be a list of strings")
                try:
                    out = run_marina_registry("add", str(target), "--subrepos", ",".join(subrepos))
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                self.send_json({"ok": True, "output": out.strip()})
                return

            if self.path == "/api/remove-project":
                pid = str(body.get("id", "")).strip()
                if not pid:
                    raise ValueError("id required")
                try:
                    out = run_marina_registry("rm", pid)
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                self.send_json({"ok": True, "output": out.strip()})
                return
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash plugin/tests/test-registry-api.sh`
Expected: `PASS test-registry-api`

- [ ] **Step 6: Commit**

```bash
cd ~/IdeaProjects/sumin/marina
git add plugin/scripts/marina-control.py plugin/tests/test-registry-api.sh
git commit -m "feat(plugin): dashboard infer/add/remove-project endpoints shell out to marina.sh"
```

---

## Task 3: control.py — project switcher + per-project scoped rendering

Replaces the multi-project `.project-group` stacking with a vertical switcher (status chips) that scopes the sidebar to one project at a time. UI only — verified via the preview server.

**Files:**
- Modify `marina-control.py`: `.sessions-bar` markup (`:1828`); CSS near `.sessions-bar`/`.project-group` (`:1658`/`:1701`); JS state (`:1886`); `render()` (`:2680-2699`).

- [ ] **Step 1: Add switcher markup to the sidebar header**

Replace the `.sessions-bar` div (`marina-control.py:1828`):

```html
      <div class="sessions-bar"><button id="collapseAll" title="세션 카드 전체 접기/펼치기">⇈</button></div>
```
with:

```html
      <div class="sessions-bar">
        <div class="switcher" id="switcher">
          <button id="switcherToggle" class="switcher-toggle" title="프로젝트 전환">
            <span id="switcherCurrent" class="switcher-current">프로젝트</span>
            <span class="switcher-chev">▾</span>
          </button>
          <div id="switcherMenu" class="switcher-menu" hidden></div>
        </div>
        <button id="collapseAll" title="세션 카드 전체 접기/펼치기">⇈</button>
      </div>
```

- [ ] **Step 2: Add switcher CSS**

Immediately after the `.sessions-bar button` rule (`marina-control.py:1659`), and change `.sessions-bar` justify from `flex-end` to `space-between`. Replace `:1658`:

```css
    .sessions-bar { display: flex; justify-content: flex-end; padding: 12px 14px 0; }
```
with:

```css
    .sessions-bar { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 12px 14px 0; }
    .switcher { position: relative; min-width: 0; flex: 1; }
    .switcher-toggle { display: flex; align-items: center; gap: 6px; width: 100%; height: 28px; padding: 0 8px; border: 1px solid var(--sys-style-neutral-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-neutral-default); }
    .switcher-toggle:hover { background: var(--sys-bg-surface-hover); }
    .switcher-current { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; font-weight: 700; }
    .switcher-chev { margin-left: auto; font-size: 10px; color: var(--sys-cont-neutral-light); }
    .switcher-menu { position: absolute; z-index: 50; top: 32px; left: 0; right: 0; max-height: 60vh; overflow-y: auto; padding: 4px; border: 1px solid var(--sys-style-neutral-default); border-radius: 10px; background: var(--sys-bg-surface); box-shadow: 0 6px 24px rgba(0,0,0,0.18); }
    .switcher-row { display: flex; align-items: center; gap: 6px; padding: 8px; border-radius: 8px; cursor: pointer; }
    .switcher-row:hover { background: var(--sys-bg-surface-hover); }
    .switcher-row.active { background: var(--sys-bg-surface-hover); }
    .switcher-row-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; font-weight: 600; color: var(--sys-cont-neutral-default); }
    .switcher-row-actions { display: none; gap: 2px; }
    .switcher-row:hover .switcher-row-actions { display: flex; }
    .switcher-row-actions button { width: 22px; height: 22px; padding: 0; font-size: 12px; color: var(--sys-cont-neutral-light); }
    .switcher-chip { font-size: 11px; padding: 1px 6px; border-radius: 999px; white-space: nowrap; }
    .switcher-chip.on { color: var(--sys-cont-primary-default); border: 1px solid var(--sys-cont-primary-default); }
    .switcher-chip.conflict { color: #c0392b; border: 1px solid #c0392b; }
    .switcher-chip.idle { color: var(--sys-cont-neutral-light); border: 1px solid var(--sys-style-neutral-default); }
    .switcher-register { width: 100%; margin-top: 4px; padding: 8px; border-top: 1px solid var(--sys-style-neutral-light); border-radius: 0 0 8px 8px; text-align: left; font-size: 13px; color: var(--sys-cont-primary-default); }
    .switcher-register:hover { background: var(--sys-bg-surface-hover); }
```

- [ ] **Step 3: Add switcher JS state + helpers**

After the `const expandedRoots = new Set();` line (`marina-control.py:1886`), add:

```javascript
    let selectedProjectId = localStorage.getItem('marinaSelectedProject') || null;
    let switcherOpen = false;

    function projectSummaries() {
      // worktreeData 가 모든 등록 프로젝트의 main 엔트리를 포함 → projectId 로 그룹.
      const byId = new Map();
      for (const wt of worktreeData) {
        if (!byId.has(wt.projectId)) {
          byId.set(wt.projectId, { id: wt.projectId, label: wt.projectLabel || wt.projectId, root: wt.projectRoot, on: 0, conflict: 0 });
        }
      }
      for (const s of sessions) {
        const wt = worktreeData.find(w => w.root === s.root);
        if (!wt) continue;
        const sum = byId.get(wt.projectId);
        if (!sum) continue;
        if ((s.services || []).some(svc => svc.running)) sum.on += 1;
        if ((s.webPortConflictWith || []).length) sum.conflict += 1;
      }
      return [...byId.values()];
    }

    function setSelectedProject(id) {
      selectedProjectId = id;
      if (id) localStorage.setItem('marinaSelectedProject', id);
      else localStorage.removeItem('marinaSelectedProject');
      switcherOpen = false;
      render();
    }

    function chipHtml(sum) {
      if (sum.conflict) return `<span class="switcher-chip conflict">${sum.conflict} 충돌</span>`;
      if (sum.on) return `<span class="switcher-chip on">${sum.on} ON</span>`;
      return '<span class="switcher-chip idle">idle</span>';
    }

    function renderSwitcher() {
      const summaries = projectSummaries();
      const current = summaries.find(s => s.id === selectedProjectId);
      document.getElementById('switcherCurrent').textContent = current ? current.label : (summaries.length ? '프로젝트 선택' : '등록된 프로젝트 없음');
      const menu = document.getElementById('switcherMenu');
      menu.hidden = !switcherOpen;
      if (!switcherOpen) return;
      menu.innerHTML = '';
      for (const sum of summaries) {
        const row = document.createElement('div');
        row.className = `switcher-row${sum.id === selectedProjectId ? ' active' : ''}`;
        row.innerHTML = `
          <span class="switcher-row-name" title="${escapeHtml(sum.root)}">${escapeHtml(sum.label)}</span>
          ${chipHtml(sum)}
          <span class="switcher-row-actions">
            <button data-edit-subrepos title="subrepos 편집">⚙</button>
            <button data-remove-project class="danger" title="프로젝트 등록 해제">✕</button>
          </span>`;
        row.querySelector('.switcher-row-name').onclick = () => setSelectedProject(sum.id);
        row.querySelector('[data-edit-subrepos]').onclick = (e) => { e.stopPropagation(); openSubrepoEdit(sum); };
        row.querySelector('[data-remove-project]').onclick = (e) => { e.stopPropagation(); removeProject(sum); };
        menu.appendChild(row);
      }
      const reg = document.createElement('button');
      reg.className = 'switcher-register';
      reg.textContent = '+ 프로젝트 등록';
      reg.onclick = () => openRegisterPanel();
      menu.appendChild(reg);
    }

    document.getElementById('switcherToggle').onclick = () => { switcherOpen = !switcherOpen; renderSwitcher(); };
    document.addEventListener('click', (e) => {
      if (switcherOpen && !e.target.closest('#switcher')) { switcherOpen = false; renderSwitcher(); }
    });
```

`openSubrepoEdit`, `removeProject`, `openRegisterPanel` are defined in Tasks 4–5. To keep this task runnable on its own, add temporary stubs right below the block above (they are REPLACED with real implementations in Tasks 4 and 5 — do not leave them):

```javascript
    function openRegisterPanel() { console.warn('register panel: Task 4'); }
    function openSubrepoEdit(sum) { console.warn('subrepos edit: Task 5'); }
    function removeProject(sum) { console.warn('remove project: Task 5'); }
```

- [ ] **Step 4: Scope `render()` to the selected project and drop group stacking**

In `render()` (`marina-control.py:2680`), after `const wtByRoot = new Map(...)` (`:2684`), replace the multi-project block (`:2685-2699`, the `const multiProject ...` line through the `for (const session of sessions) { ... seenProjects` group-header injection) so the loop iterates a scoped list and injects no group headers.

Replace:
```javascript
      const wtByRoot = new Map(worktreeData.map(w => [w.root, w]));
      // 멀티프로젝트면 프로젝트 그룹 헤더 (단일이면 생략 — 현 UX 동일)
      const multiProject = new Set(worktreeData.map(w => w.projectId)).size > 1;
      const seenProjects = new Set();
      for (const session of sessions) {
        const card = document.createElement('div');
        const isExpanded = expandedRoots.has(session.root);
        const wt = wtByRoot.get(session.root);
        if (multiProject && wt && !seenProjects.has(wt.projectId)) {
          seenProjects.add(wt.projectId);
          const groupCount = sessions.filter(s => wtByRoot.get(s.root)?.projectId === wt.projectId).length;
          const groupHead = document.createElement('div');
          groupHead.className = 'project-group';
          groupHead.innerHTML = `<span class="project-group-name">${escapeHtml(wt.projectLabel || wt.projectId)}</span><span class="project-group-meta" title="${escapeHtml(wt.projectRoot)}">${escapeHtml(shortPath(wt.projectRoot))} · ${groupCount} worktree</span>`;
          sessionsEl.appendChild(groupHead);
        }
```
with:
```javascript
      const wtByRoot = new Map(worktreeData.map(w => [w.root, w]));
      // 등록 프로젝트 목록 — 선택 보정(선택이 사라졌으면 첫 프로젝트로 폴백)
      const projectIds = [...new Set(worktreeData.map(w => w.projectId))];
      if (selectedProjectId && !projectIds.includes(selectedProjectId)) selectedProjectId = null;
      if (!selectedProjectId && projectIds.length) selectedProjectId = projectIds[0];
      renderSwitcher();
      // 선택 프로젝트로 스코프 — project-group 스태킹 대체 (세로 카드 목록 그대로)
      const scopedSessions = sessions.filter(s => wtByRoot.get(s.root)?.projectId === selectedProjectId);
      for (const session of scopedSessions) {
        const card = document.createElement('div');
        const isExpanded = expandedRoots.has(session.root);
        const wt = wtByRoot.get(session.root);
```

The `.project-group` CSS (`:1701-1704`) is now dead; leave it for now (removed in cleanup) or delete the four rules. Deleting is preferred (DRY):

```css
    .project-group { display: flex; align-items: baseline; gap: 8px; padding: 12px 12px 4px; border-top: 1px solid var(--sys-style-neutral-light); }
    .project-group:first-child { border-top: 0; }
    .project-group-name { font-size: 13px; font-weight: 700; color: var(--sys-cont-primary-default); }
    .project-group-meta { font-size: 12px; color: var(--sys-cont-neutral-light); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
```
→ delete these four lines.

- [ ] **Step 5: Verify in the preview**

Start the preview dashboard (port 3901, separate from the :3900 daemon — re-run after each edit):

Run:
```bash
cd ~/IdeaProjects/sumin/marina
MARINA_CONTROL_PORT=3901 python3 plugin/scripts/marina-control.py
```
Open `http://localhost:3901` (the live registry has `mdc-main` + `homeserver`). Expected observations:
- The sidebar header shows a project switcher button labeled with one project (e.g. `mdc-main`), not stacked project-group headers.
- Clicking it opens a menu listing `mdc-main` and `homeserver`, each with a status chip (`N ON` / `N 충돌` / `idle`) and a `+ 프로젝트 등록` row at the bottom.
- Selecting `homeserver` scopes the sidebar to homeserver's cards only (the `main` card + its 3 worktrees), vertically; selecting `mdc-main` scopes back. The choice survives a page reload (localStorage).

Stop the preview (Ctrl-C) when done.

- [ ] **Step 6: Commit**

```bash
cd ~/IdeaProjects/sumin/marina
git add plugin/scripts/marina-control.py
git commit -m "feat(plugin): dashboard project switcher scopes sidebar to one project"
```

---

## Task 4: control.py — register flow (path → infer → checklist → add)

Adds the register panel reached from the switcher's `+ 프로젝트 등록`, and makes it the default view when the registry is empty.

**Files:**
- Modify `marina-control.py`: add register-panel markup inside `<aside>` after `.sessions` (`:1829`); CSS; JS (`openRegisterPanel` + checklist + confirm).

- [ ] **Step 1: Add register-panel markup**

In `<aside>`, after `<div class="sessions" id="sessions"></div>` (`marina-control.py:1829`), add:

```html
      <div class="register-panel" id="registerPanel" hidden>
        <div class="register-head">
          <span class="register-title" id="registerTitle">프로젝트 등록</span>
          <button id="registerClose" title="닫기">✕</button>
        </div>
        <label class="register-label">프로젝트 경로</label>
        <div class="register-path-row">
          <input id="registerPath" class="register-input" placeholder="~/path/to/project" />
          <button id="registerInfer">분석</button>
        </div>
        <div class="register-error" id="registerError" hidden></div>
        <div class="register-preview" id="registerPreview" hidden>
          <div class="register-meta" id="registerMeta"></div>
          <div class="register-checklist-head">서브레포 <span class="register-hint">(체크된 것만 등록)</span></div>
          <div class="register-checklist" id="registerChecklist"></div>
          <button id="registerConfirm" class="register-confirm">등록</button>
        </div>
      </div>
```

- [ ] **Step 2: Add register-panel CSS**

After the switcher CSS added in Task 3 (after `.switcher-register:hover {...}`), add:

```css
    .register-panel { padding: 14px; display: flex; flex-direction: column; gap: 10px; }
    .register-head { display: flex; align-items: center; justify-content: space-between; }
    .register-title { font-size: 14px; font-weight: 700; color: var(--sys-cont-neutral-default); }
    .register-label { font-size: 12px; color: var(--sys-cont-neutral-light); }
    .register-path-row { display: flex; gap: 6px; }
    .register-input { flex: 1; height: 30px; padding: 0 8px; border: 1px solid var(--sys-style-neutral-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-neutral-default); }
    .register-path-row button, .register-confirm { height: 30px; padding: 0 12px; border: 1px solid var(--sys-cont-primary-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-primary-default); }
    .register-error { font-size: 12px; color: #c0392b; }
    .register-preview { display: flex; flex-direction: column; gap: 8px; }
    .register-meta { font-size: 12px; color: var(--sys-cont-neutral-light); }
    .register-checklist-head { font-size: 13px; font-weight: 600; color: var(--sys-cont-neutral-default); }
    .register-hint { font-weight: 400; color: var(--sys-cont-neutral-light); }
    .register-checklist { display: flex; flex-direction: column; gap: 4px; max-height: 40vh; overflow-y: auto; }
    .register-check { display: flex; align-items: center; gap: 8px; font-size: 13px; color: var(--sys-cont-neutral-default); }
    .register-empty { font-size: 12px; color: var(--sys-cont-neutral-light); }
    .register-confirm { align-self: flex-start; }
```

- [ ] **Step 3: Replace the `openRegisterPanel` stub with the real flow**

Replace the three stubs from Task 3 Step 3 with the real `openRegisterPanel` (and keep `openSubrepoEdit`/`removeProject` stubs — replaced in Task 5):

```javascript
    let registerMode = 'new'; // 'new' | 'edit'
    let registerEditId = null;

    function showRegisterPanel(show) {
      document.getElementById('registerPanel').hidden = !show;
      document.getElementById('sessions').hidden = show;
      document.querySelector('.sessions-bar').style.visibility = show ? 'hidden' : '';
    }

    function openRegisterPanel() {
      registerMode = 'new'; registerEditId = null; switcherOpen = false;
      document.getElementById('registerTitle').textContent = '프로젝트 등록';
      document.getElementById('registerPath').value = '';
      document.getElementById('registerPath').disabled = false;
      document.getElementById('registerPreview').hidden = true;
      document.getElementById('registerError').hidden = true;
      showRegisterPanel(true);
      renderSwitcher();
    }

    function renderChecklist(universe, checked) {
      const box = document.getElementById('registerChecklist');
      box.innerHTML = '';
      if (!universe.length) {
        box.innerHTML = '<div class="register-empty">monorepo (subrepos 없음)</div>';
        return;
      }
      for (const name of universe) {
        const row = document.createElement('label');
        row.className = 'register-check';
        const cb = document.createElement('input');
        cb.type = 'checkbox'; cb.value = name; cb.checked = checked.includes(name);
        row.appendChild(cb);
        row.appendChild(document.createTextNode(name));
        box.appendChild(row);
      }
    }

    async function inferAndPreview(path, checkedDefault) {
      const err = document.getElementById('registerError');
      err.hidden = true;
      try {
        const info = await api('/api/infer-project', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({ path }),
        });
        document.getElementById('registerMeta').textContent =
          `id: ${info.id} · ${info.worktreeGlobs.join(', ')}`;
        const universe = info.subrepos || [];
        renderChecklist(universe, checkedDefault === null ? universe : checkedDefault);
        document.getElementById('registerPreview').hidden = false;
        return info;
      } catch (e) {
        err.textContent = String(e.message || e); err.hidden = false;
        document.getElementById('registerPreview').hidden = true;
        return null;
      }
    }

    document.getElementById('registerClose').onclick = () => showRegisterPanel(false);
    document.getElementById('registerInfer').onclick = () => {
      const path = document.getElementById('registerPath').value.trim();
      if (path) inferAndPreview(path, null); // 신규 = 전체 체크 기본
    };
    document.getElementById('registerConfirm').onclick = async () => {
      const path = document.getElementById('registerPath').value.trim();
      const subrepos = [...document.querySelectorAll('#registerChecklist input:checked')].map(c => c.value);
      await api('/api/add-project', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({ path, subrepos }),
      });
      showRegisterPanel(false);
      await loadWorktrees(true);
      await load({ force: true });
      const justAdded = projectSummaries().find(s => s.root && path && (s.root === path || s.root.endsWith('/' + path.split('/').pop())));
      if (justAdded) setSelectedProject(justAdded.id); else render();
    };
```

- [ ] **Step 4: Default to the register panel when the registry is empty**

In `render()`, right after the `projectIds`/`selectedProjectId` reconciliation added in Task 3 Step 4 (after `renderSwitcher();`), add:

```javascript
      if (!projectIds.length) { showRegisterPanel(true); return; }
      if (!document.getElementById('registerPanel').hidden && registerMode === 'new' && projectIds.length && !switcherOpen) {
        // 등록 패널은 명시적으로 열렸을 때만 — 자동 닫기는 confirm/close 가 처리
      }
```

(The first line is the spec's "empty registry → register panel is default." The second is a no-op guard comment kept for clarity; omit if preferred.)

- [ ] **Step 5: Verify in the preview**

Run:
```bash
cd ~/IdeaProjects/sumin/marina
MARINA_CONTROL_PORT=3901 python3 plugin/scripts/marina-control.py
```
Create a throwaway fixture to register:
```bash
mkdir -p /tmp/marina-fix/{api,web}/.git /tmp/marina-fix/docs
```
In `http://localhost:3901`:
- Switcher → `+ 프로젝트 등록` → enter `/tmp/marina-fix` → `분석` → preview shows `id: marina-fix`, a checklist with `api` and `web` both checked.
- Uncheck `web` → `등록` → panel closes, switcher now lists `marina-fix`, the view scopes to it.
- Confirm the registry: `bash plugin/scripts/marina.sh ls` (or `cat ~/.marina/projects.json`) shows `marina-fix` with `subrepos: [api]`.
- Cleanup: `bash plugin/scripts/marina.sh rm marina-fix && rm -rf /tmp/marina-fix`.

Empty-registry default (optional, uses a temp home so it does not touch your real registry):
```bash
MARINA_HOME=/tmp/marina-empty MARINA_CONTROL_PORT=3902 python3 plugin/scripts/marina-control.py
```
Open `http://localhost:3902` → the register panel is shown by default (no projects). Stop it and `rm -rf /tmp/marina-empty`.

- [ ] **Step 6: Commit**

```bash
cd ~/IdeaProjects/sumin/marina
git add plugin/scripts/marina-control.py
git commit -m "feat(plugin): in-dashboard project registration with editable subrepo checklist"
```

---

## Task 5: control.py — subrepos 편집 + remove project

Fills the two remaining switcher affordances: `⚙` edits a project's subrepos by reusing the register panel pre-filled with the inferred universe and the project's current selection; `✕` unregisters the project.

**Files:**
- Modify `marina-control.py`: replace the `openSubrepoEdit`/`removeProject` stubs with real implementations.

- [ ] **Step 1: Replace `openSubrepoEdit` and `removeProject`**

Replace the two remaining stubs with:

```javascript
    async function openSubrepoEdit(sum) {
      registerMode = 'edit'; registerEditId = sum.id; switcherOpen = false;
      document.getElementById('registerTitle').textContent = `subrepos 편집 — ${sum.label}`;
      document.getElementById('registerPath').value = sum.root;
      document.getElementById('registerPath').disabled = true;
      document.getElementById('registerError').hidden = true;
      document.getElementById('registerPreview').hidden = true;
      showRegisterPanel(true);
      renderSwitcher();
      // 현재 선택 = 이 프로젝트의 등록된 subrepos. universe = infer 결과(현재 nested-git 전수).
      const mainEntry = worktreeData.find(w => w.projectId === sum.id && w.isMain);
      const current = mainEntry ? (mainEntry.subrepos || []) : [];
      await inferAndPreview(sum.root, current);
    }

    async function removeProject(sum) {
      if (!confirm(`'${sum.label}' 등록을 해제할까요? (코드·worktree 는 그대로, 레지스트리에서만 제거)`)) return;
      await api('/api/remove-project', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({ id: sum.id }),
      });
      if (selectedProjectId === sum.id) setSelectedProject(null);
      await loadWorktrees(true);
      await load({ force: true });
      render();
    }
```

**Required server field (added during implementation):** the edit checklist must pre-check the **registered** subrepos (the curated subset), NOT the filesystem universe. `branches` reflects nested-git repos present on disk (= `infer`'s universe), so deriving "current" from it wrongly checks excluded repos (e.g. a project registered `[api]` whose root still contains `api/` and `web/` would show both checked). The registered set comes from the registry, so `worktree_info()` exposes it: add `"subrepos": list(project["subrepos"]) if project else [],` to the info dict (`marina-control.py`, after `projectRoot`). The client reads `mainEntry.subrepos` for the checked-by-default set; the universe still comes from `infer`.

- [ ] **Step 2: Confirm the confirm-path reuses `/api/add-project` (upsert)**

No new code: the register panel's `registerConfirm` handler (Task 4 Step 3) already POSTs `/api/add-project` with `path` (the disabled, pre-filled root) and the checked set. Because `marina.sh add` upserts by `realpath(root)`, editing = re-adding with the curated set. Verify by reading the handler — `path` is read from `#registerPath.value` which is set to `sum.root` in edit mode.

- [ ] **Step 3: Verify in the preview**

Run:
```bash
cd ~/IdeaProjects/sumin/marina
mkdir -p /tmp/marina-fix2/{api,web,worker}/.git
bash plugin/scripts/marina.sh add /tmp/marina-fix2 --subrepos api,web   # seed: 2 of 3
MARINA_CONTROL_PORT=3901 python3 plugin/scripts/marina-control.py
```
In `http://localhost:3901`:
- Switcher → hover `marina-fix2` → `⚙` → panel opens titled `subrepos 편집 — marina-fix2`, path pre-filled+disabled, checklist shows `api`,`web`,`worker` with `api`+`web` checked, `worker` unchecked.
- Check `worker` → `등록` → `bash plugin/scripts/marina.sh ls` shows `marina-fix2` subrepos `api, web, worker`.
- Switcher → hover `marina-fix2` → `✕` → confirm → it disappears from the switcher; `cat ~/.marina/projects.json` no longer lists it.
- Cleanup: `rm -rf /tmp/marina-fix2` (registry entry already removed; if you skipped the `✕` step, `bash plugin/scripts/marina.sh rm marina-fix2`).

- [ ] **Step 4: Full regression — run all plugin tests**

Run:
```bash
cd ~/IdeaProjects/sumin/marina
for t in plugin/tests/test-*.sh; do echo "== $t =="; bash "$t" || break; done
```
Expected: every test prints its `PASS ...` line (`test-add-subrepos`, `test-registry-api`, `test-infer`, `test-resolve`, `test-dashboard-launch`, `test-install-cli`, `test-attach-clean-codex-worktree`).

- [ ] **Step 5: Commit**

```bash
cd ~/IdeaProjects/sumin/marina
git add plugin/scripts/marina-control.py
git commit -m "feat(plugin): switcher subrepos 편집 + project unregister"
```

---

## Self-Review

**1. Spec coverage:**
- A. Project switcher (nav + status + register entry) → Task 3 (switcher, chips, `+ 프로젝트 등록` row).
- B. Per-project scoped view (vertical, scoped) → Task 3 Step 4 (`scopedSessions`, group-stacking removed).
- C. Register flow (path → infer → checklist default-all-checked → confirm → switch); empty registry default → Task 4.
- D. Subrepo curation one mechanism (CLI `--subrepos`, dashboard shells `add`) → Task 1 (CLI) + Task 4/5 (dashboard add/edit, both POST `/api/add-project`).
- E. Dashboard API (`infer-project` no-write, `add-project`, `remove-project`, existing `do_POST` pattern) → Task 2.
- Components/files (marina.sh `registry_add`+`usage`; control.py switcher/scoped/panel/edit/3 endpoints; tests) → all tasks.
- Error handling: invalid path → API 4xx + inline error (Task 2 validation + Task 4 `registerError`); no nested repos → "monorepo (subrepos 없음)" empty checklist (Task 4 `renderChecklist`); all unchecked → `subrepos: []` (Task 1 empty-CSV handling + dashboard sends `[]`).

**2. Placeholder scan:** The only stubs are the three `console.warn` placeholders in Task 3 Step 3, explicitly created to keep Task 3 independently runnable and explicitly REPLACED in Tasks 4 (`openRegisterPanel`) and 5 (`openSubrepoEdit`, `removeProject`). No `TBD`/"handle errors"/"similar to" placeholders remain.

**3. Type/name consistency:** `selectedProjectId`, `projectSummaries()`, `renderSwitcher()`, `setSelectedProject()`, `showRegisterPanel()`, `inferAndPreview()`, `renderChecklist()`, `registerMode`/`registerEditId` are defined once and reused with the same signatures across tasks. Endpoint names (`/api/infer-project`, `/api/add-project`, `/api/remove-project`) and payload keys (`path`, `subrepos`, `id`) match between Task 2 (server) and Tasks 4–5 (client). `marina.sh add --subrepos` CSV format matches the server's `",".join(subrepos)`.

**Out of scope (v1), not implemented:** switcher search box; dedicated all-projects overview page; project reorder/pin; non-git-repo subrepos.

## Execution Handoff

Plan saved to `docs/plans/2026-06-16-dashboard-register-ui.md`. Tasks 1–2 are TDD with bash tests; Tasks 3–5 are UI verified on the preview server (`MARINA_CONTROL_PORT=3901`). Dependencies are linear (2 needs 1's flag; 4–5 need 3's switcher + 2's endpoints), so execute in order with a verification checkpoint after each task.
