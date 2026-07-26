# 렌더링·Liveness 통일 설계 (2026-07-26)

## 배경 — 반복되던 버그의 두 뿌리

지난 세션들에서 하나씩 땜빵한 버그들(카드 alias 포커스 소실, 인박스 스크롤/포커스 리셋, 터미널 "새 셸" `<select>` 닫힘, 모바일 큐 배지 "문신", 작업중인데 "유휴" 오탐)은 **서로 다른 버그가 아니라 두 개의 구조적 뿌리에서 나온 증상**이다. 전수 조사(웹 렌더·모바일 렌더+큐·백엔드 liveness 3축)로 확정했다.

### 뿌리 1 — 렌더링: "폴마다 전체 재빌드 + 공유 reconciler 부재"

- 폴 타이머가 여러 개: 메인 5s(`app-6-modals.js:717`), 터미널 3s(`app-10-term.js:496`), 리모트 15s(`app-6d-remote.js:83`), 빌드 2s(`app-4b-build.js:126`), 로그 SSE(`app-4-logs.js:352`). 모바일은 3s(`marina_mobile.py` `autoPollMs=3000`).
- 매 폴마다 각 render가 자기 DOM 서브트리를 `innerHTML=` / `replaceChildren`로 **통째 재생성**한다. 공유 diff/reconcile 헬퍼가 **전무**하다(grep `reconcile|diffList|keyed|morphdom|patchDom` = 0).
- 대신 손으로 발명한 가드가 난립:
  - **signature-skip 변수 7종**(웹): `sessionSignature`, `worktreeStructureSig`, `lastInboxSig`, `updateBannerSig`, `termNewWtSig`, `termSideSig` — 각자 `JSON.stringify` 규칙이 제각각. 모바일도 3종(`updateHtmlIfChanged` 문자열비교, `sessionStructureKey`, `turnsStructureKey`).
  - **defer-while-editing 2번 따로**: 세션패널(`app-5-sessions.js:302-316`), 터미널 select(`app-10-term.js:20,404,416`).
  - **focus/scroll capture-restore 3번 따로**: 인박스(`app-1-core.js:110-134`), 로그(`app-4-logs.js:457-462`), 트랜스크립트(`app-6-modals.js:695-698`), 모바일 스크롤앵커(`marina_mobile.py` `captureScrollAnchor`).
  - **병렬 패처**: `updateServiceStates`(`app-5-sessions.js:223`)는 `render()`와 바이트 호환을 손으로 맞춰야 하는 제2의 렌더러.
- 결과: 새 상호작용 요소가 생길 때마다 재발. **아직 무방비(잠복 버그)**: `renderSwitcher`(열어둔 프로젝트 메뉴가 매 폴 파괴, `app-1-core.js:202`), ⋯액션메뉴 orphan(`app-5b-actions.js:104/126`), git 탭 스크롤·열린 diff(`app-8-git.js`), conn `<select data-conn-wt>`(`app-9-connections.js:60`), users 체크박스/`<select>`(`app-6c-users.js`), build `<details>`(`app-4b-build.js`), **모바일에서 AskUserQuestion/live-question 카드 미표시**.
- **핵심 자산**: 아이템 identity(reconcile key)가 이미 DOM에 있다 — `data-root`(세션), `data-service-key`=`root::svc`, `data-agent-sid`, `data-term-item`=tid, `data-agent-inbox-id`, git `data-git-repo`, conn `option value=root`, users `data-username`/`data-resource-key`. 유일한 예외: agent 행이 fast-path에서 sid가 아니라 **배열 인덱스 정렬**에 의존(`updateServiceStates:270`).

### 뿌리 2 — Liveness: "신호 5개, 단일 진실 부재"

세션이 살아있는가/도달 가능한가를 매 caller가 재조립한다. 신호 5종:

