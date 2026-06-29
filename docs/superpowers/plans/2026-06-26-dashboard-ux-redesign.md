# Marina 대시보드 UX 재설계 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (또는 executing-plans). Steps = `- [x]`. **구현=Claude(Edit/Write), 리뷰=codex**([[marina-claude-implements-codex-reviews]]). 백엔드 먼저(Python TDD) → UI.

**Goal:** marina 대시보드를 정규설정(compose+`x-marina`)·opt-in links 3분류·위저드/고급/복붙공유 로 재설계.

**Architecture:** 백엔드(x-marina 파서·links 3분류·scan·import·migration; `marina-compose.py`/`marina.sh`/`marina-control.py`, Python/bash TDD) → UI(`marina-web/`, vanilla JS). 기존 helper(`_list_dockerfiles`·`_dockerfile_expose`·ARG감지·`_compose_scaffold_service`)·게이트웨이·엮기 재사용. 신규 모달 최소, 기존 모달 합침.

**Tech Stack:** Python stdlib(http.server) · bash · vanilla JS · 테스트 `plugin/tests/*.sh`.

**Spec:** `docs/superpowers/specs/2026-06-26-dashboard-ux-redesign-design.md`

---

## Task 0 — 사전 확인 (코드 안 고침, 메모만)
- [x] marina 가 compose YAML 을 **어떻게 파싱**하는지 확인: `grep -nE "yaml|safe_load|docker compose config|json.loads" plugin/scripts/marina-compose.py`. x-marina 읽기는 그 방식 따름(PyYAML 있으면 `yaml.safe_load`, 없으면 `docker compose config --format json` 경유).
- [x] 헬퍼 시그니처: `_list_dockerfiles(repo)->list`, `_dockerfile_expose(path)`, ARG감지 함수(1399~1418, `{args,requiredArgs,artifacts,runtime}` 반환)·`_compose_scaffold_service(target,subrepo,dockerfile,...)` 위치/인자 확인.
- [x] 현재 links 규칙 소스: `apply_glob_links`/`links_json`(marina.sh) 가 글롭 룰을 어디서 읽나(backing.json? links.json?) 확인.

---

## Phase 1 — x-marina 파서/직렬화 (backend 기반)

### Task 1: x-marina 읽기/쓰기 왕복
**Files:** Modify `plugin/scripts/marina-compose.py` (또는 신규 `_xmarina` 섹션) · Test `plugin/tests/test-xmarina.sh`
- [x] **Step1 실패테스트** — `test-xmarina.sh`: compose YAML(`x-marina: {prebuild:{be-api:"./gradlew"}, links:{symlink:[node_modules], copy:["**/*local.yml"]}, forward:{6379:{target:host}}, gateway:{routes:{web:["/v1.0"]}}}`)을 `python3 -c "import marina_compose; print(marina_compose.parse_xmarina(open(F).read()))"` → dict 비교. 직렬화 왕복(`serialize_xmarina(d)` → 재파싱 동일).
- [x] **Step2 fail 확인** — `bash plugin/tests/test-xmarina.sh` → FAIL(함수 없음).
- [x] **Step3 구현** — `parse_xmarina(compose_text)->dict` (YAML 파싱 후 `x-marina` 키 추출, 없으면 `{}`), `serialize_xmarina(services_dict, xmarina_dict)->str`. 기존 compose 파싱 재사용.
- [x] **Step4 pass** · **Step5 commit** `feat(compose): x-marina 파서/직렬화`

### Task 2: x-marina → overlay/적용 배선
**Files:** Modify `marina-compose.py`(overlay), `marina.sh`(prebuild/links 호출부)
- [x] **Step1 테스트** — x-marina 의 `forward`/`prebuild` 가 기존 overlay·prebuild 경로로 들어가는지(`test-compose-overlay.sh` 확장: x-marina.forward → `<svc>-bind` 사이드차). gateway.routes → `_gateway_snapshot`(이미 backing.json gatewayRoutes 읽음 → x-marina 도 읽게).
- [x] **Step2~5** — `forward`(이미 `_normalize_forward` 가 top-level forward 읽음 → x-marina.forward 도 같은 dict 로), `prebuild`(prebuild.json 대신 x-marina.prebuild), gateway(gatewayRoutes 대신 x-marina.gateway.routes) 소스 전환. commit.

---

## Phase 2 — opt-in links 3분류

