# 표준 CLI 명령 체계 + SessionStart 규칙 주입 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** marina CLI 를 프로세스 매니저 표준 체계로 통일하고, SessionStart 가 LLM 에 "marina 로 서버를 띄워라 + 사용법" 규칙을 주입(pull 모델)하며, 대시보드 서비스 등록에 LLM 위임 경로를 추가한다.

**Architecture:** marina.sh 가 표준 명령의 SoT — 라이프사이클(`start`/`stop`/`restart`/`status`/`ports`/`logs`)은 최상위 동사, 리소스(`service`/`project`)는 서브커맨드 그룹. entrypoint 와 control.py 가 그 표준명을 그대로 호출. SessionStart 훅은 superpowers 의 플랫폼 분기 JSON 패턴으로 규칙을 stdout 주입.

**Tech Stack:** bash, python3(stdlib only), plugin hooks(SessionStart). 테스트는 `plugin/tests/test-*.sh`(bash) + 대시보드는 marina preview(:3901/:3902) 실검증.

**Spec:** `docs/specs/2026-06-17-standard-cli-and-context-injection-design.md`

## File Structure

- `plugin/scripts/marina.sh` — dispatch 를 표준 서브커맨드 그룹으로 재배치 + 라이프사이클 무인자 가드 + `service ls`. (표준 명령 SoT)
- `plugin/scripts/marina-entrypoint.sh` — 그룹 라우팅(`service`/`project`/`dashboard`) + usage 갱신 + 구 별칭 제거.
- `plugin/scripts/marina-control.py` — `run_marina_registry` 호출 6곳 표준명 + 서비스 추가 버튼 아이콘화 + LLM 위임 버튼.
- `plugin/scripts/marina-session-start-hook.sh` — attach 뒤 규칙 JSON stdout(Claude/Codex 분기).
- `plugin/commands/{add-service,register,ls}.md` — 슬래시 본문 표준명.
- `README.md` — 명령 문서.
- `plugin/tests/test-standard-cli.sh`, `test-session-start-context.sh` — 신규 테스트.

각 작업 단위는 marina worktree(`feature/standard-cli-context`)에서 commit. 커밋 메시지는 Conventional Commits, `Co-Authored-By` 줄 없음.

---

### Task 1: marina.sh — 표준 서브커맨드 dispatch + 라이프사이클 가드 + `service ls`

**Files:**
- Modify: `plugin/scripts/marina.sh` (early dispatch `add)/infer)/rm)/default)/add-service)/rm-service)` ~216-222; `main()` case ~945-990)
- Test: `plugin/tests/test-standard-cli.sh` (create)

**배경:** 현재 dispatch — `add`/`infer`/`rm`/`default`(registry), `add-service`/`rm-service`(service), `start`/`stop`/`status`/`logs`/`ports`/`print-command`(lifecycle, `main()` case). `start` 는 `selected_services_from_args "$@"` 로 서비스 선택(`--all` 지원), 인자 없으면 빈 선택. `restart` 는 entrypoint 에만 있고 marina.sh 엔 없음(stop+start 조합). `service_add`/`service_rm`/`registry_*` 함수는 그대로 재사용.

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-standard-cli.sh`

```bash
#!/usr/bin/env bash
# marina.sh 표준 서브커맨드 dispatch: service/project 그룹 + lifecycle 무인자 가드 + service ls
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"

# project add/ls/rm (구 add/rm/ls 대체)
proj="$TMP/proj"; mkdir -p "$proj"; ( cd "$proj" && git init -q )
"$SH" project add "$proj" >/dev/null
"$SH" project ls | grep -q "$(basename "$proj")" || { echo "FAIL: project ls"; exit 1; }

# service add/ls/rm (구 add-service/rm-service 대체)
id="$(basename "$proj")"
"$SH" service add "$id" '{"name":"web","portBase":3000,"run":"exec true"}' >/dev/null
"$SH" service ls "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); assert any(s['name']=='web' for s in d['services']), d" \
  || { echo "FAIL: service ls 가 정의 json 출력 안 함"; exit 1; }
