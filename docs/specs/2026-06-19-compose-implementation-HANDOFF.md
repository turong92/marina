# HANDOFF: compose-kind 구현 완료 — 다음 세션(검토·push·follow-on)

> 2026-06-19. 직전 세션에서 compose-kind 오케스트레이션을 **구현 완료**(CLI + 대시보드 + 로그).
> 로컬 커밋만(미push). 이 문서 = 오리엔테이션. 상태는 직접 재검증(그 사이 변동 가능).

## 한 줄
marina가 프로젝트 풀스택을 **워크트리별 격리 Docker compose**로 띄우고(CLI), 그 서비스·포트·상태·로그를 **대시보드(:3900)**에서 관제한다. inter-service는 컨테이너 DNS(주입 0), marina는 compose 불투명 실행, 포트는 Docker가 자동 할당. 대시보드에서 **compose 프로젝트 등록(📁import/✨AI 초안/검증)**도 한다. **설계+구현 끝(CLI·대시보드·로그·등록 UI·AI 초안), 형 검토→push 대기.**

## 무엇이 구현됐나 (전부 이 브랜치, 미push)
- **Plan A — CLI compose-kind** (`docs/superpowers/plans/2026-06-18-compose-orchestration.md`):
  - `marina project add <path> --compose <file> [--env-var NAME --env-default VAL]` → kind:compose 등록 + compose를 `~/.marina/<id>/`로 복사(앱 레포 불변).
  - `marina start|stop|restart|status|ports|logs` 가 compose로 동작. 새 파일 `plugin/scripts/marina-compose.py`(순수: `compose_project_name`·`build_overlay`·`parse_ps_ports`·`isolation_breakers` + docker 실행) + `marina.sh` 분기(`compose_main`, kind==compose 만).
  - **포트**: `!override` overlay로 published를 `127.0.0.1::<target>`(localhost + Docker 자동할당)로 덮음 → 충돌·secret 디스크 잔류 0. 포트는 안 저장, `docker compose ps`로 live 조회.
- **Plan B — 대시보드** (`docs/superpowers/plans/2026-06-19-compose-dashboard.md`):
  - 데몬 `session_payload`가 compose면 `docker compose ps --all`을 **native 서비스 shape**로 변환(카드 UI 재사용). `log_targets_for`+`stop_service`/`restart_service`/`stop_all`이 compose면 `marina.sh`로 shell(start는 이미). `marina-control.py`가 `marina-compose.py`의 `compose_project_name`을 importlib 재사용(=CLI와 -p 이름 일치). 프론트: source 뱃지·subrepo/서비스추가 UI를 compose에서 게이트.
- **로그(option B)** (`docs/superpowers/plans/2026-06-19-compose-dashboard-logs.md`):
  - start 때 서비스별 `docker compose logs -f`를 네이티브와 동일한 `run-NNN.log`로 캡처(`_compose_logtail_start/_stop`, stop/restart/down에서 kill). `_compose_services`가 `service_log`/`log_run_payload`로 노출 → 기존 로그 뷰어(run셀렉터·검색·SSE) 100% 재사용, `/api/logs` 무변경. compose 카드의 포트·프로파일 override 편집기는 숨김.
- **Plan C+D — 대시보드 compose 등록 + LLM 초안** (plan `docs/superpowers/plans/2026-06-19-compose-registration-and-ai-draft.md`, spec `…/2026-06-19-compose-registration-and-ai-draft-design.md`):
  - 프로젝트 등록 모달에 kind 토글(일반/compose) + compose 섹션 — 📁 레포에서 import / ✨ AI 초안 / 직접 작성 → YAML 에디터(=SoT) → 검증 → 등록. 서비스 LLM assist bar 패턴(picker/progress/origin-gate) 재사용, 편집은 native 전용.
  - 백엔드(`marina-control.py`): `llm_compose_analyze`(read-only LLM→compose YAML, 추출+2회 재시도) · `compose_validate`(`docker compose config` + `isolation_breakers`, env-aware) · 엔드포인트 `/api/compose-{analyze,validate,register,detect}`(미등록 `path` 기반; register 는 `marina project add --compose` 경유 = 새 영속화 경로 0). **자동 기동 검증 루프 없음**(사람 검토, spec ⑤).

