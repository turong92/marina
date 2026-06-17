# marina — 표준 CLI 명령 체계 + SessionStart 규칙 주입 + 대시보드 LLM 등록 위임 (pull 모델)

- **Date:** 2026-06-17
- **Branch:** `feature/standard-cli-context` (origin/main `7dfc7a0` 위에 리베이스)
- **Status:** Design approved (브레인스토밍); spec for review.
- **Builds on:** 멀티프로젝트 서비스 격리(`2026-06-16-multiproject-service-isolation`)·service-add(`2026-06-16-service-add-and-merge`)·in-dashboard 업데이트. 그 위에 (1) entrypoint 명령을 프로세스 매니저 표준으로 재배치, (2) SessionStart 가 LLM 에 사용 규칙 주입, (3) 대시보드 서비스 등록에 LLM 위임 경로 추가.

## Goal

LLM(Claude·Codex)이 dev 서버를 직접 띄우다 포트·실행방식에서 헤매는 것을 없앤다. 포트 값을 미리 주입(push)하는 대신, **SessionStart 가 "marina 로 띄워라 + 사용법" 정적 규칙을 1회 주입**하고 LLM 은 실행 시점에 marina 에서 최신 값을 pull 한다. 동시에 entrypoint 명령을 표준 CLI 로 정리하고, 대시보드의 서비스 등록을 LLM 에게 위임할 수 있게 한다.

## Problem

1. **컨텍스트 0:** SessionStart 훅이 서브레포 attach 만 하고 출력을 로그파일로 보낸다 → LLM 컨텍스트에 marina 사용법이 없다. LLM 이 직접 `npm run dev` 하면 포트 격리가 깨지고 실제 포트를 몰라 헤맨다.
2. **비표준 명령:** entrypoint 가 표준(docker compose·pm2·systemctl)을 벗어난다 — `start` 가 서비스가 아니라 대시보드를 띄우고, 서비스 기동이 `all`/`restart` 로 분산, `add-service`/`rm-service` 는 하이픈 복합어, 대시보드 명령이 서비스와 섞임.
3. **등록 UX 가 수동 일변도:** 서비스 정의가 없는 프로젝트(`no svc`)에서 대시보드는 **수동 폼**(name·portBase·cwd·run·정규식 직접 입력)만 제공한다. LLM 이 구조 분석해 등록하는 `/marina:add-service` 슬래시가 있는데도, 대시보드엔 그 LLM 위임을 안내·트리거하는 게 전혀 없다.

## Design

### A. 명령 표준화 (`marina-entrypoint.sh`)

docker 모델: **라이프사이클은 최상위 동사, 리소스 관리는 서브커맨드 그룹.**

**라이프사이클** (현재 worktree 서비스가 기본 대상):

| 명령 | 동작 |
|---|---|
| `marina start <svc..>` / `stop <svc..>` / `restart <svc..>` | 지정 서비스. **무인자 = usage 안내** |
| `marina start --all` / `stop --all` / `restart --all` | 전체 (명시 opt-in) |
| `marina status` / `ports` / `logs <svc>` | 조회 |

**안전 가드:** start/stop/restart 무인자는 전체를 건드리지 않고 usage 출력. 서비스 5개(mdc: web·be·index·search·audio) 동시 기동 시 메모리 폭발 방지. 전체는 `--all` 로만.

**리소스 그룹** (2번째 인자 = 서브액션):

| 그룹 | 명령 |
|---|---|
| `marina service` | `add <id> '<json>' [--root]` · `rm <id> <name> [--root]` · **`ls <id>`** |
| `marina project` | `add <path>` · `rm <id>` · `ls` · `default <id> a,b,c` · `infer <path>` |
| `marina dashboard` | `start`(무인자) · `stop` · `status` · `open` |

- **`service ls <id>` = 머지된 서비스 정의(root∪중앙)를 json 으로 출력 + 각 항목 `source`(`root`/`central`) 태그.** 런타임 `status`(포트·헬스)와 구분되는 **정의 조회**다. `service add` 가 full-json upsert(부분 수정 불가)이므로, LLM·사용자가 현재 정의를 보고 한 필드 바꿔 다시 upsert 하는 워크플로우의 전제. `merged_services_json()`(이미 존재) 재사용.

**표준화 범위 = 전체 일관:** 이 표준 명령은 entrypoint 표면뿐 아니라 **marina.sh dispatch**(구 `add-service`/`rm-service`/`add`/`rm`/`infer`/`default` → `service add/rm/ls`·`project add/rm/ls/infer/default`)와 **control.py 의 `run_marina_registry` 호출 6곳**까지 통일한다. control.py 는 marina.sh 를 **직접 호출**(entrypoint 미경유, `run_marina_registry`)하므로, marina.sh dispatch 가 표준 서브커맨드를 받아야 control.py 도 표준명으로 호출할 수 있다 — 한 곳만 바꾸면 불일치.

