# Compose Watch Standard Dev Design

## 결정

Marina 전용 dependency fingerprint나 volume 무효화 규약을 추가하지 않는다. 프로젝트는 Docker Compose 표준
`develop.watch`로 소스 동기화와 dependency rebuild 조건을 선언하고, Marina는 해당 Watch 프로세스의
수명만 worktree별로 관리한다.

MDC web에서는 전체 소스 bind mount와 `web_app_node_modules` named volume을 제거한다. 일반 소스 변경은
Compose Watch `sync`, dependency 입력 변경은 `rebuild`로 처리한다. `.next` named volume은 빌드 캐시이므로
유지한다.

## 배경

현재 web 서비스는 다음 두 mount를 겹쳐 사용한다.

- `./web-app-monorepo/apps/web:/app/apps/web`: 호스트 소스 bind mount
- `web_app_node_modules:/app/apps/web/node_modules`: bind mount가 가린 이미지 의존성을 되살리는 named volume

새 이미지가 최신 dependency를 포함해도 기존 named volume이 `/app/apps/web/node_modules`를 다시 가리므로,
lockfile 변경 뒤 예전 pnpm 링크가 남을 수 있다. 실제 `mdc-main-main_web_app_node_modules`는 약 656KB이고
대부분 pnpm 링크와 `.bin` 파일이지만, 이미지와 별도 수명을 가진다는 점이 정확성 문제다.

Docker Compose는 named volume을 선언하고 재사용할 수 있지만 호스트 파일의 checksum을 계산해 volume을
자동 교체하지는 않는다. 시간 기반 이름은 매 시작마다 캐시를 버리고, 세션명은 dependency 변경에도 같아
무효화 신호가 되지 않는다.

## 목표

- Docker Compose 표준 기능을 프로젝트 설정의 진실의 원천으로 사용한다.
- 일반 소스 변경은 이미지 rebuild 없이 실행 중 컨테이너에 반영한다.
- lockfile과 package manifest 변경만 이미지 rebuild를 유발한다.
- 이미지 안의 app-level `node_modules`를 직접 사용해 stale runtime volume을 제거한다.
- Marina는 언어·패키지 매니저별 dependency 규칙을 알지 않는다.
- worktree별 포트·컨테이너·이미지 격리를 유지한다.

## 비목표

- `x-marina.dependencyCache` 같은 새 Marina 전용 스키마
- lockfile hash 저장·비교
- 시간·세션·Git SHA 기반 volume 이름 변경
- 팀 공용 dev-base 이미지
- Compose Watch가 없는 구버전 Docker Compose 지원

## 프로젝트 설정

### Web 서비스 mount

MDC web에서 다음을 제거한다.

```yaml
- ./web-app-monorepo/apps/web:/app/apps/web
- web_app_node_modules:/app/apps/web/node_modules
```

다음은 유지한다.

```yaml
- web_app_next:/app/apps/web/.next
```

Docker build context의 `.dockerignore`가 `.env*`를 제외하므로 local 환경 파일은 source sync에 기대지 않는다.
Marina link가 worktree에 준비한 파일을 Compose의 파일 단위 bind mount로 연결한다.

```yaml
- ./web-app-monorepo/apps/web/.env:/app/apps/web/.env
- ./web-app-monorepo/apps/web/.env.ssm.local:/app/apps/web/.env.ssm.local:ro
```

`.env`는 `pnpm load-env`가 갱신하므로 read-write, `.env.ssm.local`은 입력이므로 read-only다.

### Compose Watch

web 서비스가 다음 규칙을 선언한다.

```yaml
develop:
  watch:
    - action: sync
      path: ./web-app-monorepo/apps/web
      target: /app/apps/web
      initial_sync: true
      ignore:
        - node_modules/
        - .next/
        - package.json
        - Dockerfile.local
        - .env
        - .env.*
    - action: rebuild
      path: ./web-app-monorepo/pnpm-lock.yaml
    - action: rebuild
      path: ./web-app-monorepo/pnpm-workspace.yaml
    - action: rebuild
      path: ./web-app-monorepo/package.json
    - action: rebuild
      path: ./web-app-monorepo/apps/web/package.json
    - action: rebuild
      path: ./web-app-monorepo/apps/web/Dockerfile.local
```

Compose Watch path는 project directory 기준이다. Marina는 현재 worktree를 `--project-directory`로 전달하므로
모든 path가 해당 worktree 파일을 가리킨다. Compose Watch는 glob path를 지원하지 않으므로 dependency 입력은
명시적인 파일 규칙으로 선언한다.

현재 bind mount도 `apps/web`만 실시간 공유하므로 위 sync 범위는 기존 동작과 동일하다. workspace package
소스까지 실시간 편집해야 하는 프로젝트는 해당 package별 `sync` 규칙을 Compose에 추가한다.

## Marina 수명 관리

Docker Compose 2.40.3에서 `up -d --watch`는 허용되지 않는다. Marina는 다음 두 표준 명령을 조합한다.

1. 컨테이너 기동: `docker compose ... up -d`
2. Watch 시작: `docker compose ... watch --no-up <services>`

