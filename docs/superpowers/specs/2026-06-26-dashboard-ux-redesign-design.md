# Marina 대시보드 UX 재설계 — 설계

**작성:** 2026-06-26 · 브랜치 `claude/suspicious-cartwright-61c154`

## 목표
워크트리별 compose 격리 dev-orchestration(marina) 대시보드를 **직관적**으로 재설계한다. 한 사람이 프로젝트를 세팅하면 팀원은 **복붙 한 번**으로 동일 환경을 재현한다.

## 동기 (현재 문제)
1. **모달 난립** — compose 등록·서비스 설정·links 가 흩어져 흐름이 안 보임.
2. **links 자동 심링크 과잉** — node_modules뿐 아니라 **빌드 출력(JAR·build·.next)까지 자동 심링크** → docker build 컨텍스트의 심링크가 깨져 빌드 실패(user-api JAR 버그 근본 원인). 빌드 산출물은 워크트리마다 독립이어야 함.
3. **Dockerfile 스캔 + env 입력 유실** — LLM compose-assist 제거 시 같이 사라짐 → 비-LLM 으로 복구 필요.
4. **팀 공유 수단 없음** — 세팅이 ~/.marina 에 흩어져 공유 불가.

## 1. 핵심: "하나의 정규 설정" = 공유 단위
프로젝트 전체 marina 세팅을 **compose YAML 한 파일**에 담는다. docker-compose 표준 필드 + `x-marina` 확장(docker 는 `x-*` 무시 → 유효 compose, marina 만 읽음).

```yaml
services:
  user-api:
    build: { context: ./be-api/user-api, dockerfile: DockerFile, args: { PROFILE: local } }   # build-args(env)
    expose: ["8081"]
x-marina:
  prebuild: { be-api: "./gradlew assemble" }                   # 호스트측 사전빌드(워크트리별)
  links:
    symlink: [ node_modules, .venv ]                           # 의존성 공유
    copy:    [ "**/*local.yml", ".env*.local" ]                # 가벼운 config 독립 복사
    # 빌드 출력(build·.next·dist·out·target·*.jar) = 목록 제외 = 워크트리별 독립 빌드
  forward: { "6379": { target: host } }                        # 엮기: 컨테이너 localhost:6379 → host redis (포트 키는 string — docker 가 x-* 확장의 비-string 키 거부)
  gateway: { routes: { user-api: ["/v1.0"] } }                 # caddy: 호스트 브라우저 진입
```
- **공유 = 이 YAML 한 블록 복붙.** 경로는 **프로젝트 상대** → 같은 레포 받은 팀원이면 그대로 복원.
- **시크릿 값 제외** — 선택/구조(PROFILE·links전략·forward·gateway)만. 실제 시크릿(.env 값)은 각자.

## 2. links 모델 (opt-in · 3분류)
자동 전부-심링크 폐기. 원본→워크트리 대상을 성격별로 **사용자가 선택**:

| 분류 | 예 | 동작 | 기본 |
|---|---|---|---|
| 의존성 | node_modules·.venv·gradle 캐시 | **심링크**(공유·재설치 회피) | 제안 켬 |
| Config(gitignore) | `*local.yml`·`.env*` | **심링크**(공유) 또는 **복제**(독립 편집) | 사용자 택 |
| 빌드 출력 | build·.next·dist·out·target·`*.jar` | **가져오지 않음**(독립 빌드) | 제외 |

- **"override" 개념 폐기** — 복제가 "워크트리별 다른 값", 링크 끄기 토글이 "이 워크트리는 자체로"를 커버. 헷갈리는 용어 제거.
- 심링크 walker 재귀 버그는 수정 완료(`.claude`/dst_base 제외, d247591).

## 3. 세 모드 = 같은 YAML 의 뷰
- **위저드(기본)** — 단계별로 정규 설정을 채움.
- **고급(토글)** — 같은 YAML 을 한 화면에서 직접 편집(파워유저, 위저드 스킵).
- **공유/가져오기** — 복사 ↔ 붙여넣기.

