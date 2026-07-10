# 팀 사용성 페인포인트 해소 — 엮기 규약 일원화 + LLM marina 강제

날짜: 2026-07-10
상태: 구현 완료 (형 검토 대기) — B4 확인 결과 Codex 도 PreToolUse 와이어 지원(훅 신뢰 후, 공용 hooks.json 그대로)
후속: 대시보드 worktree 콘솔 UI 재설계는 **별도 스펙**으로 진행 (이 스펙의 범위 아님)

## 배경 — 팀원이 실제로 겪은 두 가지

1. **"게이트웨이/포워드를 docker-compose 에 설정해뒀는데 따로 파일(backing.json)을 만들어서 기동하게 됐다."**
   조사 결과 팀원 잘못이 아니라 문서·코드 불일치다:
   - 실행 SoT 는 보관 compose 의 `x-marina.forward` 이고 backing.json 보다 우선한다
     (`plugin/scripts/marina-compose.py:619-621`). 대시보드 위저드도 x-marina.forward 를 쓴다
     (`plugin/scripts/marina-web/app-2-register.js` wizCommitConnect).
   - 그런데 README(엮기 섹션, 285줄 근방)는 아직 `backing.json` 의 `hostForward: ["6379"]` 를
     안내한다. **`hostForward` 는 코드가 명시적으로 무시하는 레거시 포맷**이다
     (`plugin/tests/test-compose-forward.sh:50-51` 가 "무시"를 검증까지 함).
   - 코드 경고문조차 레거시로 유도한다: `marina-compose.py:617-618` "host 타겟은 backing.json
     top-level forward 로 선언하세요".
   - backing.json 에 무시되는 키가 있어도 아무 피드백이 없고, 엮기가 실제 적용됐는지 볼 곳도 없다.

2. **"LLM 이 marina 로 실행하지 않고 헤맨다."**
   에이전트에게 규칙이 전달되는 채널이 SessionStart 1회 주입뿐이고 강제 장치가 없다:
   - 미등록 프로젝트면 훅이 침묵(exit 0) — marina 존재 자체를 모름 (`marina-session-start-hook.sh:44`).
   - 긴 세션에서 주입 텍스트가 컨텍스트 앞부분에 묻힘. UserPromptSubmit 재강조 없음.
   - 금지 문구가 "직접(npm/gradlew 등)"뿐이라 `docker compose up` 직접 실행이 커버리지 밖.
   - 서브에이전트(Task)에는 additionalContext 가 전달되지 않음.
   - "dev 서버 실행" 상황에서 자동 발동할 스킬이 없음 (`marina:project` 는 등록 관리 전용).

## 목표

- 엮기 선언은 `x-marina.forward` 를 공식 경로로 문서화하고, 이미 쓰이는 backing.json 은
  (hostForward 포함) **제대로 읽히게** 고쳐 조용한 무시를 없앤다. 파일 마이그레이션은 하지 않는다.
- 에이전트가 등록 프로젝트에서 dev 서버를 직접 띄우는 것을 **차단하고 marina 명령으로 안내**한다
  (형 결정: 경고가 아니라 차단).

## 비목표

- 대시보드 UI 재설계(별도 스펙).
- 게이트웨이 동작 변경 — 게이트웨이 자체(`~/.marina/gateway/Caddyfile` 자동 생성·호스트 caddy)는
  이번 문제의 원인이 아니었고 그대로 둔다.
- AGENTS.md/.mdc 파일 주입 부활 (기존 결정대로 폐기 유지).

---

## Part A — 엮기(forward) 규약 일원화

### A1. README 엮기 섹션 재작성

- `x-marina.forward` 를 유일한 공식 선언 경로로 문서화. 예시:

  ```yaml
  x-marina:
    forward:
      "6379": host      # 컨테이너의 localhost:6379 → 호스트 redis
      "8081": be        # (보통 자동이라 불필요 — 명시 override 예)
  ```

  - 포트 키는 **따옴표 문자열**로 안내 (docker compose config 가 x-* 확장의 비-string 키 거부).
  - 값은 `host`(호스트 인프라) 또는 같은 compose 서비스명. 서비스↔서비스는 자동이므로
    "사람은 host 타겟만 선언한다" 원칙 유지.
