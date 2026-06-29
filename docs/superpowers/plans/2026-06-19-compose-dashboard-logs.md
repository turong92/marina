# compose Dashboard Logs (option B) + port-editor gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (or subagent-driven-development). Steps use `- [ ]`.

**Goal:** Make compose service logs appear in the dashboard's existing log viewer (run selector, history, search, SSE streaming) **verbatim** — by capturing each compose service's `docker compose logs -f` into marina's standard `run-NNN.log` files on every `start`. Also hide the native-only port/profile override editor on compose cards (no-op there).

**Architecture (option B):** marina already writes per-service `run-NNN.log` for native services (`next_run_log`); the dashboard reads them via `log_run_payload`/`service_log` and streams via `/api/logs`. For compose we just need to **fill those same files**: on `marina start` (compose), spawn a detached `docker compose -p <name> logs -f --no-log-prefix <svc>` per service, redirected into a fresh `run-NNN.log` (via the existing `next_run_log`), and track the tailer PID in `<svc>.logtail.pid` so `stop`/`restart` can kill it. The daemon then exposes `log`/`logRuns` for compose services (reusing the native helpers), and the **existing `/api/logs` + viewer work unchanged** (compose names already pass `safe_service` from Plan B). No `/api/logs` change.

**Tech Stack:** bash (`marina.sh` compose_main + new tailer helpers reusing `next_run_log`/`session_dir`), Python (`marina-control.py` `_compose_services` log fields + `renderConfigRows` gate), Docker Compose v2, bash test harness.

**Builds on:** Plan A (compose CLI) + Plan B (compose dashboard), both implemented on this branch.

---

## Key facts (verified)
- marina.sh: `next_run_log(service)` (899) creates `logs/<svc>/run-NNN.log`, symlinks `<svc>.log` → it, prunes to `MARINA_LOG_KEEP`. `session_dir`/`pid_file`/`log_file` (630/634/638).
- daemon: `service_log(root,svc)` (617) = current `<svc>.log`; `log_run_payload(root,svc)` (625) = run list the viewer shows; `/api/logs` SSE reads `run-*.log` (622) generically and `safe_service` (Plan B) already accepts compose names.
- `docker compose -p <name> logs -f <svc>` follows by project label (no `-f` files needed), like ps/down.
- Native background services write logs **raw** (only the foreground `tee` path redacts) → the compose tailer writes raw too (parity).
- `renderConfigRows(session)` (4935) renders the `⚙ 포트 · 프로파일` override editor unconditionally → for compose it edits `overrides.env` which the compose path never reads (no-op) → gate it.

---

## Phase 1 — marina.sh: log tailer lifecycle

### Task 1.1: tailer helpers + wire into compose_main

**Files:** Modify `plugin/scripts/marina.sh` (add helpers near `compose_main`; wire start/stop/restart). Test `plugin/tests/test-compose-logtail.sh` (create).

- [ ] **Step 1: Write the failing test (fake docker)**

```bash
#!/usr/bin/env bash
# compose start 가 서비스별 docker compose logs -f 를 run-NNN.log 로 캡처하고 logtail.pid 추적, stop 이 tailer 를 죽인다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose version --short") echo "2.40.3" ;;
  info) exit 0 ;;
  *"config --format json"*) cat "$DOCKER_CONFIG_FIXTURE" ;;
  *"ps --all --services"*) echo "web" ;;
  *"ps --all --format json"*) echo '[{"Service":"web","State":"running","Health":"","Publishers":[{"PublishedPort":5555}]}]' ;;
  *"logs -f"*) echo "HELLO-COMPOSE-LOG"; exec sleep 30 ;;   # follow 시뮬레이션
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" DOCKER_CONFIG_FIXTURE="$TMP/cfg.json"
cat > "$TMP/cfg.json" <<'JSON'
{"services":{"web":{"image":"x","ports":[{"target":80,"published":"3000","protocol":"tcp"}]}}}
JSON
P="$TMP/proj"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"; cp "$TMP/cfg.json" "$P/docker-compose.yml"
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
mrun(){ (cd "$P" && MARINA_HOME="$MARINA_HOME" PATH="$TMP/bin:$PATH" DOCKER_CONFIG_FIXTURE="$DOCKER_CONFIG_FIXTURE" bash "$SH" "$@"); }

mrun start --all >/dev/null
SD="$P/.workspace/marina/main"
runlog="$(ls "$SD"/logs/web/run-*.log 2>/dev/null | head -1)"
[[ -n "$runlog" ]] || { echo "FAIL: no run-NNN.log for compose web"; exit 1; }
grep -q "HELLO-COMPOSE-LOG" "$runlog" || { echo "FAIL: tailer output not captured"; cat "$runlog"; exit 1; }
tpf="$SD/web.logtail.pid"
[[ -f "$tpf" ]] || { echo "FAIL: no logtail pid"; exit 1; }
tpid="$(cat "$tpf")"; kill -0 "$tpid" 2>/dev/null || { echo "FAIL: tailer not alive"; exit 1; }

mrun stop --all >/dev/null
[[ ! -f "$tpf" ]] || { echo "FAIL: logtail pid not cleaned"; exit 1; }
kill -0 "$tpid" 2>/dev/null && { echo "FAIL: tailer still alive after stop"; exit 1; } || true
echo "PASS test-compose-logtail"
```