"$SH" service rm "$id" web >/dev/null
"$SH" service ls "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); assert not d['services'], d" \
  || { echo "FAIL: service rm"; exit 1; }

# lifecycle 무인자 가드: start 인자 없으면 usage(비-0) + '--all' 힌트, 전체 안 띄움
( cd "$proj" && "$SH" service add "$id" '{"name":"web","portBase":3000,"run":"exec true"}' >/dev/null )
out="$( cd "$proj" && "$SH" start 2>&1 )" && { echo "FAIL: 무인자 start 가 0 exit"; exit 1; }
echo "$out" | grep -q -- "--all" || { echo "FAIL: start 무인자 usage 에 --all 힌트 없음"; exit 1; }

# 구 명령 제거 확인: add-service 는 더 이상 안 받음
( cd "$proj" && "$SH" add-service "$id" '{"name":"x","portBase":3001,"run":"exec true"}' 2>&1 ) && { echo "FAIL: 구 add-service 가 살아있음"; exit 1; }

echo "PASS test-standard-cli (marina.sh)"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-standard-cli.sh`
Expected: FAIL (현재 `project`/`service`/무인자 가드 미구현, 구 `add-service` 살아있음)

- [ ] **Step 3: marina.sh dispatch 재배치** — early dispatch(`add)…rm-service)` 블록)를 그룹으로 교체:

```bash
# (구) add) infer) rm) default) add-service) rm-service) 블록을 아래로 교체
  project)
    shift
    case "${1:-}" in
      add)     shift; registry_add "$@";     exit $? ;;
      infer)   shift; registry_infer "$@";   exit $? ;;
      rm)      shift; registry_rm "$@";      exit $? ;;
      default) shift; registry_default "$@"; exit $? ;;
      ls)      shift; registry_ls "$@";      exit $? ;;
      *) die "usage: marina project {add|rm|ls|default|infer} …" ;;
    esac
    ;;
  service)
    shift
    case "${1:-}" in
      add) shift; service_add "$@"; exit $? ;;
      rm)  shift; service_rm "$@";  exit $? ;;
      ls)  shift; service_ls "$@";  exit $? ;;
      *) die "usage: marina service {add|rm|ls} …" ;;
    esac
    ;;
```

`registry_ls` 가 인자 없이 전체 목록을 출력하는 기존 함수면 그대로. (구 최상위 `add)`/`infer)`/`rm)`/`default)`/`add-service)`/`rm-service)` 케이스는 삭제 — clean break.)

- [ ] **Step 4: `service_ls` 함수 추가** (marina.sh, `service_rm` 함수 뒤):

```bash
# 머지된 서비스 정의(root∪중앙) json + source 태그 출력. status(런타임)와 구분되는 정의 조회.
service_ls() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: marina service ls <id>"
  local root; root="$(registry_root_for "$id")" || exit $?
  ROOT="$root" merged_services_json   # merged_services_json: {"services":[{…,"source":"root|central"}]}
}
```

(`registry_root_for` = 기존 id→root 해석 헬퍼. 없으면 `registry_ls` 가 쓰는 동일 조회 재사용. `merged_services_json` 이 `source` 태그를 이미 안 붙이면, root 항목 `source:"root"`·중앙 `source:"central"` 추가.)

- [ ] **Step 5: 라이프사이클 무인자 가드** — `main()` 의 `start)`/`stop)` case 를 교체하고 `restart)` 추가:

```bash
    start|stop|restart)
      # 무인자 = 전체 안 건드리고 usage(메모리 사고 방지). 전체는 --all.
      if [[ $# -eq 0 ]]; then
        echo "usage: marina $command <service..>   (전체: marina $command --all)" >&2
        echo "서비스: ${SERVICES[*]:-(없음)}" >&2
        exit 2
      fi
      offset="$(port_offset)"
      case "$command" in
        start)   while IFS= read -r s; do start_service "$s" "$offset"; done < <(selected_services_from_args "$@"); print_status ;;
        stop)    while IFS= read -r s; do stop_service  "$s"; done < <(selected_services_from_args "$@") ;;
        restart) while IFS= read -r s; do stop_service "$s"; start_service "$s" "$offset"; done < <(selected_services_from_args "$@"); print_status ;;
      esac
      ;;