- 본문 안내는 `x-marina.forward` 로 통일하고 "marina 설정은 compose 파일 하나(x-marina)에 모인다"
  원칙을 엮기 섹션 서두에 명문화. backing.json 은 "레거시 — 계속 읽히지만 신규 선언은 x-marina 로"
  한 줄로만 남긴다(`hostForward` 예시는 삭제하되 A3 로 인해 실제로는 동작함).

### A2. 코드 경고문 수정

- `marina-compose.py:617-618` 의 service-redirect 경고 문구를 "host 타겟(redis/db 등)은
  **x-marina.forward** 로 선언하세요" 로 교체.

### A3. backing.json 을 제대로 읽기 (마이그레이션 없음 — 형 결정)

- 파일 이전·리네임 등 마이그레이션 기계는 만들지 않는다. 대신 **선언된 것은 읽히거나, 최소한
  조용히 무시되지 않게** 한다.
- `_legacy_host_forward` 신설 — top-level `hostForward: ["6379", ...]` 를 `{"6379":"host"}` 로 해석해
  **정상 반영**한다. README 가 안내해 온 포맷이므로 읽는 게 맞다. (명시 `forward` dict 포맷은
  `_normalize_forward` 현행 유지.)
- **우선순위(리뷰 반영)**: legacy hostForward < 자동 서비스타겟 < 명시 forward(backing.json < x-marina).
  스테일 hostForward(redis 를 나중에 compose 서비스로 옮긴 경우)가 auto 라우트를 덮어 엮기를 깨지
  않게 하기 위함. 대시보드 레거시 변환(`_migrate_to_xmarina`)도 hostForward 를 이전한다(통합 뷰
  채택 시 설정 소실 방지).
- `services.<svc>.hostForward`(서비스별)는 현행대로 무시하되, 발견 시 stderr 경고 1줄
  ("services.*.hostForward 는 지원되지 않음 — top-level forward 를 쓰세요") — 조용한 무시 금지 원칙.
