# Orca 비교와 marina 제품 로드맵

날짜: 2026-07-14

상태: 방향 확정, 구현 체크리스트 시작
첫 실행 계획: `docs/superpowers/plans/2026-07-14-build-observability.md`

## 목적

Orca의 넓은 IDE·에이전트 기능을 그대로 따라가는 대신, marina가 빠르게 차용할 기능과
worktree별 풀스택 dev runtime이라는 정체성을 강화할 기능을 구분한다. 팀이 제기한 빌드 속도 문제를
첫 번째 제품 과제로 삼고, 이후 Orca식 agent 운영 UX를 낮은 비용 순서로 도입한다.

## 비교 기준

- `O`: 제품 안에서 기본 제공하며 주 흐름으로 쓸 수 있다.
- `△`: 일부 제공하거나 외부 도구·수동 조작이 필요하다.
- `X`: 제품 기능으로 제공하지 않는다.
- Orca 판정은 2026-07-14 공식 문서 기준이다.
- marina 판정은 현재 main(`8c823c6`)과 로컬 `mdc-main` 실측 기준이다.

## 기능 비교

### Worktree와 Agent

| 기능 | Orca | marina | 결정 |
|---|:---:|:---:|---|
| 작업별 git worktree 생성·삭제 | O | O | marina 유지·개선 |
| Agent 세션 연결·재접속 | O | O | marina 기존 자산 활용 |
| 여러 agent를 나란히 실행 | O | △ | 터미널 탭·분할로 점진 확장 |
| 다양한 agent CLI 지원 | O | △ | Claude·Codex 우선, 범용화는 후순위 |
| working/idle/blocked 상태 | O | △ | hook 기반 상태로 보강 |
| Agent Activity Feed·Inbox | O | X | 빠른 차용 대상 |
| 사용량·rate·계정 전환 | O | X | 보류 |
| Agent 간 task dispatch | O | X | 보류 |
| Linear/GitHub/Jira 작업 연결 | O | X | PR/check 이후 검토 |

### 개발과 리뷰

| 기능 | Orca | marina | 결정 |
|---|:---:|:---:|---|
| 내장 코드 에디터·파일 탐색 | O | X | 비목표 |
| 내장 터미널 | O | O | Quick Commands·분할 확장 |
| 내장 Chromium·Design Mode | O | X | 비목표 |
| 로그·터미널 Copy Context | O | △ | 빠른 차용 대상 |
| 텍스트 diff·stage·commit·push | O | O | 기존 기능 유지 |
| merge·rebase·stash | O | O | 기존 기능 유지 |
| 이미지 diff·AI conflict resolver | O | X | 후순위 |
| PR 생성·상태·CI check | O | △ | 중기 과제 |
| 멀티 worktree Git lane graph | △ | O | marina 강점 유지 |

### Dev Runtime

| 기능 | Orca | marina | 결정 |
|---|:---:|:---:|---|
| Worktree별 Docker Compose stack | X | O | marina 핵심 |
| 컨테이너·네트워크·포트 격리 | X | O | marina 핵심 |
| Gateway·host forwarding | X | O | marina 핵심 |
| 서비스 lifecycle·health·로그 | △ | O | 빌드 관측성까지 확장 |
| Dockerfile·Compose 스캔·검증 | X | O | Dockerfile Doctor로 확장 |
| prebuild·build args·env 주입 | X | O | Smart Build 입력으로 활용 |
| dependency symlink 재사용 | X | O | 유지 |
| 연결 topology | X | O | 유지 |
| 팀 runtime 설정 공유 | △ | O | profile·warm cache로 확장 |

### 원격과 통합

| 기능 | Orca | marina | 결정 |
|---|:---:|:---:|---|
| SSH 원격 agent·worktree | O | X | 장기 보류 |
| 모바일 companion | O | X | 비목표 |
| Desktop 알림 | O | O | Agent 완료 알림으로 확장 |
| GitHub/GitLab·Linear·Jira | O | △ | GitHub PR/check부터 |
| MCP server 관리 | O | X | 비목표 |
| Agent용 skill·hook·CLI | O | O | marina 강점 유지 |
| 예약 automation | O | X | 보류 |

## 포지셔닝 결정

> Orca가 agent를 운영하는 IDE라면, marina는 agent가 망가뜨리지 못하는 팀 로컬 개발환경이다.

선택한 전략은 **runtime-first**다.

1. 빌드·기동 비용을 측정하고 설명한다.
2. 안전한 범위에서 불필요한 rebuild를 줄인다.
3. 팀 공용 runtime을 빠르게 재현한다.
4. 그 위에 Orca식 agent 운영 UX를 얹는다.

