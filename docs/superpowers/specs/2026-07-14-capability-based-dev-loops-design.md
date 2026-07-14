# Capability-based Development Loops Design

날짜: 2026-07-14

상태: P0 구현 및 MDC reference 검증 완료

## 결정

Marina의 개발 루프를 특정 프로젝트나 언어가 아니라 **서비스가 요구하는 반영 방식**으로 표준화한다.

서비스는 프로젝트의 Docker Compose와 `x-marina` 설정을 조합해 다음 세 경로 중 필요한 경로를 선언한다.

1. **Sync/reload**: 소스 파일을 컨테이너에 동기화하고 애플리케이션 자체 reload를 사용한다.
2. **Artifact/restart**: 호스트에서 실행한 빌드가 산출물을 만들면 해당 컨테이너만 재시작한다.
3. **Image/rebuild**: Dockerfile, 시스템 패키지, dependency manifest처럼 이미지 경계를 바꾸는 입력은 이미지를 다시 빌드한다.

Compose가 표현할 수 있는 파일 감시와 컨테이너 동작은 표준 `develop.watch`가 소유한다. Compose가 실행할 수 없는
호스트 빌드 명령만 `x-marina.prebuild`가 소유한다. Marina 코어는 Gradle, Spring, Python, Uvicorn, Node 같은
언어나 프레임워크를 추론하지 않고 선언을 검증하고 실행한다.

MDC는 이 구조를 검증하는 첫 번째 reference fixture일 뿐, Marina의 스키마나 런타임 분기 기준이 아니다.

## 배경

MDC web에 적용한 Compose Watch는 source-only 변경에서 Docker build를 제거하고, manifest 변경만 해당 이미지를
다시 빌드하게 만들었다. 같은 원칙을 다른 서비스에 그대로 복제하면 두 문제가 생긴다.

- reload 가능한 Python 서비스와 JAR 산출물이 필요한 JVM 서비스는 반영 방식이 다르다.
- 모든 서비스를 컨테이너 내부 source build로 통일하면 표준성은 높지만 이미 동작하는 호스트 build cache와 IDE
  빌드를 포기해 시작 속도와 개발 편의가 나빠질 수 있다.

반대로 모든 변경 감지와 빌드를 Marina가 직접 소유하면 프로젝트 설정이 Marina 전용 규약에 종속된다. 따라서
Compose를 기본 실행 계약으로 두되, 호스트 산출물 빌드라는 표준 Compose의 빈칸만 작은 확장으로 채운다.

## 목표

- 프로젝트와 언어에 무관한 개발 루프 계약을 제공한다.
- source-only 변경이 불필요한 image rebuild를 일으키지 않게 한다.
- 서비스 하나를 시작할 때 관련 없는 서비스의 호스트 빌드를 실행하지 않는다.
- Docker Compose를 컨테이너 파일 감시와 재시작/rebuild의 진실의 원천으로 유지한다.
- 기존 `x-marina.prebuild` 문자열 형식을 깨지 않고 서비스 단위 선언을 추가한다.
- 프로젝트 설정만으로 각 서비스의 반영 경로를 이해할 수 있게 한다.
- Marina의 기존 build timeline과 로그에서 호스트 prebuild 실패를 설명할 수 있게 한다.

## 비목표

- Gradle, Maven, pnpm, pip 등 도구별 자동 감지
- source input/output fingerprint와 Marina 전용 cache invalidation
- 모든 프로젝트를 `bootRun`, Uvicorn reload 또는 하나의 dev server 방식으로 통일
- 호스트 파일 변경 때 compiler를 자동으로 상시 실행하는 범용 daemon
- 팀 공용 dev-base 이미지
- ffmpeg, Node, Chromium 같은 선택 의존성의 runtime profile 분리
- registry cache와 원격 BuildKit cache 도입
- Docker Compose가 지원하지 않는 Watch action을 Marina가 다른 의미로 자동 변환

## 책임 경계

### 프로젝트 Docker Compose

프로젝트가 다음 내용을 명시한다.

- 감시할 `path`
- 컨테이너 안의 `target`
- `sync`, `rebuild`, `restart`, `sync+restart` 중 사용할 Watch action
- 동기화에서 제외할 파일과 디렉터리
- 산출물 bind mount 또는 named volume
- 서비스별 Docker build context와 Dockerfile

