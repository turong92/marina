# marina per-service profile — 설계

> 2026-06-29 형과 brainstorm 합의. P1 의 `${VAR}` 테이블을 **폐기**하고, 그 자리를 "서비스별 profile"로 대체.
> 구현=Claude(Edit/Write), 리뷰=codex. compose-kind(docker) 전용.

## 배경 / 문제

- P0 에서 단일 `composeEnvVar`(프로젝트당 1개 `${VAR}` 주입)를 제거했다. 대체로 `${VAR}` 추출 테이블을 계획했으나, **실제 모델과 안 맞아 폐기**한다.
- mdc-main 실측: compose 에 `${VAR}` 없음. "환경 선택"은 **서비스별 `PROFILE`** 로 표현되고 전부 `local` 하드코딩:
  - be-api(Spring): `build.args.PROFILE` → Dockerfile `ARG PROFILE` → `ENV SPRING_PROFILES_ACTIVE=${PROFILE}` → `-Dspring.profiles.active`.
  - ai-api(FastAPI): `build.args.PROFILE` → `ARG PROFILE` → `ENV PROFILE`; compose 에 중복 `environment: PROFILE=local` 도 있음.
  - web(Next): PROFILE 변수 없음 — 프로파일이 명령(`pnpm dev:web:local`)에 박힘.
- per-service 차이 실재: IntelliJ run config 가 index/search=`local`, **audio=`dev`**.
- **핵심 인사이트**: profile 이 "들어가는" 이유는 그 서비스 Dockerfile 이 **자기가 받는 변수(ARG)**를 프레임워크 프로파일로 넘겨주기 때문. 보편 표준 변수는 없다(Spring=`SPRING_PROFILES_ACTIVE`, Python=없음, Next=`NODE_ENV`는 프레임워크가 강제라 부적합). → marina 는 **변수를 추측하지 않고, 그 서비스가 이미 선언/사용하는 변수를 관리**한다.

## 목표

서비스별로 profile 값(`local`/`dev`/…)을 marina 가 1급으로 관리한다:
1. compose 에 하드코딩된 profile 변수를 marina overlay 로 옮겨 **한 곳에서 서비스마다** 설정.
2. 변수 이름은 **그 서비스가 실제 받는 것**(Dockerfile ARG / 기존 build.args)을 그대로 사용 — 추측 금지, override 가능.
3. UI 로 서비스별 profile 을 보고(칩) 바꾼다(P0 공통 칩 언어 재사용).

## 비목표 (YAGNI)

- 런타임 env 기반 hot-swap(재빌드 없이 profile 변경). v1 은 **build-arg 만** → 변경 시 다음 start 에서 재빌드(marina 격리개발은 어차피 빌드, profile 변경은 드묾).
- 런타임 env-only profile(ARG 없이 `environment` 로만 받는 서비스) 관리. (mdc 는 전부 ARG 경유 → 해당 없음. 추후 확장.)
- web 의 명령형 프로파일(`dev:web:local`) 추상화 — 별개 메커니즘, 안 건드림.

### 경계: compose 자기완결 서비스는 profile 주입 대상이 아니다 (정상 경로)

프로파일·환경을 **compose 안에서 자기완결**하는 서비스(예: web — `command: pnpm dev:web:local` + `.env*.local` 마운트 + volumes)는 marina 가 아무것도 주입하지 않는다. compose 를 제대로 작성하면 환경까지 그대로 돈다 — 이게 정상 경로이며 **갭이 아니다**. profile 주입 기능은 값이 **build arg(ARG)** 로 들어가는 서비스(Spring/FastAPI)에서만 쓰는 편의다. (`.env*.local` 류 시크릿은 개발자 각자 로컬 파일 → marina links/volume 으로 컨테이너에 실릴 뿐, 공유 대상 아님.)
- profile **값** 자동 탐지(`application-<profile>.yml` 스캔 등) — 자유입력 + 후보 제안만.
- 프로젝트 단일 profile — per-service 로 결정됨.