에디터·내장 브라우저·모바일·범용 orchestration의 기능 수 경쟁은 하지 않는다.

## 빌드 속도 조사 결과

### 관찰 범위

- 이 결과는 2026-07-14 현재 로컬 `mdc-main`의
  `info-video-wizard-refactor-017576` worktree에서 수집했다.
- 팀원 머신의 원격 측정값은 아니므로, 제품 구현 후 동일 Build Summary를 팀원 환경에서도 수집한다.
- 조사 시점 marina는 모든 `start/restart`에 `docker compose up -d --build`를 사용했다. P0 구현에서
  기본 Start/Restart와 명시적 Rebuild를 분리했다.

### 실측

| 구간 | 결과 | 해석 |
|---|---:|---|
| Gradle prebuild | 13초, 다음 실행 7초 | build cache 정상 |
| search-api ffmpeg layer | 404MB, `CACHED` | cold build 비용, 반복 병목 아님 |
| Playwright Chromium | build arg `false` | 설치되지 않음 |
| web build context | 5.1초 | 매 시작 고정비 |
| web `pnpm install` | 22.9초, 1,670 package download | 주요 cache miss |
| web export/unpack | 68.5초 | 관찰된 최대 병목 |
| 다음 실행 | Docker layer 전부 `CACHED` | cache hit이면 빠름 |

P0.1 구현 후 같은 worktree에서 다시 측정한 결과:

| run | 총 시간 | cache hit / run | 가장 느린 단계 |
|---|---:|---:|---|
| cold `run-004` | 302.6초 | 4 / 32 | pip dependency install 189.8초 |
| 즉시 재실행 `run-005` | 33.9초 | 13 / 23 | Gradle prebuild 8초 |

cold run에서는 search-api Python dependency resolver가 `llama-parse` 호환 버전을 backtracking하며
가장 오래 걸렸다. Playwright 설치 분기는 `false`였고 0.6초, ffmpeg layer는 cache hit였다.

프로젝트 설정 최적화 후 web local image를 독립 측정한 결과:

| build | 총 시간 | dependency install | image export/unpack |
|---|---:|---:|---:|
| cold | 99초 | 24.9초, 1,670 download | 57.3초 |
| source-only 변경 | 24초 | `CACHED` | 8.8초 |
| manifest-only 변경 | 71초 | 9.0초, 1,670 reuse / 0 download | 48.0초 |

`turbo prune web --docker`의 pruned manifest를 install layer 입력으로 사용하면서 source-only 변경은
dependency layer를 무효화하지 않았다. manifest 변경은 install을 다시 실행했고, pnpm store cache가
네트워크 다운로드를 제거했다.

Compose Watch와 빠른 Start를 통합한 뒤 같은 feature worktree에서 측정한 결과:

| 경로 | 결과 | 해석 |
|---|---:|---|
| 동일 이미지 Start | 8.4초 | Docker build 0회 |
| source 변경 | build 0회 | Compose sync + Next hot reload |
| manifest 이벤트 | context 4.6초 | web만 rebuild, 모든 Docker 단계 cache hit |
| 명시적 Rebuild | 18.2초 | `up -d --build`, 모든 Docker 단계 cache hit |

앱의 `node_modules` named volume은 제거했고 이미지의 pnpm symlink를 직접 사용한다. `.next` volume은
worktree별 build cache로 유지한다. source 반영은 Aside에서 임시 DOM 문자열로 확인한 뒤 원복했다.

capability 기반 루프를 BE/AI까지 확장한 뒤 측정한 결과:

| 경로 | 첫 실행 | warm/변경 경로 | 해석 |
|---|---:|---:|---|
| `index-api` rebuild | 259.9초 | 14.6초 | pip 183.3초, export/unpack 62.1초 |
| `search-api` rebuild | 235.8초 | 14.9초 | pip 160.4초, Node 11.8초, export/unpack 50.7초 |
| AI source 변경 | build 0회 | 약 3초 내 sync | Uvicorn reload, 컨테이너 유지 |
| index requirements 변경 | index만 rebuild | 모든 layer `CACHED` | search 컨테이너 유지 |
| BE user prebuild | 45.4초 | 5.0초 | 38 up-to-date, 6 from cache |
| BE JAR 변경 | build 0회 | 약 2.1초 내 restart | 소유 서비스 컨테이너만 재시작 |

AI 첫 rebuild에서도 ffmpeg/apt는 cache hit였고 Chromium build arg는 `false`였다. 반복 지연의 핵심은
ffmpeg나 Playwright 설치가 아니라 Python dependency resolver/install과 최초 image export였다. source bind를
제거한 AI image는 dependency 뒤 bootstrap source를 포함하고, 실행 후 Compose Watch `sync`로 갱신한다.

