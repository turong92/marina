# Phase 1: 서비스 `env` 주입 — 워크트리별 run-주입 (additive)

2026-06-18. config 작업의 Phase 1. **Additive — 현 Team/Local 모델 유지** (Team/Local 제거는 Phase 2 파킹). Codex 리뷰(2026-06-18) 반영. 구 `marina-local-config-model` spec 대체.

## 목표 (핵심 가치)

표준화 환경에서 **워크트리별로 inter-service 포트/설정이 run-주입으로 돈다.** marina 가 서비스 정의의 `env`(토큰 포함)를 `run` 과 동일한 per-worktree 치환으로 주입 → ai-api→BE 등이 자기 워크트리의 실제 포트를 봄. **현 모델에 additive**(Team/Local·머지·source 칩 그대로) = 저위험.

배경: 팀 미사용·미공유 단계라 팀공유 보존이 현 제약 아님(Codex BLOCKER#1 비적용). Team/Local 제거(고위험 리팩터)는 이 가치에 불필요(직교) → Phase 2 로 분리.

## 설계

- 서비스 정의 옵션 `env`: `{ "KEY": "value with {tokens}" }` (str→str). 토큰 집합 = `run` 과 동일: `{port}{<name>_port}{profile}{python}{root}{session}{env_file}{tmp}`.
- 기동 시 `run` 과 **동일 경로**로 토큰 치환(offset·충돌이동 반영 `port_for`) 후 서비스 프로세스 env 에 주입 → **워크트리별 자동**.
- Team/Local 유지: `env` 는 service def 의 일부라 root·central 양쪽에서 기존 머지·source 태그를 그대로 탄다.

## 표면 (marina core — turong92/marina)

1. **스키마 검증 + 보존**:
   - `env`(object of str→str) 수용·검증 — `control.py` `_normalize_service`(~L925) 가 `out` 에 포함, `marina.sh` add-service 검증(~L212).
   - ⚠ **`_read_services_file`(~L1593)가 미지 필드를 drop → `env` 보존**(Codex). `merged_services_json`(~L277)은 `{**s, source}` 라 자동 라이드(회귀 검증).
2. **기동 주입 (port-shift-safe)**:
   - `service_env` accessor: 서비스 `env` 의 토큰을 `command_for` 와 **동일 시점/순서**로 치환해 `KEY=val` emit.
   - `start_service`/`run_foreground` 가 `env KEY=val … bash -lc "$command"` 로 주입 (기존 `env PATH=…` 와 합쳐서).
   - ⚠ **포트 충돌이동 반영**(Codex): start_service 가 포트를 shift·박제한 *뒤* env 를 resolve (A 가 {be_port} 캡처 후 BE 이동 시 stale 방지). 즉 env resolve 는 prepare/shift 이후.
   - `print-command` 가 주입 env 도 노출(디버그). 값에 시크릿 가능성 → redaction 고려(현 `redact_stream` 정책 따름).
3. **테스트 (격리 fixtures)**:
   - ⚠ **기존 서브레포/라이브 config 안 읽음** — `mktemp -d` 임시 프로젝트 + fake 서비스로만 (marina 기존 테스트 방식).
   - 케이스: env 토큰 per-worktree(offset) 치환·주입 / 포트 충돌이동 후 env 재해석 / 머지가 env+source 보존 / `print-command` env 노출 / `env` 없는 서비스 무영향.

## 소비처 (Phase 1, 별도 repo — marina 배포 후)

4. **ai-api** `common/rest_api/servers.py`: be/index/search/audio URL env-override (`os.getenv(X) or servers_config.get(...)`). 프로파일은 이미 `PROFILE` env. (ai-api-convention 스킬 적재 후 작업.)
5. **mdc** `marina-services.json`(현 라이브/tracked): index/search/audio 에 `env`(형제 URL 토큰) 선언.

## Phase 1 범위 밖 (이연)

- 대시보드 모달 env 에디터 — **Phase 1.5** (Codex D2: CLI/표시 먼저, 풀 편집 나중).
- LLM 등록이 `env` 생성·프롬프트 — Phase 1.5.
- **Team/Local 제거 — Phase 2** (팀 적극 공유 시 재평가; 고위험 리팩터).
- 워크트리 run/env override(`overrides.json`) — Phase 2/3 (D1).
- `marina-web-launch.sh` 거취·mdc config 커밋 삭제 — Phase 2 (로컬 전환과 함께).

## Codex 캐치 반영

- 미지필드 drop → `env` 보존(표면 1).
- port-shift 후 env 재해석(표면 2).
- env 인용/redaction/`print-command` 노출(표면 2).
- project-id basename 충돌(`<id>.json`) — Phase 1 무관(추가 인지, Phase 2 에서 다룸).

## 순서 / 하위호환

`marina(env 주입) → ai-api(env-read) → mdc(env 선언) → 워크트리 실측`. 구 marina 는 미지 `env` 무시, ai env-read 없으면 현 동작 = 무회귀. **marina·ai-api·mdc 모든 push 형 승인.**
