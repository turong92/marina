# marina — 대시보드 compose 프로젝트 등록 + LLM compose 초안 (Plan C+D, 통합 설계)

- **Date:** 2026-06-19
- **Branch:** `claude/suspicious-cartwright-61c154` (compose-kind 구현 누적 — Plan A CLI + Plan B 대시보드 + 로그 위)
- **Status:** Design approved (사용자: import 포함 · 자동검증 루프 제외). 구현은 자율 진행(TDD+프리뷰), 형 최종 검토 후 단일 push.
- **Relation:** compose-kind 설계 SoT = `2026-06-18-worktree-compose-orchestration-design.md`(단계 ① 등록 · ⑤ LLM starter). LLM 엔진 패턴은 `2026-06-17-llm-service-registration-design.md`(서비스용 analyze/form-fill)를 **프로젝트/compose 레벨로 복제**. CLI 등록(`marina project add --compose`)은 Plan A에 이미 존재 — 이 설계는 그 위의 **대시보드 등록 UI(C)** 와 **LLM 초안 생성(D)** 을 통합한다.

## Goal

compose-kind 프로젝트 등록을 대상 사용자(손으로 compose 작성·`marina project add` 인자 조립이 장벽인 사람)가 **대시보드에서** 직관적으로 하게 한다: 레포에서 기존 compose를 가져오거나, **LLM이 Dockerfile·구조를 보고 dev compose 초안을 생성**해 채워주고, 에디터에서 검토·수정·검증 후 한 번에 등록. 편집 가능한 **YAML 에디터가 single source of truth**.

## Problem

1. **compose 등록 경로가 CLI뿐.** Plan A의 `marina project add <path> --compose <file> [--env-var --env-default]`는 동작하지만, 인자 조립·경로 지정이 대상 사용자에겐 장벽이다. 대시보드에는 compose 프로젝트를 등록하는 자리가 없다.
2. **dev compose가 없는 프로젝트가 많다.** 실물(be/ai-api/web)은 **prod Dockerfile만** 존재(dev/HMR 없음) — compose-kind를 쓰려면 "풀스택 dev compose 하나"를 새로 써야 하는데, 그 초안 작성이 시작 장벽이다(spec §검증). LLM이 이 초안을 만들어주면 장벽이 사라진다(spec ⑤).
3. **등록과 편집·교체가 비대칭.** 한 번 보관한 compose를 고치거나(편집) 레포가 바뀌어 다시 가져오는(replace) 경로가 없다(spec ① "편집/교체 경로 제공").

## Design

### 아키텍처 — "LLM = read-only config 함수" 원칙 재사용

서비스 LLM 등록과 **동일한 핵심 원칙**: LLM은 레포를 읽어 **compose 초안(YAML)만** 내놓고, 모든 side effect(검증·복사·등록)는 daemon이 소유한다. 에디터의 YAML이 single source of truth. 차이는 산출물이 *서비스 JSON*이 아니라 *풀스택 compose YAML*, 대상이 *서비스*가 아니라 *프로젝트(kind:compose)*라는 것.

```
대시보드 [compose 프로젝트 등록] 모달 (single source = YAML 에디터)
  ┌─ 획득(어느 하나로 에디터를 채움) ─────────────────────┐
  │  📁 레포에서 가져오기   ✨ AI 초안        ✎ 직접 작성   │
  │  (compose 파일 탐지·로드)  (LLM 생성)     (빈/붙여넣기)  │
  └──────────────────────────┬──────────────────────────┘
                             ▼
                    YAML 에디터(편집 가능)
                             ▼
              [검증]  docker compose config + isolation_breakers
                             ▼   (container_name/network_mode:host = reject, external = warn)
              환경변수명(APP_ENV) · 기본값(local)
                             ▼
              [등록]  검증 통과 → ~/.marina/<id>/<file> 로 복사 + projects.json kind:compose
                      (marina project add --compose 경유 — 새 영속화 경로 0)
```