### Task 3: links 스키마 = 명시 리스트(글롭-자동 폐기)
**Files:** Modify `marina.sh`(apply_glob_links/links_json) · Test `plugin/tests/test-config-glob-links.sh`(확장)
- [x] **Step1 테스트** — x-marina.links `{symlink:[node_modules,.venv], copy:["**/*local.yml"]}` 적용 시: node_modules **심링크**, *local.yml **복제**(실파일·원본과 독립), `build`/`.next`/`*.jar` 는 **링크/복제 안 됨**(목록에 없으면 아무것도 안 함). 기존 #3 재귀 테스트 유지.
- [x] **Step2 fail** — 현재는 글롭 자동이라 build 도 링크됨 → FAIL.
- [x] **Step3 구현** — `apply_glob_links` 가 글롭 자동탐색 대신 **x-marina.links.symlink/copy 명시 리스트만** 처리. symlink=기존 심링크 로직, copy=`shutil.copy2`(파일)/`copytree`(디렉터리, 가벼운 것만 — 큰 디렉터리 copy 경고). 목록 외 = 무시(빌드출력 자동 제외).
- [x] **Step4 pass**(node_modules 심링크·yml 복제 독립·build 미링크) · **Step5 commit** `feat(links): opt-in 심링크/복제 3분류`