Watch는 foreground 장기 실행 프로세스이므로 Marina가 서비스별로 `<service>.watch.pid`와 로그를 session
directory에 기록한다. 같은 worktree·서비스에 살아 있는 watcher가 있으면 중복 실행하지 않는다. 서비스
stop/restart와 전체 down에서는 해당 watcher를 종료하고, restart 뒤 다시 시작한다. Watch가 비정상 종료해도
실행 중인 컨테이너는 유지하며 로그와 상태에 실패 원인을 노출한다.

Watch 선언이 없는 Compose 프로젝트는 현재 동작을 유지한다. Marina는 `develop.watch`의 path나 action을
해석하지 않고 Compose에 그대로 위임한다.

## Start와 Rebuild

표준성과 시작 속도를 위해 실행 의미를 분리한다.

- **Start**: 기존 이미지가 있으면 그대로 `up -d`; 이미지가 없으면 Compose가 최초 build; 이후 Watch 시작
- **Rebuild**: `up -d --build`; 이후 Watch 시작
- **Clean Rebuild**: BuildKit cache와 프로젝트가 명시한 cache를 정리한 뒤 rebuild

Watch가 실행 중일 때 dependency 입력이 바뀌면 Compose가 자동 rebuild한다. Watch가 꺼진 동안 branch 전환이나
pull로 dependency 입력이 바뀐 경우에는 사용자가 Rebuild를 선택해야 한다. 이 제한은 숨기지 않는다. 자동
pre-start 판정을 추가하려면 fingerprint가 필요하므로 이번 표준 경로의 범위에서 제외한다.

## 성능 기준

- `.tsx`, `.ts`, CSS 등 `apps/web` 소스 변경: Docker image build 0회
- source sync 후 Next hot reload까지: 기존 bind mount와 유사한 체감 지연
- dependency 입력 변경: web 서비스만 rebuild/recreate
- 동일 이미지 Start: Docker build 단계 0회
- `.next` cache: worktree별 named volume 계속 재사용
- `node_modules`: 이미지 layer를 사용하며 별도 runtime named volume 없음

## 검증

격리된 MDC feature worktree에서 다음을 순서대로 검증한다.

1. `docker compose config`가 Watch와 파일 mount를 정상 해석한다.
2. 최초 Start 후 Next가 Ready가 되고 로컬 환경 파일이 정상 로드된다.
3. `.tsx` 파일을 변경하면 build 없이 sync되고 브라우저에서 변경이 보인다.
4. `apps/web/package.json` 또는 lockfile을 변경하면 web image가 rebuild되고 컨테이너가 교체된다.
5. 컨테이너 안의 app-level dependency symlink가 이미지의 `/app/node_modules/.pnpm`을 가리킨다.
6. `web_app_node_modules` volume 없이 재시작해도 Next와 ds-react watcher가 정상 동작한다.
7. Marina stop/restart/down 뒤 Watch 프로세스가 남지 않는다.
8. Watch 미선언 Compose fixture의 기존 lifecycle 테스트가 그대로 통과한다.

브라우저 검증은 Aside로 수행한다. 실험 중 환경 파일, 토큰, 컨테이너 환경값은 로그나 문서에 기록하지 않는다.

## 롤백

실험에서 Compose Watch sync가 Next hot reload, local env 생성, Turbo watcher 중 하나라도 안정적으로 만족하지 못하면
프로젝트 설정을 기존 bind mount로 되돌린다. 이 경우 fallback은 Marina fingerprint가 아니라 이미지에 보관한
작은 pnpm 링크 seed를 컨테이너 시작 시 named volume에 복사하는 Dockerfile/entrypoint 방식으로 별도 설계한다.

## 완료 조건

- MDC web이 `develop.watch`로 소스 sync와 dependency rebuild를 수행한다.
- `web_app_node_modules` volume이 제거된다.
- source-only 개발 루프에서 Docker build가 발생하지 않는다.
- Marina가 Watch 선언 프로젝트의 watcher를 누수 없이 관리한다.
- 프로젝트별 dependency hash나 Marina 전용 cache schema가 없다.

## 검증 결과

2026-07-14 `mdc-main`의 격리된 `feature/dev-build-cache` worktree에서 검증했다.

| 항목 | 결과 |
|---|---|
| Compose config | `sync` 1개, `rebuild` 5개 해석 |
| runtime mount | app `node_modules` volume 없음, `.next` volume 유지 |
| app dependency | app symlink가 이미지 `/app/node_modules/.pnpm`을 참조 |
| 첫 Ready | Next `235ms` |
| 동일 이미지 Start | 8.4초, Docker build 0회 |
| source 변경 | Watch `Syncing`, Docker build 0회, Aside DOM 반영 확인 |
| manifest 이벤트 | web만 rebuild, 모든 Docker 단계 cache hit, build context 4.6초 |
| 명시적 Rebuild | `up -d --build`, 18.2초 |
| Stop | watcher PID 파일 제거 및 프로세스 종료 |

처음 실행한 root 기준 `require.resolve('next/package.json')` 검사는 실패했지만 앱 작업 디렉터리
`/app/apps/web`에서는 정상 해석됐다. 모노레포 dependency 검증 기준의 문제였으며 런타임 결함은 아니었다.