- [ ] **Step 2: Run → fails** (no tailer yet): `bash plugin/tests/test-compose-logtail.sh`

- [ ] **Step 3: Add tailer helpers** (insert just before `compose_main` in marina.sh):

```bash
# compose 서비스 로그를 네이티브와 동일한 run-NNN.log 로 캡처하는 tailer (백그라운드, idempotent).
_compose_logtail_start() {  # $1=compose project name, $2=service
  local name="$1" service="$2" log_path tpf
  tpf="$(session_dir)/${service}.logtail.pid"
  if [[ -f "$tpf" ]]; then local _o; _o="$(cat "$tpf" 2>/dev/null)"; [[ -n "$_o" ]] && kill -0 "$_o" 2>/dev/null && kill "$_o" 2>/dev/null; rm -f "$tpf"; fi
  log_path="$(next_run_log "$service")"   # run-NNN 생성 + <svc>.log 심링크 + prune (네이티브 헬퍼 재사용)
  {
    echo "service=$service (compose)"
    echo "project=$name"
    echo "---"
  } > "$log_path"
  ( set -m
    nohup docker compose -p "$name" logs -f --no-log-prefix "$service" >> "$log_path" 2>&1 &
    echo $! > "$tpf"
  )
}

_compose_logtail_stop() {  # $1=service (없으면 전체)
  local sd f; sd="$(session_dir)"
  local p
  if [[ -n "${1:-}" ]]; then
    f="$sd/${1}.logtail.pid"; [[ -f "$f" ]] && { p="$(cat "$f" 2>/dev/null)"; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null; rm -f "$f"; }
  else
    shopt -s nullglob
    for f in "$sd"/*.logtail.pid; do p="$(cat "$f" 2>/dev/null)"; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null; rm -f "$f"; done
    shopt -u nullglob
  fi
}
```

- [ ] **Step 4: Wire into `compose_main`** — in the `start|stop|restart` block, after each verb's marina-compose.py call. Replace the `case "$command"` inner block's `start)`, `stop)`, `restart)` arms with:

```bash
      case "$command" in
        start)
          python3 "$cp" up --stored "$stored" --project-dir "$ROOT" --session-dir "$sd" "${nameargs[@]}" \
            ${svcs[@]+"${svcs[@]}"} ${envargs[@]+"${envargs[@]}"} || return $?
          local cname; cname="$(python3 "$cp" name "${nameargs[@]}")"
          local -a tail_svcs=(); local x
          if [[ ${#svcs[@]} -gt 0 ]]; then
            for x in "${svcs[@]}"; do tail_svcs+=("${x#--service=}"); done
          else
            while IFS= read -r x; do [[ -n "$x" ]] && tail_svcs+=("$x"); done \
              < <(docker compose -p "$cname" ps --all --services 2>/dev/null)
          fi
          for x in ${tail_svcs[@]+"${tail_svcs[@]}"}; do _compose_logtail_start "$cname" "$x"; done
          ;;
        stop)
          if [[ ${#svcs[@]} -gt 0 ]]; then
            for x in "${svcs[@]}"; do _compose_logtail_stop "${x#--service=}"; done
            python3 "$cp" stop "${nameargs[@]}" "${svcs[@]}"
          else
            _compose_logtail_stop
            python3 "$cp" down "${nameargs[@]}"
          fi ;;
        restart)
          if [[ ${#svcs[@]} -gt 0 ]]; then
            python3 "$cp" restart "${nameargs[@]}" "${svcs[@]}"
            local cname2; cname2="$(python3 "$cp" name "${nameargs[@]}")"
            for x in "${svcs[@]}"; do _compose_logtail_start "$cname2" "${x#--service=}"; done
          else
            _compose_logtail_stop
            python3 "$cp" down "${nameargs[@]}"
            python3 "$cp" up --stored "$stored" --project-dir "$ROOT" --session-dir "$sd" "${nameargs[@]}" ${envargs[@]+"${envargs[@]}"} || return $?
            local cname3; cname3="$(python3 "$cp" name "${nameargs[@]}")"
            while IFS= read -r x; do [[ -n "$x" ]] && _compose_logtail_start "$cname3" "$x"; done \
              < <(docker compose -p "$cname3" ps --all --services 2>/dev/null)
          fi ;;
      esac ;;
```