## 설계

### 1. 저장 — 기존 build-args.json 재사용 (신규 저장소 없음)

profile 은 결국 **build arg 하나**다. marina 엔 이미 서비스별 build-args overlay 가 있다:
- `~/.marina/<id>/build-args.json` = `{ "<service>": { "<ARG>": "<value>", … } }`
- `compose_resolved_view`/`unified_compose_yaml` 가 이를 `services.<svc>.build.args` 로 병합(기존).

→ profile = build-args.json 의 **profile 변수 키**. **새 x-marina 필드·새 resolve 경로 0.**

### 2. profile 변수 감지 (서비스별)

서비스 S 의 profile 변수 = 다음에서 후보 이름과 매칭되는 것:
- 소스: S 의 Dockerfile `ARG` 목록(기존 compose-scan/ARG 감지 헬퍼) + 현재 `build.args` 키.
- 후보 이름(대소문자 무시): `PROFILE, SPRING_PROFILES_ACTIVE, APP_ENV, ASPNETCORE_ENVIRONMENT, RAILS_ENV, ENVIRONMENT, STAGE, ENV, NODE_ENV`.
- 매칭 0개 → 그 서비스는 **profile 없음**(web 처럼). 칩·컨트롤 숨김.
- 매칭 ≥1 → 첫 후보(우선순위 위 순서)를 profile 변수로. **UI 에서 변수명 override 가능**(자유입력).

`mc.detect_profile_var(service) -> str|None` (marina_compose_svc.py). 결과를 서비스 구성 응답에 포함.

### 3. 마이그레이션 — **없음** (비파괴, stored compose 안 건드림)

stored compose 의 하드코딩 `args.PROFILE: local`·`environment: PROFILE=local` 은 **그대로 두고 "기본값"으로 취급**한다. marina 의 profile overlay 가 start 시점에 이를 **덮는다**(아래 §4). → compose 재작성·주석 손실·마이그레이션 0. 사용자가 profile 을 바꾸기 전엔 보관 compose 의 값(local)이 그대로 적용된다.

### 4. 주입 (start 시 overlay 로 덮기) — 기존 build_overlay 재사용

marina-compose.py `up` 은 이미 워크트리 격리용 overlay(`marina-overlay.yml`, `docker compose -f stored -f overlay`)를 **비침투적으로** 생성한다(`build_overlay(config, build_args, connectivity)` — 엮기 `-bind` 사이드카·published 덮기). profile 도 **이 overlay 에 얹는다**:
- **build arg 측**: `build-args.json[svc][V] = value` → 기존 `--build-arg svc=V=value` 경로 그대로(이미 동작). compose 의 하드코딩 `args.V` 를 덮음.
- **런타임 env 측 (신규, 작음)**: `build_overlay` 가 `build_args` 중 **키가 profile 후보(`detect_profile_var` 의 후보집합)인 항목**을 그 서비스의 `environment: {V: value}` 로도 **미러링**해 overlay 에 emit. → `docker compose -f stored -f overlay` 머지에서 overlay env 가 stored 의 하드코딩 `environment: V=local` 을 **이긴다**(ai-api 런타임 override 문제 해소). stored compose 불변.
- profile 후보 build arg 가 없는 서비스(`build-args.json` 에 profile 키 없음)는 overlay env 미러링 없음 → 기존 동작 그대로.
- profile 값 변경 = build arg 변경 → 다음 start 에서 이미지 재빌드(캐시 무효) → 새 profile 반영. (런타임 env 미러링은 재빌드 없이도 컨테이너 재기동에 반영.)

부수효과: ARG 없이 런타임 env 로만 받는 서비스도, 사용자가 그 env 이름으로 build-args.json 에 넣으면(=의미상 profile 키) overlay env 미러링으로 런타임에 적용된다(build arg 는 미선언 ARG 라 docker 가 무시·무해). v1 은 ARG 케이스(mdc)가 주 대상.