| # | 신호 | 수집 | 답 |
|---|------|------|-----|
| S1 | ps `comm=` + lsof cwd | `marina_sessions.py:843,859` | root에 claude/codex 프로세스 살아있나 |
| S2 | ps `command=` argv `--resume` | `marina_mobile.py:548` | 이 sid의 resume 프로세스 살아있나 |
| S3 | **인메모리 PTY 레지스트리** | `marina_term.py:81-82` `_by_tid`/`_by_key` | marina가 소유한 live PTY 있나 |
| S4 | 트랜스크립트 tail + mtime | `marina_sessions.py:492,531,599` | 트랜스크립트가 시사하는 턴 상태 |
| S5 | 훅 이벤트 저널 | `marina_agent_events.py:431` | 훅이 마지막 emit한 lifecycle |

캐논 객체가 없어 **5군데서 충돌(D1~D5)**:
- **D1** 프로세스 살았는데(S1/S2/S4) marina PTY 없음(S3) → `mobile_send`가 배달 거절(`marina_mobile.py:741-742`). **문신 근본.**
- **D2** "프로세스 살아있나"를 S1(comm+cwd)와 S2(argv resume) 두 방식이 서로 다르게 답함.
- **D3** 트랜스크립트는 working(S4)인데 cwd liveness(S1)가 idle로 강등(`:901/939`). "작업중인데 유휴".
- **D4** completed→waiting 승격이 이중 — `merge_agent_status`의 `terminal_active`(`:639`)는 **死코드**(아무도 True 안 줌), 실제는 S3 레지스트리(`:948`)만.
- **D5** `active_agents` 집합을 mobile(`:433`)와 handler(`marina_handler.py:564`)가 다른 필터로 만들어 같은 세션이 surface마다 다르게 승격.

**S3가 인메모리 전용** → marina-control 재시작 시 통째 소멸. 살아있던 세션이 전부 "배달불가"로 떨어지고(D1), waiting 승격·`term_open` 중복방지(reuse-by-key)도 깨진다.

**모바일 큐 reconcile**은 pending 레코드에 **tid/메시지id가 없어**(`marina_mobile.py:1686`) 순수 텍스트 매칭(`isConfirmed`/`ghost`, `:2283-2296`)으로만 소비 판정. liveness 신호(`state.terms`·`status`)를 **전혀 안 본다**. 게다가 **혼자 큐된 메시지**(대부분 케이스)는 `ghost`가 원천적으로 안 걸려(`:2288-2289`) 텍스트가 안 맞으면 영원히 stuck. 시간기반 탈출구는 과거 오탐 때문에 제거됨(`:2284-2286`). `pendingTurns`는 localStorage 미영속(`:1335`)이라 리로드하면 지워지지만 세션 내에선 무한 잔존.

---

## 처방

### 뿌리 1 — 공유 keyed reconciler (웹·모바일 공용)

**API (한 개):**
```
reconcile(container, items, {
  key(item)   -> string,        // 안정 identity (이미 있는 data-* 값)
  create(item) -> HTMLElement,  // 새 노드 (최초 1회)
  patch(el, item) -> void,      // 기존 노드에 바뀐 텍스트/속성만 반영
})
```
동작: `container`의 자식을 key로 매핑 → items 순서대로 (a) 있으면 재사용+`patch`, (b) 없으면 `create`, (c) 순서 바뀌면 `insertBefore`, (d) 남는 건 제거. **노드를 부수지 않으므로** 포커스·캐럿·미저장 입력값·스크롤·열린 네이티브 `<select>`·커스텀 메뉴·`<details>` open이 **구조적으로 생존**한다 — 사이트별 가드가 불필요해진다.

**`patch`의 규율:** 텍스트/클래스/속성만 갱신. 포커스된 `input`/`textarea`의 `.value`는 **덮어쓰지 않음**(사용자가 편집 중일 수 있음). 자식 리스트는 다시 `reconcile` 재귀.

**이주 대상(핵심 사이트) 및 삭제할 가드:**

