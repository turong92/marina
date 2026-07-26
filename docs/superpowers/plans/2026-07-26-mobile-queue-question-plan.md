# 모바일 큐 tid-reconcile + 질문 surface Implementation Plan (Plan 3/3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 모바일 큐 메시지가 영원히 "작업 끝나면 전달돼요"로 문신되던 것을, Plan 2 의 tid-liveness 로 **자동 정리**하고(전달 대상 PTY 가 사라지면 실패로 전환) + **탭 취소/재시도**를 붙인다. 그리고 에이전트 질문(AskUserQuestion)이 모바일에 안 뜨던 것을 **로버스트하게 surface**(캡처 하드닝·리스트 마커·텍스트 폴백)한다.

**Architecture:** 모바일 앱은 `marina_mobile.py` 안에 임베드된 HTML/CSS/JS. pending 큐 레코드에 `tid` 를 실어, 폴 reconcile 이 `state.terms`(살아있는 PTY, Plan 2 로 재시작에도 생존) 대조로 죽은 tid 의 pending 을 자동 실패 처리. 질문은 훅 캡처(marina_question.py)를 하드닝하고 렌더에 텍스트 폴백을 둔다.

**Tech Stack:** Python(marina_mobile.py, marina_question.py) + 임베드 JS. 검증은 3910 실데이터 + Aside `/mobile`. 백엔드 상태파일(agent-questions).

## Global Constraints

- Plan 2 자산 재사용: `state.terms` 는 이제 재시작에도 살아있는 PTY 목록(tid). "그 메시지가 들어간 PTY 가 사라졌다" 는 구체적 death 신호만 auto-fail 근거로 — 시간 타임아웃 금지(과거 idle+15s 오탐 회귀 방지, `marina_mobile.py:2284-2286` 주석 참조).
- pending 큐 auto-fail 은 **확실한 신호일 때만**: tid 결석(+최소 나이/2연속 폴) 또는 소비확인. 정상 대기(긴 턴) 는 유지.
- 질문 캡처 훅은 fail-open(에이전트 흐름 방해 금지).
- 커밋 끝에 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. asdf 누적, 미push. 관심사 1개당 1커밋.
- `test-mobile-control.sh` 는 사전 실패(auth/model-effort) 있음 — 변경 전후 동일함만 확인.

## 조사 근거(Plan 시작 전 investigation)

- pending 레코드: `queuePendingTurn`(~1678) `{role,text,baseline,pending,delivery,createdAt}` — **tid/msg-id 없음**(문신 근본). reconcile(~2290): `isConfirmed`(텍스트)→제거, `ghost`(뒤엣것 확정)→fail, else 유지. **혼자 큐된 건 ghost 원천불가→영원 stuck.**
- `state.terms` = `term_list().sessions`(live PTY). send 응답 `d.tid` 존재. `pendingDeliveryLabel`(~1647): queue/steer/started 는 나이무관 sticky.
- 질문: `marina_question.py`(PreToolUse 훅) `agent-questions/claude-<sid>.json` 기록, `mobile_pending_question`(~404) 읽음, `renderLiveQuestion`(~1248) 카드. `tool_input.questions` 비면 훅이 아무것도 안 씀(캡처 갭). 카드는 채팅 안에서만.

---

## File Structure

- **Modify** `plugin/scripts/marina_mobile.py` — pending 레코드 tid 저장·reconcile tid auto-fail·탭 취소/재시도·세션리스트 질문 마커·renderQuestionCard 텍스트 폴백·detached controllable=False.
- **Modify** `plugin/scripts/marina_question.py` — 캡처 하드닝(edge question 도 best-effort 기록).
- **Create** `plugin/tests/test-mobile-queue-reconcile.sh` — pending reconcile 로직 단위(크래프트 state.terms 로 tid auto-fail/유지).

---

## Task 1: pending 레코드에 tid 저장 + tid-liveness auto-fail

**Files:** Modify `marina_mobile.py`(`queuePendingTurn`~1678, send 성공경로 `selectReturnedTerm`/`selectAgentAfterSend`~1688/1727, reconcile ~2290). Test `plugin/tests/test-mobile-queue-reconcile.sh`.

