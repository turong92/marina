# 깃 그래프 패널 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 대시보드에 GitKraken 스타일 커밋 그래프 패널(레인=브랜치, WIP 행, 머지·불일치 칩)과 unified diff 모달을 추가한다. 전부 읽기 전용.

**Architecture:** 백엔드는 새 모듈 `marina_git.py` 에 `/api/git-graph`·`/api/git-diff` 두 GET 엔드포인트(레포당 main 체크아웃에서 전 브랜치 로그 — 워크트리는 객체DB 공유, dirty 는 워크트리별 status). 프론트는 새 파일 `app-8-git.js`(전역 스코프 공유 — 기존 `api`/`escapeHtml`/`worktreeData` 재사용) + styles.css 추가 + 툴바 ⎇ 버튼. 스펙: `docs/superpowers/specs/2026-07-02-git-graph-panel-design.md`

**Tech Stack:** Python(stdlib http.server 기존 핸들러), vanilla JS + inline SVG, bash e2e 테스트(기존 `plugin/tests/*.sh` 스타일)

**참고 — 기존 코드 사실관계 (구현 전 확인 완료):**
- `marina_sessions.py`: `repo_branch()`(detached→빈문자열), `worktree_info()`(15s 캐시, `branches`/`alias`), `worktree_status()`(repos[].path·changeCount·untrackedCount), `safe_root()`
- `marina_registry.py`: `source_root_for()`, `subrepos_of()`, `discover_all_roots()`
- `marina_handler.py` GET 라우트 패턴: `parsed.path == "/api/..."` → `safe_root` → `send_json` (`/api/worktree-changes` 참고, 274행 부근)
- 프론트: JS 파일들은 IIFE 없이 top-level `let`/`function` — classic script 라 파일 간 전역 공유. `api()`/`enc()`/`escapeHtml()` 은 app-3-util.js, `worktreeData`/`selectedProjectId` 는 app-1-core.js. 모달 패턴은 app-6-modals.js `openLinksModal`(backdrop div + `.modal-backdrop` + zIndex 200 + ✕만으로 닫기)
- CSS 변수: `--sys-bg-surface`, `--sys-bg-surface-hover`, `--sys-style-neutral-light`, `--sys-cont-neutral-default`, `--sys-cont-primary-default`, `--sys-cont-positive-default`, `--sys-cont-negative-default`
- 테스트 패턴: `plugin/tests/test-attach-detach-api.sh` (mktemp + `gi()` 레포 시드 + `marina.sh project add` + worktreeGlobs 패치 + 서버 기동 + curl 어서션)

---

### Task 1: 백엔드 `/api/git-graph` (marina_git.py + 라우트)

**Files:**
- Create: `plugin/scripts/marina_git.py`
- Modify: `plugin/scripts/marina_handler.py` (import 1줄 + GET 라우트 2블록 — Task 2 라우트도 여기서 함께 추가)
- Test: `plugin/tests/test-git-graph.sh`

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-git-graph.sh` 전체 (Task 2 의 diff 어서션 포함 — 한 서버 기동으로 전부 검증):

```bash
#!/usr/bin/env bash
# /api/git-graph · /api/git-diff — 레인 그래프 데이터·diff 본문·검증 가드
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39731; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT")

gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm "init $2"; }

# main checkout: 루트 레포 + 서브레포 a (test-attach-detach-api.sh 와 동일 구조)
SRC="$TMP/src"; gi "$SRC" root; gi "$SRC/a" suba
bash "$SH" project add "$SRC" --subrepos a >/dev/null
# 워크트리: 루트를 feat/x 브랜치로 + 서브레포 a 를 main 그대로 attach(브랜치 불일치 시나리오)
WT="$TMP/wt/feature-x"; mkdir -p "$TMP/wt"
git -C "$SRC" worktree add -q -b feat/x "$WT" main
git -C "$SRC/a" worktree add -q --detach "$WT/a" main
python3 - "$MARINA_HOME/projects.json" "$TMP/wt/*" <<'PY'
import json, sys
f, glob = sys.argv[1], sys.argv[2]
d = json.load(open(f)); d["projects"][0]["worktreeGlobs"] = [glob]
json.dump(d, open(f, "w"), ensure_ascii=False, indent=2)
PY
# feat/x 에 커밋 1개(ahead) + 미커밋 변경 1개 + untracked 1개
echo change >> "$WT/r"; git -C "$WT" add r; git -C "$WT" commit -qm "feat commit"
echo wip >> "$WT/r"
echo new > "$WT/newfile.txt"
FEAT_HEAD="$(git -C "$WT" rev-parse HEAD)"

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# ── git-graph: 브랜치·커밋·불일치 ──────────────────────────────
curl -s "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=." | python3 -c "
import json, sys
g = json.load(sys.stdin)
assert g['repo'] == '.' and '.' in g['repos'] and 'a' in g['repos'], g['repos']
assert g['mainBranch'] == 'main', g['mainBranch']
by = {b['branch']: b for b in g['branches']}
assert 'main' in by and by['main']['isMain'] is True, by
assert 'feat/x' in by, by
fx = by['feat/x']
assert fx['head'] == '$FEAT_HEAD', fx
assert fx['merged'] is False, fx
assert fx['dirtyCount'] >= 2, fx                    # r 수정 + newfile.txt
assert any('a=' not in m or True for m in fx['mismatch']) and fx['mismatch'], fx  # a 는 detached(빈 브랜치)·root 는 feat/x → 불일치
hashes = {c['hash'] for c in g['commits']}
assert '$FEAT_HEAD' in hashes, 'feat head not in log'
assert all(set(c) >= {'hash','parents','subject','ts'} for c in g['commits'])
" || { echo 'FAIL: git-graph'; exit 1; }

