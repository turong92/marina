# 대시보드 compose 등록 + LLM 초안 (Plan C+D) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 대시보드에서 compose-kind 프로젝트를 등록한다 — 레포 import / ✨AI 초안(LLM) / 직접 작성 → YAML 에디터 → 검증(`docker compose config` + isolation) → `marina project add --compose` 경유 등록.

**Architecture:** 서비스 LLM 등록(`llm_analyze`/`/api/llm-analyze`/assist bar)을 **프로젝트/compose 레벨로 복제**. LLM은 read-only config 함수(레포→compose YAML), 모든 side effect는 daemon. 에디터 YAML이 single source. 자동 기동 검증 루프 없음(사람 검토). 등록은 기존 CLI(`marina project add --compose`, root 기준 upsert + 파일 복사)로 funnel — 새 영속화 경로 0.

**Tech Stack:** Python stdlib(daemon `marina-control.py`), bash(`marina.sh`), `marina-compose.py`(순수 함수: `isolation_breakers`), 바닐라 JS(`INDEX_HTML`), docker compose. 테스트=bash + `MARINA_LLM_FAKE` 가짜 LLM, 실docker는 `docker info` 게이트.

**SoT 설계:** `docs/specs/2026-06-19-compose-registration-and-ai-draft-design.md`.

**작업 브랜치:** `claude/suspicious-cartwright-61c154` (compose A+B+로그 위에 누적). 커밋: Conventional Commits, **Co-Authored-By·Task trailer 없음**.

**참조 코드(미러 대상):**
- `marina-control.py`: `_analyze_prompt`(~1064) · `llm_analyze`(~1103) · `_llm_provider`/`_llm_run`(996–1061) · `_extract_service_json`(~891) · do_POST 라우팅(5466–) : `add-project`(5495) `llm-analyze`(5635) · do_GET `browse`(5380) · `run_marina_registry`/`invalidate_registry_caches` · 프론트 add-project/browse JS(3303–3460) · LLM assist JS(3559–3700).
- `marina-compose.py`: `isolation_breakers`(23) · `docker_config_json`(117).
- `marina.sh`: `project add`(91–155, `--compose`/`--env-var`/`--env-default`, upsert by root, `cp` 복사).
- 테스트 하니스: `test-llm-analyze.sh`(fake LLM + python import `mc`) · `test-llm-api.sh`(데몬 띄워 curl + origin-gate) · `test-compose-config.sh`(실docker 게이트).

---

## File Structure

- **`plugin/scripts/marina-control.py`** (수정): Plan D 헬퍼 2개(`_compose_analyze_prompt`, `llm_compose_analyze`) + `_extract_compose_yaml` + `compose_validate` 헬퍼; do_POST 라우트 3개(`/api/compose-analyze`, `/api/compose-validate`, `/api/compose-register`); do_GET 라우트 1개(`/api/compose-detect`, import 후보 + 등록된 compose의 stored yaml); `INDEX_HTML` compose 등록 모달 + assist bar JS/CSS.
- **`plugin/scripts/marina-compose.py`** (재사용만): `isolation_breakers` import. 변경 없음(가능하면).
- **`plugin/scripts/marina.sh`** (변경 없음 예상): `project add --compose` 이미 존재.
- **테스트(신규)**: `test-compose-llm-analyze.sh`(헬퍼 단위, fake LLM) · `test-compose-register-api.sh`(데몬 엔드포인트 + origin-gate) · `test-compose-validate.sh`(검증, 실docker 게이트).
- **`README.md`** (수정): 대시보드 compose 등록 섹션.

> compose-analyze/validate/register는 **미등록 프로젝트 경로(`path`)** 기준(등록 중이므로) — `add-project` 패턴을 따르고, `root=safe_root()`(5550) 위쪽에 배치.

---

## Task 1: Plan D 헬퍼 — `_compose_analyze_prompt` + `_extract_compose_yaml` + `llm_compose_analyze`

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`llm_analyze` 정의 직후, ~1123 뒤에 추가)
- Test: `plugin/tests/test-compose-llm-analyze.sh` (신규)