```

(주의: `selected_services_from_args` 가 `--all` 을 전체로 확장하는 기존 동작 유지. 무인자는 위 가드에서 먼저 차단되므로 빈 선택 도달 안 함.)

- [ ] **Step 6: 테스트 통과 확인**

Run: `bash plugin/tests/test-standard-cli.sh`
Expected: PASS

- [ ] **Step 7: 회귀 — 기존 테스트 전체**

Run: `cd plugin/tests && for t in test-*.sh; do bash "$t" >/tmp/t.log 2>&1 || { echo "FAIL $t"; tail -8 /tmp/t.log; }; done; echo done`
Expected: 기존 service/registry 테스트가 구 `add-service`/`add` 명령을 쓰면 깨진다 → 그 테스트들을 표준명으로 갱신(`test-service-*.sh`·`test-registry-api.sh` 등에서 `add-service`→`service add`, marina.sh 직접 호출 `add`→`project add`). API 경유 테스트는 Task 3 후 통과.

- [ ] **Step 8: Commit**

```bash
git add plugin/scripts/marina.sh plugin/tests/
git commit -m "feat(cli): marina.sh 표준 서브커맨드(service/project) + 라이프사이클 무인자 가드 + service ls"
```

---

### Task 2: marina-entrypoint.sh — 그룹 라우팅 + usage (clean break)

**Files:**
- Modify: `plugin/scripts/marina-entrypoint.sh` (case ~56-142, usage ~21-45)
- Test: `plugin/tests/test-standard-cli.sh` (entrypoint 섹션 추가)

**배경:** entrypoint 가 marina.sh(`SESSION`)·dashboard(`DASHBOARD`)·attach 로 위임. 현재 `start)`→대시보드, `all)`→`SESSION start --all`, `restart)`→stop+start, registry 는 `SESSION "$command"` 패스스루.

- [ ] **Step 1: 테스트 추가** — `test-standard-cli.sh` 끝에 append:

```bash
EP="$HERE/../scripts/marina-entrypoint.sh"
# start = 서비스(대시보드 아님). 무인자는 usage(비-0).
( cd "$proj" && "$EP" start 2>&1 ) && { echo "FAIL: entrypoint 무인자 start 0 exit"; exit 1; }
# dashboard 는 별도 그룹
"$EP" dashboard 2>&1 | grep -qi "dashboard\|http" || true   # 기동 시도(스모크)
# 제거된 별칭: up/down/dash/all 은 unknown(비-0)
for dead in up down dash all off quit add-service; do
  ( cd "$proj" && "$EP" "$dead" 2>&1 ) && { echo "FAIL: 제거된 '$dead' 가 살아있음"; exit 1; }
done
echo "PASS test-standard-cli (entrypoint)"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-standard-cli.sh`
Expected: FAIL (`start`→대시보드라 0 exit, `all`/`up` 등 살아있음)

- [ ] **Step 3: entrypoint case 재배치** — `case "$command"` 를 표준으로:

```bash
case "$command" in
  service|project)
    "$SESSION" "$command" "$@" ;;          # 그룹 → marina.sh 그룹 dispatch 로 위임
  start|stop|restart|status|ports|logs)
    "$SESSION" "$command" "$@" ;;          # 라이프사이클 → marina.sh (무인자 가드 포함)
  dashboard)
    case "${1:-start}" in
      start|"") "$DASHBOARD" start; print_dashboard_url ;;
      stop)     "$DASHBOARD" stop ;;
      status)   "$DASHBOARD" status ;;
      open)     shift; exec "$0" open ;;    # open 핸들러 재사용
      *) echo "usage: marina dashboard {start|stop|status|open}" >&2; exit 2 ;;
    esac ;;
  open)
    url="http://${MARINA_CONTROL_HOST:-localhost}:${MARINA_CONTROL_PORT:-3900}"
    if command -v open >/dev/null 2>&1; then open "$url"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url"
    else echo "$url"; fi ;;
  attach|prepare) "$ATTACH" ;;
  install-cli|uninstall-cli) <기존 블록 유지> ;;
  -h|--help|help) usage ;;
  *) echo "error: unknown command: $command" >&2; usage >&2; exit 1 ;;
