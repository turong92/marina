# 워크트리별 Docker compose 오케스트레이션 (compose-kind)

2026-06-18. marina가 프로젝트 풀스택을 **워크트리별 격리 컨테이너**로 띄우는 새 실행 방식. 기존 네이티브 실행(`run` + env/links/overrides — `2026-06-18-worktree-env-override-observability-design.md`)과 **병존하는 두 번째 kind**. Docker dev hot-reload는 스파이크로 실측 통과(아래 §검증).

## 목표 (핵심 가치)

한 머신에서 여러 git worktree가 각자 **풀스택(be·ai-api·web 등)을 포트 충돌 없이 동시에** 띄운다. 워크트리 X의 서비스끼리는 X 안에서만 통신한다.

- **inter-service는 컨테이너 내부 DNS**(`http://be:8081`, 고정)로 — 워크트리별 URL **주입 0**.
- marina는 **compose 오케스트레이터**일 뿐: 보관·워크트리별 격리 실행·lifecycle·관측. **앱 config 포맷은 모름**(compose를 불투명하게 실행).
- **비침투**: 앱 레포엔 Dockerfile(빌드)만. 풀스택 오케스트레이션 compose는 **marina가 보관**(앱 레포 불변).
- 네이티브 `run`은 **fallback**으로 유지(기존 프로젝트 무회귀).

## 왜 compose-kind인가 (직전 결론 요약)

네이티브 토큰/env 주입 모델은 inter-service 배선에 **fragile**(hop 많음·스택별 글루·포트 shift staleness)하고, generic 도구가 남의 (지저분한) 프로젝트마다 config 포맷을 알아야 했다. Docker 네트워크 격리는 그 주입 자체를 없앤다(DNS 고정). macOS엔 network namespace가 없어 컨테이너 런타임이 사실상 유일한 격리 경로다.

## 모델

### 입력 (프로젝트 책임)
- 각 서비스의 **Dockerfile**(앱 레포 소유, 빌드 방법) — 이미 존재.
- **풀스택 dev compose 하나** — 모든 서비스를 **한 네트워크**에 정의, 각 `build:`가 서브레포 Dockerfile을 가리킴, dev 설정(소스 볼륨·dev 커맨드)·상대경로. 평범한 compose라 `docker compose up`만으로도 돈다(marina 무관). **marina가 보관**(새로 작성 or 기존 거 import — 둘 다 marina 저장).

예 (개념):
```yaml
# marina 보관: ~/.marina/<id>/docker-compose.yml  (경로는 루트 기준 상대 → 워크트리로 해석됨)
services:
  be:
    image: eclipse-temurin:21
    working_dir: /app
    command: ./gradlew :user-api:bootRun --args='--server.port=8081 --spring.profiles.active=local'
    volumes: [ "./be-api:/app", "gradle:/root/.gradle" ]
    environment: { AI_WKWK_SEARCH_BASE_URL: http://search:8000, AI_WKWK_INDEX_BASE_URL: http://index:8000 }
    ports: [ "8081:8081" ]
  index:
    build: { context: ./ai-api, dockerfile: index_api/DockerFile }
    command: uvicorn index_api.app:app --reload --host 0.0.0.0 --port 8000
    volumes: [ "./ai-api:/ai-api" ]
    ports: [ "8000:8000" ]
  # search·audio 동일 패턴, web = node 이미지 + pnpm dev:web:local
volumes: { gradle: {} }
```

### 실행 (marina 책임) — 워크트리별 격리
```
docker compose -f ~/.marina/<id>/docker-compose.yml \
  --project-directory <worktree> \
  -p <project>-<worktree해시> \
  [remap된 published 포트] [env 통과] up -d
```
- **`--project-directory <worktree>`** — compose의 상대경로(build context·volume·env_file)를 **워크트리** 기준으로 해석. compose는 marina에 살아도 빌드·마운트는 워크트리 소스. (핵심 기술 포인트)
- **`-p <project>-<worktree해시>`** — 워크트리별 compose 프로젝트명 → 네트워크·컨테이너·볼륨 격리, 이름 충돌 없음. 해시 = 기존 세션 id/포트 오프셋 근거.
- **포트 remap** — marina가 resolved config(`docker compose config`)에서 published 호스트포트를 **워크트리별 외부포트**(기존 `portBase + 오프셋` 스킴 재사용)로 재배정해 실행. 충돌 회피 + 워크트리별 안정 포트. 매핑을 세션에 기록(대시보드·접속용). 내부포트·DNS는 불변.
- **env 통과** — 환경 스트링(local/dev/staging/prod 등) + 필요한 env를 run에 전달. compose는 **자기 변수명**으로 소비(marina 전용 변수 불요). 환경값은 워크트리/실행별 선택 가능(기본 local), 단순 문자열 주입.