Marina는 Watch path나 manifest 종류를 추론하지 않는다. 같은 언어라도 프로젝트 구조와 런타임에 따라 다른 선언을
사용할 수 있다.

### `x-marina`

`x-marina`는 Compose가 호스트에서 실행할 수 없는 명령만 선언한다.

- 호스트 명령의 작업 디렉터리
- 실행할 명령
- 그 명령을 실행해야 하는 Compose 서비스

파일 감시, 산출물 경로, restart 조건은 `x-marina`에 중복 선언하지 않는다.

### Marina 코어

Marina는 다음만 담당한다.

- 선택된 서비스에 해당하는 prebuild 선언 검증 및 실행
- 동일한 prebuild 작업의 중복 제거
- prebuild 실패 시 start/rebuild 중단과 로그 보존
- 실행 중인 서비스에 한정한 프로젝트 단일 Compose Watch 프로세스 수명 관리
- 현재 Compose 버전에서 프로젝트가 선언한 Watch action을 사용할 수 있는지 검증
- start, rebuild, stop, restart의 기존 lifecycle과 build timeline 연결

## 범용 Prebuild 계약

### 신규 서비스 단위 형식

`x-marina.prebuild`의 key를 Compose 서비스명으로 사용하고, 값에 작업 디렉터리와 명령을 선언한다.

```yaml
x-marina:
  prebuild:
    user-api:
      cwd: be-api
      command: ./gradlew :user-api:bootJar --build-cache
    batch:
      cwd: be-api
      command: ./gradlew :batch:bootJar --build-cache
```

필드 의미는 언어와 무관하다.

| 필드 | 필수 | 의미 |
|---|:---:|---|
| map key | O | 기존 Compose의 서비스명 |
| `cwd` | O | worktree root 기준 상대 작업 디렉터리 |
| `command` | O | 해당 디렉터리에서 실행할 호스트 shell 명령 |

`cwd`는 symlink 해석 후에도 worktree root 밖으로 벗어날 수 없다. 신규 object 형식은 경로를 추론하지 않고 적힌
값 그대로 worktree root 상대경로로 해석한다. 외부 repository는 Marina가 준비한
`.workspace/external/<name>`을 `cwd`에 명시한다. `command`는 프로젝트의 신뢰된 공유 설정으로 취급하고 현재 shell
실행 모델을 유지한다.

### 기존 형식 호환

현재 subrepo 단위 문자열 형식은 그대로 지원한다.

```yaml
x-marina:
  prebuild:
    be-api: ./gradlew user-api:bootJar batch:bootJar --build-cache --parallel
```

문자열 값은 기존과 동일하게 key를 subrepo 작업 디렉터리로 해석하고, 선택 서비스의 build context 첫 경로와
일치할 때 실행한다. object 값은 신규 서비스 단위 형식으로만 해석한다. 한 key의 값이 문자열도 object도 아니면
설정 오류로 start 전에 중단한다.

### 선택과 중복 제거

- `marina start --user-api`: `user-api` object prebuild만 실행한다.
- `marina start --all`: 먼저 `x-marina.startGroup`을 해석하고, start group이 있으면 그 서비스만, 없으면 모든
  startable service의 object prebuild를 실행한다.
- 같은 `cwd`와 `command` 조합이 여러 선택 서비스에 선언되면 한 번만 실행한다.
- 선택되지 않은 서비스, 존재하지 않는 서비스 key, 비어 있는 `cwd`/`command`는 명확한 검증 결과를 남긴다.
- 명령은 선언 순서를 보존해 직렬 실행한다. 병렬 host build는 빌드 도구 자체 옵션으로 제어한다.

이번 단계에서는 `inputs`, `outputs`, `watch`, `language`, `cache` 필드를 추가하지 않는다. 산출물 변경 감지는
Compose Watch가 담당하며, 호스트 compiler의 상시 실행은 프로젝트의 IDE나 별도 명령이 담당한다.

## 개발 루프

### Sync/reload 서비스

reload 가능한 런타임은 source bind mount 대신 Compose Watch `sync`와 `initial_sync`를 사용한다.

```yaml
services:
  api:
    develop:
      watch:
        - action: sync
          path: ./api
          target: /workspace/api
          initial_sync: true
          ignore:
            - .venv/
            - __pycache__/
            - requirements*.txt
        - action: rebuild
          path: ./api/requirements.txt
        - action: rebuild
          path: ./api/Dockerfile.local
```