실세션 검증 중 Compose Watch가 같은 프로젝트에 watcher lock 하나만 허용한다는 제약도 확인했다. Marina는
서비스별 watcher를 여러 개 띄우지 않고, 실행 중인 watchable 서비스를 하나의 project watcher로 묶도록 수정했다.

### 원인

1. web Dockerfile이 `COPY . .` 다음에 `pnpm install --filter "web..."`을 실행한다.
   포함된 소스가 바뀌면 1.77GB dependency layer가 무효화될 수 있다.
2. pnpm store용 BuildKit cache mount가 없어 cache miss 때 패키지를 다시 다운로드한다.
3. 조사 시점 marina가 매 start/restart마다 `--build`를 강제해 context·definition 검사를 항상 수행했다.
4. 현재 머신은 Docker images 350.6GB, BuildKit cache 300.1GB, local volumes 69.7GB를 사용한다.
   한 worktree의 `.next` volume만 13.77GB다.
5. search-api cold path는 ffmpeg 404MB, Node 257MB, Python dependencies 1.97GB로 크다.
   현재 반복 실행에서는 캐시됐지만 새 머신·requirements 변경 때 비용이 크다.

### 프로젝트 설정에서 먼저 고칠 항목

- [x] web dependency layer를 소스 layer와 분리한다.
- [x] pnpm store에 BuildKit cache mount를 적용한다.
- [x] `turbo prune --docker` 또는 동등한 manifest-only install을 검증한다.
- [x] 전체 source bind와 app `node_modules` runtime volume을 Compose Watch로 대체한다.
- [x] source는 `sync`, manifest·lockfile·Dockerfile은 `rebuild`로 선언한다.
- [x] search-api의 optional Node 설치를 pip dependency layer 뒤로 이동한다.
- [x] AI image에 bootstrap source를 포함하고 source bind를 Compose Watch sync로 대체한다.
- [x] AI requirements·Dockerfile 변경을 소유 서비스 rebuild로 격리한다.
- [x] BE prebuild를 서비스 단위로 분리하고 JAR 변경을 소유 서비스 restart로 연결한다.
- [x] Compose 프로젝트당 watcher를 하나만 유지한다.
- [ ] ffmpeg·Node·Chromium을 `lite/media/browser/full` runtime profile로 나눌지 검증한다.
- [ ] registry cache가 cold-start를 실제로 줄이는지 측정한다.

팀 공용 dev-base image는 P0에서 도입하지 않는다. 현재 병목은 base image 재사용보다 web dependency
cache 경계와 marina의 강제 rebuild에 있고, dev-base는 별도 버전·배포·취약점 관리 비용을 만든다.
위 개선 후에도 공통 system dependency 설치가 cold-start의 주 병목으로 남을 때만 다시 검토한다.

위 항목은 `mdc-main` 프로젝트 변경이며 marina core 변경과 분리해 리뷰한다.

## 우선순위

### P0. 체감 속도와 설명 가능성

- [x] **P0.1 Build Timeline**: run별 총 시간, 단계별 시간, cache hit, bottleneck을 로그 탭에 표시한다.
- [x] **P0.2 Why Rebuilt**: 이전 run과 비교해 바뀐 Dockerfile·manifest·build arg를 설명한다.
- [ ] **P0.3 Start / Rebuild / Clean Rebuild 분리**: Start와 Rebuild는 분리 완료. Clean Rebuild가 남았다.
- [x] **P0.4 Fast Start / Compose Watch**: 기본 Start의 강제 `--build`를 제거하고, 프로젝트 표준
  `develop.watch` 선언으로 source sync와 dependency rebuild를 자동화한다.
- [ ] **P0.5 Worktree Disk View**: image·BuildKit·volume·`.next` 사용량과 안전한 정리를 제공한다.
- [ ] **P0.6 Dockerfile Doctor**: `COPY . . → install`, cache mount 누락, 대형 layer 후보를 경고한다.
- [ ] **P0.7 Runtime Profile / Registry Cache**: 선택적 의존성을 나누고 검증된 remote cache 경로를 제공한다.