### Task 4: 분류 제안 헬퍼 (UI 가 쓸 기본값)
**Files:** Modify `marina-control.py` (links 스캔 시 분류 태깅)
- [x] **Step1 테스트** — gitignored 스캔 결과에 `category` 부여: node_modules/.venv→`deps`(심링크 제안), *local.yml/.env*→`config`(심링크/복제 택), build/.next/dist/out/target/*.jar→`build`(제외 제안). `test-config-glob-links.sh` 에 분류 assert.
- [x] **Step2~5** — `_categorize_link(path)->{"deps"|"config"|"build"}` + `/api/links` 응답에 category 포함. commit.

---

## Phase 3 — compose-scan (비-LLM) + 스캔 복구

### Task 5: /api/compose-scan 엔드포인트
**Files:** Modify `marina-control.py` · Test `plugin/tests/test-compose-scan.sh`
- [x] **Step1 테스트** — 더미 레포(서브레포 2개·각 Dockerfile[ARG·EXPOSE])에 `/api/compose-scan` POST{root} → `{subrepos:[{subrepo, dockerfiles:[{dockerfile, expose, args, requiredArgs, artifacts}]}]}` 반환. **LLM 호출 없음**(`_llm_run` 안 탐).
- [x] **Step2 fail** — 엔드포인트 없음.
- [x] **Step3 구현** — `do_POST`/`do_GET` 에 `/api/compose-scan` 추가: `_list_dockerfiles`·`_dockerfile_expose`·ARG감지 헬퍼(전부 유지됨)로 서브레포별 스캔. (제거된 compose-analyze 의 **스캔 부분만**, LLM 제외 — d247591 diff 의 `for df in _list_dockerfiles(base): {subrepo,dockerfile,expose,args,...}` 구조 참고.)
- [x] **Step4 pass** · **Step5 commit** `feat(api): 비-LLM compose-scan`

---

## Phase 4 — import (복붙)

### Task 6: /api/compose-import
**Files:** Modify `marina-control.py` · Test `plugin/tests/test-compose-import.sh`
- [x] **Step1 테스트** — 공유 블록(compose+x-marina YAML)을 `/api/compose-import` POST{root, blob} → 프로젝트 등록 + x-marina 적용(links/prebuild/forward/gateway 저장) → `marina service ls` 로 서비스 확인. 잘못된 YAML/레포 불일치 → 4xx + 메시지.
- [x] **Step2~5** — 파싱(`parse_xmarina`)·검증(compose 유효: 기존 validate 재사용 · 서브레포/Dockerfile 존재 확인) → 기존 등록 경로(`/api/compose-register` 로직 재사용) + x-marina 저장. commit.

---

## Phase 5 — 마이그레이션

### Task 7: 흩어진 JSON → x-marina (로드 시 1회)
**Files:** Modify `marina-control.py` · Test `plugin/tests/test-xmarina-migrate.sh`
- [x] **Step1 테스트** — 기존 `~/.marina/<id>/{build-args,prebuild,links}.json`+backing.json(forward) 있는 프로젝트 로드 → x-marina 로 합쳐진 compose 반환(원래 동작 동일). 기존 JSON 은 보존(롤백 가능).
- [x] **Step2~5** — `_migrate_to_xmarina(pid)`: 흩어진 JSON 읽어 x-marina dict 구성(build-args→`build.args`, prebuild→x-marina.prebuild, links→x-marina.links[symlink], forward→x-marina.forward). 로드 시 x-marina 없고 레거시 JSON 있으면 합쳐서 노출. commit.

---

## Phase 6 — UI 위저드 (marina-web)

### Task 8: 진입 2경로 + 위저드 셸
**Files:** Modify `marina-web/index.html`·`marina-web/app.js`
- [x] 프로젝트 추가 → 모달: **[새로 설정(위저드)] · [팀원 설정 붙여넣기]** 두 버튼.
- [x] 위저드 셸: 4스텝 진행바(스캔·파일·연결·검토) + 다음/이전. 상태는 **하나의 config 객체**(= x-marina+services) 에 누적(고급뷰와 공유).
- [x] 검증: 더미 프로젝트로 위저드 열림·스텝 이동. commit.

### Task 9: 스텝1 스캔 (Dockerfile + ARG + env 입력) — *복구*
- [x] `/api/compose-scan` 호출 → 서비스 카드: 🐳 Dockerfile(읽기전용·`highlightVars` 재사용)·ARG/필수ARG·EXPOSE · ⚙️ build-args 입력(KEY=VALUE) · [✓]포함.
- [x] 입력 → config.services[svc].build.args 에 반영. commit.

### Task 10: 스텝2 파일(opt-in links)
- [x] `/api/links`(category 포함) → 3그룹 표시. deps=심링크 체크(기본 켬), config=심링크/복제 라디오, build=제외(회색·"독립 빌드" 안내).
- [x] 선택 → config.x-marina.links{symlink,copy}. commit.

### Task 11: 스텝3 연결 + 스텝4 검토
- [x] 연결: 흔한 백킹(redis6379·mysql3306·postgres5432) 체크 → forward{port:host} · 게이트웨이 토글→gateway.
- [x] 검토: config → compose YAML 직렬화(`serialize_xmarina`) 미리보기(편집 가능) → 등록(기존 register 경로). commit.

---

## Phase 7 — UI 고급 + 공유/가져오기

### Task 12: 고급 뷰(raw YAML) + 공유
- [x] 위저드 헤더에 **[고급]** 토글 → 같은 config 를 YAML textarea 로(직렬화) 직접 편집 → 파싱해 config 갱신(양방향).
- [x] **[공유용 복사]** 버튼 → config 직렬화(시크릿 제외) 클립보드 복사.
- [x] **[팀원 붙여넣기]** 경로 → textarea 붙여넣기 → `/api/compose-import` → 등록+적용 "끝" 토스트. commit.

---

## Phase 8 — UI 서비스 카드

### Task 13: 카드 + 인라인 ⓘ + 게이트웨이 URL
- [x] 실행중 서비스 카드: 상태·포트 · 게이트웨이 켜졌으면 `<wt>.<proj>.localhost:port` **URL+복사** · **ⓘ** → 인라인(Dockerfile 보기·build-args·prebuild·links·forward, 기존 1737~1853 재사용/정리).
- [x] 검증: 데모 프로젝트로 카드·URL·ⓘ 동작. commit.

---

## Self-Review (작성자 체크 — 완료)
- **Spec 커버**: §1 정규설정→P1·P5 · §2 links→P2 · §3 모드→P6/P7 · §4 진입→T8 · §5 위저드→P6 · §6 카드→P8 · §7 연결→T2/T11 · §8 마이그레이션→P5 · §9 백엔드→P1·P3·P4. 갭 없음.
- **Placeholder**: 각 백엔드 task 에 테스트·헬퍼·소스 명시. UI 는 컴포넌트 스펙(컨텍스트 절약 — 실행자=Claude+spec). 미세 JS 코드는 실행 때 spec 보고 채움.
- **타입 일관**: `parse_xmarina`/`serialize_xmarina`·`_categorize_link`·`/api/compose-scan|import` 명칭 통일.

## 다음 세션 핸드오프
1. **Task 0** 부터(파싱 방식·헬퍼 확인) → Phase 순서대로. 백엔드(P1~5) 먼저 = 테스트로 안전.
2. 각 task 끝 commit, Phase 끝마다 codex 리뷰(`codex review --base main`).
3. 데모 환경(`/tmp/marina-gw-demo2`)·기존 50/50 테스트 회귀 유지.

## 진행 상태 (2026-06-26)
- ✅ Phase 1~5 (Task 0~7) 백엔드 완료 — 테스트 55, codex 9건 수정. 커밋 b94d68f~0de7cd4.
- 🔄 Phase 6 시작: Task 8 진입 2경로 모달 + Task 12 붙여넣기 import 완료(acbf73d, Aside 검증). "새로 설정" 은 아직 기존 compose 폼으로 라우팅.
- 🔜 남음: Task 9~11 위저드 4스텝 · Task 12 공유복사+고급뷰(+`/api/compose-export` 필요) · Task 13 서비스 카드. 메모리 [[marina-dashboard-ux-redesign]] 참조.
