# marina — service-add (3 surface) + per-service root/central merge (design)

- **Date:** 2026-06-16
- **Branch:** `feature/multiproject-services` (이어서)
- **Status:** Design approved (per-service merge + 3-surface add); spec for review.
- **Builds on:** stage-3 (`docs/specs/2026-06-16-multiproject-service-isolation-design.md`) — stage-3 의 central fallback 을 **per-service 머지**로 확장하고, 서비스 정의를 만드는 UX 를 추가한다.

## Goal

동료 온보딩의 마지막 갭(서비스 정의)을 메우고, 개인이 팀 정의를 공유 전 override·테스트할 수 있게:

1. **서비스 정의를 3 surface(LLM 슬래시·CLI·대시보드 폼)로 추가/편집/삭제** — 동료가 "no svc" 에서 막히지 않게.
2. **root(팀) + 중앙(개인) 서비스 단위 머지** (name 겹치면 중앙 우선) — `.env.local` 패턴.

## Problem

- **온보딩 갭:** 프로젝트/서브레포 등록은 UX(CLI·슬래시·대시보드)가 있지만, **서비스 정의는 파일 수동 작성 + 대시보드 안내 0** (`no svc` 는 텍스트뿐, `add-service` API/UI 없음). 동료는 등록까지 하고 "no svc" 에서 멈춘다 (사용자가 막혔던 그 지점).
- **개인 override 불가:** stage-3 는 파일 단위 root 우선이라, 개인이 중앙에 정의를 둬도 root 가 있으면 무시된다 → "공유 전 개인 수정·테스트" 가 안 된다.

## Design

### A. Per-service merge (코어 변경)

- `extra_services_for(root)` = root `marina-services.json` 서비스 **∪** 중앙 `~/.marina/services/<id>.json` 서비스. **name 이 겹치면 중앙 우선** (합집합). 각 항목에 `source: "root" | "central"` 태그.
- 소비처(`services_for`·`service_subrepo_map`·`port_base_for`·`log_targets_for`·`orphan_rules_for`)는 머지 결과 위에서 동작. (stage-3 의 단일 파일 reader `services_file_for` 를 머지 reader 로 대체 — 읽기는 두 파일 머지.)
- `marina.sh` 의 서비스 조회(`command_for`·`port_for` 등)도 두 파일을 머지(name 중앙 우선)해서 본다 — python-heredoc.
- **읽기 = 머지(두 파일), 쓰기 = 단일(위치 선택, §B).**

### B. Writer (`marina.sh`)

- `add-service <id> '<service-json>' [--root]` — `name` 으로 **upsert**(추가/편집 겸용). 기본 중앙 `~/.marina/services/<id>.json`, `--root` 면 프로젝트 root `marina-services.json`. 파일 없으면 생성. 검증: `name` identifier · `portBase` int · `run` 비어있지 않음.
- `rm-service <id> <name> [--root]` — 삭제.
- `registry_add`/`registry_default` 의 python-heredoc `json.dump` 패턴을 그대로 미러.

### C. LLM 슬래시 — `/marina:add-service [path]`

`/marina:register` 와 같은 패턴(커맨드 본문 = 에이전트 프롬프트):

- 프로젝트 root 구조 분석(`package.json` scripts · `build.gradle` · `Dockerfile` · `pyproject` 등) → 서비스별 `name/portBase/cwd/run` 추론(run 은 `{port}`/`{profile}` 치환자, native·docker 판단) → **사용자에게 보여주고 확인** → `marina add-service <id> '<json>'` (중앙 기본). 변수(프로젝트 구조 다양성)를 LLM 이 흡수.

### D. 대시보드 — 추가/편집/삭제 + 출처 뱃지

- `no svc` subrepo · 빈 서비스 프로젝트에 **"+ 서비스 추가"** 버튼 (동료가 막히는 그 자리).
- 모달: `name` · `portBase` · `cwd`(subrepo 드롭다운 + 자유 입력) · `run`(자유텍스트 + 치환자 힌트) · 고급(`cachePaths`·`orphanPattern`) · **"팀 공유 (root 에 커밋)" 체크 → `--root`**.
- 서비스 행: **출처 뱃지**(`팀(root)` / `내 override(중앙)`) + 편집(✎ 폼 prefill) · 삭제(✕, 중앙/root 구분).
- API: `POST /api/add-service {root, service, central}` · `POST /api/remove-service {root, name, central}` → 전부 `marina.sh` shell-out(writer SoT), 캐시 무효화.

## Components / files

- **`plugin/scripts/marina-control.py`** — 머지 reader(+`source`) 및 소비처 갱신; `do_POST` add/remove-service; `INDEX_HTML` 서비스 추가/편집 모달·출처 뱃지·삭제.
- **`plugin/scripts/marina.sh`** — `add-service`/`rm-service` writer + 서비스 조회 머지.
- **`plugin/commands/add-service.md`** — 신규 슬래시 커맨드.
- **`README.md`** — 서비스 추가(3 surface)·override(머지) 모델·중앙 경로 문서화 (stage-3 에서 누락된 중앙 fallback 포함).
- **`plugin/tests/`** — 머지(override·합집합·source), writer(add/rm · 중앙/root), API, 슬래시 파일 존재.

## Error handling

- 양쪽 파일 다 없음 → 0 서비스 (현 동작 유지).
- 중앙·root name 충돌 → 중앙 우선(정의된 동작), 출처 뱃지로 표시.
- writer 잘못된 json/필드 → 비-0 exit, 파일 불변.
- `rm-service` 없는 name → no-op 성공.
- 머지 시 한쪽 파일 파싱 실패 → 그쪽은 빈 목록 취급(다른 쪽은 살림), crash 없음.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| override 모델 | per-service 머지, name 중앙 우선 | `.env.local` 패턴; 개인이 일부만 override(공유 전 테스트) — 파일단위=전체복사·root우선=override불가 |
| 저장 위치 | 중앙 기본 + `--root` opt-in | 개인은 repo 안 건드림이 기본; 팀 공유는 명시 체크 |
| surface | 공통 writer + 슬래시·CLI·폼 | 등록(project)과 동일 구조 — `marina.sh` writer 가 SoT |
| 자동 추론 | 휴리스틱(코드) 제외, LLM 슬래시 | 코드 추론은 프로젝트 구조 변수↑ 부정확; LLM 이 맥락 흡수 |
| 충돌 표시 | 서비스별 출처 뱃지(root/중앙) | 머지 충돌을 투명화 — 우선순위 토글 불요 |

## Out of scope

- 휴리스틱(코드) 서비스 추론 — LLM 슬래시가 대신.
- `run` 템플릿 빌더/위저드 — 자유텍스트 + 힌트로 충분.
- 서비스 reorder.

## Open items (decide during plan)

1. `marina.sh` 머지 조회 구현 위치 — 자체 python-heredoc 머지 vs control.py 헬퍼 위임. (writer 와 조회가 같은 머지 규칙을 공유해야 — name 중앙 우선.)
2. 출처(`source`) 노출 — payload service 에 `source` 필드 추가 지점(`_tagged_services` 부근) 및 뱃지 렌더.
3. 편집(✎) UX — 같은 모달 prefill + `central` 고정(원래 출처)인지, 출처 변경 허용인지.