# 알 수 없는 repo → 4xx
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=zzz")"
[[ "$code" == 4* ]] || { echo "FAIL: git-graph bad repo expected 4xx, got $code"; exit 1; }

# ── merged 판정: feat/x 를 main 에 머지 후 refresh=1 ───────────
git -C "$SRC" merge -q --no-ff feat/x -m "merge feat/x"
curl -s "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=.&refresh=1" | python3 -c "
import json, sys
g = json.load(sys.stdin)
fx = next(b for b in g['branches'] if b['branch'] == 'feat/x')
assert fx['merged'] is True, fx
" || { echo 'FAIL: git-graph merged'; exit 1; }

# ── git-diff: working / 커밋 / untracked / 가드 ────────────────
curl -s "${hdr[@]}" "$base/api/git-diff?root=$WT&repo=." | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert '+wip' in d['text'], d['text'][:200]        # 미커밋 변경
assert d['truncated'] is False, d
" || { echo 'FAIL: git-diff working'; exit 1; }

curl -s "${hdr[@]}" "$base/api/git-diff?root=$WT&repo=.&commit=$FEAT_HEAD" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'feat commit' in d['text'] and '+change' in d['text'], d['text'][:300]
" || { echo 'FAIL: git-diff commit'; exit 1; }

curl -s "${hdr[@]}" "$base/api/git-diff?root=$WT&repo=.&file=newfile.txt" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert '+new' in d['text'], d['text'][:200]        # untracked → /dev/null 대비
" || { echo 'FAIL: git-diff untracked'; exit 1; }

for bad in "file=../../../etc/passwd" "commit=DROP;TABLE" "repo=zzz"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "$base/api/git-diff?root=$WT&${bad}")"
  [[ "$code" == 4* ]] || { echo "FAIL: git-diff guard ($bad) expected 4xx, got $code"; exit 1; }
done

echo "PASS test-git-graph"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-git-graph.sh`
Expected: `FAIL: git-graph` (엔드포인트 없음 → curl 이 404/에러 JSON 을 받아 python 어서션 실패)

- [ ] **Step 3: `marina_git.py` 구현 (graph + diff 함께 — 모듈 하나가 한 책임)**

```python
"""marina_git.py — 깃 그래프 패널 백엔드 (전부 읽기 전용 git).
spec: docs/superpowers/specs/2026-07-02-git-graph-panel-design.md
서브레포는 git worktree attach 라 main 체크아웃과 객체DB 를 공유 → 커밋 로그는
'레포당 main 체크아웃 하나' 에서 전 브랜치를 얻고, 브랜치/dirty 는 워크트리별로 얻는다."""
from __future__ import annotations
import re
import subprocess
import time
from pathlib import Path
from typing import Any

from marina_registry import discover_all_roots, source_root_for, subrepos_of
from marina_sessions import repo_branch, worktree_info, worktree_status

_GRAPH_TTL = 15.0
_graph_cache: dict[str, tuple[float, dict[str, Any]]] = {}
MAX_DIFF_BYTES = 200_000
_HASH_RE = re.compile(r"[0-9a-f]{7,40}")


def _git(args: list[str], cwd: Path, timeout: float = 5.0, ok_codes: tuple[int, ...] = (0,)) -> str:
    proc = subprocess.run(["git", "-C", str(cwd), *args],
                          capture_output=True, text=True, timeout=timeout)
    if proc.returncode not in ok_codes:
        msg = (proc.stderr or proc.stdout).strip().splitlines()
        raise RuntimeError(msg[-1] if msg else f"git {args[0]} failed")
    return proc.stdout


def repo_names_for(main: Path) -> list[str]:
    # '.'(root 레포) + 등록 서브레포. external 은 체크아웃 경로가 달라(.workspace/external) 1단계 제외.
    return ["."] + subrepos_of(main)


def _checkout_of(root: Path, repo: str) -> Path:
    return root if repo == "." else root / repo