실행 순서는 프로젝트 설정의 dependency cache 경계를 먼저 고친 뒤 marina core 최적화로 넘어간다.
P0.1과 P0.4, P0.3의 Start/Rebuild 분리는 구현·실측했다. Marina 전용 fingerprint는 도입하지 않았다.
Watch가 꺼진 동안 dependency 입력이 바뀐 경우에는 Rebuild가 필요하며, 자동 pre-start 판정과 Clean Rebuild는
후속 범위다. P0.2 비교값은 Compose에 선언된 Dockerfile·`develop.watch` rebuild 입력·build arg를 대상으로
하며, build arg 원문은 로컬 HMAC으로만 기록한다. 이 설명은 Marina lifecycle run 간 비교 범위이고 Compose
Watch가 자체 실행한 rebuild를 자동 수집하는 기능은 후속 범위다.

### P1. 낮은 비용의 Orca UX 차용

- [ ] **P1.1 Agent Activity Inbox**: 완료·질문·최근 응답을 worktree 전체 피드로 보여준다.
- [ ] **P1.2 Quick Commands**: 프로젝트별 shell command와 agent prompt를 저장·실행한다.
- [ ] **P1.3 Copy Context**: 로그·터미널 최근 범위를 bounded text로 복사한다.
- [ ] **P1.4 Agent 상태 정확도**: working/idle/blocked를 hook 이벤트로 판정한다.
- [ ] **P1.5 터미널 탭·분할**: 한 worktree에서 여러 agent를 나란히 본다.
- [ ] **P1.6 Start-from picker**: base branch·local branch·remote·SHA를 선택한다.

### P2. 외부 리뷰 흐름

- [ ] **P2.1 GitHub PR 생성**: compare 페이지 열기를 실제 PR 생성 흐름으로 확장한다.
- [ ] **P2.2 PR·CI 상태**: worktree 카드에 review/check 상태를 표시한다.
- [ ] **P2.3 실패 check context 전달**: 실패 로그를 agent에 전달한다.

### 보류·비목표

- [ ] 내장 코드 에디터
- [ ] 내장 Chromium·Design Mode
- [ ] 모바일 companion
- [ ] Claude/Codex 계정 hot-swap·사용량 tracking
- [ ] 범용 agent orchestration·MCP host
- [ ] SSH 원격 runtime

이 목록은 기능 누락 체크리스트가 아니다. 포지셔닝이 바뀌기 전까지 구현하지 않을 항목을 기록한다.

## 마일스톤 완료 조건

### M0: Build Observability

- 동일 run에서 총 시간과 가장 느린 단계가 일관되게 나온다.
- BuildKit cache hit/miss와 Gradle prebuild를 구분한다.
- 알 수 없는 로그 형식은 원문 로그를 깨뜨리지 않고 `unknown`으로 남는다.
- 실제 `mdc-main` cold/cache-hit run에서 결과를 검증한다.

### M1: Fast Start

- 소스-only 변경은 dependency image rebuild 없이 기동한다.
- manifest·Dockerfile·build arg 변경은 rebuild를 놓치지 않는다.
- 사용자가 Rebuild와 Clean Rebuild를 명시적으로 실행할 수 있다.
- stale image가 감지되면 이유와 다음 행동을 보여준다.

### M2: Runtime Hygiene

- worktree별 image·volume·cache 사용량을 조회한다.
- 실행 중인 서비스가 참조하는 자산은 기본 정리에서 제외한다.
- 정리 전에 회수 예상 용량과 삭제 대상을 보여준다.

### M3: Agent Operations

- 완료·blocked 이벤트가 Inbox에 한 번만 기록된다.
- 알림에서 해당 worktree·agent terminal로 이동한다.
- Quick Command와 Copy Context가 worktree 경계를 보존한다.

## 작업 규칙

- 각 체크박스는 독립 spec·plan·테스트·리뷰 단위를 가진다.
- marina core 개선과 `mdc-main` Dockerfile 개선은 같은 커밋에 섞지 않는다.
- lifecycle 의미 변경은 unit test와 실제 Docker e2e를 모두 통과해야 한다.
- 대시보드 변경은 Aside로 desktop·좁은 viewport·dark/light를 검증한다.
- 마일스톤 완료 시 이 문서의 체크박스와 상태를 갱신한다.

## 참고 자료

- Orca: <https://www.onorca.dev/docs>
- Orca Worktrees: <https://www.onorca.dev/docs/model/worktrees>
- Orca Terminal·Quick Commands: <https://www.onorca.dev/docs/terminal>
- Orca Agent Feed: <https://www.onorca.dev/docs/activity>
- Orca Notifications: <https://www.onorca.dev/docs/notifications>
- Orca GitHub Review: <https://www.onorca.dev/docs/review/github>
- marina runtime 개요: `README.md`
- marina build 실행: `plugin/scripts/marina-compose.py`
- marina build log 수집: `plugin/scripts/marina_cli.py`
- marina agent 세션 UI: `plugin/scripts/marina-web/app-5-sessions.js`