| 사이트 | 파일 | 삭제되는 가드 |
|--------|------|----------------|
| 세션 카드 리스트 | `render()` `app-5-sessions.js:318` | `panelEditing`/`renderDeferred`/focusout(302-316), `replaceChildren` 통째교체, **병렬 패처 `updateServiceStates` 통합** |
| 서비스 트리 | `renderServiceTree:556` | `.svc-list` 통째 `innerHTML` |
| 에이전트 인박스 | `renderAgentInbox` `app-1-core.js:92` | `lastInboxSig`+scroll+focus capture(90,110-134) |
| 프로젝트 스위처 | `renderSwitcher:202` | (현재 무방비) 열린 메뉴 파괴 |
| ⋯ 액션메뉴 | `app-5b-actions.js:104/126` | 앵커 재생성 orphan |
| 터미널 사이드/select | `termRenderSide/NewWt` `app-10-term.js` | `termSideSig`/`termNewWtSig`/`termRenderDeferred` |
| 모바일 세션리스트 | `renderSessions` `marina_mobile.py:1828` | `sessionStructureKey` 이중경로 |
| 모바일 타임라인 | `renderTurns/reconcileAgentExchanges:2264` | `turnsStructureKey`+exchange 재조정+scrollAnchor(부분 유지) |
| 모바일 root/target select | `render():2701/2710` | 매 렌더 `innerHTML` 통째 + `isEditing()` 폴 억제 |

정적 사이트(memory, sourceTabs)와 이벤트 전용 탭(git·conn·users·build)은 **2단계**로 이주(같은 reconciler 재사용). 1단계에서 reconciler + 위 핵심 사이트만.

**전역 안전망:** reconciler로 못 옮긴 잔여 사이트를 위해, "활성 상호작용(포커스된 input/textarea/select, 열린 네이티브 팝업, 활성 selection) 감지 → 해당 폴 렌더 defer + 상호작용 종료 시 flush"를 **한 지점**(기존 2회 defer를 대체하는 단일 유틸)으로 둔다. reconciler가 우선, 이건 fallback.

**부록 — 에이전트 질문 로버스트 surface(모바일).** AskUserQuestion(pending)은 답 전엔 트랜스크립트에 없어 PreToolUse 훅(`marina_question.py`)이 세션별 상태파일에 기록해야만 모바일이 본다(`mobile_pending_question` → `.questionCard`). 이 경로가 취약: (a) `tool_input.questions`가 비거나 형식이 이상하면 훅이 아무것도 안 씀(`marina_question.py:48-49`), (b) 카드는 채팅 안에서만(`renderLiveQuestion`), 리스트 카드엔 표시 없음, (c) 구조화 실패 시 텍스트 폴백 없음. 처방:
- **캡처 하드닝**: questions가 이상해도 best-effort 기록(최소 "질문 중" 마커+원문 텍스트). 빈 것만 아니면 잡히게.
- **리스트 마커**: `status=blocked`/`pendingQuestion`이면 세션 리스트 카드에 "❓ 질문 대기" 표시 → 그 채팅 밖에서도 인지.
- **텍스트 폴백**: `renderQuestionCard`가 옵션/라벨로 카드를 못 만들면 질문 원문+선택지를 평문으로 렌더(항상 뭐라도 보이게).

### 뿌리 2 — 단일 liveness resolver + PTY 영속화

**(a) 단일 resolver.** `resolve_session_liveness(source, sid, root) -> SessionLiveness`:
```
SessionLiveness = { status, reachable: bool, tid: str|"", reason: str }
```
신호 **우선순위 규칙**(한 곳에 못박음):
- `status`: S5 훅(newest, ts≥) > S4 트랜스크립트. `_downgrade_if_dead`(S1)는 "working/blocked인데 root에 프로세스 없음"일 때만 강등 — **S5 ended는 무시하지 않도록** 병합 규칙 통일(D3 해소).
- `reachable`/`tid`: S3(live PTY) 우선. S3 없고 프로세스 살아있음(S1/S2)이면 `reachable=false, reason="pty-lost"`(재시작 등) — 단, 아래 (b)로 재구성 시도.
- `completed→waiting` 승격을 이 resolver 하나로(D4 死코드 제거, D5 필터 통일).