def git_graph(any_root: Path, repo: str, refresh: bool = False) -> dict[str, Any]:
    main = source_root_for(any_root).resolve()
    repos = [r for r in repo_names_for(main) if (_checkout_of(main, r) / ".git").exists()]
    if repo not in repos:
        raise ValueError("unknown repo")
    key = f"{main}::{repo}"
    cached = _graph_cache.get(key)
    if cached and not refresh and time.time() - cached[0] < _GRAPH_TTL:
        return cached[1]

    main_co = _checkout_of(main, repo)
    main_branch = repo_branch(main_co) or "main"

    branches: list[dict[str, Any]] = []
    seen: set[str] = set()   # 같은 브랜치를 보는 체크아웃 중복 방지 (main 우선)
    roots = sorted(discover_all_roots(), key=lambda r: r.resolve() != main)
    for root in roots:
        if source_root_for(root).resolve() != main:
            continue
        co = _checkout_of(root, repo)
        if not (co / ".git").exists():
            continue
        try:
            head = _git(["rev-parse", "HEAD"], co).strip()
        except (RuntimeError, subprocess.TimeoutExpired):
            continue   # 깨진/고아 워크트리 — 세션 카드가 broken 을 이미 표시, 그래프에선 제외
        branch = repo_branch(co)
        label = branch or head[:7]   # detached → short hash 칩
        if label in seen:
            continue
        seen.add(label)
        info = worktree_info(root)
        status_repo = next((r for r in worktree_status(root)["repos"]
                            if Path(r["path"]).resolve() == co.resolve()), None)
        merged = False
        if branch and branch != main_branch:
            rc = subprocess.run(
                ["git", "-C", str(main_co), "merge-base", "--is-ancestor", head, main_branch],
                capture_output=True, timeout=5).returncode
            merged = rc == 0
        wt_branches = info.get("branches", {})
        mismatch = ([f"{k}={v}" for k, v in wt_branches.items() if v != branch]
                    if branch and len(set(wt_branches.values())) > 1 else [])
        # attach 됐지만 브랜치 미보고(detached 서브레포)도 불일치로 — branches 에 안 잡히므로 fs 로 보강
        if branch:
            for sub in info.get("attachedSubrepos", []):
                if sub not in wt_branches and ((root / sub) / ".git").exists():
                    mismatch.append(f"{sub}=(detached)")
        branches.append({
            "branch": label, "detached": not branch, "head": head,
            "root": str(root), "alias": info.get("alias") or info.get("id"),
            "isMain": root.resolve() == main,
            "dirtyCount": (status_repo or {}).get("changeCount", 0),
            "untrackedCount": (status_repo or {}).get("untrackedCount", 0),
            "merged": merged, "mismatch": mismatch,
        })

    commits: list[dict[str, Any]] = []
    heads = sorted({b["head"] for b in branches})
    if heads:
        out = _git(["log", "--topo-order", "-n", "200",
                    "--format=%H%x1f%P%x1f%s%x1f%ct%x1e", *heads], main_co, timeout=10.0)
        for rec in out.split("\x1e"):
            rec = rec.strip("\n")
            if not rec:
                continue
            h, parents, subject, ts = rec.split("\x1f")
            commits.append({"hash": h, "parents": parents.split(),
                            "subject": subject, "ts": int(ts)})

    payload = {"repo": repo, "repos": repos, "mainRoot": str(main),
               "mainBranch": main_branch, "branches": branches, "commits": commits}
    _graph_cache[key] = (time.time(), payload)
    return payload


def git_diff(root: Path, repo: str, file: str = "", commit: str = "") -> dict[str, Any]:
    main = source_root_for(root).resolve()
    if repo not in repo_names_for(main):
        raise ValueError("unknown repo")
    co = _checkout_of(root, repo)
    if not (co / ".git").exists():
        raise ValueError("repo not checked out")
    if file:
        base = co.resolve()
        target = (base / file).resolve()
        if target != base and base not in target.parents:
            raise ValueError("bad path")
    if commit:
        if not _HASH_RE.fullmatch(commit):
            raise ValueError("bad commit")
        text = _git(["show", commit, *(["--", file] if file else [])], co, timeout=10.0)
    elif file and not _git(["ls-files", "--", file], co).strip():
        # untracked — diff HEAD 에 안 나옴 → /dev/null 대비 (no-index 는 차이 있으면 rc=1 이 정상)
        text = _git(["diff", "--no-index", "--", "/dev/null", file], co, timeout=10.0, ok_codes=(0, 1))
    else:
        text = _git(["diff", "HEAD", *(["--", file] if file else [])], co, timeout=10.0)
    raw = text.encode("utf-8")
    if len(raw) > MAX_DIFF_BYTES:
        return {"text": raw[:MAX_DIFF_BYTES].decode("utf-8", "ignore"), "truncated": True}
    return {"text": text, "truncated": False}
```

- [ ] **Step 4: `marina_handler.py` 라우트 추가**

import 블록(38행 `from marina_sessions import ...` 아래)에:

```python
from marina_git import git_diff, git_graph
```

`/api/worktree-changes` 블록(283행 `return` 뒤) 다음에 GET 라우트 2개:

```python
        if parsed.path == "/api/git-graph":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                payload = git_graph(root, query.get("repo", ["."])[0],
                                    refresh=query.get("refresh", ["0"])[0] == "1")
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return

        if parsed.path == "/api/git-diff":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                payload = git_diff(root, query.get("repo", ["."])[0],
                                   file=query.get("file", [""])[0],
                                   commit=query.get("commit", [""])[0])
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `bash plugin/tests/test-git-graph.sh`
Expected: `PASS test-git-graph`