### 5. API

- 읽기: 서비스 구성 응답(`/api/compose-config`)에 서비스별 `profileVar`(감지된 변수 또는 null) + `profileValue`(현재 build-args.json 값) 추가.
- 쓰기: `POST /api/compose-service-profile {root, service, value, var?}` → `build-args.json[service][var||detected] = value`. (얇은 래퍼 — 내부는 기존 build-args 저장 재사용. `var` 생략 시 감지값.)

### 6. UI (marina-web, P0 칩 재사용)

- **ⓘ 서비스 구성 패널**(`renderServiceConfig`): build args 위/옆에 **profile 컨트롤** — 라벨 `profile (<var>)`, 값 입력 `<input list=profileSuggest>`(datalist `local/dev/prod/staging`), 저장 버튼. profile 변수 없으면 컨트롤 숨김(대신 "이 서비스는 프로파일 변수 없음" 힌트). 저장 → `/api/compose-service-profile`.
- **서비스 카드/칩 row**: profile 값이 있으면 **profile 칩**(P0 `.svc-chip` 계열, 예: `⚙ dev`) 표시. 기본값(예: local)과 다르면 강조(메타칩). 변수 없는 서비스는 칩 없음.
- 변수명 override: ⓘ 패널에서 `profile (<var>)` 의 `<var>` 옆 작은 편집(고급) — 감지가 틀렸을 때만. v1 은 input 1개로 충분하면 생략 가능(감지 신뢰).

## 컴포넌트 / 경계

- `detect_profile_var(service_meta)` — 순수 함수(Dockerfile ARGs + build.args 키 → 변수명|None). 테스트 단독 가능.
- 마이그레이션 `_migrate_profiles(pid)` — stored compose + build-args.json 입력 → (수정된 compose, 갱신된 build-args.json). 비파괴·idempotent.
- `/api/compose-service-profile` 핸들러 — 얇은 검증 + build-args 저장 재사용.
- UI profile 컨트롤·칩 — `renderServiceConfig`/카드 렌더에 국소 추가, 기존 build-args 와일딩 재사용.

## 테스트 (Python/bash TDD 먼저)

- `detect_profile_var`: mdc 형태(`ARG PROFILE`→`PROFILE`), Spring 직접(`ARG SPRING_PROFILES_ACTIVE`), 변수 없음(web)→None, 후보 우선순위.
- `build_overlay` env 미러링: `build_args={ai-index:{PROFILE:dev}}` → overlay 에 `services.ai-index.environment.PROFILE=dev` emit. profile 후보 아닌 build arg(예: `JAVA_TOOL_OPTIONS`)는 env 미러링 안 함.
- overlay 머지 효과(통합/실docker 1케이스): stored `environment: PROFILE=local` + overlay `PROFILE=dev` → 런타임 `PROFILE=dev`.
- `compose_resolved_view`: 서비스에 `profileVar`(감지)·`profileValue`(marinaBuildArgs 우선, 없으면 stored build.args) 포함.
- `/api/compose-service-profile`: build-args.json 저장·감지 var 사용·잘못된 입력 4xx.
- 회귀: 기존 54 테스트 green 유지(stored compose 불변 → 기존 compose 테스트 영향 0).

## 배포 메모

- 기존 등록 프로젝트(mdc-main)는 마이그레이션 없이 그대로 동작 — 하드코딩 `PROFILE: local` 이 UI 에 "현재 profile=local" 로 보이고, 바꾸면 overlay 가 덮음. stored compose 불변.
- profile **값** 변경은 재빌드 트리거(build arg 변경). 문서에 명시.
- overlay env 미러링은 `build_overlay` 한 곳 — 기존 weave/build-args overlay 와 같은 파일(`marina-overlay.yml`)에 합쳐짐.