esac
```

무인자 `command="${1:-dashboard}"` 유지(무인자 `marina`=대시보드). 제거: `dash`/`up`/`down`/`off`/`quit`/`all`/`dashboard-stop`/`dashboard-status`/`add-service`/`rm-service`/구 `add`·`infer`·`rm`·`default` 최상위.

- [ ] **Step 4: usage 텍스트 갱신** — `usage()` heredoc 을 표준 체계로:

```
usage:
  services (current worktree):
    marina start|stop|restart <svc..>     # 무인자=안내, 전체는 --all
    marina status | ports | logs [svc]
  service definitions:
    marina service add <id> '<json>' [--root] | rm <id> <name> | ls <id>
  projects (~/.marina/projects.json):
    marina project add <path> | rm <id> | ls | default <id> a,b,c | infer <path>
  dashboard (:3900):
    marina dashboard [start|stop|status|open]    # 무인자 marina = dashboard start
  setup: marina attach | install-cli | uninstall-cli
```

- [ ] **Step 5: 테스트 통과**

Run: `bash plugin/tests/test-standard-cli.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina-entrypoint.sh plugin/tests/test-standard-cli.sh
git commit -m "feat(cli): entrypoint 표준 그룹 라우팅(service/project/dashboard) + 구 별칭 제거"
```

---

### Task 3: marina-control.py — `run_marina_registry` 호출 표준명

**Files:**
- Modify: `plugin/scripts/marina-control.py` (~4641, 4655, 4668, 4754, 4772, 4780)
- Test: `plugin/tests/test-registry-api.sh`, `test-service-api.sh` (기존 — 통과 확인)

**배경:** control.py 가 `run_marina_registry(*args)` 로 marina.sh 를 직접 호출. 6곳을 표준명으로:

| 위치 | 현재 | 표준 |
|---|---|---|
| ~4641 | `run_marina_registry("infer", str(target))` | `("project","infer", str(target))` |
| ~4655 | `run_marina_registry("add", str(target), "--subrepos", …)` | `("project","add", str(target), "--subrepos", …)` |
| ~4668 | `run_marina_registry("rm", pid)` | `("project","rm", pid)` |
| ~4754 | `run_marina_registry("default", id, …)` | `("project","default", id, …)` |
| ~4772 | `run_marina_registry("add-service", id, json, *args)` | `("service","add", id, json, *args)` |
| ~4780 | `run_marina_registry("rm-service", id, name, *args)` | `("service","rm", id, name, *args)` |

- [ ] **Step 1: 6곳 치환** (위 표대로). 다른 로직 변경 없음.

- [ ] **Step 2: ast 파싱 확인**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read()); print('ok')"`
Expected: `ok`

- [ ] **Step 3: API 테스트 통과 확인**

Run: `bash plugin/tests/test-registry-api.sh && bash plugin/tests/test-service-api.sh`
Expected: PASS (control.py→marina.sh 표준명 경로가 Task 1·2 와 일치)

- [ ] **Step 4: Commit**

```bash
git add plugin/scripts/marina-control.py
git commit -m "refactor(dashboard): control.py 의 marina 호출을 표준 service/project 명령으로"
```

---

### Task 4: marina-session-start-hook.sh — pull 규칙 stdout 주입