- [ ] **Step 1: 실패 테스트 작성** — `test-llm-analyze.sh` 하니스 미러(fake LLM = `out-<n>` 파일 emit, python으로 `mc.llm_compose_analyze` 호출)

```bash
#!/usr/bin/env bash
# llm_compose_analyze: LLM 출력에서 compose YAML 추출(펜스/raw), services: 없으면 1회 재시도 후 ValueError.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/proj"; mkdir -p "$P"

# fake LLM: prompt(stdin) 무시하고 $MARINA_HOME/out-<callcount> 출력(없으면 out-1)
cat > "$TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
n="$MARINA_HOME/.n"; c=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$n"
f="$MARINA_HOME/out-$c"; [ -f "$f" ] || f="$MARINA_HOME/out-1"; cat "$f"
EOF
chmod +x "$TMP/fake.sh"; export MARINA_LLM_FAKE="$TMP/fake.sh"

# (a) 펜스로 감싼 정상 출력 → 추출되고 services: 보존
printf '```yaml\nservices:\n  web:\n    image: nginx\n```\n' > "$MARINA_HOME/out-1"
rm -f "$MARINA_HOME/.n"
python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: fenced extract"; exit 1; }
import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mc",sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
y=mc.llm_compose_analyze(Path(sys.argv[2]))
assert "services:" in y and "nginx" in y and "```" not in y, repr(y)
PY

# (b) 1차 prose(서비스 없음) → 2차 정상 → 재시도로 성공
printf 'sorry here you go\n' > "$MARINA_HOME/out-1"
printf 'services:\n  api:\n    image: x\n' > "$MARINA_HOME/out-2"
rm -f "$MARINA_HOME/.n"
python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: retry then ok"; exit 1; }
import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mc",sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
y=mc.llm_compose_analyze(Path(sys.argv[2]))
assert "api:" in y, repr(y)
PY

# (c) 2회 다 prose → ValueError
printf 'nope\n' > "$MARINA_HOME/out-1"; rm -f "$MARINA_HOME/out-2" "$MARINA_HOME/.n"
python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: exhausted raises"; exit 1; }
import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mc",sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
try:
    mc.llm_compose_analyze(Path(sys.argv[2])); assert False, "expected ValueError"
except ValueError: pass
PY
echo "PASS test-compose-llm-analyze"
```

- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-compose-llm-analyze.sh` · Expected: FAIL (`mc.llm_compose_analyze` AttributeError).

- [ ] **Step 3: 구현** — `marina-control.py`의 `llm_analyze` 정의 직후에 추가(상단에 `import re`·`subprocess`·`tempfile` 이미 있음 — 없으면 추가):

```python
def _compose_analyze_prompt(root: Path, instruction: str, current_yaml: str | None) -> str:
    lines = [
        "You are writing a docker compose file for LOCAL DEV of a full-stack project, for the marina orchestrator.",
        "Output ONLY the docker-compose YAML — no prose. A ```yaml fence is allowed.",
        f"Project root: {root}",
        "",
        "Inspect the repo (root and subdirectories) for each runnable service: Dockerfile(s) (often prod), "
        "package.json (scripts.dev), build.gradle*/settings.gradle* (Spring bootRun), "
        "pyproject.toml/requirements.txt (uvicorn/flask). Emit ONE compose defining every service on a "
        "single default network for DEV:",
        "- each service: build: at that subdir's Dockerfile (reuse the prod Dockerfile) or image: for a runtime; "
        "a DEV command overriding prod CMD (hot-reload); bind-mount the source (e.g. ./be-api:/app) for live edits.",
        "- inter-service calls use the compose SERVICE NAME as host via container DNS (e.g. http://be:8081) — "
        "NEVER hardcode a host port between services.",
        "- publish ports (ports:) ONLY for services a human opens from the host (e.g. web); internal-only use expose.",
        "- relative paths (./subdir) only — marina resolves them per worktree.",
        "- do NOT set container_name; do NOT use network_mode: host (marina isolates per worktree — these are rejected).",
        "- read the active environment from one env var with a default so plain `docker compose up` works, e.g. ${APP_ENV:-local}.",
    ]
    if current_yaml:
        lines += ["", "Current compose (edit this):", current_yaml]
    if instruction:
        lines += ["", f"User instruction: {instruction}"]
    lines += ["", "Output the compose YAML now:"]
    return "\n".join(lines)