**서비스 등록의 `verify+fix` 자동 루프(자동 기동→health→재분석)는 compose에 넣지 않는다.** spec ⑤가 "초안 → **사람 검토** → 보관"으로 명시. 사람이 에디터에서 검토·수정·검증 후 저장(form-fill 모드만). 자동 `docker compose up` 검증은 무겁고(풀스택 빌드) 범위 밖 — 필요하면 fast-follow.

### A. compose-analyze — read-only LLM이 compose 초안 생성 (Plan D)

- **입력:** 프로젝트 `root`(+ 선택 NL 지시). 편집 맥락이면 현재 보관 compose.
- **Spawn(daemon, 레포 dir, read-only):** `_analyze_prompt`/`llm_analyze`와 같은 경로 — claude `-p`(read tools만) / codex read-only 샌드박스, `_bin()` 해석. 비용/지연 통제 위해 **버튼 클릭 시에만** 호출.
- **프롬프트(`_compose_analyze_prompt`):** 레포의 서브레포별 **Dockerfile**(대개 prod), `package.json`(scripts.dev)·`build.gradle*`(bootRun)·`pyproject/requirements`(uvicorn/flask)를 보고 **풀스택 dev compose YAML**을 생성하도록 지시 —
  - 모든 서비스를 **한 (기본) 네트워크**에, 각 `build:`가 서브레포 Dockerfile을 가리키게(런타임 전용은 `image:`).
  - **dev 커맨드 + 소스 bind-mount**(prod Dockerfile 재사용 + 핫리로드 커맨드로 override).
  - inter-service는 **서비스명 DNS**(`http://be:8081`) — 하드코딩 호스트포트 금지.
  - 호스트 접근 필요한 서비스만 `ports:` 게시(web 등). 내부 전용은 `expose`.
  - **`container_name` 금지, `network_mode: host` 금지**(워크트리 격리 — `isolation_breakers`가 거부할 것).
  - 출력은 **YAML만**(펜스 또는 raw).
- **파싱·검증:** YAML 추출 → `docker compose config`로 파싱 가능 검증 → 실패 시 1회 재시도(에러 첨부). 2회 실패 ⇒ 실패 보고(에디터는 비거나 직전 상태 유지).
- **결과:** 초안 YAML을 에디터에 채움. 사람이 검토·수정.

### B. 레포에서 가져오기 — 기존 compose import (사용자 결정 a)

- 프로젝트 레포(루트 + 서브레포)에서 `docker-compose*.yml` / `compose*.y?ml` **자동 탐지** → 후보 목록 → 사용자 선택 → daemon이 파일 내용을 읽어 **에디터에 로드**. 탐지·읽기는 기존 `/api/browse`(레포 파일 열람) 경로 재사용.
- **import = 내용 복사**(레포 경로 참조 아님). 저장 시 `~/.marina/<id>/`로 복사(spec ①). 레포가 바뀌면 다시 가져와 덮음(replace).

### C. 검증 — `docker compose config` + isolation_breakers (env-aware)

- 에디터 YAML을 temp에 쓰고 `docker compose config --format json` 실행. `${VAR}` 보간을 위해 **환경변수명·기본값**(아래)을 env로 주입(`cmd_up`의 `_env_with`→`docker_config_json` 흐름과 동일).
- 결과 config를 `marina-compose.isolation_breakers`에 통과 — `container_name`/`network_mode:host`는 **에러(reject)**, `external` 네트워크/볼륨은 **경고**.
- 인라인 표시: 어느 서비스의 어떤 위반인지. **저장 전 항상 검증**(저장 버튼이 검증을 먼저 호출).

### D. 등록/저장 — marina project add --compose 경유