주의 — 실패 흔한 원인: ① `source_root_for` 가 등록 프로젝트 root 를 못 찾으면 `_git_main_checkout` 폴백 (worktreeGlobs 패치 확인) ② `worktree_status` 캐시 15s — 테스트에서 dirty 를 서버 기동 **전에** 만들어 캐시 이슈 회피(위 스크립트가 그렇게 함) ③ subrepo `a` 의 워크트리 attach 가 detached 라 `repo_branch` 빈 문자열 → mismatch 는 attachedSubrepos 보강 경로로 잡힘.

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina_git.py plugin/scripts/marina_handler.py plugin/tests/test-git-graph.sh
git commit -m "feat(marina): /api/git-graph·git-diff — 깃 그래프 백엔드 (읽기 전용, 브랜치·merged·불일치·diff 가드)"
```

---

### Task 2: 기존 테스트 회귀 확인

**Files:** 없음 (검증만)

- [ ] **Step 1: 전체 테스트 실행**

Run: `for t in plugin/tests/test-*.sh; do bash "$t" >/dev/null 2>&1 && echo "PASS $(basename $t)" || echo "FAIL $(basename $t)"; done`
Expected: 전부 PASS (docker 필요 테스트는 로컬 docker 상태에 따라 skip 로직이 있으면 그에 따름 — 기존에 PASS 였던 것이 FAIL 로 바뀐 게 없어야 함)

---

### Task 3: 프론트 골격 — 툴바 버튼·모달·레포 탭·행 목록

**Files:**
- Create: `plugin/scripts/marina-web/app-8-git.js`
- Modify: `plugin/scripts/marina-web/index.html` (툴바 버튼 1개 + script 태그 1개)
- Modify: `plugin/scripts/marina-web/styles.css` (말미에 블록 추가)

- [ ] **Step 1: index.html — 툴바 버튼 + script**

20행 `<button id="refresh" ...>↻</button>` **앞에**:

```html
      <button id="gitGraph" title="깃 그래프 — main·워크트리 브랜치 지형도와 diff">⎇</button>
```

168행 `app-6-modals.js` 다음, `app-7-init.js` **앞에**:

```html
  <script src="/web/app-8-git.js"></script>