def _extract_compose_yaml(raw: str) -> str:
    """LLM 출력 → compose YAML. ```yaml/``` 펜스 우선, 없으면 raw. 'services:' 없으면 거부."""
    s = (raw or "").strip()
    m = re.search(r"```(?:ya?ml)?\s*\n(.*?)```", s, re.DOTALL)
    if m:
        s = m.group(1).strip()
    if "services:" not in s:
        raise ValueError("compose YAML 아님 (services: 없음)")
    return s + "\n"


def llm_compose_analyze(root: Path, instruction: str = "", current_yaml: str | None = None) -> str:
    """read-only LLM 이 레포 보고 dev compose 초안(YAML) 생성. 2회 재시도, 모든 side effect 없음."""
    provider = _llm_provider()
    if not provider:
        raise ValueError("LLM 미설치 (claude/codex 없음)")
    prompt = _compose_analyze_prompt(root, instruction, current_yaml)
    last_err = ""
    for attempt in range(2):
        p = prompt if attempt == 0 else (
            prompt + f"\n\nYour previous output was invalid ({last_err}). Output ONLY the compose YAML.")
        raw = _llm_run(provider, p, root)
        try:
            return _extract_compose_yaml(raw)
        except ValueError as exc:
            last_err = str(exc)
    raise ValueError(f"LLM compose 초안 파싱 실패: {last_err}")
```

- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-compose-llm-analyze.sh` · Expected: `PASS test-compose-llm-analyze`.

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-compose-llm-analyze.sh
git commit -m "feat(compose): LLM compose 초안 헬퍼 (llm_compose_analyze) — read-only, YAML 추출+재시도"
```

---

## Task 2: 검증 헬퍼 `compose_validate` (`docker compose config` + `isolation_breakers`)

**Files:**
- Modify: `plugin/scripts/marina-control.py` (`llm_compose_analyze` 뒤. `marina-compose` 모듈 핸들은 기존 `compose_project_name` 로딩분 재사용 — 검색: `compose_project_name` 의 import 위치)
- Test: `plugin/tests/test-compose-validate.sh` (신규, 실docker 게이트)

- [ ] **Step 1: 실패 테스트 작성**

```bash
#!/usr/bin/env bash
# compose_validate: docker compose config 로 해석 → isolation_breakers. container_name=에러, 정상=ok.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-validate (docker 미가동)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"; P="$TMP/proj"; mkdir -p "$P"

python3 - "$CTRL" "$P" <<'PY' || { echo "FAIL: compose_validate"; exit 1; }
import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mc",sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
pd=Path(sys.argv[2])
ok_yaml="services:\n  web:\n    image: nginx\n    ports: [\"8080:80\"]\n"
r=mc.compose_validate(ok_yaml, pd, "APP_ENV", "local")
assert r["ok"] and not r["errors"], r
bad="services:\n  web:\n    image: nginx\n    container_name: fixed\n"
r2=mc.compose_validate(bad, pd, "", "")
assert not r2["ok"] and any("container_name" in e for e in r2["errors"]), r2
broken="services: [this is not valid"
r3=mc.compose_validate(broken, pd, "", "")
assert not r3["ok"] and r3["errors"], r3
PY
echo "PASS test-compose-validate"
```

- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-compose-validate.sh` · Expected: FAIL (`compose_validate` AttributeError) — docker 가동 시. (docker 없으면 SKIP — CI 동등.)