**기타:** `marina attach`, `marina install-cli`/`uninstall-cli`. 무인자 `marina` = 대시보드 기동(= `dashboard start`).

**제거(clean break):** `all`·`down`·`off`·`quit`·`up`·`dash`·`start`→대시보드 별칭·`add-service`/`rm-service`(→`service add/rm`)·`dashboard-stop`/`dashboard-status`(→`dashboard stop/status`). usage 전면 갱신. 데몬 supervisor 는 ExecStart 가 control.py 직접이라 무관.

### B. SessionStart 규칙 주입 (`marina-session-start-hook.sh`)

- 기존 attach 유지. **attach 출력은 로그파일/ stderr 로** (stdout 오염 금지).
- attach 뒤, 등록 worktree 면 **사용 규칙을 stdout JSON 으로** 출력 → 모델 컨텍스트 주입.
- **superpowers 플랫폼 분기 패턴 복제** (`superpowers/hooks/session-start` 검증 표준):
  - Claude Code (`CLAUDE_PLUGIN_ROOT` && !`COPILOT_CLI`): `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<rules>"}}`
  - 기타(Codex 포함 SDK 표준): `{"additionalContext":"<rules>"}`
  - JSON escape 는 bash 파라미터 치환(`\\`·`\"`·`\n`).
- **규칙 텍스트** (호출자·서비스명 동적 치환):

  ```
  [marina] 이 worktree 는 marina 가 관리합니다. dev 서버는 직접(npm/gradlew 등)
  띄우지 말고 marina 로 — worktree 별 포트가 자동 격리됩니다.
  · 기동:   marina start <서비스>     (전체는 --all)
  · 정지:   marina stop <서비스>      (전체는 --all)
  · 재시작: marina restart <서비스>   (전체는 --all)
  · 상태·포트: marina status      · 로그: marina logs <서비스>
  문제 해결:
  · 포트 충돌은 자동으로 빈 포트로 이동 — 실제 포트는 marina status 로 확인
  · 정의(포트·실행방식·환경변수) 변경: marina service ls <id> 로 확인 →
    marina service add <id> '<json>' 로 수정(upsert)
  이 worktree 서비스: web, be, …
  ```

  - **명령 호출자:** PATH 에 `marina` 셰임 있으면 `marina`, 없으면 `<설치경로>/marina-entrypoint.sh` — 훅이 resolve.
  - **서비스명:** marina.sh 머지 조회 재사용. 조회 실패·서비스 0 이면 그 줄 생략.
- **트리거 폐기:** UserPromptSubmit·포트 변경 재주입 없음. pull 이라 포트가 바뀌어도 다음 실행 때 최신.

### C. 슬래시 커맨드 · README 갱신

- `plugin/commands/add-service.md` → 본문 명령 `marina service add`. (슬래시 파일명 `/marina:add-service` 유지 vs `service-add` 는 Open item.)
- `register.md`(내부 `marina add` → `project add`), `ls.md`(→ `project ls`).
- `README.md` 명령 표·예시·설치 전면 갱신.

### D. 대시보드 LLM 등록 위임 (`marina-control.py`)

- **제약:** 대시보드(:3900 웹)는 LLM 세션(터미널 Claude/Codex)을 **직접 호출 못 한다**(분리 프로세스). 그래서 LLM 위임 = **명령 복사 + 안내** 형태다.
- **서비스 추가 (아이콘화):** 현 `+ 서비스 추가` **텍스트 버튼을 `+` 아이콘으로 대체**(main 의 iconify 스타일과 일관). 클릭 시 기존 **수동 폼 모달 유지**. 그 옆에 **LLM 위임 아이콘 버튼** 추가 — 클릭 시 `/marina:add-service <project-path>` 클립보드 복사 + "Claude/Codex 세션에 붙여넣어 실행" 안내(토스트/작은 모달). `no svc` 자리·subrepo 헤더에 배치. 간단=수동 폼, 구조 분석=LLM 위임 두 경로 공존.
- 프로젝트 등록(`infer`)의 LLM 위임 버튼은 이번 scope 밖(Open item).

## Components / files