- 검증 통과 → 에디터 YAML을 temp 파일로 써서 `marina project add <root> --compose <temp> --env-var <NAME> --env-default <VAL>` 호출(Plan A 경로). daemon은 그 결과로 `~/.marina/<id>/<file>` 복사 + `projects.json`에 `kind:compose`·`composeFile`·`composeEnvVar`·`composeEnvDefault` 기록. **새 영속화 경로를 만들지 않는다**(서비스 등록이 `marina service add`로 funnel하는 것과 동형).
- **편집/교체(이미 등록된 compose):** 보관 compose를 에디터로 로드 → 수정/재가져오기 → 검증 → 저장 = `~/.marina/<id>/<file>` 덮어쓰기(등록은 유지). 업서트 의미는 plan에서 확정.

### UI — 등록 모달(assist bar + YAML 에디터)

서비스 모달 패턴 미러(`marina-dashboard-ux-preferences` 준수: compact·iconified·state-adaptive):
- **상단 assist bar:** `📁 레포에서` · `✨ AI 초안`(+ 선택 NL 입력) · LLM 피커(상태적응 — 2+ 감지·미pin일 때만 드롭다운). AI 실행 중엔 바가 **진행 스트립**으로 모핑(`레포 분석 중…` → `✓ 초안 생성` / `✕ 실패 — 직접 작성`). 취소 affordance.
- **본문:** YAML 에디터(textarea) + `[검증]`(인라인 결과) + 환경변수명/기본값 입력 + `[등록]`/`[취소]`.
- LLM 미설치면 `✨` 비활성+힌트, import/직접 작성/검증/등록은 그대로 동작.

## Components / files

- **`marina-control.py`**
  - `_compose_analyze_prompt` + `llm_compose_analyze`: 서비스용 미러, 산출물=compose YAML, 검증=`docker compose config`.
  - 엔드포인트(전부 origin-gated): `POST /api/compose-analyze`(AI 초안 YAML), `POST /api/compose-validate`(config+isolation, env-aware), `POST /api/compose-register`(검증→복사→등록), compose 파일 탐지(기존 browse 재사용 또는 얇은 `compose-detect`).
  - `INDEX_HTML`: compose 등록 모달 + assist bar JS/CSS. LLM 감지/피커/진행 스트립/origin-gating은 서비스 모달에서 재사용.
- **`marina-compose.py`:** 검증에 기존 `isolation_breakers` + `docker_config_json` 재사용(필요 시 얇은 `validate` 훅 — 순수 함수 유지).
- **`marina.sh`:** `marina project add --compose`는 Plan A에 존재 — register가 호출. 변경 최소.
- **`plugin/tests/`:** 아래 §Testing.

## Data flow

1. **AI 초안:** UI `✨` → `POST /api/compose-analyze {root, instruction?}` → daemon read-only LLM → YAML → 에디터 채움.
2. **가져오기:** UI `📁` → 탐지(browse) → 파일 선택 → 내용 읽어 에디터.
3. **검증:** UI `[검증]`/저장 직전 → `POST /api/compose-validate {yaml, envVar, envDefault}` → temp+`docker compose config`(env 주입)+`isolation_breakers` → `{ok, errors[], warnings[]}`.
4. **등록:** UI `[등록]` → `POST /api/compose-register {root, yaml, composeFile?, envVar, envDefault}` → 검증 → temp 파일 → `marina project add --compose …` → projects.json kind:compose + `~/.marina/<id>/` 복사. 등록 즉시 워크트리 카드에 compose 서비스가 뜸(Plan B `compose ps` 경로).

## Error handling