## 검증됨
- 테스트 **55/55** (compose 16 = A/B/로그 13 + C/D 신규 3: `compose-llm-analyze`·`compose-validate`·`compose-register-api`). 실 docker 테스트는 `docker info` 게이트.
- 실 docker(이 머신 29.1.3/compose 2.40) E2E: up→127.0.0.1 도달→down, 컨테이너 로그 run-NNN 캡처, `/api/sessions`·`/api/start`·`/api/stop` 실측.
- 코덱스 리뷰: Plan A 5라운드, Plan B 3라운드, 로그 1라운드 — 발견 블로커 전부 수정.

## ⚠️ 주의 (다음 세션이 꼭 알 것)
- **compose 프론트(INDEX_HTML) 변경 후엔 반드시 `marina-preview`(:3901)로 카드 렌더 확인.** 테스트는 대시보드 JS를 렌더하지 않아 못 잡는다. 실제로 `renderConfigRows` 게이트가 `[data-save-config]`를 없애 `saveBtn.onclick`이 null→`render()` 전체가 죽어 **모든 카드가 안 뜨는** 심각 버그가 프리뷰에서만 잡혔다(→`if(saveBtn)` 가드로 수정). compose 카드에서 native 전용 요소를 가릴 땐 그 요소를 만지는 wiring도 같이 가드.
- **docker는 compose-kind 에만 필요.** native 프로젝트는 docker 호출 0(무회귀, 테스트로 박제).
- `!override`는 compose **2.24.4+** 필요(`compose_main` start/restart에서 버전 체크).
- 포트는 재시작마다 바뀜(ephemeral) — 접속은 대시보드 `↗`/`marina ports`로(설계상 의도).

## 정리할 잔재 (직전 세션이 남김)
- **`~/.marina`에 데모 `compose-demo` 등록 + 컨테이너 실행 중**(형 지시로 "home에서 빼는 건 보류"). 정리하려면: `cd /tmp/compose-demo && marina stop --all; marina project rm compose-demo; rm -rf /tmp/compose-demo ~/.marina/compose-demo`. (형이 playground로 둘 수도 있다 했음.)
- `marina-preview`(:3901) 프리뷰 서버 떠 있을 수 있음.
- `.workspace/codex-*.md`(리뷰 산출물, gitignore) — 무시 가능.

## 다음 (우선순위)
1. **형 검토 → push/merge 결정** (미push, 모든 push 형 승인). 브랜치 = `claude/suspicious-cartwright-61c154` = A/B/로그(`bbeec25`) + C/D(spec·plan·구현 다수 커밋). **연계 기능이라 한 번에 push.** feature/compose-orchestration로 합치거나 PR.
2. follow-on(선택): compose **자동 기동·health 검증 루프**(서비스 direct 모드의 compose판 — 현재는 사람 검토만, spec ⑤). 가치 생기면 fast-follow.
3. 파킹(스펙): 리버스 프록시, prod 오케스트레이션, 서브레포 compose 머지 — 안 함.

## compose-only 전환 (진행 중 — marina 를 도커 전용으로, 형 방향)
marina = 도커/Dockerfile/LLM 을 토대로 한 **compose 전용**, native 는 점진 폐기.
- ✅ **Dockerfile 필수 게이트**(`compose_validate` — build 서비스 Dockerfile 없으면 거부 + docker 미설치 안내).
- ✅ **`marina project add --ai`** — 레포 보고 LLM 이 compose 초안 생성→등록(`marina-control.py compose-draft` CLI 브리지, 편집 fallback).
- ✅ **`marina project migrate <id>`** — 기존 native→compose 전환(root upsert = kind 만 바뀜). docker 불요.
- ✅ **대시보드 등록 compose-only**(native 토글 제거). compose 기본·LLM 자동 초안, LLM 없으면 편집만.
- ⏳ **native-kind 코드 전면 제거 = 형 ok 후** — shipped 코드 절반 삭제라 위험·되돌리기 어려움. 실제 native 프로젝트 migrate 완료 + "아무도 native 안 씀" 확인 후 별도 TDD. 그전까진 native 가 dormant(사용자는 compose 만 봄).
- 테스트 56/56(신규 `compose-migrate`).

## 워크플로
- TDD(격리 mktemp fixture), 실 docker 테스트 게이트. Conventional Commits, **Co-Authored-By·Task trailer 없음**. compose 프론트 변경 시 :3901 검증. push·배포 형 승인.