위저드·고급은 **같은 데이터의 두 뷰**(소스 하나) → 항상 일치.

## 4. 진입 경로 두 개 (프로젝트 추가 시)
- **새로 설정(위저드)** — 처음 만드는 사람.
- **팀원 설정 붙여넣기(빠름)** — 큰 텍스트 필드에 공유 블록 붙여넣기 → 파싱(compose+x-marina) → **등록 + 전체 설정 적용 → 끝**. 위저드/개별설정 안 거침. (시크릿 .env 만 본인 것 안내.)

## 5. 위저드 단계
1. **스캔** — `/api/compose-scan`(비-LLM) 이 서브레포 Dockerfile 감지 → 서비스 카드: 🐳 Dockerfile(읽기전용·변수 하이라이트)·ARG/필수ARG·EXPOSE · ⚙️ **build-args/env 입력**. *(제거됐던 기능 복구)*
2. **파일** — gitignored 스캔 → 3분류 제안 → opt-in 체크(심링크/복제). 빌드 출력 제안 안 함.
3. **연결** — 흔한 host 백킹(redis 6379·mysql 3306·postgres 5432) 제안 → 체크 시 `forward {port: host}`. 게이트웨이 토글.
4. **검토** — 입력으로 compose 초안(비-LLM, `_compose_scaffold_service` 템플릿) 생성 → YAML 확인/수정 → 등록.

## 6. 실행중 = 서비스 카드
상태·포트 · **게이트웨이 URL(복사 버튼)** · **ⓘ 인라인 설정**(Dockerfile 보기·build-args·prebuild·links·forward). 별도 모달 최소화.

## 7. 연결(connectivity) 3종 — 전부 x-marina
| 방향 | 수단 | 선언 |
|---|---|---|
| 컨테이너→호스트백킹(redis/db) | 엮기 socat 사이드카(앱 0수정) | `forward: {6379: {target: host}}` |
| 컨테이너→컨테이너(app→be) | 자동 도출 `_auto_service_forward` | (자동) |
| 호스트브라우저→컨테이너 | Caddy 게이트웨이 `<wt>.<proj>.localhost` | `gateway: {routes: {...}}` |

## 8. 저장 / 마이그레이션
- 흩어진 `build-args.json`·`prebuild.json`·`links.json`·`backing.json(forward)` → **compose `build.args` + `x-marina` 로 통합**.
- 기존 프로젝트: 등록/로드 시 흩어진 JSON 을 x-marina 로 1회 마이그레이션(읽어서 합침). 무중단.

## 9. 백엔드
- `/api/compose-scan` (신규·비-LLM) — `_list_dockerfiles`·`_dockerfile_expose`·ARG감지·config후보 재사용 → 서브레포별 `{dockerfile, expose, args, requiredArgs, artifacts, configCandidates}`.
- `/api/compose-import` (신규) — 공유 블록 파싱·검증(compose 유효·레포 매칭) → 등록 + x-marina 적용.
- **x-marina 파서/적용** — links(symlink/copy/제외)·prebuild·forward·gateway 를 기존 overlay·링크 경로에 연결.
- 유지: detect/scaffold/validate · build-args·prebuild 엔드포인트(내부적으로 x-marina 읽기/쓰기).

## 10. 테스트
- x-marina 파싱·왕복(설정→YAML→설정 동일).
- links 3분류 적용(심링크·복제·빌드출력 제외) + 재귀 0(회귀테스트 확장).
- compose-scan 비-LLM 출력.
- import e2e: 공유 블록 → 등록+적용.
- 마이그레이션: 기존 JSON → x-marina.

## 11. 비목표
- LLM compose 생성/검증(제거 유지) · "override" 개념(폐기) · 빌드 출력 공유(의도적 독립).