### inter-service / config / gitignored
- **inter-service**: compose 단일 네트워크 + 서비스명 DNS. 고정·주입 0.
- **gitignored 개인 config**: 워크트리에 존재 → compose가 상대경로(`.env.local` 등) 참조, `--project-directory`로 워크트리 해석. (a) 상시 개인 config는 marina의 기존 attach-time symlink(source→worktree)로, (b) 이 작업만의 scratch(테스트 api key 등)는 dev가 워크트리에 직접 둠. marina는 compose 내부를 모름.

## 표면 (marina core — turong92/marina) · 단계

**① compose 보관/등록**
- 저장: `~/.marina/<id>/docker-compose.yml` (per-project, 서비스 정의 `~/.marina/services/<id>.json` 과 같은 중앙 보관 일관). 앱 레포 불변.
- 등록: 프로젝트 레지스트리에 `kind: compose` + compose 식별 + **실행 옵션**(환경 주입 변수명·기본 환경값 등). **import = 그들 compose 내용을 marina로 복사 저장**(레포 경로 참조 아님 — 변경 시 재import).
- 편집/교체 경로 제공.

**② 워크트리별 실행** (위 docker compose 호출)
- 포트 remap 로직: config 읽기 → 서비스별 외부포트 배정(portBase+오프셋) → effective compose(또는 `-f` override)를 세션 폴더에 emit → 매핑 기록(`overrides.env` 또는 ports 파일 재사용).
- `--project-directory` · `-p` · env 통과 조립.

**③ lifecycle**
- `start|stop|restart|status|logs` → `docker compose -p <project>-<해시> up -d|down|ps|logs`(서비스 인자 매핑). 기존 CLI/대시보드 동사 그대로, 백엔드만 compose.

**④ 대시보드**
- 워크트리 서비스(=`compose ps`) + **외부(remap)포트** + 상태 표시. 기존 카드/헬스 패턴 재사용. **dashboard UX 원칙 준수**(compact·iconified·state-adaptive·viewport-safe — `marina-dashboard-ux-preferences`). `marina-preview`(:3901) 검증.

**⑤ LLM starter 생성** (편의, 후순위)
- 기존 `/marina:service add` LLM 분석 흐름 확장 — 프로젝트 Dockerfile·구조 보고 **풀스택 dev compose 초안 제안** → 사람 검토 → marina 보관. (없는 프로젝트가 빠르게 시작)

## marina가 안 하는 것 (generic 유지)
- compose 내부를 **해석/이해 안 함** — 불투명하게 실행만.
- 앱 config 포맷(yaml/env/args) **무지**.
- per-app config **주입 안 함**(DNS·compose가 처리).
- 앱 레포에 marina 파일 **0**.
- 서브레포 N개 compose **머지 안 함**(루트 풀스택 compose 하나가 정답 — 머지는 대환장).

## 네이티브 fallback (native-kind, 기존)
- compose 없는 프로젝트/서비스는 기존 `run`(네이티브)로 그대로. 이미 배포된 env 주입·`overrides.json`·`marina config`·links는 **native-kind용으로 유지**(무회귀).
- 한 프로젝트가 compose-kind ∪ 네이티브 혼용 가능(단 DNS는 compose 내부만; 혼용 시 네이티브↔컨테이너는 호스트 포트 경유).

## 접속 (access) — 워크트리별 web 도달

각 워크트리의 web은 **자기 remap된 호스트포트**로 도달한다(A=`localhost:3012`, B=`localhost:3047`…). 대시보드가 워크트리별로 나열하고 **`↗`로 그 web을 열어준다**(기존 web `↗` 패턴) — 포트를 외울 필요 없음.