- **`plugin/scripts/marina-entrypoint.sh`** — 서브커맨드 그룹 라우팅(`service`/`project`/`dashboard`), 무인자 라이프사이클 가드, usage.
- **`plugin/scripts/marina.sh`** — dispatch 를 표준 서브커맨드 그룹(`service add/rm/ls`·`project add/rm/ls/default/infer`)으로 재배치(구 `add-service`/`add`/`infer` 등 제거), `service ls`(머지 정의+source json) 추가. 라이프사이클·writer 함수는 재사용.
- **`plugin/scripts/marina-session-start-hook.sh`** — 규칙 JSON stdout(플랫폼 분기·escape) + 호출자/서비스명 resolve.
- **`plugin/scripts/marina-control.py`** — `run_marina_registry` 호출 6곳(`add-service`/`rm-service`/`add`/`rm`/`infer`/`default`)을 표준명(`service add` 등)으로 갱신 + 서비스 추가 버튼 `+` 아이콘화·"LLM 으로 등록" 아이콘 버튼.
- **`plugin/commands/*.md`** — 슬래시 본문 갱신.
- **`README.md`** — 명령 문서.
- **`plugin/tests/`** — entrypoint 라우팅·무인자 가드·`service ls` 출력·훅 출력 테스트.

## Error handling

- **훅:** 비등록·서비스 조회 실패 → 규칙 stdout 생략(또는 서비스 줄만), attach·세션 유지, **exit 0**. stdout 은 순수 JSON 만.
- **entrypoint 무인자 기동:** usage(서비스 목록 + `--all` 힌트). exit code 는 Open item.
- **`service ls <id>`** 정의 없음 → `{"services":[]}` 출력(에러 아님).
- **unknown 명령/서브커맨드:** usage + 비-0.
- **대시보드 "LLM 으로 등록":** 클립보드 API 실패 시 명령 문자열을 선택 가능한 텍스트로 노출(복사 폴백).

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| pull vs push | **pull**(실행 시점 조회) | stale 0 · 포트 트리거 불필요 · 토큰 최소 |
| start 무인자 | usage(전체 안 띄움) | 무거운 dev 서버 동시 기동 → 메모리 사고 방지 |
| 라이프사이클 vs 리소스 | 최상위 동사 / 서브커맨드 그룹 | docker 모델 표준 |
| 그룹화 범위 | service·project·dashboard 전부 | 완전 대칭(1인 도구라 breaking 영향 작음) |
| 정의 조회 | **`service ls` 추가** | `service add` 가 full upsert — 현재 정의를 봐야 수정 가능 |
| 부분수정 CLI(`service set`) | 안 만듦 | `ls`+`add` 로 충분, LLM 은 json 재구성 능함 |
| 임시/세션한정 override(`set-port`·`set-env`) | 안 만듦 | 포트는 자동 격리, worktree 한정 env 는 프로젝트 `.env.local` 영역. 비교용 동시 기동 안 함 |
| 대시보드 서비스 등록 | 수동 폼 유지 + LLM 위임(명령 복사) 버튼 | 간단=폼·복잡=LLM. 대시보드는 LLM 직접 호출 불가라 복사/안내 |
| 표준화 범위 | CLI 표면 + marina.sh dispatch + control.py 호출 전체 | control.py 가 marina.sh 직접 호출 → 한 곳만 바꾸면 불일치 |
| 서비스 추가 버튼 | `+` 아이콘(텍스트 제거) | main iconify 스타일 일관 |
| Codex 주입 | superpowers 분기 복제 | 검증된 양 하네스 표준 |

## Out of scope

- 임시(세션 한정) 포트/env override CLI — `service add`(정의) + 포트 자동격리로 갈음.
- UserPromptSubmit 재주입·포트 변경 트리거 — pull 이라 불필요.
- 라이프사이클 명령 그룹화(`service start`) — 자주 쓰여 최상위 유지.
- 구 명령 후방호환 별칭 — clean break.
- 프로젝트 등록(`infer`)의 대시보드 LLM 위임 버튼 — 이번은 서비스 등록만.

## Open items (decide during plan)

1. 무인자 start/stop/restart 의 exit code(usage 출력 시 0 vs 비-0).
2. 훅의 서비스명 조회 구현 — `marina.sh status`/`ports` 파싱 vs 머지 reader 직접. stdout JSON 분리 유지.
3. Codex 컨텍스트 주입 실검증 — superpowers 패턴이 현 Codex 버전에서 실제 주입되는지(안 되면 Claude 전용·Codex attach 만, 회귀 0).
4. 슬래시 파일명 표준화 — `/marina:add-service` 유지 vs `/marina:service-add`. 대시보드 "LLM 으로 등록" 이 복사할 명령이 이걸 참조.