```

(app-7-init.js 가 초기 폴링을 시작하므로 그 앞에 로드 — app-8 은 전역 함수 정의 + 버튼 바인딩만, 초기화 의존 없음)

- [ ] **Step 2: styles.css 말미에 패널 스타일 추가**

```css
/* ── 깃 그래프 패널 (app-8-git.js) ─────────────────────────────── */
.git-modal { width: min(880px, 94vw); max-height: 88vh; display: flex; flex-direction: column; background: var(--sys-bg-surface); border: 1px solid var(--sys-style-neutral-light); border-radius: 12px; padding: 14px 16px; }
.git-head { display: flex; align-items: center; gap: 10px; margin-bottom: 8px; flex: none; }
.git-tabs { display: flex; gap: 4px; }
.git-tabs button { font-size: 12px; padding: 3px 10px; border-radius: 8px; border: 1px solid var(--sys-style-neutral-light); background: transparent; color: inherit; cursor: pointer; }
.git-tabs button.active { background: var(--sys-cont-primary-default); color: #fff; border-color: transparent; }
.git-legend { margin-left: auto; font-size: 11px; color: var(--sys-cont-neutral-default); }
.git-body { overflow: auto; position: relative; min-height: 120px; }
.git-graph-wrap { position: relative; }
.git-graph-wrap svg { position: absolute; top: 0; left: 0; }
.git-row { height: 32px; display: flex; align-items: center; gap: 8px; padding-right: 10px; border-bottom: 1px solid var(--sys-style-neutral-light); font-size: 12.5px; cursor: pointer; white-space: nowrap; overflow: hidden; }
.git-row:hover { background: var(--sys-bg-surface-hover); }
.git-subject { overflow: hidden; text-overflow: ellipsis; }
.git-when { margin-left: auto; font-size: 11px; color: var(--sys-cont-neutral-default); font-family: ui-monospace, Menlo, monospace; flex: none; }
.git-chip { flex: none; font-size: 11px; padding: 1px 8px; border-radius: 9px; border: 1px solid var(--sys-style-neutral-light); font-family: ui-monospace, Menlo, monospace; }
.git-chip.ses { color: var(--sys-cont-neutral-default); font-family: inherit; }
.git-chip.ok { color: var(--sys-cont-positive-default); border-color: var(--sys-cont-positive-default); }
.git-chip.warn { color: var(--sys-cont-negative-default); border-color: var(--sys-cont-negative-default); }
.git-sub { color: var(--sys-cont-neutral-default); font-size: 12px; }
.git-err { color: var(--sys-cont-negative-default); font-size: 12px; padding: 8px; }
.git-diff-modal { width: min(920px, 96vw); max-height: 90vh; display: flex; flex-direction: column; background: var(--sys-bg-surface); border: 1px solid var(--sys-style-neutral-light); border-radius: 12px; padding: 14px 16px; }
.git-diff-body { display: flex; overflow: hidden; min-height: 200px; }
.git-files { width: 220px; flex: none; overflow: auto; border-right: 1px solid var(--sys-style-neutral-light); font-size: 12px; }
.git-file { padding: 4px 10px; cursor: pointer; font-family: ui-monospace, Menlo, monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.git-file:hover { background: var(--sys-bg-surface-hover); }
.git-patch { flex: 1; overflow: auto; font-family: ui-monospace, Menlo, monospace; font-size: 11.5px; line-height: 1.55; }
.dl { white-space: pre; padding: 0 12px; }
.dl.add { background: color-mix(in srgb, var(--sys-cont-positive-default) 12%, transparent); color: var(--sys-cont-positive-default); }
.dl.del { background: color-mix(in srgb, var(--sys-cont-negative-default) 10%, transparent); color: var(--sys-cont-negative-default); }
.dl.hunk { color: var(--sys-cont-primary-default); }
.dl.meta { color: var(--sys-cont-neutral-default); }
.dl.file { color: var(--sys-cont-neutral-default); margin-top: 8px; font-weight: 600; }
```

- [ ] **Step 3: app-8-git.js — 모달·탭·행 목록 (그래프 SVG 는 Task 4)**

```js
    // app-8-git.js — 깃 그래프 패널: GitKraken 스타일 레인 그래프 + diff 모달. 전부 읽기 전용.
    // 전역 공유(classic script): api/enc/escapeHtml(app-3), worktreeData/selectedProjectId(app-1)
    const GIT_LANES = ['#8a7ef0', '#2fae87', '#e0854f', '#d4537e', '#4f8fdd', '#b08a2e', '#7aa53c'];
    const GIT_ROW_H = 32, GIT_LANE_W = 20, GIT_PAD_X = 14;
    let gitRepoTab = '.';

    function gitMainRoot() {
      const main = worktreeData.find(w => w.projectId === selectedProjectId && w.source === 'main');
      return main ? main.root : (worktreeData.find(w => w.source === 'main') || {}).root;
    }

    function gitRelTime(ts) {
      const s = Math.max(0, Date.now() / 1000 - ts);
      if (s < 3600) return `${Math.max(1, Math.round(s / 60))}분`;
      if (s < 86400) return `${Math.round(s / 3600)}시간`;
      return `${Math.round(s / 86400)}일`;
    }

    function openGitGraph() {
      const root = gitMainRoot();
      if (!root) { alert('프로젝트가 아직 없어요 — 먼저 프로젝트를 등록하세요'); return; }
      const ex = document.getElementById('gitModalBack'); if (ex) ex.remove();
      const back = document.createElement('div');
      back.id = 'gitModalBack'; back.className = 'modal-backdrop'; back.style.zIndex = '200';
      back.innerHTML = `<div class="git-modal">
        <div class="git-head"><strong>⎇ 깃 그래프</strong><div class="git-tabs" data-git-tabs></div>
          <span class="git-legend">● 미커밋 · ✓ 머지됨 · ⚠ 브랜치 불일치 — 행 클릭 = diff</span>
          <button class="links-modal-x" data-git-close title="닫기">✕</button></div>
        <div class="git-body" data-git-body>불러오는 중…</div>
      </div>`;
      document.body.appendChild(back);
      back.querySelector('[data-git-close]').onclick = () => back.remove();
      loadGitGraph(root, gitRepoTab, false);
    }
    document.getElementById('gitGraph').onclick = openGitGraph;

    async function loadGitGraph(root, repo, refresh) {
      const back = document.getElementById('gitModalBack'); if (!back) return;
      const body = back.querySelector('[data-git-body]');
      let g;
      try { g = await api(`/api/git-graph?root=${enc(root)}&repo=${enc(repo)}${refresh ? '&refresh=1' : ''}`); }
      catch (e) {
        if (repo !== '.') { gitRepoTab = '.'; return loadGitGraph(root, '.', refresh); }  // 탭 잔상(다른 프로젝트의 repo명) 복구
        body.innerHTML = `<div class="git-err">${escapeHtml(e.message)}</div>`; return;
      }
      gitRepoTab = g.repo;
      const tabs = back.querySelector('[data-git-tabs]');
      tabs.innerHTML = g.repos.map(r =>
        `<button data-git-repo="${escapeHtml(r)}" class="${r === g.repo ? 'active' : ''}">${escapeHtml(r === '.' ? 'root' : r)}</button>`).join('');
      tabs.querySelectorAll('[data-git-repo]').forEach(b => b.onclick = () => loadGitGraph(root, b.dataset.gitRepo, false));
      renderGitGraph(body, g);
    }
```

`renderGitGraph` 는 이 단계에선 임시(목록만):

```js
    function renderGitGraph(body, g) {
      body.innerHTML = g.commits.map(c =>
        `<div class="git-row"><span class="git-subject">${escapeHtml(c.subject)}</span>
         <span class="git-when">${c.hash.slice(0, 7)} · ${gitRelTime(c.ts)}</span></div>`).join('')
        || '<div class="git-sub" style="padding:12px">커밋 없음</div>';
    }
```

- [ ] **Step 4: 손 검증 (프리뷰)**

대시보드가 로컬에서 :3901 로 떠 있으면(memory: marina-preview) 새로고침 → ⎇ 버튼 → 모달에 커밋 목록·레포 탭 렌더 확인. 안 떠 있으면 Task 1 테스트의 서버 기동 방식으로 임시 기동해 확인:
`MARINA_CONTROL_PORT=3999 python3 plugin/scripts/marina-control.py` → 브라우저 `http://127.0.0.1:3999`

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina-web/app-8-git.js plugin/scripts/marina-web/index.html plugin/scripts/marina-web/styles.css
git commit -m "feat(marina): 깃 그래프 패널 골격 — ⎇ 툴바 버튼·모달·레포 탭·커밋 목록"
```

---

### Task 4: 레인 그래프 SVG + 칩 (WIP·머지됨·불일치·세션)

**Files:**
- Modify: `plugin/scripts/marina-web/app-8-git.js` (`renderGitGraph` 교체)

- [ ] **Step 1: `renderGitGraph` 를 레인 그래프로 교체**

레인 배치: main = lane 0(회색), 각 브랜치 = 고유 레인. 각 브랜치 tip 에서 first-parent 체인을 따라 내려가며 "아직 레인 없는 커밋" 에 자기 레인을 배정 — main 이 먼저 걸어 공유 히스토리를 차지(스펙의 '선형 세션 브랜치' 전제; octopus 등 예외는 직선 폴백으로 자연 강등).

```js
    function renderGitGraph(body, g) {
      const byHash = new Map(g.commits.map(c => [c.hash, c]));
      const ordered = [...g.branches].sort((a, b) => (b.branch === g.mainBranch) - (a.branch === g.mainBranch));
      const lane = new Map();
      ordered.forEach((b, i) => { if (!lane.has(b.branch)) lane.set(b.branch, lane.size); });
      const laneOf = new Map();
      for (const b of ordered) {
        let h = b.head;
        while (h && byHash.has(h) && !laneOf.has(h)) {
          laneOf.set(h, lane.get(b.branch));
          h = (byHash.get(h).parents || [])[0];
        }
      }
      const rows = [];
      for (const b of g.branches) if (b.dirtyCount) rows.push({ wip: true, b, lane: lane.get(b.branch) || 0 });
      for (const c of g.commits) rows.push({ c, lane: laneOf.get(c.hash) ?? 0 });
      const rowIdx = new Map();
      rows.forEach((r, i) => rowIdx.set(r.c ? r.c.hash : `wip:${r.b.branch}`, i));

      const laneCount = Math.max(1, lane.size);
      const gw = GIT_PAD_X * 2 + (laneCount - 1) * GIT_LANE_W;
      const X = l => GIT_PAD_X + l * GIT_LANE_W, Y = i => i * GIT_ROW_H + GIT_ROW_H / 2;
      const C = l => GIT_LANES[l % GIT_LANES.length];
      let svg = '';
      rows.forEach((r, i) => {
        if (r.wip) {
          const tip = rowIdx.get(r.b.head);
          if (tip !== undefined) svg += `<path d="M${X(r.lane)},${Y(i)} L${X(r.lane)},${Y(tip)}" stroke="${C(r.lane)}" stroke-width="2" stroke-dasharray="3 3" fill="none"/>`;
          svg += `<circle cx="${X(r.lane)}" cy="${Y(i)}" r="5" fill="none" stroke="${C(r.lane)}" stroke-width="2" stroke-dasharray="3 2.5"/>`;
          return;
        }
        for (const p of r.c.parents) {
          const pi = rowIdx.get(p);
          if (pi === undefined) {   // 200개 창 밖 부모 — 아래로 사라지는 스텁
            svg += `<path d="M${X(r.lane)},${Y(i)} L${X(r.lane)},${Y(i) + GIT_ROW_H * 0.8}" stroke="${C(r.lane)}" stroke-width="2" opacity=".35" fill="none"/>`;
            continue;
          }
          const pl = rows[pi].lane, ym = (Y(i) + Y(pi)) / 2;
          svg += pl === r.lane
            ? `<path d="M${X(r.lane)},${Y(i)} L${X(pl)},${Y(pi)}" stroke="${C(r.lane)}" stroke-width="2" fill="none"/>`
            : `<path d="M${X(r.lane)},${Y(i)} C${X(r.lane)},${ym} ${X(pl)},${ym} ${X(pl)},${Y(pi)}" stroke="${C(Math.max(r.lane, pl))}" stroke-width="2" fill="none"/>`;
        }
        svg += `<circle cx="${X(r.lane)}" cy="${Y(i)}" r="5" fill="${C(r.lane)}"/>`;
      });

      const tipOf = new Map();
      g.branches.forEach(b => { (tipOf.get(b.head) || tipOf.set(b.head, []).get(b.head)).push(b); });
      const html = rows.map((r, i) => {
        if (r.wip) {
          const b = r.b;
          return `<div class="git-row wip" data-wip-root="${escapeHtml(b.root)}" title="미커밋 변경 — 클릭해 diff">
            <span class="git-chip warn">● 미커밋 ${b.dirtyCount}</span>
            <span class="git-sub">${escapeHtml(b.alias || '')} — 작업 중인 변경</span>
            <span class="git-when">지금</span></div>`;
        }
        const c = r.c;
        const chips = (tipOf.get(c.hash) || []).map(b => {
          const col = C(lane.get(b.branch) || 0);
          let s = `<span class="git-chip br" style="border-color:${col};color:${col}">${escapeHtml(b.branch)}</span>`;
          if (!b.isMain && b.alias) s += `<span class="git-chip ses" title="이 브랜치를 체크아웃한 세션">${escapeHtml(b.alias)}</span>`;
          if (b.merged) s += `<span class="git-chip ok" title="HEAD 가 ${escapeHtml(g.mainBranch)} 에 포함 — 워크트리 정리 가능">✓ 머지됨</span>`;
          if (b.mismatch && b.mismatch.length) s += `<span class="git-chip warn" title="같은 워크트리의 다른 레포가 다른 브랜치를 체크아웃">⚠ ${escapeHtml(b.mismatch.join(' · '))}</span>`;
          return s;
        }).join('');
        return `<div class="git-row" data-commit="${c.hash}" title="클릭해 이 커밋의 diff">
          ${chips}<span class="git-subject">${escapeHtml(c.subject)}</span>
          <span class="git-when">${c.hash.slice(0, 7)} · ${gitRelTime(c.ts)}</span></div>`;
      }).join('');

      body.innerHTML = `<div class="git-graph-wrap">
        <svg width="${gw}" height="${rows.length * GIT_ROW_H}" aria-hidden="true">${svg}</svg>
        <div class="git-rows" style="margin-left:${gw}px">${html}</div></div>`;
      body.querySelectorAll('[data-commit]').forEach(el =>
        el.onclick = () => openGitDiff({ root: g.mainRoot, repo: g.repo, commit: el.dataset.commit,
                                         title: el.querySelector('.git-subject').textContent }));
      body.querySelectorAll('[data-wip-root]').forEach(el =>
        el.onclick = () => openGitDiff({ root: el.dataset.wipRoot, repo: g.repo, title: '미커밋 변경' }));
    }
```

주의: `tipOf` 채우는 한 줄이 기교적이라 실수 잦음 — 명시형으로 써도 됨:
`g.branches.forEach(b => { if (!tipOf.has(b.head)) tipOf.set(b.head, []); tipOf.get(b.head).push(b); });`
(구현 시 명시형 권장. `openGitDiff` 는 Task 5 에서 정의 — 이 시점엔 콘솔 에러 안 나게 `typeof openGitDiff === 'function' &&` 가드 붙이거나 Task 5 와 같은 커밋으로 묶는다. **같은 커밋 권장.**)

- [ ] **Step 2: 손 검증** — 프리뷰에서 레인·칩·WIP 행 렌더 확인 (Task 5 와 묶어 진행 가능)

---

### Task 5: diff 모달 (커밋 / WIP / untracked) + 세션 카드 연동

**Files:**
- Modify: `plugin/scripts/marina-web/app-8-git.js` (말미에 추가)
- Modify: `plugin/scripts/marina-web/app-5-sessions.js` (변경 목록에 diff 버튼)

- [ ] **Step 1: `openGitDiff`·`renderGitDiff` 추가**

```js
    async function openGitDiff(opts) {   // {root, repo, commit?, file?, title}
      const ex = document.getElementById('gitDiffBack'); if (ex) ex.remove();
      const back = document.createElement('div');
      back.id = 'gitDiffBack'; back.className = 'modal-backdrop'; back.style.zIndex = '210';
      back.innerHTML = `<div class="git-diff-modal">
        <div class="git-head"><strong>${escapeHtml(opts.title || 'diff')}</strong>
          <span class="git-sub">${escapeHtml(opts.commit ? opts.commit.slice(0, 7) : '워킹트리')}${opts.file ? ' · ' + escapeHtml(opts.file) : ''}</span>
          <button class="links-modal-x" data-git-close title="닫기" style="margin-left:auto">✕</button></div>
        <div class="git-diff-body" data-diff-body>불러오는 중…</div></div>`;
      document.body.appendChild(back);
      back.querySelector('[data-git-close]').onclick = () => back.remove();
      const q = `root=${enc(opts.root)}&repo=${enc(opts.repo)}`
        + (opts.commit ? `&commit=${enc(opts.commit)}` : '') + (opts.file ? `&file=${enc(opts.file)}` : '');
      let d, untracked = [];
      try {
        d = await api(`/api/git-diff?${q}`);
        if (!opts.commit && !opts.file) {   // WIP 전체 보기 — untracked 는 diff HEAD 에 없어 목록으로 보강
          const wc = await api(`/api/worktree-changes?root=${enc(opts.root)}`);
          const entry = (wc.repos || []).find(r => opts.repo === '.' ? r.path === opts.root : r.name === opts.repo);
          untracked = (entry ? entry.changes || [] : []).filter(l => l.startsWith('??')).map(l => l.slice(3));
        }
      } catch (e) { back.querySelector('[data-diff-body]').innerHTML = `<div class="git-err">${escapeHtml(e.message)}</div>`; return; }
      renderGitDiff(back.querySelector('[data-diff-body]'), d, opts, untracked);
    }

    function renderGitDiff(el, d, opts, untracked) {
      const lines = d.text.replace(/\n$/, '').split('\n');
      const files = [];
      lines.forEach((ln, i) => { const m = ln.match(/^diff --git a\/.* b\/(.*)$/); if (m) files.push({ name: m[1], start: i }); });
      const colored = lines.map(ln => {
        const cls = ln.startsWith('+++') || ln.startsWith('---') ? 'meta' : ln.startsWith('@@') ? 'hunk'
          : ln.startsWith('+') ? 'add' : ln.startsWith('-') ? 'del'
          : ln.startsWith('diff --git') || ln.startsWith('commit ') ? 'file' : '';
        return `<div class="dl ${cls}" data-ln>${escapeHtml(ln) || '&nbsp;'}</div>`;
      }).join('');
      const list = files.map(f => `<div class="git-file" data-goto="${f.start}" title="${escapeHtml(f.name)}">${escapeHtml(f.name)}</div>`).join('')
        + (untracked || []).map(f => `<div class="git-file" data-untracked="${escapeHtml(f)}" title="untracked — 클릭해 내용 보기">+ ${escapeHtml(f)}</div>`).join('');
      el.innerHTML = `${(files.length + (untracked || []).length) > 1 ? `<div class="git-files">${list}</div>` : ''}
        <div class="git-patch">${d.truncated ? '<div class="git-err">⚠ 200KB 초과 — 절단됨</div>' : ''}${colored || '<div class="git-sub" style="padding:12px">변경 없음</div>'}</div>`;
      el.querySelectorAll('[data-goto]').forEach(b => b.onclick = () => {
        const t = el.querySelectorAll('[data-ln]')[Number(b.dataset.goto)];
        if (t) t.scrollIntoView({ block: 'start' });
      });
      el.querySelectorAll('[data-untracked]').forEach(b =>
        b.onclick = () => openGitDiff({ ...opts, file: b.dataset.untracked, title: opts.title }));
    }
```

- [ ] **Step 2: 세션 카드 변경 목록 → diff 진입**

`app-5-sessions.js` 의 changes 토글(314행 부근, `area.textContent = ...` 블록)을 레포 헤더에 diff 버튼이 있는 innerHTML 렌더로 교체:

```js
              const data = await api(`/api/worktree-changes?root=${enc(session.root)}`);
              // 레포별로 tracked(✎)/untracked(+) 분해 — "합산이 어디서 왔는지" 출처를 드러냄. ⎇ diff = 깃 그래프의 diff 모달 재사용
              area.innerHTML = (data.repos ?? []).filter(r => (r.changeCount || 0) > 0).map(r => {
                const repoParam = r.path === session.root ? '.' : r.name;
                const head = `■ ${escapeHtml(r.name)}  ✎${r.trackedCount || 0}${(r.untrackedCount || 0) ? ` · +${r.untrackedCount} untracked` : ''}`
                  + ` <button class="git-chip" data-repo-diff="${escapeHtml(repoParam)}" title="이 레포의 미커밋 diff 보기">⎇ diff</button>`;
                const lines = escapeHtml((r.changes ?? []).join('\n'));
                const more = r.changeCount > (r.changes ?? []).length ? `\n... +${r.changeCount - r.changes.length} more` : '';
                return `${head}\n${lines}${more}`;
              }).join('\n\n') || '(변경 없음 — Refresh 해봐)';
              area.querySelectorAll('[data-repo-diff]').forEach(b => b.onclick = (e) => {
                e.stopPropagation();
                openGitDiff({ root: session.root, repo: b.dataset.repoDiff, title: `미커밋 변경 — ${session.alias || session.id}` });
              });
```

(area 가 `white-space: pre` 계열인지 확인 — textContent 렌더였으므로 줄바꿈 보존 스타일일 것. innerHTML 전환 후 `\n` 이 안 먹으면 wrapper 에 `style="white-space:pre-wrap"` 유지/추가.)

- [ ] **Step 3: 손 검증** — 프리뷰에서 ① 커밋 행 클릭 → 커밋 diff ② WIP 행 클릭 → 워킹 diff + untracked 목록 → untracked 클릭 → 신규 파일 내용 ③ 세션 카드 ✎ 목록의 ⎇ diff 버튼 → 같은 모달

- [ ] **Step 4: 커밋**

```bash
git add plugin/scripts/marina-web/app-8-git.js plugin/scripts/marina-web/app-5-sessions.js
git commit -m "feat(marina): 깃 그래프 레인 SVG·칩 + diff 모달(커밋/WIP/untracked) + 세션 카드 연동"
```

---

### Task 6: 마무리 — 전체 테스트·프리뷰 e2e·codex 리뷰

**Files:** 없음 (검증·리뷰 반영만)

- [ ] **Step 1: 전체 테스트**

Run: `for t in plugin/tests/test-*.sh; do bash "$t" >/dev/null 2>&1 && echo "PASS $(basename $t)" || echo "FAIL $(basename $t)"; done`
Expected: 전부 PASS

- [ ] **Step 2: 프리뷰 e2e** — 임시 시드 프로젝트(Task 1 테스트와 동일 구조)로 서버 기동 → Aside 로 ⎇ 패널 열기 → 그래프·칩·diff 모달 스냅샷/스크린샷 확보 (형 검토용)

- [ ] **Step 3: codex 리뷰** — `codex exec` 리뷰(구현은 내가, 리뷰만 codex — 형 워크플로) → 지적 반영 → 재실행

- [ ] **Step 4: 잔여 수정 커밋** (있으면)

```bash
git add -A && git commit -m "fix(marina): 깃 그래프 codex 리뷰 반영"
```