- 여러 워크트리를 *동시에* 보면 탭이 **워크트리당 하나**. 이는 독립 프론트엔드 N개를 동시에 띄우는 것의 본질이며 **네이티브 marina도 동일**(새 제약 아님).
- **v1 = 이 방식**(워크트리별 포트 + 대시보드 `↗` 링크). 단순·검증됨.
- 리버스 프록시(URL 하나로 워크트리 전환)는 **범위 밖/후속**(아래).

## 에러 처리
- Docker 미설치/미가동 → compose-kind에 명확한 안내. **네이티브 프로젝트 무영향**(Docker 의존은 compose-kind 한정).
- build/run 실패 → compose 에러를 **그대로** 노출(프로젝트 compose 책임 = clean blame).
- 포트 고갈 → 기존 free-port 로직.
- `container_name` 고정 등 다중인스턴스 비호환 → remap 단계에서 제거하거나 안내.
- compose 미등록 compose-kind → 등록/import 안내(또는 네이티브 fallback).

## 테스트 (격리 mktemp fixture — 기존 관례, 라이브 config·실서비스 안 읽음)
- **포트 remap 로직**: 픽스처 compose config를 읽어 published 포트를 워크트리별로 재배정·충돌회피·매핑 기록 (실 docker 없이 로직 단위).
- **명령 조립**: `-p`=project+해시, `--project-directory`=worktree, env 통과를 *생성된 커맨드*로 검증.
- naming/격리, 네이티브 fallback 무회귀.
- **실 docker E2E는 docker 가용 시에만 게이트** — trivial 이미지(예: `python -m http.server`) compose로 up→ps→포트도달→down 스모크 1개.

## 순서 / 하위호환
- 단계 ①→⑤ 점진. ②(실행)가 핵심 가치, ③④ 그 위, ⑤ 편의.
- **native-kind 전 구간 유지**(기존 env/links/overrides 그대로). 구 marina는 compose-kind만 미지원 → 해당 프로젝트만 영향, 네이티브 무영향.
- **모든 push·배포 형 승인.** spec→TDD→preview(:3901 UI 변경 시)→code-review.

## 범위 밖 / 파킹
- **리버스 프록시**(워크트리 web을 서브도메인/경로로 라우팅, URL 하나로 전환) — v1 밖. 멀티탭 불편이 실제 통증이 되면 후속 generic 레이어로(프록시 → 워크트리별 web 호스트포트 라우팅). 앱 무관.
- prod 배포 오케스트레이션 — dev 한정.
- 서브레포 compose 자동 머지/합성 — 안 함.
- Team/Local 이중소스 제거 — 직교(기존 파킹).
- compose-kind에서의 `marina config`(effective 관측) 확장 — 가치 있으나 후순위(④ 대시보드가 1차).

## 검증 (스파이크, 2026-06-18)
- **파일변경 전파**(host→container, VirtioFS): 중앙값 ~13ms, polling 불필요.
- **실 Next dev 재컴파일**(소스 bind-mount, 호스트 편집): ~50–90ms (cold 1.1s). 네이티브 동급 — VirtioFS 오버헤드 무시 수준.
- 결론: macOS 컨테이너 dev hot-reload 응답성 = native급(이 머신, Docker Desktop v29). 남은 비용은 셋업/오케스트레이션(이 설계가 다룸)이지 per-edit 지연 아님.
- 실물 확인: be/ai-api/web 모두 **prod Dockerfile만** 존재(dev/HMR 없음) → 프로젝트가 **dev compose 하나**(루트, marina 보관)를 작성하는 게 선행작업(기존 prod Dockerfile 재사용 + 소스 마운트 + dev 커맨드로 작게 떨어짐).

## 핵심 컨텍스트·주의
- compose는 **marina 보관**(import도 복사 저장). 앱 레포는 Dockerfile만, marina 흔적 0.
- marina는 **compose 불투명 실행** — generic 유지. (모순 아님: "marina가 앱 config 알지 마"는 포맷 해석 얘기였고, 여기선 파일 하나 보관·실행일 뿐.)
- `--project-directory <worktree>` 가 "marina 보관 compose ↔ 워크트리 소스" 를 잇는 핵심.
- 포트 remap은 marina 기존 포트 스킴(portBase+오프셋)을 외부포트 배정에 재사용 → 워크트리별 안정·예측가능.