- [ ] **Step 3: 구현** — `marina-control.py`에 추가. (기존에 `marina-compose` 를 로드해 `compose_project_name` 을 쓰는 모듈 핸들이 있다 — 그 핸들을 `_cmod` 라 가정; 없으면 같은 importlib 로더로 1회 로드해 모듈 전역에 캐시. `isolation_breakers` 를 그 핸들에서 호출.)

```python
def compose_validate(yaml_text: str, project_dir: Path,
                     env_var: str = "", env_default: str = "") -> dict[str, Any]:
    """yaml 을 temp 에 써서 `docker compose config` 로 해석 → isolation_breakers.
    반환 {ok, errors[], warnings[]}. docker 실패(파싱/보간) → ok:False + stderr."""
    env = dict(os.environ)
    if env_var:
        env.setdefault(env_var, env_default or "local")
    with tempfile.TemporaryDirectory() as td:
        f = Path(td) / "docker-compose.yml"
        f.write_text(yaml_text, encoding="utf-8")
        try:
            out = subprocess.check_output(
                ["docker", "compose", "-f", str(f), "--project-directory", str(project_dir),
                 "config", "--format", "json"],
                text=True, env=env, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError as exc:
            return {"ok": False, "errors": [(exc.output or "").strip() or "docker compose config 실패"], "warnings": []}
    errors, warnings = _cmod.isolation_breakers(json.loads(out))
    return {"ok": not errors, "errors": errors, "warnings": warnings}
```

> `_cmod` 가 없으면 이 한 줄을 헬퍼 위에 추가(기존 compose_project_name 로딩과 중복이면 그걸 재사용):
> ```python
> _cmod = _load_module("marina_compose", CONTROL_SCRIPT.parent / "marina-compose.py")  # 기존 로더 사용
> ```
> (실제 로더 이름·핸들은 `grep -n "marina-compose" marina-control.py` 로 확인해 그대로 사용.)

- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-compose-validate.sh` · Expected: `PASS test-compose-validate` (docker 가동 시).

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-compose-validate.sh
git commit -m "feat(compose): compose_validate — docker compose config + isolation_breakers (env-aware)"
```

---

## Task 3: 엔드포인트 — `/api/compose-analyze`, `/api/compose-validate`, `/api/compose-register` + `/api/compose-detect`

**Files:**
- Modify: `plugin/scripts/marina-control.py` (do_POST: `add-project`(5495) 블록 뒤 — `root=safe_root()`(5550) **위**. do_GET: `browse`(5380) 뒤)
- Test: `plugin/tests/test-compose-register-api.sh` (신규)

- [ ] **Step 1: 실패 테스트 작성** — `test-llm-api.sh` 미러(데몬 띄워 curl, fake LLM, origin-gate)