일반 source 변경은 파일 동기화와 런타임 reload로 끝난다. dependency manifest와 Dockerfile 변경은 해당 서비스
이미지만 rebuild한다. 프로젝트가 reload 기능을 켜지 않았다면 `sync+restart`를 선택할 수 있다.

Marina는 컨테이너를 먼저 기동하고 그 뒤 `watch --no-up`을 시작한다. 따라서 bind mount를 제거한 서비스의 이미지는
watcher가 붙기 전에도 실행 가능한 bootstrap source를 포함해야 한다. 보통 dependency install layer 뒤에 source를
`COPY`해 이 조건을 만족한다. 이 source layer는 최초 기동용이며, 실행 뒤에는 `initial_sync`가 worktree 내용을
동기화한다. 이 조건은 프로젝트 설정과 통합 테스트가 보장하며, Marina가 Dockerfile을 추론해 판정하지 않는다.

### Artifact/restart 서비스

컨테이너가 JAR, binary, generated bundle 같은 호스트 산출물을 실행하는 경우 다음 순서로 동작한다.

1. Start/rebuild 전에 선택 서비스의 `x-marina.prebuild`를 실행한다.
2. Compose가 산출물을 bind mount한 컨테이너를 기동한다.
3. Compose Watch가 산출물 경로의 변경을 감시한다.
4. 산출물이 바뀌면 `restart` action으로 해당 서비스만 재시작한다.

```yaml
services:
  api:
    volumes:
      - ./api/build/libs:/app/libs:ro
    develop:
      watch:
        - action: restart
          path: ./api/build/libs
```

이 경로에서 source 저장 자체는 compiler 실행 신호가 아니다. 개발 중 반영은 IDE build, 프로젝트의 Gradle/Maven/
Make 명령, 또는 Marina의 명시적 service restart를 통해 새 산출물을 만든 뒤 일어난다. save-to-compile 자동화는
성능 측정 후 별도 기능으로 설계한다.

### Image/rebuild 경계

다음 변경은 일반적으로 Compose Watch `rebuild`로 선언한다.

- Dockerfile과 entrypoint
- package/dependency manifest와 lockfile
- apt/apk 같은 system dependency 입력
- build arg의 입력 파일
- 생성된 이미지 내용에 영향을 주지만 runtime sync 대상이 아닌 파일

정확한 경계는 프로젝트가 선언한다. Marina는 파일명이나 확장자로 rebuild 조건을 자동 생성하지 않는다.

## Lifecycle

### Start

1. 서비스 선택 또는 start group을 확정한다.
2. 선택 서비스의 신규 object prebuild와 관련 legacy prebuild를 해석한다.
3. prebuild를 검증하고 중복 제거한 뒤 실행한다.
4. 기존 이미지로 `docker compose up -d`를 실행한다. 이미지가 없으면 Compose가 최초 build한다.
5. 실제 running 상태인 Watch 선언 서비스를 하나의 프로젝트 watcher에 묶어 시작한다.

### Rebuild

Start와 같은 prebuild 경로를 거친 뒤 `docker compose up -d --build`를 실행한다. 이후 running watchable 서비스
목록으로 프로젝트 watcher를 교체한다. Compose는 같은 프로젝트의 동시 watcher를 exclusive lock으로 막으므로
서비스별 watcher 프로세스를 만들지 않는다.

### Restart

현재 동작과의 호환을 위해 prebuild를 실행한 뒤 대상 컨테이너를 다시 기동한다. artifact 서비스에서는 이 경로가
명시적 host build + restart 역할을 한다. 장기적으로 build와 container restart를 별도 UI command로 나누는 것은
후속 설계 대상이다.

### 외부 산출물 변경

IDE나 터미널에서 산출물이 갱신되면 Marina 명령 없이 Compose Watch가 해당 컨테이너만 restart한다. watcher는
Marina가 시작한 실행 중 서비스에만 존재하고 stop/down에서 종료된다.

## Compose 버전과 기능 검증

Marina의 전역 최소 Docker Compose 버전은 기존 `2.24.4`를 유지한다. 프로젝트가 사용한 기능에 따라 추가 요구
버전을 검증한다.

| 기능 | 최소 Compose 버전 |
|---|---:|
| `develop.watch` / `sync` / `rebuild` | 2.22.0 |
| `sync+restart` | 2.23.0 |
| `restart` | 2.32.0 |
| `sync+exec` | 2.32.0 |
| Watch `exec` 세부 기능 | 2.32.2 |