- **LLM 미설치/양쪽 미해결:** `✨` 비활성+힌트. import/직접/검증/등록은 영향 없음.
- **AI 출력 파싱 불가:** 1회 재시도(에러 첨부) → 2회 실패 시 보고 + 에디터 유지(빈/직전).
- **검증 실패:** 인라인 에러(서비스·위반 종류). `isolation_breakers` 에러는 등록 차단, 경고는 통과 허용.
- **등록 실패(`marina project add` 비정상):** stderr 노출, projects.json 무변경(부분 등록 없음).
- **취소 mid-run:** in-flight LLM 프로세스 중단.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| v1 범위 | 등록 UI(import/편집/replace) + AI 초안(form-fill) | "리치 등록 UI" 요구 + spec ① · ⑤. 사용자: import 포함 |
| C↔D 통합 | 한 모달, `✨AI 초안`이 에디터를 채움 | 한 매끄러운 흐름; C가 D의 소비처(사용자 결정) |
| LLM 역할 | read-only config 함수(레포→YAML), 모든 side effect는 daemon | 서비스 패턴과 동형 — 결정적·감사가능·exec/write 권한 불요·에디터=SoT |
| 자동 검증 루프 | **없음** — 사람 검토만(form-fill) | spec ⑤; 풀스택 자동 `up`은 무겁고 범위 밖(사용자 동의) |
| 영속화 | `marina project add --compose` 경유(새 경로 0) | 서비스가 `service add`로 funnel하는 것과 동형 |
| 검증 | `docker compose config` + `isolation_breakers`(env 주입) | 실 compose 의미 그대로 + 워크트리 격리 위반 사전 차단 |
| import | 레포 compose 자동 탐지→내용 복사 | spec ① "import=복사"; 기존 browse 재사용(저비용) |
| LLM trigger | 클릭 시에만 | 비용/지연 통제(서비스와 동일) |

## Out of scope (v1)

- compose 자동 기동·health 검증 루프(서비스 direct 모드의 compose판) — fast-follow.
- 멀티 compose/프로젝트 — 루트 풀스택 compose 하나가 정답(spec).
- 레포 변경 자동 감지·동기화 — 재가져오기는 수동(spec "변경 시 재import").
- 리버스 프록시·prod 오케스트레이션·서브레포 compose 머지(spec 파킹).
- 멀티서비스 초안의 부분 선택 UX — 풀스택 한 장이 단위.

## Open items (decide during plan)

1. **compose 파일 탐지:** 기존 `/api/browse` 재사용 vs 얇은 `/api/compose-detect`(루트+서브레포 글롭). Lean: browse 재사용, 부족하면 얇은 detect.
2. **편집/교체 업서트 의미:** `marina project add`가 기존 id 재등록을 upsert하는지 확인 → 아니면 보관 파일 덮어쓰기만(등록 유지). Lean: 보관 파일 덮어쓰기.
3. **검증 env 주입:** 환경변수명·기본값만으로 `${VAR:?}` 류가 다 풀리는지 — 안 풀리면 검증 시 "필요한 변수" 안내. Lean: 기본값 주입 + 미해결 변수 리포트.
4. **에디터:** plain textarea(+monospace) vs 경량 YAML 하이라이트. Lean: textarea(YAGNI), 줄번호 정도.

## Testing (TDD, 격리 mktemp fixture, 실docker는 `docker info` 게이트)

- `_compose_analyze_prompt` 구성(레포 신호 반영) · `llm_compose_analyze` 파싱(정상 YAML/펜스/prose-wrapped/재시도-후-실패) — LLM은 fake(고정 출력)로.
- 검증: 정상 config 통과 · `container_name`/`network_mode:host` reject · `external` warn · 파싱불가 에러 · env 주입으로 `${VAR}` 보간(실 `docker compose config`, docker 게이트).
- 등록: temp→`marina project add --compose` 호출 인자 정확(env-var/default) · projects.json에 kind:compose·composeFile·composeEnvVar·composeEnvDefault 기록 · `~/.marina/<id>/` 복사.
- 엔드포인트 origin-gate · LLM 없을 때 `✨` 비활성(payload/플래그).
- **:3901 프리뷰 실측(필수 — compose 프론트 변경):** 모달 렌더 · source 전환(📁/✨/직접) · 검증 인라인 에러 · AI 진행 스트립 · 등록→카드 출현. (테스트는 JS 렌더 안 함 — 카드 전체 깨지는 류 버그는 프리뷰만 잡음.)