```bash
#!/usr/bin/env bash
# compose 등록 엔드포인트: analyze(fake LLM)→validate(docker)→register(projects.json kind:compose + 복사). origin-gate.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"; CTRL="$SCR/marina-control.py"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/proj"; mkdir -p "$P/web"; : > "$P/web/Dockerfile"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
cleanup(){ kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT

# fake LLM → 항상 정상 compose 출력
cat > "$TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
printf 'services:\n  web:\n    image: nginx\n    ports: ["8080:80"]\n'
EOF
chmod +x "$TMP/fake.sh"

MARINA_LLM_FAKE="$TMP/fake.sh" MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
b="http://127.0.0.1:$PORT"; H=(-H "Origin: $b" -H "content-type: application/json")
for i in $(seq 1 50); do curl -s -o /dev/null "$b/api/sessions" && break; sleep 0.1; done

# analyze: 미등록 path 로도 동작(등록 중이므로)
curl -s "${H[@]}" -d "{\"path\":\"$P\"}" "$b/api/compose-analyze" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'] and 'services:' in r['yaml'], r" || { echo "FAIL: compose-analyze"; exit 1; }

# origin-gate: 잘못된 Origin → 403
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Origin: http://evil.test" -H "content-type: application/json" -d "{\"path\":\"$P\"}" "$b/api/compose-analyze")
[ "$code" = "403" ] || { echo "FAIL: origin-gate ($code)"; exit 1; }

# detect: 레포에 compose 두면 후보로 잡힘
printf 'services:\n  x:\n    image: alpine\n' > "$P/docker-compose.yml"
curl -s "${H[@]}" "$b/api/compose-detect?path=$P" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'] and any(f['rel']=='docker-compose.yml' for f in r['files']), r" || { echo "FAIL: compose-detect"; exit 1; }

# register: validate(docker 가동 시 실검증)→ projects.json kind:compose + ~/.marina/<id>/ 복사
if docker info >/dev/null 2>&1; then
  Y='services:\n  web:\n    image: nginx\n    ports: ["8080:80"]\n'
  curl -s "${H[@]}" -d "{\"path\":\"$P\",\"yaml\":\"$Y\",\"envVar\":\"APP_ENV\",\"envDefault\":\"local\"}" "$b/api/compose-register" \
    | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'], r" || { echo "FAIL: compose-register"; exit 1; }
  python3 - "$MARINA_HOME" "$(basename "$(cd "$P" && pwd -P)")" <<'PY' || { echo "FAIL: registry kind:compose"; exit 1; }
import json,sys,os
from pathlib import Path
home,pid=Path(sys.argv[1]),sys.argv[2]
d=json.loads((home/"projects.json").read_text())
p=next(x for x in d["projects"] if x["id"]==pid)
assert p["kind"]=="compose" and p["composeFile"]=="docker-compose.yml" and p["composeEnvVar"]=="APP_ENV" and p["composeEnvDefault"]=="local", p
assert (home/pid/"docker-compose.yml").exists(), "stored compose missing"
PY
else
  echo "  (docker 미가동 — register 실검증 SKIP)"
fi
echo "PASS test-compose-register-api"
```

- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-compose-register-api.sh` · Expected: FAIL (`compose-analyze` 404 → assert 실패).

- [ ] **Step 3: 구현(do_POST)** — `add-project` 블록(5509 `return`) 직후, `root = safe_root(...)`(5550) **위**에 추가:

```python
            if self.path == "/api/compose-analyze":
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not str(body.get("path", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                cur = body.get("currentYaml")
                yaml_text = llm_compose_analyze(
                    target, str(body.get("instruction", "")).strip(),
                    cur if isinstance(cur, str) and cur.strip() else None)
                self.send_json({"ok": True, "yaml": yaml_text})
                return

            if self.path == "/api/compose-validate":
                yaml_text = str(body.get("yaml", ""))
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not yaml_text.strip():
                    raise ValueError("yaml required")
                if not str(body.get("path", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                self.send_json(compose_validate(
                    yaml_text, target,
                    str(body.get("envVar", "")).strip(), str(body.get("envDefault", "")).strip()))
                return

            if self.path == "/api/compose-register":
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not str(body.get("path", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                yaml_text = str(body.get("yaml", ""))
                if not yaml_text.strip():
                    raise ValueError("yaml required")
                env_var = str(body.get("envVar", "")).strip()
                env_default = str(body.get("envDefault", "")).strip() or "local"
                compose_file = str(body.get("composeFile", "")).strip() or "docker-compose.yml"
                v = compose_validate(yaml_text, target, env_var, env_default)
                if not v["ok"]:
                    self.send_json({"ok": False, **v})
                    return
                with tempfile.TemporaryDirectory() as td:
                    tmp = Path(td) / compose_file
                    tmp.write_text(yaml_text, encoding="utf-8")
                    args = [str(target), "--compose", str(tmp)]
                    if env_var:
                        args += ["--env-var", env_var, "--env-default", env_default]
                    try:
                        out = run_marina_registry("project", "add", *args)
                    except subprocess.CalledProcessError as exc:
                        raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                self.send_json({"ok": True, "id": target.resolve().name,
                                "output": out.strip(), "warnings": v.get("warnings", [])})
                return
```

- [ ] **Step 4: 구현(do_GET)** — `browse` 블록(5407 위) 근처, `/api/browse` 처리 뒤에 추가:

```python
        if parsed.path == "/api/compose-detect":
            qs = urllib.parse.parse_qs(parsed.query)
            target = Path((qs.get("path", [""])[0] or "").strip()).expanduser()
            if not target.is_dir():
                self.send_json({"ok": False, "files": [], "stored": None})
                return
            files = []
            for p in sorted(target.rglob("*compose*.y*ml")):
                if any(part in (".git", "node_modules", ".workspace") for part in p.parts):
                    continue
                if p.name == "marina-overlay.yml":
                    continue
                files.append({"path": str(p), "rel": str(p.relative_to(target))})
                if len(files) >= 50:
                    break
            # 이미 등록된 compose 프로젝트면 보관본도 같이(편집용)
            stored = None
            proj = project_for(target)
            if proj and proj.get("kind") == "compose":
                sp = MARINA_HOME / proj["id"] / proj.get("composeFile", "docker-compose.yml")
                if sp.exists():
                    stored = {"yaml": sp.read_text(encoding="utf-8"),
                              "composeFile": proj.get("composeFile", "docker-compose.yml"),
                              "envVar": proj.get("composeEnvVar", ""),
                              "envDefault": proj.get("composeEnvDefault", "local")}
            self.send_json({"ok": True, "files": files, "stored": stored})
            return
```

> 주의: `project_for`/`MARINA_HOME`/`urllib`/`Path` 는 이미 모듈 전역. do_GET 상단 origin 정책은 GET이라 별도 게이트 없음(기존 browse와 동일). `safe_root` 안 씀(미등록 path 허용).

- [ ] **Step 5: 통과 확인** — Run: `bash plugin/tests/test-compose-register-api.sh` · Expected: `PASS test-compose-register-api`.

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina-control.py plugin/tests/test-compose-register-api.sh
git commit -m "feat(compose): 대시보드 등록 엔드포인트 — compose-analyze/validate/register/detect (path 기반, marina project add 경유)"
```

---

## Task 4: 회귀 가드 — native fallback 무영향 + 전체 스위트

**Files:**
- Test: 기존 `plugin/tests/*.sh` 전체

- [ ] **Step 1: 전체 스위트 실행**

Run:
```bash
pass=0; fail=0; failed=""
for t in plugin/tests/*.sh; do out=$(bash "$t" 2>&1); rc=$?; if [ $rc -ne 0 ]; then fail=$((fail+1)); failed="$failed $t"; else pass=$((pass+1)); fi; done
echo "PASS=$pass FAIL=$fail$failed"
```
Expected: `FAIL=0` (신규 3 테스트 포함, 기존 52 무회귀 → 55 PASS; docker 미가동 시 일부 SKIP=PASS 취급).

- [ ] **Step 2: native fallback 확인** — `test-compose-native-fallback.sh` 가 여전히 통과(=docker 호출 0인 native 경로 무회귀). Run: `bash plugin/tests/test-compose-native-fallback.sh` · Expected: PASS.

- [ ] **Step 3: 커밋(필요 시 없음)** — 코드 변경 없으면 스킵.

---

## Task 5: 프론트 — compose 등록 모달 마크업 + 진입

**Files:**
- Modify: `plugin/scripts/marina-control.py` `INDEX_HTML` (등록/프로젝트 UI 영역 — 검색: add-project 모달 마크업; LLM assist bar 마크업 `3559–3700` 인접)

- [ ] **Step 1: 진입점** — 프로젝트 등록 흐름(add-project)에 `kind` 선택을 더한다: "일반(native)" | "compose". compose 선택 시 compose 등록 모달을 연다. (기존 add-project 모달/스위처 마크업을 찾아 그 옆에 분기 — `grep -n "add-project\|등록\|register" ` 로 위치.)

- [ ] **Step 2: 모달 마크업** — `marina-dashboard-ux-preferences` 준수(compact·iconified). 구성:
  - 상단 assist bar: `📁 레포에서` 버튼 · `✨ AI 초안` 버튼 + NL 입력(placeholder `"예: web은 pnpm dev로"`) · LLM 피커(서비스 모달의 피커 로직 재사용 — 2+ 감지·미pin일 때만).
  - 본문: `<textarea data-compose-yaml>` (monospace, 줄바꿈 보존) · `[검증]` 버튼 + `<div data-compose-validate-out>` (인라인 결과) · `환경변수명` `<input data-compose-envvar placeholder="APP_ENV">` · `기본값` `<input data-compose-envdefault value="local">` · `[등록]` `[취소]`.
  - import 후보 선택용 작은 목록 영역(`data-compose-detect-list`, 기본 숨김).

- [ ] **Step 3: 검증(렌더)** — Task 7에서 :3901 프리뷰로 일괄 확인(테스트는 JS 렌더 안 함). 여기선 마크업이 INDEX_HTML 문자열에 문법오류 없이 들어갔는지 데몬 기동으로 확인. Run: `MARINA_CONTROL_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])') python3 plugin/scripts/marina-control.py & sleep 1; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:$!...` → 페이지 200. (간단히: 데몬 떠서 `/` 가 200이면 템플릿 문자열 정상.)

- [ ] **Step 4: 커밋**

```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(compose-dash): compose 프로젝트 등록 모달 마크업 + 진입(kind 선택)"
```

---

## Task 6: 프론트 — assist bar/검증/등록 wiring

**Files:**
- Modify: `plugin/scripts/marina-control.py` `INDEX_HTML` (스크립트 영역 — LLM assist JS `3559–3700` 미러)

- [ ] **Step 1: 핸들러 배선** — 기존 `api('/api/llm-analyze',…)`(3622) 패턴 미러:
  - `📁 레포에서`: `GET /api/compose-detect?path=<등록대상 path>` → `files` 를 `data-compose-detect-list` 에 렌더, 선택 시 그 파일을 다시 detect(또는 stored)로 읽어 textarea 채움. (파일 내용 읽기는 register 대상 path 기준 — 후보 path 로 `compose-detect` 의 stored 가 아니라, 선택 파일은 별도로 읽어야 하면 detect 응답에 내용 포함 옵션 추가; v1 은 후보 rel 만 보여주고 선택 시 textarea 에 경로 주석 + 사용자가 ✨/직접으로 대체 가능하게. **단순화**: detect 가 후보 파일의 내용을 같이 반환하도록 files[].content 추가해도 됨 — 구현 시 택1, 테스트는 rel 존재만 검증).
  - `✨ AI 초안`: assist bar 를 진행 스트립으로 모핑(`레포 분석 중…`) → `POST /api/compose-analyze {path, instruction}` → 성공 `r.yaml` 을 textarea 에, 실패 시 `✕ 실패 — 직접 작성` + 에러.
  - `[검증]`: `POST /api/compose-validate {yaml, path, envVar, envDefault}` → `data-compose-validate-out` 에 ok(녹색)·errors(빨강, 서비스별)·warnings(노랑) 표시.
  - `[등록]`: 먼저 검증 → ok 면 `POST /api/compose-register {path, yaml, envVar, envDefault}` → 성공 시 모달 닫고 프로젝트 새로고침(기존 add-project 성공 후 흐름 재사용 — `r.id` 로 선택), 실패(`r.ok===false`) 면 errors 표시.
  - LLM 없을 때 `✨` 비활성 + 힌트(서비스 모달의 `svcLlmStatus` 재사용).

- [ ] **Step 2: 검증(렌더/동작)** — Task 7 프리뷰에서 일괄. 데몬 기동 → `/` 200(문법) 확인.

- [ ] **Step 3: 커밋**

```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(compose-dash): 등록 모달 wiring — 📁import/✨analyze/검증/등록 + LLM 상태 게이트"
```

---

## Task 7: :3901 프리뷰 실측 (필수 — compose 프론트 변경)

**Files:** 없음(검증). compose 카드 전체가 깨지는 류 버그는 프리뷰만 잡음(75c8863 박제).

- [ ] **Step 1: 프리뷰 기동** — 이 워크트리에서 대시보드를 띄우고(marina 또는 직접 데몬), preview_start 로 그 포트를 연다. fake LLM(`MARINA_LLM_FAKE`)로 ✨ 동작 확인 가능하게 환경 주입.
- [ ] **Step 2: 모달 렌더** — 프로젝트 등록 → kind=compose → 모달이 뜨고 **다른 카드가 안 깨지는지** 확인(preview_snapshot). renderConfigRows류 게이트가 다른 wiring을 죽이지 않는지(`if(el)` 가드).
- [ ] **Step 3: source 전환** — 📁/✨/직접 전환 시 textarea·목록 상태 정상(preview_click + preview_snapshot).
- [ ] **Step 4: 검증 인라인** — 잘못된 yaml(container_name) 넣고 [검증] → 빨강 에러 인라인.
- [ ] **Step 5: ✨ 진행 스트립** — AI 초안 클릭 → 진행 표시 → textarea 채워짐(fake LLM).
- [ ] **Step 6: 등록→카드** — [등록] → 모달 닫힘 + compose 워크트리 카드 출현(Plan B `compose ps` 경로). preview_screenshot 로 증빙.
- [ ] **Step 7: 발견 버그 수정 → 재확인** — 깨지면 소스 수정 후 step 2부터.

---

## Task 8: README + 최종 자체 점검

**Files:**
- Modify: `README.md` (compose 섹션에 "대시보드 등록" 추가)

- [ ] **Step 1: README** — compose-kind 등록을 CLI(`marina project add --compose`)뿐 아니라 **대시보드(등록 모달: import/✨AI 초안/검증/등록)** 로도 한다고 1–2문단. AI 초안은 LLM이 Dockerfile·구조 보고 dev compose 생성→사람 검토.
- [ ] **Step 2: 자체 점검** — 스펙 커버리지(① 등록·import·편집/replace·검증, ⑤ LLM 초안) 각 항목이 Task 로 구현됐는지 대조. placeholder 스캔. 타입/이름 일치(`compose_validate`·`llm_compose_analyze`·엔드포인트 경로).
- [ ] **Step 3: 전체 스위트 재실행** — `FAIL=0` 재확인.
- [ ] **Step 4: 커밋**

```bash
git add README.md
git commit -m "docs(readme): 대시보드 compose 등록(import/✨AI 초안/검증) 문서화"
```

---

## Self-Review (작성자 체크)

**Spec 커버리지:**
- ① 등록(저장/등록/import=복사/편집·교체) → Task 3(register, upsert by root, detect+stored) ✓
- ① 검증 → Task 2 + 3(compose_validate, /api/compose-validate) ✓
- ⑤ LLM 초안 → Task 1 + 3(llm_compose_analyze, /api/compose-analyze) ✓
- UI(assist bar·에디터·검증 인라인·진행 스트립) → Task 5·6·7 ✓
- 자동 검증 루프 없음(사람 검토) → 설계대로 미포함 ✓

**Placeholder 스캔:** 백엔드(Task 1–3) 완전 코드+테스트. 프론트(Task 5·6)는 INDEX_HTML 미러라 정확 코드 대신 "미러 대상 라인 + 정확한 핸들러 명세 + :3901 실측"으로 — marina 프론트는 단위테스트가 아니라 프리뷰로 검증(75c8863 교훈)하므로 의도적. import 후보 내용 로딩은 Task 6 Step 1에서 택1 명시.

**타입/이름 일치:** `llm_compose_analyze(root, instruction, current_yaml)→str` · `_extract_compose_yaml(raw)→str` · `compose_validate(yaml, project_dir, env_var, env_default)→{ok,errors,warnings}` · 엔드포인트 `/api/compose-{analyze,validate,register,detect}` · 페이로드 키 `path·yaml·instruction·currentYaml·envVar·envDefault·composeFile` — Task 1·2·3·6 전반 일치 확인.