(The outer `start|stop|restart)` arg-parse loop + `[[ -f "$stored" ]]` guard + `svcs`/`envargs` build stay as-is above this inner case.)

- [ ] **Step 5: Run → passes:** `bash plugin/tests/test-compose-logtail.sh` → `PASS`

- [ ] **Step 6: Commit** — `git add plugin/scripts/marina.sh plugin/tests/test-compose-logtail.sh && git commit -m "feat(compose-dash): capture docker compose logs to run-NNN (tailer lifecycle) for dashboard log viewer"`

---

## Phase 2 — daemon: expose compose logRuns + gate port editor

### Task 2.1: `_compose_services` populates log/logRuns; gate `renderConfigRows`

**Files:** Modify `plugin/scripts/marina-control.py`. Test `plugin/tests/test-compose-dash-logruns.sh` (create).

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# _compose_services 가 세션의 run-NNN 로그를 logRuns/log 로 노출한다(네이티브 뷰어 재사용).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"
ROOT="$TMP/proj"; mkdir -p "$ROOT/.workspace/marina/main/logs/web"
printf 'LOGZ\n' > "$ROOT/.workspace/marina/main/logs/web/run-001.log"
python3 - "$CTRL" "$ROOT" <<'PY'
import importlib.util, sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mctl", sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root=Path(sys.argv[2])
# build_compose_services 결과를 _compose_services 가 log/logRuns 로 채우는지 — compose_ps 를 monkeypatch
m.compose_ps=lambda r,n:[{"Service":"web","State":"running","Health":"","Publishers":[{"PublishedPort":5555}]}]
m._mc=lambda: type("X",(),{"compose_project_name":staticmethod(lambda i,s:"proj-main")})
svcs=m._compose_services(root, {"id":"proj"})
web=[s for s in svcs if s["service"]=="web"][0]
assert web["log"].endswith("web.log"), web["log"]
assert isinstance(web["logRuns"], list) and len(web["logRuns"])>=1, web["logRuns"]
print("ok logruns")
PY
echo "PASS test-compose-dash-logruns"
```

- [ ] **Step 2: Run → fails** (logRuns empty): `bash plugin/tests/test-compose-dash-logruns.sh`

- [ ] **Step 3: Update `_compose_services`** — after building services, fill log/logRuns from the native helpers:

```python
def _compose_services(root: Path, project: dict) -> list:
    """compose-kind 워크트리 서비스 = docker compose ps 라이브 + run-NNN 로그(=tailer 캡처) 노출."""
    try:
        name = _mc().compose_project_name(project.get("id", ""), session_id(root))
        svcs = build_compose_services(compose_ps(root, name))
        for s in svcs:
            s["log"] = str(service_log(root, s["service"]))
            s["logRuns"] = log_run_payload(root, s["service"])
        return svcs
    except Exception:
        return []