**Files:**
- Modify: `plugin/scripts/marina-session-start-hook.sh` (attach 블록 뒤, 파일 끝)
- Test: `plugin/tests/test-session-start-context.sh` (create)

**배경:** 현재 훅은 attach 후 종료, 출력 전부 `>> "$LOG_FILE" 2>&1`. stdout 은 비어 있음. 규칙 JSON 을 stdout 으로 추가하되 attach 로그는 계속 파일로. `is_registered` 게이트·`$ROOT` 는 기존 그대로.

- [ ] **Step 1: 실패 테스트** — `plugin/tests/test-session-start-context.sh`

```bash
#!/usr/bin/env bash
# SessionStart 훅이 등록 worktree 에서 규칙 JSON 을 stdout 으로 낸다 (Claude/Codex 분기)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="$HERE/../scripts/marina-session-start-hook.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
proj="$TMP/proj"; mkdir -p "$proj"; ( cd "$proj" && git init -q )
"$HERE/../scripts/marina.sh" project add "$proj" >/dev/null
"$HERE/../scripts/marina.sh" service add "$(basename "$proj")" '{"name":"web","portBase":3000,"run":"exec true"}' >/dev/null

# Claude: hookSpecificOutput.additionalContext, 규칙에 'marina start' 포함
out="$( cd "$proj" && CLAUDE_PLUGIN_ROOT=x "$HOOK" 2>/dev/null )"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); a=d['hookSpecificOutput']['additionalContext']; assert 'marina start' in a and 'web' in a, a" \
  || { echo "FAIL: Claude additionalContext"; exit 1; }

# Codex/SDK: top-level additionalContext
out="$( cd "$proj" && "$HOOK" 2>/dev/null )"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'additionalContext' in d and 'marina start' in d['additionalContext'], d" \
  || { echo "FAIL: top-level additionalContext"; exit 1; }

# 비-marina repo: stdout 비어야 (오염 없음)
other="$TMP/other"; mkdir -p "$other"; ( cd "$other" && git init -q )
out="$( cd "$other" && CLAUDE_PLUGIN_ROOT=x "$HOOK" 2>/dev/null )"
[[ -z "$out" ]] || { echo "FAIL: 비등록 repo 가 stdout 출력: $out"; exit 1; }

echo "PASS test-session-start-context"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-session-start-context.sh`
Expected: FAIL (stdout 비어 있음)

- [ ] **Step 3: 훅에 규칙 주입 추가** — `attach-detached-subrepos.sh` 호출 블록 뒤(파일 끝)에:

```bash
# --- 규칙 주입 (pull 모델): LLM 이 marina 로 서버를 다루게 한다. stdout=순수 JSON. ---
# 명령 호출자 resolve: PATH 의 marina 셰임 우선, 없으면 entrypoint 절대경로.
caller="marina"; command -v marina >/dev/null 2>&1 || caller="$SCRIPT_DIR/marina-entrypoint.sh"
# 서비스명(머지 정의) — 실패/빈값이면 줄 생략
svc_line=""
svcs="$("$SCRIPT_DIR/marina.sh" service ls "$(basename "$ROOT")" 2>/dev/null \
  | python3 -c "import json,sys
try: d=json.load(sys.stdin); print(', '.join(s['name'] for s in d.get('services',[])))
except Exception: pass" 2>/dev/null || true)"
[[ -n "$svcs" ]] && svc_line="이 worktree 서비스: $svcs"

read -r -d '' rules <<EOF || true
[marina] 이 worktree 는 marina 가 관리합니다. dev 서버는 직접(npm/gradlew 등) 띄우지 말고 $caller 로 — worktree 별 포트가 자동 격리됩니다.
· 기동:   $caller start <서비스>     (전체는 --all)
· 정지:   $caller stop <서비스>      (전체는 --all)
· 재시작: $caller restart <서비스>   (전체는 --all)
· 상태·포트: $caller status      · 로그: $caller logs <서비스>
문제 해결:
· 포트 충돌은 자동으로 빈 포트로 이동 — 실제 포트는 $caller status 로 확인
· 정의(포트·실행방식·환경변수) 변경: $caller service ls <id> 로 확인 → $caller service add <id> '<json>' 로 수정
$svc_line
EOF

# JSON escape (bash 파라미터 치환 — superpowers 방식)
esc="$rules"; esc="${esc//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//$'\n'/\\n}"
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -z "${COPILOT_CLI:-}" ]]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
else
  printf '{"additionalContext":"%s"}\n' "$esc"
fi
```