- [ ] **Step 1:** 현재 `queuePendingTurn`·reconcile 읽기. `send()`(~2818) 가 `d.tid` 를 `selectReturnedTerm(d.tid,...)` 로 넘기는 것 확인.
- [ ] **Step 2:** `queuePendingTurn(key, text, delivery, tid)` 로 tid 인자 추가, 레코드에 `tid` 저장. `selectAgentAfterSend`/`selectReturnedTerm` 가 `d.tid` 를 전달하도록 배선.
- [ ] **Step 3:** reconcile(~2290)에 규칙 추가: 소비 안 됐고 `delivery∈{queue,steer,started}` 이고 레코드에 `tid` 가 있는데 **그 tid 가 `state.terms` 에 없으면**(살아있는 PTY 아님) → `{...t, failed:true, delivery:"failed"}`(문신 자동 소멸→탭 재시도 가능). 단 send 직후 레이스 방지: `createdAt` 최소 나이(예: >4s) 또는 2연속 폴 결석. 기존 `isConfirmed`/`ghost` 는 그대로(우선).
- [ ] **Step 4:** 순수 로직을 테스트 가능하게 — reconcile 판정을 JS 헬퍼로 뽑거나, `test-mobile-queue-reconcile.sh` 에서 크래프트 `pendingTurns`+`state.terms` 로 결과 단정(node vm + 최소 stub). 케이스: tid 살아있음→유지, tid 결석+나이 충족→failed, 소비됨→제거.
- [ ] **Step 5:** 커밋 — `feat(mobile): queue pending auto-fail via tid liveness (clear the stuck 문신)`.

## Task 2: pending/queued/failed 탭 취소·재시도

**Files:** Modify `marina_mobile.py`(`renderTimelineMessage`~2127, 이벤트 위임).

- [ ] **Step 1:** pending/queued/failed 말풍선에 인라인 액션 `↻ 재시도` · `✕ 취소` 추가(작은 버튼, data-attr).
- [ ] **Step 2:** `취소` = `pendingTurns[key]` 에서 그 레코드 제거 + 재렌더(문신 즉시 제거, 클라 상태만).
- [ ] **Step 3:** `재시도` = 그 텍스트+타겟으로 기존 send 경로 재호출(`/mobile/api/send`). 실패 시 failed 유지.
- [ ] **Step 4:** Aside 로 3910 `/mobile` 에서 stuck pending 주입→✕제거, ↻재전송 확인(수동/문서 e2e).
- [ ] **Step 5:** 커밋 — `feat(mobile): tap to cancel/retry pending messages`.

## Task 3: 에이전트 질문 로버스트 surface

**Files:** Modify `marina_question.py`(캡처), `marina_mobile.py`(`renderLiveQuestion`~1248·`renderQuestionCard`·세션리스트 `renderSessions`~1828).

- [ ] **Step 1: 캡처 하드닝** — `marina_question.py`: `questions` 가 비었거나 형식이 이상해도 best-effort 로 최소 레코드(질문 원문 텍스트라도) 기록. 완전 빈 것만 skip. fail-open 유지.
- [ ] **Step 2: 리스트 마커** — `renderSessions` 세션 카드에 `status==="blocked"`/`pendingQuestion` 이면 `❓ 질문 대기` 배지. 그 채팅 안 봐도 인지.
- [ ] **Step 3: 텍스트 폴백** — `renderQuestionCard` 가 옵션/라벨로 카드를 못 만들면(누락·이상) 질문 원문+선택지를 평문으로 렌더(항상 뭐라도 보이게).
- [ ] **Step 4:** 3910 `/mobile` 에서 pending 질문 상태파일 주입→리스트 마커+카드/폴백 표시 확인(Aside).
- [ ] **Step 5:** 커밋 — `feat(mobile): robust agent-question surfacing (capture harden + list marker + text fallback)`.

## Task 4: detached PTY → controllable=False (Plan 2 잔여 wart)

**Files:** Modify `marina_mobile.py`(`mobile_state` ~461-483).

- [ ] **Step 1:** `mobile_state` 에서 세션의 tid 가 재구성된 `detached` PTY 면(term_list 항목에 detached 표식 노출 필요 시 marina_term/term_list 에 `detached` 필드 추가) `controllable=False` 로. detached 는 term_input 이 400 이므로 버튼이 됨직해 보이면 안 됨.
- [ ] **Step 2:** 3910 확인 — detached 세션이 controllable=False.
- [ ] **Step 3:** 커밋 — `fix(mobile): detached (adopted) PTY is not controllable`.

## Task 5: 라이브 Aside 검증(모바일)

- [ ] **Step 1:** 3910 `/mobile` (실데이터, auth off) 열어 — 큐 메시지 auto-fail(tid 죽이면), 취소/재시도, 질문 마커/폴백 확인. 결과를 리포트/e2e 로.
- [ ] **Step 2:** 커밋(문서/e2e).

## Self-Review

- **Spec coverage:** Root2 (c)큐 tid-reconcile=Task1-2, 부록 질문 surface=Task3, Plan2 잔여 wart=Task4, 라이브=Task5. 모바일 세션리스트/타임라인 **reconcile 이주는 범위 밖**(별도 follow-up — 모바일은 이미 자체 가드 3종 보유, 급하지 않음; 급한 건 큐·질문).
- **Placeholder scan:** Task1 Step3 auto-fail 조건(tid 결석+최소나이/2폴) 구체 명시. Task4 detached 필드 노출 필요성 명시. 나머지 구체.
- **Type consistency:** `queuePendingTurn(key,text,delivery,tid)` 시그니처 Task1/2 동일.