- backing.json 이 **실효 소스일 때만** 안내 1줄("x-marina.forward 로 compose 파일 하나에
  모으는 걸 권장") — 이전 완료 사용자에게 영구 반복하지 않음. 강제 아님.

### A4. 엮기 적용 상태 가시화

- `marina start` 성공 출력에 요약 1줄 추가: `엮기: localhost:6379→host · localhost:8081→be`
  (적용 없으면 생략). 소스는 cmd_up 이 이미 계산하는 forward dict — 새 계산 없음.
- `marina status` 는 이번 범위에서 변경하지 않는다(대시보드 노출은 UI 스펙으로 이월).

---

## Part B — LLM 이 marina 를 못 건너뛰게 (3중 장치)

### B1. PreToolUse 차단 훅 (Claude Code)

- `plugin/hooks/hooks.json` 에 `PreToolUse`(matcher: `Bash`) 추가 →
  `plugin/scripts/marina-pretooluse-hook.sh`.
- 판정 순서 (모두 통과해야 차단):
  1. stdin JSON 에서 `tool_input.command` 와 `cwd` 파싱.
  2. cwd 가 **등록 프로젝트**(SessionStart 와 동일한 projects.json 판정 로직 공유) 안이 아니면 allow.
  3. 명령에 `MARINA_DIRECT=1` 이 포함되면 allow (의도적 직접 실행 탈출구 — deny 메시지에 명시).
  4. 명령이 **차단 패턴표**에 걸리면 deny + 안내.
- 차단 패턴표 (정적, 결정적 — compose 파생 동적 매칭은 복잡도·훅 지연 때문에 채택 안 함):
  - `docker compose up|start|restart` · `docker-compose up|start|restart`
  - `npm|yarn|pnpm|bun run dev|start|serve` · `npm|yarn|pnpm|bun start`
  - `next dev` · `vite`(단독 dev 서버 호출) · `nuxt dev` · `astro dev`
  - `./gradlew bootRun|run` · `gradle bootRun` · `mvn spring-boot:run` · `mvnw spring-boot:run`
  - `python manage.py runserver` · `flask run` · `uvicorn` · `rails s|server`
  - 패턴은 명령 텍스트 정규식 매칭(파이프·`&&` 연결 포함 전체 문자열 검사). 조회성 명령
    (`docker compose config|ps|logs|down`, `npm run build|test` 등)은 표에 없으므로 통과.
- deny 응답: `permissionDecision: "deny"` + reason 에 대체 명령을 구체적으로:
  "이 워크트리는 marina 가 관리합니다. `marina start <서비스>` (전체 `--all`) 로 띄우세요 —
  포트가 워크트리별로 격리됩니다. 상태 `marina status` · 로그 `marina logs <서비스>`.
  정말 직접 실행해야 하면 명령 앞에 `MARINA_DIRECT=1` 을 붙이세요."
- 성능: 순수 셸 + 최소 파싱(JSON 은 SessionStart 훅과 같은 방식) — 실행당 수십 ms 목표.
  훅 오류 시 fail-open(allow) — marina 문제로 세션 Bash 전체가 막히면 안 됨.
- 서브에이전트의 Bash 호출에도 PreToolUse 가 적용되므로 기존 사각지대가 함께 해소된다.

### B2. dev-server 스킬 동봉

- `plugin/skills/dev-server/SKILL.md` (노출명 `marina:dev-server`).
- description 트리거: "dev 서버 실행/정지/재시작, 서비스 로그·포트 확인, 프리뷰 URL이 필요할 때"
  — 에이전트가 차단당하기 전에 자연스럽게 marina 경로로 가게 하는 1차 장치.
- 내용: start/stop/restart/status/logs 사용법, 게이트웨이 URL(`<wt>.<proj>.localhost:3902`) 확인법,
  포트 충돌 시 대응(`marina status` 로 실제 포트 확인), compose 정의 변경은 대시보드/`project add --compose`,
  직접 실행 금지 이유(워크트리 포트 격리)와 `MARINA_DIRECT=1` 탈출구.

### B3. SessionStart 보강

- 금지 문구에 `docker compose up` 명시: "dev 서버는 직접(npm/gradlew/**docker compose up** 등)
  띄우지 말고 …".
- **미등록 프로젝트 힌트**: 현재는 미등록이면 exit 0(완전 침묵). 변경 — git 레포이고 marina CLI 가
  있으면 1줄만 주입: "[marina] 이 레포는 marina 미등록입니다. worktree 별 dev 서버 격리가 필요하면
  `marina project add .` 또는 대시보드(:3900)에서 등록하세요." (등록 프로젝트용 본문 대비 최소 소음.)

### B4. Codex 폴백

- Codex 가 PreToolUse 상당 훅을 지원하는지 구현 시 확인. 지원하면 동일 스크립트 연결
  (플랫폼 분기는 SessionStart 훅과 같은 방식), 미지원이면 Codex 는 B2+B3 만으로 간다.
- 훅 스크립트는 지금처럼 플랫폼 공용 1벌 유지.

---

## 테스트 계획

- **Part A**: test-compose-forward.sh 갱신 — top-level `hostForward` 가 이제 `forward:{port:host}` 로
  읽히는 케이스(기존 "무시" assert 를 "반영" 으로 교체), 서비스별 hostForward 경고 케이스, 우선순위
  회귀(자동 < backing.json < x-marina) 유지. README 예시 YAML 이 `docker compose config` 를 통과하는지 검증.
- **Part B**: 훅 단위 테스트 — 차단(패턴표 각 계열 대표), 통과(미등록 cwd·조회성 명령·MARINA_DIRECT=1),
  fail-open(깨진 stdin). 실세션 e2e 1회: 등록 프로젝트에서 에이전트가 `npm run dev` 시도 → deny 메시지
  확인 → `marina start` 로 우회하는지.

## 리스크·완화

- **오탐 차단**(정적 패턴의 숙명): 조회성 명령을 표에서 제외 + `MARINA_DIRECT=1` 탈출구 + deny 메시지에
  탈출구 명시. 패턴표는 한 파일에 모아 추가·삭제가 1줄이 되게.
- **훅 지연**: Bash 매 호출마다 실행되므로 셸 단독·조기 반환(미등록이면 즉시 exit) 구조로.
- **hostForward 재지원의 스코프 충돌**: hostForward 는 host 타겟 전역 선언이라 서비스별 스코프 문제
  (과거 endpoints 를 버린 이유)가 없고, 자기 서빙 포트 제외 로직이 그대로 적용된다. 서비스별
  hostForward 는 계속 미지원(경고만)으로 스코프 문제를 피한다.

## 구현 순서 (플랜 단계에서 상세화)

1. A2 경고문 → A3 hostForward 읽기 복원 → A4 요약 출력 → A1 README (코드 확정 후 문서)
2. B1 훅 → B3 SessionStart 보강 → B2 스킬 → B4 Codex 확인
3. 테스트는 각 항목과 함께 TDD.