Marina는 시작 전에 보관 Compose의 Watch action을 읽고 현재 버전과 비교한다. 지원하지 않는 action이 있으면
서비스명, action, 필요한 최소 버전, 현재 버전을 표시하고 실행을 중단한다. `restart`를 `sync+restart`로 바꾸는
등의 자동 fallback은 의미가 달라질 수 있으므로 하지 않는다.

Watch를 사용하지 않는 프로젝트와 `sync`/`rebuild`만 사용하는 프로젝트는 기존 최소 버전에서 계속 동작한다.

## 오류 처리와 관측성

- prebuild schema 오류는 Docker 실행 전에 실패시킨다.
- prebuild command의 non-zero exit는 해당 서비스 start/rebuild를 중단한다.
- 실행한 service, `cwd`, command, elapsed time, exit status를 build log에 기록한다.
- command stdout/stderr는 현재 build run에 연결하고 기존 secret redaction 규칙을 적용한다.
- Watch 시작 실패는 기존처럼 컨테이너를 내리지 않고 watcher 상태와 로그에 노출한다.
- Watch action 버전 불일치는 실행 전 오류로 처리한다.
- 존재하지 않는 service key는 조용히 무시하지 않고 설정 오류로 보고한다.
- 외부 repository나 `cwd`가 준비되지 않으면 prebuild를 건너뛰지 않고 실패시킨다.

## MDC Reference Fixture

MDC에는 범용 계약을 다음처럼 매핑한다. 이 이름과 명령은 Marina 코어에 들어가지 않는다.

### `index-api`와 `search-api`

- 전체 `./ai-api:/ai-api` source bind mount를 제거한다.
- 두 local image가 dependency install layer 뒤에 `COPY . .`로 실행 가능한 bootstrap source를 포함하게 한다.
- 각 서비스가 필요한 `ai-api` source를 `/ai-api`로 `sync`하고 `initial_sync`를 사용한다.
- `.git`, `.venv`, `__pycache__`, cache directory와 dependency manifest는 source sync에서 제외한다.
- 각 서비스의 requirements와 Dockerfile 변경은 그 서비스만 `rebuild`한다.
- Uvicorn reload는 현재 runtime command를 그대로 사용한다.
- `search-api` Dockerfile의 optional Node 설치 단계를 pip dependency layer 뒤로 옮겨 Node build arg 변경이 Python
  dependency cache를 불필요하게 무효화하지 않게 한다.
- ffmpeg, Node, Chromium profile 분리는 이번 구현에서 하지 않는다.

### `user-api`와 `batch`

- 기존 JAR directory bind mount를 유지한다.
- legacy subrepo prebuild 한 개를 서비스 단위 object 두 개로 바꾼다.
- `user-api`는 `:user-api:bootJar`, `batch`는 `:batch:bootJar`만 빌드한다.
- 각 서비스는 자신의 `build/libs` 경로에 Compose Watch `restart`를 선언한다.
- IDE나 수동 Gradle build가 JAR를 갱신해도 해당 컨테이너만 재시작되는지 검증한다.
- `bootRun`과 Spring DevTools 도입은 이번 범위에서 제외한다.

## 테스트 전략

### Marina 자동 테스트

- legacy 문자열 prebuild가 기존 subrepo 필터 규칙으로 실행된다.
- object prebuild가 선택 서비스에만 실행된다.
- `--all`과 start group이 실제 대상 서비스만 선택한다.
- 동일한 `cwd`/`command` 조합은 한 번만 실행된다.
- 존재하지 않는 서비스, 잘못된 type, 빈 필드, root 밖 `cwd`를 거부한다.
- prebuild 실패 시 Compose `up`을 호출하지 않는다.
- service별 elapsed time과 exit status가 build log에 남는다.
- Compose 2.24 환경에서 기본 Watch는 통과하고 `restart` action은 명확히 거부된다.
- Compose 2.32 이상에서 artifact `restart` watcher가 시작되고 lifecycle 종료 때 누수되지 않는다.
- 여러 watchable 서비스가 실행돼도 프로젝트 watcher와 PID 파일은 하나만 존재한다.
- Watch 미선언 fixture와 기존 prebuild fixture의 회귀 테스트가 통과한다.

