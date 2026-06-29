# 외부 서브레포 격리 + Dockerfile 기반 compose 작성 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (권장) 또는 superpowers:executing-plans 로 task 단위 실행. 스텝은 `- [ ]` 체크박스.

**Goal:** marina compose 작성을 (1) 프로젝트 밖 git 레포까지 워크트리별 격리, (2) `+ 서비스` 스캐폴드를 Dockerfile 기반·자율최소로, (3) AI 초안을 같은 grounding 위로 정렬.

**Architecture:** 스캐폴드/AI 가 쓰는 Dockerfile 감지 헬퍼를 먼저 세우고(Phase A), 그 위에 외부 레포를 `git worktree` 로 워크트리마다 붙이는 격리(Phase B), 마지막으로 AI 프롬프트를 같은 감지·마운트 규칙으로 정렬(Phase C). 기존 서브레포 attach 메커니즘(attach-detached-subrepos.sh)·registry·compose 보관 흐름을 재사용.

**Tech Stack:** Python 3 stdlib(데몬 marina-control.py), bash(marina.sh·attach-detached-subrepos.sh), docker compose, git worktree. 테스트=bash 스크립트(plugin/tests/*.sh), `MARINA_LLM_FAKE`·`docker info` 게이트.

**설계 문서:** `docs/specs/2026-06-22-external-subrepo-and-grounded-compose-design.md`

---

## 파일 구조

- `plugin/scripts/marina-control.py` — 감지 헬퍼(`_list_dockerfiles`/`_dockerfile_expose`), `_compose_scaffold_service` 리팩터, `/api/compose-scaffold`(루트/피커), `compose-register`(externalRepos 기록), `_compose_analyze_prompt`/`llm_compose_analyze`(grounding·마운트), 프론트(외부 뱃지·Dockerfile 피커·외부 추가 기록).
- `plugin/scripts/marina.sh` — registry `externalRepos` 저장(`registry_add`), 워크트리 정리 시 외부 worktree 제거.
- `plugin/scripts/attach-detached-subrepos.sh` — externalRepos 를 읽어 `.workspace/external/<name>` 에 `git worktree add` + `<prefix>/<id>` 브랜치.
- `plugin/tests/test-compose-scaffold.sh` — 확장(루트 자동/needPick/EXPOSE-only).
- `plugin/tests/test-external-subrepo.sh` — 신규(registry 기록 + 실 git attach + 정리).

---

## Phase A — Dockerfile 기반 스캐폴드 (Part 2)

### Task A1: Dockerfile 감지 헬퍼

**Files:** Modify `plugin/scripts/marina-control.py` (스캐폴드 헬퍼 근처) · Test `plugin/tests/test-compose-scaffold.sh`

- [ ] **Step 1: 실패 테스트 작성** — test-compose-scaffold.sh 의 python 블록에 추가:

```python
# _list_dockerfiles: 레포 안 Dockerfile 들의 상대경로(정렬). 루트 우선.
# (테스트 셋업은 기존 $T 재사용: ai-api/Dockerfile, web/apps/web/Dockerfile, multi/{x,y}/Dockerfile, api/Dockerfile[EXPOSE 8081])
assert mc._list_dockerfiles(T / "ai-api") == ["Dockerfile"], mc._list_dockerfiles(T / "ai-api")
assert mc._list_dockerfiles(T / "multi") == ["x/Dockerfile", "y/Dockerfile"], mc._list_dockerfiles(T / "multi")
assert mc._list_dockerfiles(T / "nope") == []
# _dockerfile_expose: Dockerfile 의 첫 EXPOSE 포트
assert mc._dockerfile_expose(T / "api" / "Dockerfile") == "8081", mc._dockerfile_expose(T / "api" / "Dockerfile")
assert mc._dockerfile_expose(T / "ai-api" / "Dockerfile") is None   # 빈 Dockerfile
```

- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-compose-scaffold.sh` → FAIL (`_list_dockerfiles` 없음)

- [ ] **Step 3: 구현** — marina-control.py 에 추가:

```python
def _list_dockerfiles(repo: Path) -> list:
    """레포 안 Dockerfile 들의 상대경로(루트 우선, 그다음 정렬). node_modules 등 제외."""
    if (repo / "Dockerfile").is_file():
        rest = []
        try:
            rest = sorted(str(p.relative_to(repo)) for p in repo.rglob("Dockerfile")
                          if p.is_file() and p != repo / "Dockerfile"
                          and "node_modules" not in p.parts and ".git" not in p.parts)
        except OSError:
            pass
        return ["Dockerfile", *rest]
    try:
        return sorted(str(p.relative_to(repo)) for p in repo.rglob("Dockerfile")
                      if p.is_file() and "node_modules" not in p.parts and ".git" not in p.parts)
    except OSError:
        return []


def _dockerfile_expose(path: Path) -> "str | None":
    """Dockerfile 의 첫 EXPOSE 포트(숫자). 없으면 None."""
    try:
        for ln in path.read_text(errors="replace").splitlines():
            m = re.match(r"\s*EXPOSE\s+(\d{2,5})", ln, re.I)
            if m:
                return m.group(1)
    except OSError:
        pass
    return None
```

- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-compose-scaffold.sh` → PASS
- [ ] **Step 5: 커밋** — `git add plugin/scripts/marina-control.py plugin/tests/test-compose-scaffold.sh && git commit -m "feat(compose-dash): Dockerfile 감지 헬퍼(_list_dockerfiles·_dockerfile_expose)"`

### Task A2: 스캐폴드 Dockerfile 기반 리팩터

**Files:** Modify `plugin/scripts/marina-control.py` (`_compose_scaffold_service`) · Test `plugin/tests/test-compose-scaffold.sh`

- [ ] **Step 1: 실패 테스트** — 기존 스캐폴드 단언을 새 동작으로 교체/추가:

```python
# 루트 Dockerfile: build + EXPOSE→expose. command 템플릿·compose 포트추측 없음
api = mc._compose_scaffold_service(T, "api")          # api/Dockerfile EXPOSE 8081
assert "build: ./api" in api and 'expose: ["8081"]' in api, api
assert "command:" not in api and "3000" not in api, api
# EXPOSE 없는 Dockerfile → expose 줄 없음(포트 추측 안 함)
a = mc._compose_scaffold_service(T, "ai-api")
assert "build: ./ai-api" in a and "expose:" not in a, a
# 명시 dockerfile 인자(피커 선택) → context+dockerfile
m = mc._compose_scaffold_service(T, "multi", dockerfile="x/Dockerfile")
assert "context: ./multi" in m and "dockerfile: x/Dockerfile" in m, m
```

- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-compose-scaffold.sh` → FAIL (`dockerfile=` 인자 없음/옛 동작)

- [ ] **Step 3: 구현** — `_compose_scaffold_service` 를 교체:

```python
def _compose_scaffold_service(target: Path, subrepo: str, dockerfile: str = "",
                              build_context: str = "") -> str:
    """무-LLM 스캐폴드: 레포의 Dockerfile 이 선언한 것만 반영(build 위치·EXPOSE 포트).
    dockerfile="" 이고 루트 Dockerfile 있으면 그것, 명시되면 그 경로. build_context 주면 그걸로(외부 마운트)."""
    raw = (subrepo or "").strip().strip("/")
    name = re.sub(r"[^a-z0-9_-]+", "-", raw.split("/")[-1].lower()).strip("-_") or "svc"
    d = target / raw
    ctx = build_context or f"./{raw}"
    df_rel = dockerfile.strip() or ("Dockerfile" if (d / "Dockerfile").is_file() else "")
    port = _dockerfile_expose(d / df_rel) if df_rel else None
    lines = [f"  {name}:"]
    if df_rel in ("", "Dockerfile"):
        lines.append(f"    build: {ctx}")
    else:
        lines += ["    build:", f"      context: {ctx}", f"      dockerfile: {df_rel}"]
    if port:
        lines += [f'    expose: ["{port}"]          # 컨테이너 간 DNS — http://{name}:{port}',
                  f'    # ports: ["{port}:{port}"]   # 호스트 직접 노출 시 (marina 가 포트 격리)']
    return "\n".join(lines) + "\n"
```

- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-compose-scaffold.sh` → PASS
- [ ] **Step 5: 커밋** — `git commit -am "refactor(compose-dash): 스캐폴드 Dockerfile 기반·자율제거(compose 포트추측·command 템플릿 삭제)"`

### Task A3: `/api/compose-scaffold` 루트 자동 / 애매하면 needPick

**Files:** Modify `plugin/scripts/marina-control.py` (compose-scaffold 핸들러)

- [ ] **Step 1: 핸들러 교체** — 루트 Dockerfile 있으면 yaml, 없거나 여러 개면 목록:

```python
        if parsed.path == "/api/compose-scaffold":
            qs = urllib.parse.parse_qs(parsed.query)
            target = Path((qs.get("path", [""])[0] or "").strip()).expanduser()
            subrepo = (qs.get("subrepo", [""])[0] or "").strip()
            chosen = (qs.get("dockerfile", [""])[0] or "").strip()
            ctx = (qs.get("context", [""])[0] or "").strip()        # 외부 마운트 경로(있으면)
            if not target.is_dir() or not subrepo:
                self.send_json({"ok": False, "error": "path·subrepo 필요"}); return
            d = target / subrepo.strip("/")
            dfs = _list_dockerfiles(d)
            if not chosen and dfs[:1] != ["Dockerfile"]:           # 루트 자동 불가 → 선택 요청
                self.send_json({"ok": True, "needPick": True, "dockerfiles": dfs}); return
            self.send_json({"ok": True, "yaml": _compose_scaffold_service(
                target, subrepo, dockerfile=chosen, build_context=ctx)})
            return
```

- [ ] **Step 2: 수동 확인** — 데몬 띄우고 `curl '…/api/compose-scaffold?path=<repo>&subrepo=multi'` → `needPick:true, dockerfiles:[...]`; `&dockerfile=x/Dockerfile` 추가 → yaml. (py_compile + 데몬 1회)
- [ ] **Step 3: 커밋** — `git commit -am "feat(compose-dash): compose-scaffold 루트 자동/애매하면 Dockerfile 목록 반환"`

### Task A4: 프론트 — Dockerfile 피커

**Files:** Modify `plugin/scripts/marina-control.py` (INDEX_HTML JS: `makeSubrepoRow` 의 `+ 서비스` onclick)

- [ ] **Step 1: 구현** — `+ 서비스` onclick: scaffold 호출 → `needPick` 이면 발견 목록을 행 아래 작은 버튼들로 렌더(클릭 시 그 dockerfile 로 재호출), 아니면 append:

```javascript
add.onclick = async () => {
  add.disabled = true;
  try {
    const q = '?path=' + enc(path) + '&subrepo=' + enc(s) + (mount ? '&context=' + enc(mount) : '');
    const rr = await api('/api/compose-scaffold' + q);
    if (rr && rr.needPick) { showDockerfilePicker(s, path, mount, rr.dockerfiles, row); }
    else if (rr && rr.yaml) { appendComposeService(rr.yaml); setComposeProgress('ok', s + ' 서비스 추가'); }
  } catch (e) { setComposeProgress('err', String((e && e.message) || e)); }
  finally { add.disabled = false; }
};
```
`showDockerfilePicker` = 행 아래 발견 Dockerfile 들을 버튼으로 깔고, 클릭하면 `…&dockerfile=<rel>` 로 재호출해 append.

- [ ] **Step 2: 프리뷰 검증(필수)** — :3940 ✎ 에서 multi 같은 애매 레포 `+ 서비스` → Dockerfile 목록 뜸 → 하나 선택 → 에디터에 append. 콘솔 0. (박제 방지)
- [ ] **Step 3: 커밋** — `git commit -am "feat(compose-dash): + 서비스 Dockerfile 피커(애매할 때 선택)"`

---

## Phase B — 외부 레포 격리 (Part 1)

### Task B1: registry externalRepos 저장

**Files:** Modify `plugin/scripts/marina.sh` (`registry_add`) · Test `plugin/tests/test-external-subrepo.sh`(신규)

- [ ] **Step 1: 실패 테스트** — 신규 test-external-subrepo.sh:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/proj"; mkdir -p "$P"; EXT="$TMP/ext-lib"; mkdir -p "$EXT"
git -C "$EXT" init -q; git -C "$EXT" commit -q --allow-empty -m init
bash "$SH" project add "$P" --external "be-api=$EXT" >/dev/null
python3 - "$MARINA_HOME" "$P" "$EXT" <<'PY' || { echo FAIL; exit 1; }
import json,os,sys
home,P,EXT=sys.argv[1],os.path.realpath(sys.argv[2]),os.path.realpath(sys.argv[3])
d=json.load(open(os.path.join(home,"projects.json")))
norm=lambda p:os.path.realpath(os.path.expanduser(p))
pr=next(x for x in d["projects"] if norm(x["root"])==P)
er=pr.get("externalRepos") or []
assert er and er[0]["name"]=="be-api" and norm(er[0]["source"])==EXT, er
PY
echo "PASS test-external-subrepo (registry)"
```

- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-external-subrepo.sh` → FAIL (`--external` 미지원)
- [ ] **Step 3: 구현** — `registry_add` 에 `--external name=path`(반복) 파싱 + entry["externalRepos"] 추가(절대경로 resolve, source 가 git 작업트리인지 `git -C <path> rev-parse` 검증, 아니면 die). 업서트 python 블록에 externalRepos 보존.
- [ ] **Step 4: 통과 확인** — Run → PASS
- [ ] **Step 5: 커밋** — `git commit -m "feat(registry): project add --external name=path (externalRepos 기록, git 검증)"`

### Task B2: attach 가 외부 레포를 worktree 로

**Files:** Modify `plugin/scripts/attach-detached-subrepos.sh` · Test `plugin/tests/test-external-subrepo.sh`

- [ ] **Step 1: 실패 테스트(실 git)** — `command -v git` 게이트. 위 테스트에 이어:

```bash
DEST="$TMP/wt"; mkdir -p "$DEST"; git -C "$EXT" commit -q --allow-empty -m c2
SOURCE_ROOT="$P" DEST_ROOT="$DEST" MARINA_HOME="$MARINA_HOME" BRANCH_PREFIX=claude \
  bash "$HERE/../scripts/attach-detached-subrepos.sh" >/dev/null 2>&1 || true
test -d "$DEST/.workspace/external/be-api/.git" -o -f "$DEST/.workspace/external/be-api/.git" || { echo "FAIL: external worktree 없음"; exit 1; }
br="$(git -C "$DEST/.workspace/external/be-api" branch --show-current)"
[[ "$br" == claude/* ]] || { echo "FAIL: 브랜치 $br"; exit 1; }
echo "PASS test-external-subrepo (attach)"
```

- [ ] **Step 2: 실패 확인** — Run → FAIL (외부 worktree 안 생김)
- [ ] **Step 3: 구현** — attach-detached-subrepos.sh: registry/env 에서 externalRepos 읽어, 각 `{name,source}` 에 대해 `dst=$DEST_ROOT/.workspace/external/$name`; 이미 worktree 면 skip, 아니면 `git -C "$source" worktree add --detach "$dst" HEAD` 후 `$BRANCH_PREFIX/$id` switch/create(기존 `attach_subrepo` 브랜치 로직 재사용·함수화).
- [ ] **Step 4: 통과 확인** — Run → PASS
- [ ] **Step 5: 커밋** — `git commit -m "feat(attach): externalRepos 를 .workspace/external/<name> 에 worktree+브랜치"`

### Task B3: 워크트리 teardown 시 외부 worktree 정리

**Files:** Modify `plugin/scripts/marina.sh`(워크트리 정리 경로) 또는 attach 스크립트의 detach 모드 · Test 위 파일에 추가

- [ ] **Step 1: 실패 테스트** — 정리 함수 호출 후 `$DEST/.workspace/external/be-api` 없음 + `git -C "$EXT" worktree list` 에 안 남음 단언.
- [ ] **Step 2: 실패 확인** — Run → FAIL
- [ ] **Step 3: 구현** — 정리 헬퍼: 각 externalRepo 에 `git -C "$source" worktree remove --force "$dst"` + `git -C "$source" worktree prune`. marina 의 워크트리 제거/Cleanup 경로에서 호출.
- [ ] **Step 4: 통과 확인** — Run → PASS
- [ ] **Step 5: 커밋** — `git commit -m "feat: 워크트리 정리 시 외부 레포 worktree 제거"`

### Task B4: 스캐폴드/등록이 외부 = 마운트 경로

**Files:** Modify `plugin/scripts/marina-control.py` (compose-register externalRepos 기록 위임, 프론트 외부 행 mount 전달)

- [ ] **Step 1: 구현** — 프론트: 외부 서브레포 행은 `mount = './.workspace/external/' + name` 을 scaffold 의 `context` 로 전달(Task A4 의 `mount`). compose-register 시 외부 서브레포 목록을 `run_marina_registry("project","add", target, "--external", f"{name}={source}" …)` 로 기록(또는 별도 호출). Dockerfile 감지는 `source`(실제 외부 레포)에서.
- [ ] **Step 2: 프리뷰 검증** — 외부 레포 추가 → `+ 서비스` → `build: ./.workspace/external/<name>` (절대경로 아님) + registry externalRepos 기록 확인.
- [ ] **Step 3: 커밋** — `git commit -am "feat(compose-dash): 외부 서브레포는 마운트 경로로 스캐폴드+registry 기록"`

### Task B5: 프론트 외부 뱃지

**Files:** Modify `plugin/scripts/marina-control.py` (`makeSubrepoRow` — 외부면 "외부" 뱃지, 마운트 컨텍스트 사용)

- [ ] **Step 1: 구현** — `makeSubrepoRow(path, s, opts)` 에 external 플래그 → "외부" 뱃지 표시 + scaffold 호출에 mount context. compose-detect/감지에서 외부 여부 표시(또는 browse 가 프로젝트 밖이면 external 로 표시).
- [ ] **Step 2: 프리뷰 검증** — 외부 추가 시 "외부" 뱃지 + 동작. 콘솔 0.
- [ ] **Step 3: 커밋** — `git commit -am "feat(compose-dash): 서브레포 행 외부 뱃지"`

---

## Phase C — AI 초안 정렬 (Part 3)

### Task C1: analyze 프롬프트 grounding + 외부 마운트

**Files:** Modify `plugin/scripts/marina-control.py` (`_compose_analyze_prompt`, `llm_compose_analyze`, compose-analyze 핸들러, 프론트 composeAnalyze) · Test `plugin/tests/test-compose-scaffold.sh`(프롬프트 단언)

- [ ] **Step 1: 실패 테스트** — 프롬프트에 외부 마운트 + Dockerfile/EXPOSE 힌트 포함 단언:

```python
subs=[{"name":"be-api","mount":"./.workspace/external/be-api","dockerfile":"Dockerfile","expose":"8081"}]
p=mc._compose_analyze_prompt(T,"",None,None,subs)
assert "./.workspace/external/be-api" in p and "8081" in p and "Dockerfile" in p, p
```

- [ ] **Step 2: 실패 확인** — Run → FAIL (subs dict 형태 미지원)
- [ ] **Step 3: 구현** — `_compose_analyze_prompt` 의 `subrepos` 가 dict 리스트({name,mount?,dockerfile?,expose?}) 도 받게: 각 서브레포에 "build context = <mount or ./name>, Dockerfile=<dockerfile>, EXPOSE=<expose> 를 토대로, 그 위에 dev 명령·구조 보강. 외부는 마운트 경로 사용, ../·절대 금지" 라인 추가. 프론트 composeAnalyze 가 서브레포 행에서 {name,mount,dockerfile,expose} 수집해 전달(스캐폴드 감지 재사용).
- [ ] **Step 4: 통과 확인** — Run → PASS
- [ ] **Step 5: 커밋** — `git commit -m "feat(compose-dash): AI 초안 grounding(Dockerfile/EXPOSE 힌트)+외부 마운트 경로"`

---

## 마무리

- [ ] 전체 스위트 그린(`for t in plugin/tests/*.sh; do bash "$t"; done`) + py_compile.
- [ ] :3940 프리뷰 E2E: 외부 레포 추가→`+ 서비스`(마운트)→등록(저장만)→(실 git 환경이면) attach 로 워크트리 체크아웃 확인.
- [ ] 메모리 갱신([[marina-compose-orchestration-direction]]): 외부 서브레포 격리·Dockerfile grounded 스캐폴드·AI 정렬 추가.
- [ ] 형 검토 → push(형 게이트).