(주의: attach 블록은 이미 `>> "$LOG_FILE" 2>&1` 로 stdout 안 씀 — 위 JSON 만 stdout 으로 나간다. `SCRIPT_DIR`·`ROOT` 는 파일 상단에 정의돼 있음.)

- [ ] **Step 4: 테스트 통과**

Run: `bash plugin/tests/test-session-start-context.sh`
Expected: PASS

- [ ] **Step 5: Codex 주입 실검증 (수동 메모)** — 자동 테스트는 JSON 형식만 검증. 실제 Codex 세션 주입 여부는 형이 Codex 세션에서 확인(Open item 3). 안 되면 Claude 전용으로 폴백(회귀 0 — attach 는 그대로).

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina-session-start-hook.sh plugin/tests/test-session-start-context.sh
git commit -m "feat(hook): SessionStart 가 marina 사용 규칙을 컨텍스트 주입(pull 모델, Claude/Codex)"
```

---

### Task 5: 대시보드 — 서비스 추가 `+` 아이콘 + LLM 위임 버튼

**Files:**
- Modify: `plugin/scripts/marina-control.py` (서비스 추가 버튼 렌더 = `renderSubrepoHead`/`addSvcBtn`; 모달 trigger `openServiceModal`; INDEX_HTML 의 버튼)
- Verify: marina preview(:3902) Chrome MCP 실검증

**배경:** 현재 `+ 서비스 추가` 텍스트 버튼이 subrepo 헤더에 렌더(`addSvcBtn`)되고 클릭 시 `openServiceModal`(수동 폼). 대시보드는 LLM 세션 직접 호출 불가 → LLM 위임 = `/marina:add-service <root>` 클립보드 복사 + 안내(기존 `doUpdateNow` 의 confirm/toast 패턴 참고).

- [ ] **Step 1: 버튼 아이콘화** — `addSvcBtn` 렌더에서 텍스트 `+ 서비스 추가` → `+` 아이콘만(title="서비스 추가"). main 의 iconify 버튼(stateChip 개편) 클래스/스타일과 일관:

```javascript
// (구) addSvcBtn = `<button class="addsvc" data-add-svc="${root}">+ 서비스 추가</button>`;
const addSvcBtn = `<button class="icon-btn" data-add-svc="${root}" title="서비스 추가">+</button>`;
const llmSvcBtn = `<button class="icon-btn" data-llm-svc="${root}" title="LLM 으로 등록 (명령 복사)">✨</button>`;
// 헤더에 ${addSvcBtn}${llmSvcBtn}
```

- [ ] **Step 2: LLM 위임 핸들러** — `data-llm-svc` 클릭 → 명령 복사 + 안내:

```javascript
function wireLlmSvc(el) {
  el.querySelectorAll('[data-llm-svc]').forEach(b => b.onclick = async () => {
    const root = b.getAttribute('data-llm-svc');
    const cmd = `/marina:add-service ${root}`;
    try { await navigator.clipboard.writeText(cmd); } catch {}
    alert(`복사됨:\n${cmd}\n\nClaude/Codex 세션에 붙여넣어 실행하세요. (구조를 분석해 서비스를 등록합니다)`);
  });
}
```

(클립보드 실패 시에도 alert 로 명령 문자열 노출 = 복사 폴백. 기존 버튼 와이어링 함수 옆에 호출 추가.)

- [ ] **Step 3: ast 파싱**

Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read()); print('ok')"`
Expected: `ok`

