# HANDOFF: 워크트리별 Docker compose 오케스트레이션 (compose-kind) — 구현 착수

> 2026-06-18 세션 이어받기(컨텍스트 분할). **SoT = 같은 폴더 spec
> `2026-06-18-worktree-compose-orchestration-design.md`.** 이 문서는 오리엔테이션.
> 상태는 직접 재검증(그 사이 변동 가능).

## 한 줄
marina가 프로젝트 풀스택을 **워크트리별 격리 Docker compose**로 띄운다 — inter-service는 컨테이너 DNS(주입 0), marina는 compose 불투명 실행(generic·비침투). 설계 끝, **구현 시작 단계**.

## 지금 상태 (재검증 필수)

### ✅ 이미 push·배포 — native-kind (별개·완료)
- marina **origin/main `947afd1`**: 워크트리 env override(`overrides.json`)·`marina config` 관측·`marina override` CLI·`links` 선언/적용 + README. `claude plugin update`로 배포됨.
- 이게 **native-kind** — compose 안 쓰는 프로젝트용 fallback으로 **유지**(무회귀 대상).

### 🟡 compose-kind — 설계만, 미구현
- 브랜치 **`feature/compose-orchestration`**(main 위), 커밋 `7cbc197` = spec only. **미push.**
- spec: `docs/specs/2026-06-18-worktree-compose-orchestration-design.md`.

### ⛔ 폐기 (되돌림 — 다시 시도 금지)
- ai-api `servers.py` getenv + mdc `marina-services.json` env 주입 = **시도했다 revert**. 이유: "도구 쓰려고 앱 레포에 커밋하는 건 marina 취지 위반"(형). → 이 방향(앱 레포 config 주입)은 **버림**. compose-kind(DNS)가 그걸 대체.
- 구 핸드오프 `2026-06-18-env-injection-HANDOFF.md` 의 "Phase 1 잔여(소비처 배선)"는 이 폐기로 **무효**.

## 잠긴 설계 결정 (재논의 금지 — spec에 상세)
1. **compose-kind ∥ native-kind 병존.** native(env/links/overrides)는 shipped·유지.
2. 프로젝트는 **Dockerfile들(빌드) + 풀스택 dev compose 하나**. compose는 **marina 보관**(`~/.marina/<id>/`) — 새로 작성 or 기존 거 **import=복사 저장**. **앱 레포엔 marina 파일/변수 0.**
3. 실행: `docker compose -f <marina보관> --project-directory <worktree> -p <project>-<해시> [포트remap] [env] up`.
   - `--project-directory <worktree>` = marina보관 compose의 상대경로를 워크트리로 해석(핵심).
   - 포트 격리 = `-p`(네트워크/이름) + **published 호스트포트 remap**(기존 portBase+오프셋 재사용). 내부포트·DNS는 안 겹침.
4. inter-service = **컨테이너 DNS**(`http://be:8081`) 고정, 주입 0.
5. env = **문자열 통과**, compose는 *자기 변수명*으로 소비(marina 전용 변수 금지).
6. gitignored = 워크트리에 존재(attach symlink/scratch) → compose 상대경로 참조.
7. marina = **compose 불투명 실행**(내부 해석·앱 config 포맷 무지). 서브레포 N compose **머지 안 함**.
8. 접속 v1 = 워크트리별 포트 + 대시보드 `↗`. 리버스 프록시는 후속.

## 검증됨 (스파이크 2026-06-18)
- Docker dev hot-reload: 파일감지 ~13ms, Next 재컴파일 ~50ms(이 머신, Docker Desktop v29/VirtioFS) — 응답성 native급.
- be/ai-api/web 실물 = **prod Dockerfile만**(dev/HMR 없음) → 프로젝트가 dev compose 하나(루트, marina 보관) 작성이 선행작업(기존 Dockerfile 재사용+소스 마운트+dev 커맨드로 작게).

## 다음 세션 즉시 착수
1. 메모리 + 이 핸드오프 + spec 읽기. `feature/compose-orchestration`(`7cbc197`) 체크아웃.
2. **writing-plans** → **단계 ②(워크트리 compose 실행)부터**: 포트 remap(`docker compose config` 읽어 published 재배정) + `--project-directory` + `-p name+해시` + env 통과 → 동작 슬라이스. 그 위에 ③ lifecycle(up/down/ps/logs) · ④ 대시보드(외부포트·상태) · ① 보관/등록 · ⑤ LLM starter.
3. 네이티브 fallback 무회귀 유지.

## 워크플로·주의
- spec→TDD(격리 mktemp fixture)→preview(:3901 UI 변경 시)→code-review→push(**형 승인**).
- 커밋: Conventional Commits, **Co-Authored-By·Task trailer 없음**.
- 실 docker E2E 테스트는 docker 가용 시 게이트, 나머지는 marina 로직 단위(포트 remap·커맨드 조립)로.
- 구 브랜치 `feature/service-env-injection`(native-kind granular)은 main에 squash 반영됨 — 삭제 가능.