### MDC 통합 검증

- `docker compose config`가 AI sync/rebuild와 BE restart action을 정상 해석한다.
- AI image가 Watch 시작 전에도 실행 가능한 source를 포함하고 최초 기동에 실패하지 않는다.
- AI source 변경은 image build 없이 reload된다.
- AI requirements/Dockerfile 변경은 해당 서비스만 rebuild한다.
- `user-api` start가 `batch` artifact를 빌드하지 않고 반대도 동일하다.
- JAR 갱신은 소유 서비스만 restart한다.
- 동일 artifact로 다시 시작할 때 불필요한 Docker build가 없다.
- cold/warm start, source edit, dependency edit, artifact edit 시간을 이전 측정과 비교한다.
- 실제 HTTP 응답 또는 health 상태로 각 변경 반영을 확인한다.

### MDC 검증 결과

| 항목 | 결과 |
|---|---|
| BE 서비스 선택 | `user-api`와 `batch`가 자신의 Gradle task만 실행; user prebuild 45.4초 → 5.0초 |
| BE artifact 반영 | final JAR 변경 후 약 2.1초, 소유 컨테이너만 restart |
| AI bootstrap | source bind 없이 두 서비스 기동, `/docs` 200 |
| AI source 반영 | 약 3초 내 sync, Docker build 0회 |
| AI dependency 반영 | index requirements 이벤트가 index만 rebuild, search 유지 |
| `index-api` rebuild | first 259.9초, warm 14.6초 |
| `search-api` rebuild | first 235.8초, warm 14.9초 |
| Watch 수명 | 실행 서비스 3개를 `compose.watch.pid` 하나로 감독 |

첫 AI rebuild의 지배 비용은 Python dependency resolution/install이었다. ffmpeg/apt는 cache hit였고,
`search-api`의 optional Node 설치는 11.8초, 비활성 Chromium 분기는 0.2초였다. 따라서 dev-base image는 도입하지
않고 dependency/source 경계와 표준 Watch 루프를 우선 유지한다.

## 완료 조건

- Marina 코어에 MDC, Gradle, Spring, Uvicorn, Node 전용 분기가 없다.
- 기존 문자열 `x-marina.prebuild` 프로젝트가 설정 변경 없이 동작한다.
- 신규 object prebuild가 Compose 서비스 단위로 선택된다.
- 한 서비스 시작이 관련 없는 서비스 artifact build를 실행하지 않는다.
- reload 서비스의 source-only 변경에서 Docker build가 0회다.
- artifact 갱신이 해당 컨테이너만 restart한다.
- 프로젝트가 사용한 Watch action과 Compose 버전 불일치가 실행 전에 설명된다.
- Marina 전체 자동 테스트와 MDC fixture 통합 검증이 통과한다.

## 단계별 적용

1. Marina에 object prebuild parser, 검증, 서비스 선택, 중복 제거 테스트를 추가한다.
2. Watch action별 Compose version 검증을 추가한다.
3. MDC BE prebuild를 서비스 단위로 바꾸고 artifact restart를 검증한다.
4. MDC AI bind mount를 Compose Watch sync/rebuild로 바꾸고 Dockerfile cache 경계를 조정한다.
5. cold/warm/edit benchmark를 기록하고 Orca 비교 로드맵의 프로젝트 설정 체크리스트를 갱신한다.

각 단계는 독립 commit으로 유지한다. MDC 변경이 실패하면 프로젝트 설정 commit만 되돌릴 수 있고 Marina의 legacy
prebuild 지원은 영향을 받지 않는다.

## 롤백

- object prebuild에 문제가 있으면 MDC 설정을 legacy 문자열 형식으로 되돌린다.
- artifact `restart`가 파일 교체 과정에서 불안정하면 Watch rule을 제거하고 명시적 Marina restart만 사용한다.
- AI sync가 reload나 local file 처리와 충돌하면 해당 서비스만 기존 source bind mount로 되돌린다.
- 어느 rollback도 언어별 자동 추론이나 Marina 전용 fingerprint를 추가하는 근거로 사용하지 않는다. 실패 원인을
  측정한 뒤 별도 설계한다.

## 참고

- [Docker Compose Develop specification](https://docs.docker.com/reference/compose-file/develop/)
- [Docker Compose Watch guide](https://docs.docker.com/compose/how-tos/file-watch/)