- [ ] **Step 4: preview 실검증** — `.claude/launch.json` 의 marina preview(:3902)로 띄워 Chrome MCP 로: ① 서비스 추가 버튼이 `+` 아이콘으로 보이고 클릭 시 수동 폼 모달 열림 ② `✨` 버튼 클릭 시 `/marina:add-service <root>` 복사+안내 ③ 콘솔 에러 0. (메모리: UI 변경은 preview 실검증 필수, 추측 금지)

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-control.py
git commit -m "feat(dashboard): 서비스 추가 + 아이콘화 + LLM 위임(명령 복사) 버튼"
```

---

### Task 6: 슬래시 커맨드 · README 표준명 갱신

**Files:**
- Modify: `plugin/commands/add-service.md`, `plugin/commands/register.md`, `plugin/commands/ls.md`
- Modify: `README.md`
- Test: `plugin/tests/test-install-cli.sh` 류(슬래시 파일 존재 검증) + grep 검증

- [ ] **Step 1: 슬래시 본문 표준명** —
  - `add-service.md`: `marina-entrypoint.sh add-service <id> '<json>'` → `… service add <id> '<json>'`; 1번의 `… ls`(프로젝트 매칭)·`add`(등록) → `… project ls`·`project add`.
  - `register.md`: `marina-entrypoint.sh add "$(dirname "$common")"` → `… project add "$(dirname "$common")"`.
  - `ls.md`: `marina-entrypoint.sh ls` → `… project ls`.
  - (슬래시 파일명 `/marina:add-service` 는 유지 — Open item 4 결정: 파일명 변경은 사용자 머슬메모리 영향, 본문만 표준화.)

- [ ] **Step 2: README 명령 표·예시 갱신** — `README.md` 의 명령 표/설치/예시를 표준 체계(Task 2 usage 와 동일)로. 구 `add-service`/`add`/`down` 등 등장 0 확인.

- [ ] **Step 3: grep 검증**

Run: `! grep -rn "add-service\|rm-service" plugin/commands README.md && ! grep -rEn "marina (add|infer|rm|default|ls) " README.md && echo clean`
Expected: `clean` (구 명령 잔재 0; `project add` 등 표준형만)

- [ ] **Step 4: 전체 테스트 회귀**

Run: `cd plugin/tests && pass=0; fail=0; for t in test-*.sh; do bash "$t" >/tmp/t.log 2>&1 && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $t"; tail -8 /tmp/t.log; }; done; echo "PASS=$pass FAIL=$fail"`
Expected: `FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add plugin/commands README.md
git commit -m "docs: 슬래시 커맨드·README 를 표준 service/project 명령으로 갱신"
```

---

## Open items (구현 중 확정)

1. **무인자 start/stop/restart exit code** — 본 plan 은 `exit 2`(usage). 일부 셸 워크플로우가 비-0 에 민감하면 조정.
2. **훅 서비스명 조회** — 본 plan 은 `marina service ls <basename>` 파싱. `$(basename "$ROOT")` 가 프로젝트 id 와 다른 케이스(codex 레이아웃) 있으면 registry 해석으로 보정.
3. **Codex 컨텍스트 주입 실검증** — Task 4 Step 5. 안 되면 Claude 전용 폴백.
4. **슬래시 파일명** — `/marina:add-service` 유지(본문만 표준화). 대시보드 LLM 위임 버튼도 이 이름 복사.

## 실행 후 검증 (finishing 전)

- `plugin/tests` 전체 `FAIL=0`.
- preview(:3902)로 대시보드 서비스 추가 `+`/`✨` 동작 + 콘솔 에러 0.
- `marina start`(무인자)=안내, `marina start web`=기동, `marina service ls <id>`=정의 json, `marina dashboard`=대시보드 스모크.
- `git grep -nE "add-service|rm-service|\"all\"|'all'"` 로 구 명령 잔재 0(테스트 fixture 제외).