```

- [ ] **Step 4: Gate `renderConfigRows` for compose** — first line of the function:

```javascript
    function renderConfigRows(session) {
      if (session.kind === 'compose') return '';   // 포트·프로파일 override 는 native 전용(compose 는 Docker 할당)
      return `
```

- [ ] **Step 5: Run → passes:** `bash plugin/tests/test-compose-dash-logruns.sh`; also `python3 -c "import importlib.util as u;s=u.spec_from_file_location('m','plugin/scripts/marina-control.py');m=u.module_from_spec(s);s.loader.exec_module(m);print('ok')"`.
- [ ] **Step 6: Commit** — `git commit -am "feat(compose-dash): expose compose run-NNN logs (logRuns/log); hide native port/profile editor for compose"`

---

## Phase 3 — real-docker E2E + suite

### Task 3.1: gated log E2E (extend dash-api or new)

**Files:** Test `plugin/tests/test-compose-dash-logs-e2e.sh` (create).

- [ ] **Step 1: Write the gated test**

```bash
#!/usr/bin/env bash
# 실 docker: compose start → run-NNN 에 컨테이너 로그 캡처 → /api/logs (또는 파일)에서 보인다. 데몬 없으면 SKIP.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-dash-logs-e2e (docker 미가용)"; exit 0; }
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"
cat > "$P/docker-compose.yml" <<'YML'
services:
  web: { image: "python:3-alpine", command: ["sh","-c","echo MARINA-LOG-MARKER; python -m http.server 8000"], ports: ["8000:8000"] }
YML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
cleanup(){ (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" stop --all >/dev/null 2>&1)||true; rm -rf "$TMP"; }
trap cleanup EXIT
(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" start --all >/dev/null)
SD="$P/.workspace/marina/main"
ok=false
for _ in $(seq 1 40); do grep -q "MARINA-LOG-MARKER" "$SD"/logs/web/run-*.log 2>/dev/null && { ok=true; break; }; sleep 0.5; done
[[ "$ok" == true ]] || { echo "FAIL: container log not captured to run-NNN"; ls -la "$SD"/logs/web/ 2>/dev/null; exit 1; }
echo "PASS test-compose-dash-logs-e2e"
```

- [ ] **Step 2: Run → PASS / SKIP.** **Step 3: Commit** — `git commit -am "test(compose-dash): real-docker log capture to run-NNN (gated)"`

### Task 3.2: full suite + preview re-verify + README

- [ ] **Step 1:** `for f in plugin/tests/test-*.sh; do bash "$f" >/dev/null 2>&1 || echo "FAIL $(basename $f)"; done; echo done` → no FAIL.
- [ ] **Step 2:** Preview re-verify on `:3901` (or a fresh isolated preview): a running compose service's log pane now shows container output + run selector; the `⚙ 포트·프로파일` editor is gone on compose cards. Screenshot.
- [ ] **Step 3:** README — amend the compose dashboard line: "compose 서비스 로그도 기존 로그 뷰어(run 히스토리·검색·스트리밍)로 그대로 본다(`docker compose logs` 를 run-NNN 로 캡처)."
- [ ] **Step 4:** Commit — `git commit -am "docs(readme): compose logs in dashboard viewer"`

---

## Self-review

| Item | Covered |
|------|---------|
| compose 로그를 기존 run-NNN 뷰어로 | tailer → `next_run_log` (1.1); `_compose_services` logRuns (2.1); `/api/logs` unchanged (reads run-*.log) |
| tailer 수명관리(누수·중복 방지) | idempotent start(기존 kill 후 새로), stop/restart/down 에서 kill (1.1); test asserts alive→dead (1.1) |
| 포트 편집기 compose 에서 숨김 | `renderConfigRows` gate (2.1) |
| 무회귀 | native start/stop unchanged (compose 분기 안에서만); full suite (3.2) |

**Risks/limits:** tailer는 컨테이너 recreate(`down`/`up`) 시 새 run-NNN; `restart`도 새 run(네이티브와 동일 의미). `docker compose logs -f` 가 stop 후에도 잠깐 살아있을 수 있으나 명시적 kill 로 정리. 로그는 raw(네이티브 background 와 동일, redact 안 함).

## Open question
- tailer가 데몬 `/api/start` subprocess 에서 떠도 nohup+fd리다이렉트로 detach (check_output 가 안 멈춤) — 네이티브 `start_service` 와 동일 패턴. (검증: 3.x)

## Workflow
- TDD, mktemp fixtures, docker E2E gated. Conventional Commits, no trailers. Preview(:3901). Push는 형 승인.
