# Service-add (3 surface) + per-service root/central merge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 서비스 정의를 LLM 슬래시·CLI·대시보드 폼으로 추가/편집/삭제할 수 있게 하고, root(팀)+중앙(개인) 서비스를 name 단위로 머지(중앙 우선)해 개인이 공유 전 override·테스트할 수 있게 한다.

**Architecture:** stage-3 의 단일 파일 reader(`services_file_for`)를 **머지 reader**(`extra_services_for` = root ∪ 중앙, name 중앙 우선, `source` 태그)로 바꾸고, Python·`marina.sh` 양쪽이 같은 머지 규칙으로 서비스를 본다. 쓰기는 `marina.sh add-service/rm-service`(중앙 기본, `--root` 옵션)가 SoT 이고, 슬래시·API·폼이 전부 이걸 호출한다(등록 패턴과 동일).

**Tech Stack:** Python 3 stdlib 단일 파일 `marina-control.py`(http.server + 임베드 `INDEX_HTML`); bash `marina.sh`; standalone bash 테스트(`plugin/tests/`, curl+python3/importlib); UI 는 preview(:3901) Chrome.

---

## File Structure

| File | 책임 | 변경 |
|---|---|---|
| `plugin/scripts/marina-control.py` (reader) | 머지 + source | `extra_services_for` 머지로 교체, `services_for`/`service_subrepo_map` 가 그 위에 (Task 1) |
| `plugin/scripts/marina.sh` (조회) | 런처 머지 | 서비스 조회가 root+중앙 머지 (Task 2) |
| `plugin/scripts/marina.sh` (writer) | 쓰기 SoT | `add-service`/`rm-service` (Task 3) |
| `plugin/scripts/marina-control.py` (API) | POST 핸들러 | `/api/add-service`·`/api/remove-service` (Task 4) |
| `plugin/scripts/marina-control.py` (payload) | source 노출 | `_tagged_services` 에 `source` (Task 5) |
| `plugin/scripts/marina-control.py` (`INDEX_HTML`) | UI | 출처 뱃지 + "+ 서비스 추가"/편집/삭제 모달 (Task 5·6) |
| `plugin/commands/add-service.md` | 슬래시 | 신규 (Task 7) |
| `README.md` | 문서 | 서비스 추가·머지·중앙 경로 (Task 8) |
| `plugin/tests/test-service-merge.sh` 등 | 신규 | Task 1·3·4 |

**Anchor 는 인용 코드 기준** (라인 번호는 편집으로 드리프트).

## Conventions for every task

- **Worktree:** `~/.config/superpowers/worktrees/marina/multiproject-services`, branch `feature/multiproject-services`. git 은 `git -C <worktree>`.
- **Commit:** Conventional Commits, scope `plugin`. **No `Co-Authored-By`. No `Task:` trailer.** Local only, **never push**.
- **Python 편집 후:** `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read())"` (exit 0). **bash 편집 후:** `bash -n plugin/scripts/marina.sh`.
- **테스트:** `bash plugin/tests/<name>.sh` → `PASS <name>`.
- **회귀:** 기존 6 테스트(`test-multiproject-services`·`test-central-services`·`test-per-project-services`·`test-subrepo-tree-api`·`test-registry-api`·`test-docker-run-tokens`·`test-command-no-double-exec`)는 각 task 후 영향받는 것 재실행.

---

### Task 1: 머지 reader (Python) — root ∪ 중앙, name 중앙 우선, source 태그

**Files:** Modify `plugin/scripts/marina-control.py`; Test `plugin/tests/test-service-merge.sh` (create).