모든 caller(`agents_payload`, `mobile_send`, `mobile_state`, interrupt/answer 경로)가 이걸 쓴다. S1/S2 두 ps 방식은 **S1(comm+cwd, 프롬프트 무오염)로 단일화**(D2 해소).

**(b) PTY 레지스트리 영속화/재구성.** marina-control 재시작에도 S3를 잃지 않게:
- `_by_tid`/`_by_key`의 최소 메타(tid, cwd, pid, source, sid, key)를 디스크(`MARINA_HOME/terms/*.json`)에 기록하고 부팅 시 로드 → pid `os.kill(0)`로 생존 검증 후 재등록(fd는 잃으므로 "adopt: 스트리밍 불가, but reachable 판정·중복방지엔 유효" 표기), 또는
- 부팅 시 ps(S1/S2)+lsof로 살아있는 claude/codex를 스캔해 레지스트리를 **재구성**.
- 목표: 재시작 후에도 `reuse-by-key`(중복 resume 방지)·waiting 승격·"이 세션에 배달 가능" 판정이 유지.

**(c) 모바일 큐 reconcile 재설계.** pending 레코드에 **`tid` + 서버 메시지 seq/id를 저장**. reconcile을 liveness 기반으로:
- id/seq로 소비 확인되면 제거(텍스트매칭 폐기 또는 보조로만).
- pending의 `tid`가 더 이상 live PTY(S3/resolver)가 아니면 → **자동 `failed`**("전송 안 됨 · 탭해서 재시도"). **혼자 큐된 메시지도 정리됨**(문신 자동 소멸).
- 오탐 방지: 타임아웃이 아니라 "그 메시지가 들어간 PTY가 사라졌다"는 구체적 death 신호 사용(과거 idle+15s 오탐 회피). send 직후 레이스는 최소 나이/2연속 폴 결석으로.
- **수동 제어 병행**: pending/queued/failed 버블 탭 → ↻재시도 · ✕취소(`pendingTurns`에서 제거). 자동이 확신 못하는 케이스·즉시 제거용.

---

## 비목표(YAGNI)

- 프론트 프레임워크(React 등) 도입 안 함 — 순수 vanilla 유지, 최소 reconciler 1개만.
- git/conn/users/build 탭 이주는 2단계(1단계 검증 후).
- 워크트리+직접 launch(별도 승인된 스펙 A), 초기 로드 성능(B), 모바일 헤더 버그(C)는 이 스펙 범위 밖 — 이 통일 이후 진행.

## 테스트

- **reconciler 유닛**: key 재사용·추가·삭제·순서변경, 포커스된 input의 value/focus 보존, 열린 `<details>` 보존, 스크롤 보존(jsdom 또는 node vm + 미니 DOM stub; 없으면 Aside 실브라우저).
- **웹 e2e(Aside, 3910 실데이터)**: 핵심 사이트별 — 편집중 폴 렌더에서 포커스·값 유지, 인박스 스크롤 유지, 스위처 메뉴 안 닫힘, 터미널 select 안 닫힘, ⋯메뉴 안 orphan.
- **liveness 유닛**: resolver 신호 우선순위·강등·waiting 승격·D1~D5 회귀; PTY 재구성(재시작 시뮬 후 reachable 유지).
- **모바일 큐 e2e**: tid 죽은 pending 자동 failed, ✕취소 제거, ↻재시도 재전송, 소비된 것 자동 제거.

## 이주 순서(위험 관리)

1. reconciler 유틸 + 유닛테스트(순수, 위험 0).
2. 웹 핵심 사이트 1개씩 이주 → 각 이주마다 기존 가드 삭제 + Aside 검증(회귀 격리).
3. liveness resolver 도입(기존 함수 위임 → 시그널 통일) + 유닛.
4. PTY 영속화/재구성.
5. 모바일 reconciler 이주 + 큐 reconcile 재설계.
6. (2단계) 잔여 탭 이주.

각 단계는 독립 커밋, asdf 브랜치 누적, 형 검토 후 push.
