# 워크트리 환경: 레이어드 override + 관측 (env · links · ports)

2026-06-18. config 작업의 통합 모델. **Phase 1(서비스 `env` 주입, `c13d362`) 위에 얹는다.**
구 `2026-06-18-service-env-injection-design.md`(Phase 1)와 핸드오프 `2026-06-18-env-injection-HANDOFF.md`의 Phase 2 부분을 이 문서가 구체화/대체. Team/Local 제거는 **여전히 파킹**(직교·고위험, Codex BLOCKER).

## 목표 (핵심 가치)

워크트리마다 달라지는 **모든 환경**(서비스 env·symlink·port)을 *한 선언 모델 + 보편(universal) per-key override*로 다루고, 그 **effective 상태를 출처(provenance)까지 CLI·대시보드에서 확인**한다.

- "포트만"이 아니라 모든 설정. **base는 기본값**, **worktree override가 무엇이든 덮어씀**(추가·변경·`null` 해제). 심링크도 예외 없음.
- **싹 교체 아님 — per-key.** override가 지정한 key/rule만 바뀌고 base의 나머지 key는 보존.
- 관측이 통합의 접착제: env·links·ports를 한 화면에 **이긴 출처 + 무엇을 덮었는지**까지.

## 모델 (base ＜ worktree override, per-key merge)

3개 섹션, 전부 **keyed map** (최상위 key 단위로 머지):

| 섹션 | key | value | 비고 |
|---|---|---|---|
| `env` | 환경변수 이름 | str (토큰 허용) | 앱이 `getenv() or yaml`로 읽어 override (Phase 1) |
| `links` | **rule 이름** | rule 객체 `{to?, from?, glob?}` 또는 `null` | symlink. path/glob 모두 이름으로 키잉 → 개별 redirect/해제 |
| `ports` | 서비스 이름 | int | 자동이동 박제 + 수동 override |

- **base 선언**: service/project def (`marina-services.json` ∪ 중앙 `~/.marina/services/<id>.json`). 현 `env`와 같은 locus.
- **worktree override**: 세션 폴더 `overrides.json` `{env?, links?, ports?}` (이 워크트리만) + 기존 `overrides.env`(자동 포트 박제). effective 계산 시 둘 다 머지.
- **merge = per-key overlay**: `effective[sec][k] = override[k] 우선, 없으면 base[k]`. override 값이 `null`이면 그 **key만** 제거/비활성. base의 나머지 key는 그대로(싹 안 엎음). links는 rule 이름 단위로 객체를 통째 교체(또는 null 해제) — rule 내부 deep-merge 안 함(단순·예측가능).
- **토큰 치환**: `env`·`links` 값의 `{port}{<name>_port}{profile}{python}{root}{session}{env_file}{tmp}` 등을 `run`과 **동일 시점·순서**로 치환(포트 충돌이동 박제 *후* — stale 방지).

### provenance (출처 체인) — 관측의 핵심
key마다 **두 가지**를 기록한다:
1. **이긴 출처의 위치** — 값이 어디서 왔나: `overrides.json`(워크트리 수동/대시보드) · `overrides.env`(자동 포트 박제) · `서비스 def`(root|중앙) · `app yaml`.
2. **덮인 체인** — 그 값이 무엇을 덮었나: 이전 값 + 그 출처 (최소 직전 1단계, 가능하면 전체 스택).

→ 관측에서 `값 [이긴 출처]` + `↑ 덮음  이전값 · 출처`로 노출. *"왜 이 값이지?"*를 한 줄로 추적("`be=8412` → overrides.json이 auto-pin 8400을 덮음").

## 표면 (marina core — turong92/marina)

빌드 순서 = ① → ② → ③. ①이 ②③의 검증 도구.

### ① 관측 스파인 (먼저 — 저위험, 주로 읽기)
- **effective accessor**(공용): `base ∪ overrides.json ∪ overrides.env` 를 per-key 머지 →
  `{section: {key: {value, source:{kind,location}, shadowed:[{value,source}]}}}` 반환 (이긴 출처 + 덮인 체인). CLI·대시보드·주입이 같은 소스를 씀.
- **CLI** `marina config <svc>` (워크트리 컨텍스트): env/links/ports effective + **이긴 출처 배지 + `↑ 덮음` 체인** + 해제 표시. **`redact_stream` 적용**(env 값 시크릿). 기존 `print-env`/`print-command`는 유지하거나 이 명령으로 흡수.
- **대시보드**: 서비스별 effective 뷰(아코디언 또는 모달). 단일 임베디드 `INDEX_HTML`(`plugin/scripts/marina-control.py`). **dashboard UX 원칙 준수**(compact·iconified·state-adaptive·viewport-safe — `marina-dashboard-ux-preferences` 메모리). 출처 배지(위치) · 덮음 체인(행 펼침) · 해제 표시. `marina-preview`(:3901)로 검증.

### ② `links` 선언화 (bash `sync_*` 대체)
- service/project def에 `links: { <name>: {to, from} | {glob} | null }`.
  - `to`/`from`: 단일 경로(토큰·`{source}` 허용). `glob`: 원본에서 패턴 미러(현 bash `find`와 동형).