stage-3 의 `extra_services_for`(현재 `services_file_for` 단일 파일)를 **머지**로 바꾼다. 머지 결과는 full dict(name/portBase/cwd/run/cachePaths/orphanPattern/**source**). `services_for`/`service_subrepo_map` 도 이 머지 위에서 동작.

- [ ] **Step 1: 실패 테스트** — `plugin/tests/test-service-merge.sh`:

```bash
#!/usr/bin/env bash
# root ∪ 중앙 머지, name 겹치면 중앙 우선 + source 태그
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"web","portBase":3000,"cwd":"fe","run":"team-web"},{"name":"api","portBase":8080,"cwd":"be","run":"team-api"}]}
JSON
bash "$SH" add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
mkdir -p "$MARINA_HOME/services"
# 중앙: web override(run 다름) + worker 추가
cat > "$MARINA_HOME/services/$id.json" <<'JSON'
{"services":[{"name":"web","portBase":3000,"cwd":"fe","run":"my-web-override"},{"name":"worker","portBase":9000,"cwd":".","run":"my-worker"}]}
JSON
MARINA_HOME="$MARINA_HOME" python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: merge unit"; exit 1; }
import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mc",sys.argv[1]);mc=importlib.util.module_from_spec(spec);spec.loader.exec_module(mc)
root=Path(sys.argv[2])
svcs={s["name"]:s for s in mc.extra_services_for(root)}
assert set(svcs)=={"web","api","worker"}, set(svcs)        # 합집합
assert svcs["web"]["run"]=="my-web-override", svcs["web"]   # name 겹치면 중앙
assert svcs["web"]["source"]=="central", svcs["web"]
assert svcs["api"]["source"]=="root", svcs["api"]           # root 만 → root
assert svcs["worker"]["source"]=="central", svcs["worker"]
assert sorted(mc.services_for(root))==["api","web","worker"], mc.services_for(root)
assert mc.service_subrepo_map(root).get("api")!=None
PY
echo "PASS test-service-merge"
```

Run → FAIL (현재 `extra_services_for` 는 단일 파일·`source` 없음).

- [ ] **Step 2: `_read_services_file` 헬퍼 추가** — `extra_services_for` 바로 앞에 삽입:

```python
def _read_services_file(path: Path) -> list[dict[str, Any]]:
    # 한 서비스 정의 파일 파싱 → 검증된 full dict 목록 (없거나 비-dict → []).
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return []
    if not isinstance(data, dict):
        return []
    out: list[dict[str, Any]] = []
    for item in data.get("services", []):
        name = str(item.get("name", "")).strip()
        base = item.get("portBase")
        if name and name.isidentifier() and isinstance(base, int) and name not in _BUILTIN_SERVICES:
            orphan = item.get("orphanPattern")
            out.append({
                "name": name, "portBase": base,
                "cwd": str(item.get("cwd", "")), "run": str(item.get("run", "")),
                "cachePaths": [str(c) for c in item.get("cachePaths", []) if isinstance(c, str)],
                "orphanPattern": orphan if isinstance(orphan, str) else None,
            })
    return out
```

- [ ] **Step 3: `extra_services_for` 를 머지로 교체** — 기존 `extra_services_for` 본문(현재 `services_file_for` 사용)을 통째로:

```python
def extra_services_for(root: Path) -> list[dict[str, Any]]:
    # root(팀) ∪ 중앙(개인) 서비스. name 겹치면 중앙 우선. 각 항목 source 태그.
    project = project_for(root)
    proot = Path(project["root"]) if project else root
    merged: dict[str, dict[str, Any]] = {}
    for s in _read_services_file(proot / "marina-services.json"):
        merged[s["name"]] = {**s, "source": "root"}
    if project:
        for s in _read_services_file(MARINA_HOME / "services" / f"{project['id']}.json"):
            merged[s["name"]] = {**s, "source": "central"}
    return list(merged.values())
```

- [ ] **Step 4: `services_for` / `service_subrepo_map` 를 머지 위로** — 두 함수가 현재 `services_file_for` 로 파일을 직접 읽는다. `extra_services_for(root)` 를 쓰도록 교체:

`services_for`:
```python
def services_for(root: Path) -> tuple[str, ...]:
    return _BUILTIN_SERVICES + tuple(s["name"] for s in extra_services_for(root))
```
`service_subrepo_map`:
```python
def service_subrepo_map(root: Path) -> dict[str, str]:
    subs = subrepos_of(root)
    return {s["name"]: service_subrepo(s.get("cwd", ""), subs) for s in extra_services_for(root)}
```
그리고 이제 미사용이 된 `services_file_for` 는 삭제(`grep -n "services_file_for"` 로 잔여 0 확인 — Task 2 의 marina.sh 는 별개).

- [ ] **Step 5: parse + 테스트 + 회귀** — `ast.parse` exit 0; `bash plugin/tests/test-service-merge.sh` → PASS; 회귀 `test-central-services`·`test-multiproject-services`·`test-per-project-services`·`test-subrepo-tree-api` → PASS (단일→머지지만 단일 파일만 있을 때 동작 동일).

- [ ] **Step 6: Commit**
```bash
git add plugin/scripts/marina-control.py plugin/tests/test-service-merge.sh
git commit -m "feat(plugin): per-service root∪central merge reader (name=central wins, source tag)"
```

---

### Task 2: `marina.sh` 서비스 조회 머지

**Files:** Modify `plugin/scripts/marina.sh`; Test `plugin/tests/test-launcher-merge.sh` (create).

런처(`command_for`·`port_for`)가 보는 서비스도 root+중앙 머지여야 (Python 과 같은 규칙). 현재 `marina.sh` 는 `SERVICES_FILE` 단일 파일을 `service_json_field` 로 조회한다 → 머지 JSON 을 만들어 조회한다.

- [ ] **Step 1: 실패 테스트** — `plugin/tests/test-launcher-merge.sh`: 중앙이 override 한 run 이 `print-command` 에 반영되는지.

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"web","portBase":3000,"cwd":".","run":"exec echo TEAM_WEB {port}"}]}
JSON
bash "$SH" add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
mkdir -p "$MARINA_HOME/services"
cat > "$MARINA_HOME/services/$id.json" <<'JSON'
{"services":[{"name":"web","portBase":3000,"cwd":".","run":"exec echo MY_WEB {port}"}]}
JSON
cmd="$(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" print-command web 2>/dev/null)"
case "$cmd" in *MY_WEB*) ;; *) echo "FAIL: launcher did not merge central override: $cmd"; exit 1;; esac
echo "PASS test-launcher-merge"
```

Run → FAIL (현재 root 만 읽어 TEAM_WEB).

- [ ] **Step 2: 머지 JSON 헬퍼 추가** — `marina.sh` 에서 서비스 정의를 읽는 지점을 파악(`grep -n "SERVICES_FILE\|service_json_field\|merged_services" plugin/scripts/marina.sh`). `SERVICES_FILE` 단일 참조를, root+중앙을 머지한 JSON 을 내는 함수로 대체. `MARINA_HOME`/`PROJECTS_FILE` 는 이미 정의됨. 삽입할 함수(python-heredoc, Task 1 과 동일 규칙 — name 중앙 우선):

```bash
# root ∪ 중앙 서비스 머지 JSON 을 stdout 으로 (name 중앙 우선). service_json_field 가 이걸 조회.
merged_services_json() {
  python3 - "$ROOT" "$SOURCE_ROOT" "$PROJECTS_FILE" "$MARINA_HOME" <<'PY'
import json, os, sys
root, source_root, projects_file, home = sys.argv[1:5]
def read(p):
    try:
        d = json.load(open(p, encoding="utf-8"))
        return d.get("services", []) if isinstance(d, dict) else []
    except Exception:
        return []
def norm(p): return os.path.realpath(os.path.expanduser(p))
# 프로젝트 id (SOURCE_ROOT/ROOT 매칭) + root services 파일 경로
pid = ""; proot = source_root
try:
    data = json.load(open(projects_file, encoding="utf-8"))
    tgt = {norm(source_root), norm(root)}
    for p in data.get("projects", []):
        pr = norm(p.get("root", ""))
        if pr in tgt or any(t == pr or t.startswith(pr + os.sep) for t in tgt):
            pid = p.get("id", ""); proot = p.get("root", ""); break
except Exception:
    pass
merged = {}
for s in read(os.path.join(proot, "marina-services.json")):
    n = s.get("name");  merged[n] = s if n else merged
if pid:
    for s in read(os.path.join(norm(home), "services", pid + ".json")):
        n = s.get("name");  merged[n] = s if n else merged
print(json.dumps({"services": list(merged.values())}, ensure_ascii=False))
PY
}
```

Then make `service_json_field`(또는 service 조회부)가 `SERVICES_FILE` 대신 `merged_services_json` 출력을 파싱하게 한다 — 기존 `service_json_field` 구현을 보고(파일 읽기 → 머지 json 문자열 읽기) 최소 수정. (구현자: 기존 `service_json_field` 가 `SERVICES_FILE` 를 `python3 ... json.load(open(file))` 하는 형태라면, `merged_services_json` 을 변수에 담아 `json.loads(sys.argv)` 로 넘긴다.)

- [ ] **Step 3: bash -n + 테스트 + 회귀** — `bash -n plugin/scripts/marina.sh`; `bash plugin/tests/test-launcher-merge.sh` → PASS; 회귀 `test-docker-run-tokens`·`test-command-no-double-exec`·`test-central-services` → PASS.

- [ ] **Step 4: Commit**
```bash
git add plugin/scripts/marina.sh plugin/tests/test-launcher-merge.sh
git commit -m "feat(plugin): marina.sh service lookup merges root∪central (name=central wins)"
```

---

### Task 3: writer — `marina.sh add-service` / `rm-service`

**Files:** Modify `plugin/scripts/marina.sh`; Test `plugin/tests/test-service-writer.sh` (create).

`registry_add` 의 python-heredoc 패턴으로 서비스 파일을 upsert/remove. 기본 중앙 `~/.marina/services/<id>.json`, `--root` 면 프로젝트 root.

- [ ] **Step 1: 실패 테스트** — `plugin/tests/test-service-writer.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"
bash "$SH" add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
# 중앙 add
bash "$SH" add-service "$id" '{"name":"web","portBase":3000,"cwd":".","run":"x"}' >/dev/null
f="$MARINA_HOME/services/$id.json"
python3 -c "import json;s=json.load(open('$f'))['services'];assert len(s)==1 and s[0]['name']=='web',s"
# upsert (run 갱신)
bash "$SH" add-service "$id" '{"name":"web","portBase":3000,"cwd":".","run":"y"}' >/dev/null
python3 -c "import json;s=json.load(open('$f'))['services'];assert len(s)==1 and s[0]['run']=='y',s"
# --root → 프로젝트 root 파일
bash "$SH" add-service "$id" '{"name":"api","portBase":8080,"cwd":".","run":"z"}' --root >/dev/null
python3 -c "import json;s=json.load(open('$P/marina-services.json'))['services'];assert s[0]['name']=='api',s"
# rm
bash "$SH" rm-service "$id" web >/dev/null
python3 -c "import json;s=json.load(open('$f'))['services'];assert s==[],s"
# 잘못된 json → 비0
if bash "$SH" add-service "$id" '{"portBase":1}' >/dev/null 2>&1; then echo "FAIL: accepted no-name"; exit 1; fi
echo "PASS test-service-writer"
```

Run → FAIL (`add-service` 없음).

- [ ] **Step 2: `service_add`/`service_rm` 함수 추가** — `registry_default` 함수 뒤에 삽입:

```bash
service_target_file() {  # <id> [--root] → 쓸 파일 경로
  local id="$1" use_root="${2:-}"
  if [[ "$use_root" == "--root" ]]; then
    local root; root="$(python3 - "$PROJECTS_FILE" "$id" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: sys.exit(1)
m=next((p for p in d.get("projects",[]) if p.get("id")==sys.argv[2]),None)
print(m["root"] if m else "", end="")
PY
)"; [[ -n "$root" ]] || die "unknown id: $id"; echo "$root/marina-services.json"
  else echo "$MARINA_HOME/services/$id.json"; fi
}
service_add() {
  local id="${1:-}" svc_json="${2:-}" root_flag="${3:-}"
  [[ -n "$id" && -n "$svc_json" ]] || die "usage: marina add-service <id> '<json>' [--root]"
  local file; file="$(service_target_file "$id" "$root_flag")" || exit $?
  mkdir -p "$(dirname "$file")"
  python3 - "$file" "$svc_json" <<'PY'
import json,sys
file,raw=sys.argv[1],sys.argv[2]
try: svc=json.loads(raw)
except Exception as e: print(f"bad json: {e}",file=sys.stderr); sys.exit(1)
name=str(svc.get("name","")).strip()
if not name or not name.isidentifier(): print("name must be an identifier",file=sys.stderr); sys.exit(1)
if not isinstance(svc.get("portBase"),int): print("portBase must be int",file=sys.stderr); sys.exit(1)
if not str(svc.get("run","")).strip(): print("run must be non-empty",file=sys.stderr); sys.exit(1)
try: data=json.load(open(file,encoding="utf-8"))
except Exception: data={"services":[]}
if not isinstance(data,dict): data={"services":[]}
svcs=[s for s in data.get("services",[]) if s.get("name")!=name]
svcs.append(svc); data["services"]=svcs
json.dump(data,open(file,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
print(f"service {name} -> {file}")
PY
}
service_rm() {
  local id="${1:-}" name="${2:-}" root_flag="${3:-}"
  [[ -n "$id" && -n "$name" ]] || die "usage: marina rm-service <id> <name> [--root]"
  local file; file="$(service_target_file "$id" "$root_flag")" || exit $?
  [[ -f "$file" ]] || { echo "no services file: $file"; return 0; }
  python3 - "$file" "$name" <<'PY'
import json,sys
file,name=sys.argv[1],sys.argv[2]
data=json.load(open(file,encoding="utf-8"))
data["services"]=[s for s in data.get("services",[]) if s.get("name")!=name]
json.dump(data,open(file,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
print(f"removed {name} from {file}")
PY
}
```

- [ ] **Step 3: dispatch 추가** — 등록 dispatch `case`(Task: `add)`/`default)`/`rm)` 있는 곳)에 추가:
```bash
  add-service) shift; service_add "$@"; exit $? ;;
  rm-service)  shift; service_rm "$@";  exit $? ;;
```
그리고 `marina-entrypoint.sh` 패스스루 `case` 에 `add-service|rm-service` 추가(`add|infer|rm|default|ls|projects` 옆).

- [ ] **Step 4: bash -n + 테스트** — `bash -n`; `bash plugin/tests/test-service-writer.sh` → PASS.

- [ ] **Step 5: Commit**
```bash
git add plugin/scripts/marina.sh plugin/scripts/marina-entrypoint.sh plugin/tests/test-service-writer.sh
git commit -m "feat(plugin): marina.sh add-service/rm-service writer (central default, --root, upsert by name)"
```

---

### Task 4: API — `/api/add-service` · `/api/remove-service`

**Files:** Modify `plugin/scripts/marina-control.py`; Test `plugin/tests/test-service-api.sh` (create).

`run_marina_registry` 와 같은 방식으로 `marina.sh` shell-out. `do_POST` 의 no-service 섹션(`set-default-attach` 부근)에 추가.

- [ ] **Step 1: 실패 테스트** — `plugin/tests/test-service-api.sh`: 서버 띄우고 POST `/api/add-service` → 중앙 파일에 기록.

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""; cleanup(){ [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"; bash "$SH" add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
PORT=39720; b="http://127.0.0.1:$PORT"; H=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 50); do curl -sf "${H[@]}" "$b/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done
curl -s "${H[@]}" -d "{\"root\":\"$P\",\"service\":{\"name\":\"web\",\"portBase\":3000,\"cwd\":\".\",\"run\":\"x\"},\"central\":true}" "$b/api/add-service" >/dev/null
python3 -c "import json;s=json.load(open('$MARINA_HOME/services/$id.json'))['services'];assert s[0]['name']=='web',s" || { echo FAIL: add-service; exit 1; }
curl -s "${H[@]}" -d "{\"root\":\"$P\",\"name\":\"web\",\"central\":true}" "$b/api/remove-service" >/dev/null
python3 -c "import json;s=json.load(open('$MARINA_HOME/services/$id.json'))['services'];assert s==[],s" || { echo FAIL: remove-service; exit 1; }
echo "PASS test-service-api"
```

Run → FAIL (404).

- [ ] **Step 2: 핸들러 추가** — `do_POST` 에서 `set-default-attach` 분기 뒤에:

```python
            if self.path in ("/api/add-service", "/api/remove-service"):
                project = project_for(root)
                if not project:
                    raise ValueError("미등록 프로젝트")
                central = bool(body.get("central", True))
                args = [] if central else ["--root"]
                if self.path == "/api/add-service":
                    svc = body.get("service")
                    if not isinstance(svc, dict):
                        raise ValueError("service must be an object")
                    out = run_marina_registry("add-service", project["id"], json.dumps(svc, ensure_ascii=False), *args)
                else:
                    name = str(body.get("name", "")).strip()
                    if not name:
                        raise ValueError("name required")
                    out = run_marina_registry("rm-service", project["id"], name, *args)
                invalidate_registry_caches()
                self.send_json({"ok": True, "output": out.strip()})
                return
```
(`run_marina_registry` 가 `CalledProcessError` 를 던지면 기존 do_POST try/except 가 처리. 없으면 `try/except subprocess.CalledProcessError → ValueError`.)

- [ ] **Step 3: parse + 테스트 + 회귀** — `ast.parse`; `bash plugin/tests/test-service-api.sh` → PASS; `test-registry-api` 회귀 PASS.

- [ ] **Step 4: Commit**
```bash
git add plugin/scripts/marina-control.py plugin/tests/test-service-api.sh
git commit -m "feat(plugin): /api/add-service · /api/remove-service (marina.sh shell-out)"
```

---

### Task 5: payload `source` + 출처 뱃지 (UI)

**Files:** Modify `plugin/scripts/marina-control.py` (`_tagged_services`, `INDEX_HTML` CSS+render).

- [ ] **Step 1: payload 에 source** — `_tagged_services`(서비스 행 만드는 곳)에서 각 서비스에 `source` 를 붙인다. `extra_services_for(root)` 가 `source` 를 주므로 name→source 맵을 만들어 태그:
```python
def _tagged_services(root, ports, snapshot, listeners_by_port):
    smap = service_subrepo_map(root)
    srcmap = {s["name"]: s.get("source", "root") for s in extra_services_for(root)}
    out = []
    for svc in services_for(root):
        st = service_status(root, svc, ports.get(svc), snapshot, listeners_by_port)
        st["subrepo"] = smap.get(svc, "")
        st["source"] = srcmap.get(svc, "root")
        out.append(st)
    return out
```

- [ ] **Step 2: 뱃지 CSS** — `INDEX_HTML` `<style>` 의 `.svc` 규칙 부근에:
```css
    .svc-src { font-size: 10px; padding: 1px 6px; border-radius: 6px; margin-left: 6px; }
    .svc-src.central { background: hsl(36,90%,94%); color: hsl(30,80%,38%); }   /* 내 override */
    .svc-src.root { background: var(--sys-style-neutral-light); color: var(--sys-cont-neutral-light); }  /* 팀 */
```

- [ ] **Step 3: 뱃지 렌더** — 서비스 행 만드는 JS(`makeSvcRow` 또는 svc 행 템플릿, `grep -n "svc-name\|makeSvcRow\|data-act=\"start\"" plugin/scripts/marina-control.py`)에서 서비스명 옆에 출처 뱃지:
```javascript
const src = svc.source === 'central'
  ? '<span class="svc-src central" title="내 로컬 override (~/.marina/services)">내 override</span>'
  : '<span class="svc-src root" title="팀 공유 (marina-services.json, repo)">팀</span>';
```
서비스명 span 뒤에 `src` 삽입.

- [ ] **Step 4: parse + preview 검증** — `ast.parse`; preview(:3901, 본 검증 패턴)로 mdc/homeserver 카드에 뱃지 렌더 확인(콘솔 에러 0). (스크린샷 1장.)

- [ ] **Step 5: Commit**
```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(plugin): per-service source badge (team root / my central override)"
```

---

### Task 6: 서비스 추가/편집/삭제 모달 (UI)

**Files:** Modify `plugin/scripts/marina-control.py` (`INDEX_HTML` CSS+JS). 등록 모달(`openRegisterPanel`/`#registerModal` 패턴)을 미러한다.

- [ ] **Step 1: "+ 서비스 추가" 버튼** — subrepo 헤더(`renderSubrepoHead`)와 빈 서비스/`no svc` 자리에 `<button data-add-service data-subrepo="...">+ 서비스 추가</button>`. 클릭 → 서비스 모달 열기.

- [ ] **Step 2: 서비스 모달 마크업** — 등록 모달(`#registerModal`) 옆에 `#serviceModal`: 입력 `name`·`portBase`·`cwd`(`<input list>` = subrepo datalist + 자유)·`run`(textarea + placeholder `exec ... {port} {profile}`)·고급 토글(`cachePaths` csv·`orphanPattern`)·체크박스 `팀 공유 (root 에 커밋)`·버튼 `저장`/`취소`. 등록 모달 CSS 클래스 재사용.

- [ ] **Step 3: 저장 핸들러** — `저장` → `/api/add-service` POST `{root: selected.root, service: {name,portBase:Number,cwd,run,cachePaths?,orphanPattern?}, central: !teamShareChecked}` → 성공 시 모달 닫고 `refresh()`. 검증(빈 name/run/포트 NaN)은 클라에서 1차, 서버가 2차. `api()` 헬퍼(기존) 사용, try/catch 로 에러 표면화(등록 모달 패턴).

- [ ] **Step 4: 편집/삭제** — 서비스 행에 `✎`(클릭 → 모달 prefill: 기존 name/port/cwd/run + `central` 체크는 현재 source 로 고정 표시)·`✕`(확인 후 `/api/remove-service` `{root,name,central: source==='central'}`). 편집 저장도 `/api/add-service`(upsert).

- [ ] **Step 5: parse + preview 검증** — `ast.parse`; preview(:3901) Chrome 로 **풀 흐름 실검증**: 빈 프로젝트(or homeserver)에서 "+ 서비스 추가" → 입력 → 저장 → 서비스 행 + 뱃지 등장 → 편집 → 삭제 → 폴백. 콘솔 에러 0. (스크린샷.)

- [ ] **Step 6: Commit**
```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(plugin): dashboard service add/edit/remove modal (+central/root team-share toggle)"
```

---

### Task 7: LLM 슬래시 — `/marina:add-service`

**Files:** Create `plugin/commands/add-service.md`.

`plugin/commands/register.md` 패턴(본문 = 에이전트 프롬프트).

- [ ] **Step 1: 커맨드 파일** — `plugin/commands/add-service.md`:

````markdown
---
description: Analyze a project and register its dev services with marina (marina-services.json)
allowed-tools: Bash, Read, Glob, Grep
---
Analyze the target project and register its runnable dev services with marina.

Target: `$ARGUMENTS` (a project path; if empty, use the current git project's main checkout via `git rev-parse --path-format=absolute --git-common-dir` → its dirname).

1. Resolve the project **id**: `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" ls` and match the path, or register first with `add` if missing.
2. Inspect the repo to find runnable services — read `package.json` (scripts.dev/start), `build.gradle*`/`settings.gradle*` (Spring bootRun modules), `Dockerfile`/`docker-compose.yml`, `pyproject.toml`/`requirements.txt` (uvicorn/flask). For each, derive `name` (identifier), `portBase` (the app's default port; avoid collisions across services), `cwd` (relative to project root / its subrepo), and `run` — a shell command using marina tokens `{port}` (and `{profile}` if the framework has profiles). Native example: `exec npm run dev -- --port {port}`. Docker example: `exec env HOST_PORT={port} COMPOSE_PROJECT_NAME=svc-{session} docker compose up`.
3. **Show the user the proposed services (name/port/cwd/run) and ask for confirmation.** Adjust per feedback.
4. Register each (central by default; pass `--root` only if the user wants it committed to the repo for team sharing):
   `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" add-service <id> '<service-json>'`
5. Confirm with `... ls` and tell the user to refresh the dashboard.

Keep `run` a single shell command; complex startup should call a project-side helper script. Default to central storage so the project repo stays untouched unless the user asks for team sharing.
````

- [ ] **Step 2: 검증** — 파일 파싱/구문 확인: `python3 -c "import re,sys; t=open('plugin/commands/add-service.md').read(); assert t.startswith('---') and 'add-service' in t"`. (슬래시는 실세션에서 동작 — 본문이 프롬프트라 단위 실행 불가; 존재·형식만.)

- [ ] **Step 3: Commit**
```bash
git add plugin/commands/add-service.md
git commit -m "feat(plugin): /marina:add-service slash — LLM analyzes project, registers services"
```

---

### Task 8: README — 서비스 추가 3 surface + 머지 모델

**Files:** Modify `README.md`.

- [ ] **Step 1: 문서 추가** — `## 서비스 정의` 섹션에: (a) **저장 위치** — 프로젝트 root `marina-services.json`(팀 공유, 커밋) vs 중앙 `~/.marina/services/<id>.json`(개인, repo 무관), **둘 다 있으면 name 단위 머지(중앙 우선)** = 개인 override; (b) **추가 방법 3가지** — 대시보드 "+ 서비스 추가", `/marina:add-service`(LLM), `marina add-service <id> '<json>' [--root]`; (c) stale 된 `## 처음 실행` 의 `대시보드 UI — (예정, phase 3)` 줄을 "구현됨"으로 수정.

- [ ] **Step 2: Commit**
```bash
git add README.md
git commit -m "docs(plugin): service-add (3 surface) + root∪central merge + fix stale phase-3 note"
```

---

## Self-Review

- **Spec coverage:** §A 머지=Task 1·2 / §B writer=Task 3 / §C 슬래시=Task 7 / §D 폼·뱃지=Task 5·6 / API=Task 4 / 문서=Task 8. ✓
- **Open items:** (1) marina.sh 머지=Task 2 `merged_services_json`. (2) source 노출=Task 5. (3) 편집 UX=Task 6 Step 4(prefill + source 고정). ✓
- **Type consistency:** `extra_services_for` 가 full dict(+source) 반환 — Task 1 정의, Task 5 가 source 소비. `add-service <id> '<json>' [--root]` 시그니처 — Task 3 정의, Task 4 API·Task 7 슬래시가 동일 호출. `service`/`central`/`name` API 키 — Task 4·6 일치. ✓
- **No placeholders:** 코어/writer/API 는 완전 코드. UI(Task 5·6)는 기존 등록 모달 패턴 미러 + 정확한 요소·API 계약 명시 + preview 실검증 — JS 전체 대신 anchor·계약(구현자가 기존 패턴 따름).

## Out of scope (per spec)
- 휴리스틱 코드 추론(LLM 슬래시가 대신) · run 템플릿 빌더 · 서비스 reorder.