- **적용**: worktree *attach* 시 + 서비스 *start* 시 idempotent 재확인(override 반영). 현 정책 보존: `dst`가 심링크면 갱신, 실파일이고 동일하면 link로 교체, 다르면 경고 skip(`attach-detached-subrepos.sh` L279~355). `null`이면 skip/제거.
- **마이그레이션(무회귀)**: 현 하드코딩 + 전역 플래그를 기본 `links` rule로 매핑 —
  - `venv` ← `sync_venv_dir` (`SYNC_VENV`, `.venv`, `MARINA_VENV_PATH`)
  - `localYml` ← `sync_local_yml_files` (`SYNC_LOCAL_YML`, `*/src/main/resources/*local.yml`)
  - `localEnv` ← `sync_local_env_files` (`SYNC_LOCAL_ENV`, `.env*.local`)
- **links 범위 — 결정됨(default)**: 서비스 def(cwd 기준, `env`와 같은 locus). 같은 서브레포 다중 서비스는 idempotent로 무해. 프로젝트 레벨은 후속 일반화 여지.

### ③ `overrides.json` 보편 override
- 세션 폴더 `overrides.json` (**schema-versioned**). env/links/ports 부분 override.
- **authoring**: 우선 파일 + CLI(예: `marina override set <svc> <env|link|port> <key> <val>` / `... unset ...`). 대시보드 편집 UI는 후속(Phase 1.5식 — Codex D2: 표시 먼저, 풀 편집 나중).
- **`overrides.env` 공존**: 자동 포트 박제는 그대로(`config_file`/`set_config_value`, `marina.sh` L608~632). effective가 둘 다 머지. 장기적으로 `overrides.json`의 `ports`로 흡수 옵션 명시(즉시 아님).

## 적용 시점 (lifecycle — 선언/뷰는 하나, 적용은 각자 제 시점)
- `env`: 서비스 **start**(port-shift 후 resolve·주입) — Phase 1.
- `links`: worktree **attach** + start 시 idempotent 재확인(override·해제 반영).
- `ports`: start 시 resolve + 자동이동 박제(`overrides.env`).
- effective 뷰는 적용과 분리 — 어느 시점이든 머지 결과를 읽음.

## 관측 출력 예 (CLI — 출처 체인)
```
$ marina config search                       # feature/foo 워크트리
env
  BE_API_URL = localhost:8412     [override · overrides.json]
      ↑ 덮음  localhost:8400  ·  서비스 def(env 토큰)
  SEARCH_API = localhost:8533     [base · 서비스 def]
  LOG_LEVEL  = (unset)            [해제 · overrides.json]
      ↑ 덮음  info  ·  app yaml
links
  venv       → …/src/.venv        [base · 서비스 def · linked]
  localEnv   = (link 안 함)        [해제 · overrides.json]
      ↑ 덮음  glob .env*.local  ·  서비스 def
ports
  search     = 8533               [auto-pin · overrides.env]
      ↑ 덮음  8500  ·  portBase(서비스 def)
  be         = 8412               [override · overrides.json]
      ↑ 덮음  8400  ·  auto-pin(overrides.env)
```

## 하위호환 / 위험
- **구 marina**: `overrides.json` 무시 = 현 동작. **미지 필드 drop 주의** — `_read_services_file`(~L1593)이 `env`처럼 `links`도 보존하도록(Codex 캐치 재적용). `merged_services_json`(~L277) `{**s, source}` 자동 라이드 회귀 검증.
- **`sync_*` → `links`**: 기본 rule 매핑으로 무회귀. 전역 플래그(`SYNC_*`)는 default 매핑 토글로 **보존**(결정됨).
- **시크릿**: env 값 redaction을 CLI·대시보드 양쪽에.
- **provenance 정확도**: 이긴 출처 위치(파일/def)와 덮인 체인을 정확히 — auto-pin(`overrides.env`) vs 사용자 override(`overrides.json`) 구분.
- **project-id basename 충돌**(`~/.marina/services/<id>.json`) — override 파일 경로 설계 시 인지(Codex 캐치).

## 테스트 (격리 mktemp fixture — 기존 관례, 라이브 config 안 읽음)
- per-key merge: override가 한 key만 바꾸고 나머지 base 보존.
- `null` 해제: env unset / link 안 만듦 / port 제거.
- links: 단일 path·glob 링크 / redirect / disable / dst 충돌 정책.
- provenance: 이긴 출처 위치 + 덮인 체인(이전 값·출처) 정확.
- `overrides.env` + `overrides.json` 공존 머지.
- 미지 필드 보존(`links` 라이드).
- 토큰 치환 port-shift 후 재해석(env·links).

## 범위 밖 (파킹 — 직교)
- **Team/Local 이중소스 제거**: Codex BLOCKER(팀공유 상실·고위험 ~148곳). 팀 미사용·비긴급. 적극 공유 시 재평가.
- **mdc config 로컬 이전·커밋 삭제**: Team/Local 결정과 묶임.
- **대시보드 풀 편집 UI**: Phase 1.5(표시 먼저).
- **ai-api `getenv` + mdc `env` 배포·실측**: Phase 1 잔여로 별도 진행(형 승인). 이 모델의 ① 관측으로 검증.

## Codex 캐치 반영
- 미지필드 drop → `links` 보존.
- override provenance 표시 — ① 관측 스파인 핵심(이긴 출처 + 덮인 체인).
- `<id>.json` basename 충돌 — ③ 경로 설계 시.
- additive·저위험 우선(전면 재작성 반대) → ①(읽기) → ②(매핑 무회귀) → ③(부분 override) 점진.
