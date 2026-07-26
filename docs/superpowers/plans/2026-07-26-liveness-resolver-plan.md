# 단일 Liveness Resolver + PTY 영속화 Implementation Plan (Plan 2/3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** "세션이 살아있나/도달가능한가"를 5개 신호(ps comm+cwd, ps argv, 인메모리 PTY 레지스트리, 트랜스크립트 mtime, 훅 이벤트)로 caller마다 제각각 재조립하던 것을 **단일 resolver 하나**로 통일(D1~D5 해소)하고, **PTY 레지스트리를 재시작에도 살아남게** 만들어 살아있는 세션이 "배달 불가"로 떨어지는 근본(모바일 문신)을 없앤다.

**Architecture:** `resolve_session_liveness(source, sid, root, *, live_cwds, live_tids, native, event)` 하나가 status(S5 훅 > S4 트랜스크립트, 그다음 S1 cwd 로 working/blocked 강등)와 reachable/tid(S3 레지스트리)를 한 규칙으로 계산해 `SessionLiveness` 를 돌려준다. 모든 caller(`agents_payload`, `mobile_send`, `mobile_state`)가 이걸 쓴다. PTY 레지스트리(`_by_tid`/`_by_key`)는 메타를 디스크에 남겨 부팅 시 pid 생존검증 후 재등록.

**Tech Stack:** Python 3.9 (marina_sessions.py, marina_term.py, marina_mobile.py). 테스트는 기존 패턴(shell + inline python heredoc, 크래프트된 신호 입력으로 순수 판정 검증). 실동작은 3910 실데이터로 확인.

## Global Constraints

- 기존 동작 회귀 금지 — `test-session-liveness.sh`·`test-agents-section.sh`·`test-transcript-inject-filter.sh`·`test-agent-inbox.sh`·`test-update-status.sh` 는 항상 green.
- liveness 신호 통일: **S1(ps `comm`+lsof cwd, 프롬프트 무오염)로 단일화** — S2(ps `command=` argv `--resume` 스캔, `_agent_process_active`)는 폐기/대체. 프롬프트 텍스트 파싱 절대 재도입 금지.
- `_root_has_live_agent` 의 nested-worktree 제외 규칙(Plan 1 4da7079) 유지 — main root 가 워크트리 cwd 로 오매치 안 함.
- PTY 영속화는 fail-open: 디스크 읽기/쓰기 실패가 세션 흐름을 막으면 안 됨(예외는 조용히 무시, 인메모리 동작 유지).
- 커밋 메시지 끝에 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. asdf 브랜치 누적, 미push.
- 사이트/관심사 1개당 1커밋(회귀 격리).

## 조사 근거(신호·불일치 지도, 구현 시 참조)

- S1 `_parse_agent_pids`/`_live_agent_cwds`/`_root_has_live_agent` (marina_sessions.py). S3 `_by_tid`/`_by_key`/`term_list` (marina_term.py). S4 `_native_agent_status`. S5 `latest_agent_event`+`merge_agent_status`.
- D1 `mobile_send` (marina_mobile.py 후 728/741): 프로세스 살았는데 PTY(S3) 없으면 배달 거절 → 문신. D2 S1 vs S2 두 ps 방식 충돌. D3 트랜스크립트 working 인데 cwd 없으면 idle 강등. D4 `merge_agent_status` `terminal_active` 死코드, 실제 승격은 S3(`activate_agent_payloads`). D5 `active_agents` 필터 mobile/handler 불일치.

---

## File Structure

- **Modify** `plugin/scripts/marina_sessions.py` — `SessionLiveness` + `resolve_session_liveness()` 신규; `agents_payload`/`activate_agent_payloads`/`_downgrade_if_dead` 를 resolver 로 위임.
- **Modify** `plugin/scripts/marina_mobile.py` — `mobile_send` 도달성 판정을 resolver 로; `_agent_process_active`(S2) 대체; `_native_agent_active`/`_live_agent_tid` 정리.
- **Modify** `plugin/scripts/marina_term.py` — PTY 레지스트리 메타 디스크 영속화 + 부팅 재구성.
- **Create** `plugin/tests/test-liveness-resolver.sh` — resolver 단위(크래프트 신호로 D1~D5 회귀).
- **Create** `plugin/tests/test-pty-persistence.sh` — 재시작 시뮬(메타 write→reload→term_list 반영).

---

## Task 1: `resolve_session_liveness` 코어 + 단위 테스트

**Files:**
- Modify: `plugin/scripts/marina_sessions.py` (신규 함수 — `_downgrade_if_dead` 부근)
- Test: `plugin/tests/test-liveness-resolver.sh`

**Interfaces:**
- Produces: `resolve_session_liveness(source, sid, root, *, native, event, live_cwds, live_tids)` → dict `{status, reachable, tid, reason}`.
  - `native` = `_native_agent_status` 결과(dict, S4). `event` = `latest_agent_event` 결과 or None(S5). `live_cwds` = `_live_agent_cwds` 결과(S1). `live_tids` = {(source,sid): tid} 살아있는 PTY 맵(S3).
  - status 규칙: `merge_agent_status(native, event)` 로 기본 산출 → 그 status 가 working/blocked 이고 `not _root_has_live_agent(root, live_cwds)` 이면 idle+"프로세스 없음" 강등(D3) → status 가 completed 이고 reachable 이면 waiting 승격(D4, terminal_active 死코드 대체).
  - reachable/tid: `(source,sid) in live_tids` 면 reachable=True, tid=그 값; 아니면 reachable=False, tid="".

- [ ] **Step 1: 실패 테스트** — `plugin/tests/test-liveness-resolver.sh`

크래프트 신호로 D1~D5 케이스 단정(각각 fails 리스트에 push, 끝에 PASS/FAIL). 최소 케이스:
```python
# (shell + python heredoc, test-session-liveness.sh 패턴)
import marina_sessions as ms
from pathlib import Path
R = Path('/Users/sumin/work/wt'); fails=[]
N_work = {'status':'working','statusTs':100.0}   # S4 트랜스크립트 working
# D3: working 인데 cwd 없음 → idle
r = ms.resolve_session_liveness('claude','s1',R, native=N_work, event=None, live_cwds=set(), live_tids={})
if r['status']!='idle' or r['reachable']: fails.append(('D3',r))
# working + cwd 있음 → working 유지
r = ms.resolve_session_liveness('claude','s1',R, native=N_work, event=None, live_cwds={R}, live_tids={})
if r['status']!='working': fails.append(('working-live',r))
# D4: completed + reachable PTY → waiting
N_done = {'status':'completed','statusTs':100.0}
r = ms.resolve_session_liveness('claude','s2',R, native=N_done, event=None, live_cwds={R}, live_tids={('claude','s2'):'tid9'})
if r['status']!='waiting' or r['tid']!='tid9' or not r['reachable']: fails.append(('D4',r))
# completed + not reachable → completed 유지
r = ms.resolve_session_liveness('claude','s2',R, native=N_done, event=None, live_cwds=set(), live_tids={})
if r['status']!='completed': fails.append(('completed-stays',r))
# reachable 판정
r = ms.resolve_session_liveness('claude','s3',R, native=N_work, event=None, live_cwds={R}, live_tids={('claude','s3'):'tidA'})
if not r['reachable'] or r['tid']!='tidA': fails.append(('reachable',r))
```

- [ ] **Step 2: 실패 확인** — `bash plugin/tests/test-liveness-resolver.sh` → FAIL(`resolve_session_liveness` 미존재).

- [ ] **Step 3: 구현** — `marina_sessions.py` 에 `resolve_session_liveness` 추가. `merge_agent_status`(기존)·`_root_has_live_agent`(기존) 재사용. 완료→waiting 승격은 이 함수에서(캐논). 순수 함수(신호를 인자로 받음 — 테스트/캐시 용이).

- [ ] **Step 4: 통과 확인** — `bash plugin/tests/test-liveness-resolver.sh` → PASS.

- [ ] **Step 5: 커밋** — `git add marina_sessions.py test-liveness-resolver.sh && git commit -m "feat(sessions): single resolve_session_liveness (status+reachable+tid, D3/D4 unified) ..."`.

---

## Task 2: `agents_payload` 를 resolver 로 위임

**Files:** Modify `plugin/scripts/marina_sessions.py` (`agents_payload`, `activate_agent_payloads` 호출부).

**Interfaces:** Consumes `resolve_session_liveness` (Task 1).

- [ ] **Step 1:** 현재 `agents_payload` 읽기 — `agent_status`(native+event) → 아이템, 그 뒤 `_live_agent_cwds`+`_downgrade_if_dead`, 별도 `activate_agent_payloads`(S3) 흐름 확인.
- [ ] **Step 2:** 각 아이템에 대해 `resolve_session_liveness(source, sid, canonical_root, native=<agent_status 결과>, event=<latest_agent_event>, live_cwds=<한 번 조회>, live_tids=<한 번 조회>)` 로 status/reachable/tid 를 세팅. 인라인 `_downgrade_if_dead` + 별도 `activate_agent_payloads` 승격을 이 한 경로로 대체(중복 로직 제거). `live_tids` 는 `term_list`(S3)에서 (source,sid)→tid 맵으로 한 번 구성.
- [ ] **Step 3:** `node`/python 문법 + 기존 테스트: `bash plugin/tests/test-agents-section.sh`·`test-transcript-inject-filter.sh`·`test-agent-inbox.sh`·`test-update-status.sh` 전부 PASS(이들이 `_downgrade_if_dead`/monkeypatch 를 쓰면 시그니처 호환 유지 or 테스트 갱신).
- [ ] **Step 4:** 커밋 — `refactor(sessions): agents_payload via resolve_session_liveness (drop inline downgrade+activate)`.

---

## Task 3: 모바일 도달성 판정 통일(S2 폐기)

**Files:** Modify `plugin/scripts/marina_mobile.py` (`mobile_send` 724-759, `_agent_process_active`, `_native_agent_active`, `_live_agent_tid`).

**Interfaces:** Consumes `resolve_session_liveness`/`term_list`(S3).

- [ ] **Step 1:** 현재 `mobile_send` agent 분기 읽기 — `_live_agent_tid`(S3) 있으면 배달, 없고 `_agent_process_active`(S2) or `_native_agent_active` 면 거절(D1), 아니면 fresh resume.
- [ ] **Step 2:** 거절/배달 결정을 resolver 로: reachable+tid 면 그 PTY 로 배달; **reachable=False 인데 프로세스는 살아있음(cwd 로 판정, S1)** 이면 명확한 사유로 거절("이 세션은 marina 밖에서 실행 중")하되 — 단, Task 4(PTY 영속화) 착지 후엔 재시작으로 잃은 세션이 다시 reachable 이 되어 이 경로가 대부분 사라짐. `_agent_process_active`(S2 argv 스캔)는 **삭제**하고 S1 기반으로 대체.
- [ ] **Step 3:** `mobile_state`(active_agents 구성)도 resolver/term_list 로 일원화(D5 필터 불일치 제거).
- [ ] **Step 4:** 실동작 — 3910 실데이터로 `/mobile/api/state` 가 status/controllable 정상, 살아있는 세션 배달 가능 확인(curl + 필요시 Aside). 기존 `test-mobile-control.sh`(사전 실패 이슈 무관 확인) 외 회귀 없음.
- [ ] **Step 5:** 커밋 — `refactor(mobile): reachability via resolver; drop ps-argv S2 scan`.

---

## Task 4: PTY 레지스트리 영속화 + 부팅 재구성

**Files:** Modify `plugin/scripts/marina_term.py` (`_Term`/`term_open`/`term_kill`/모듈 로드). Test `plugin/tests/test-pty-persistence.sh`.

**Interfaces:** 디스크 메타 `MARINA_HOME/terms/<tid>.json` = `{tid, cwd, pid, source, sid, key, created}`.

- [ ] **Step 1: 실패 테스트** — 메타 파일을 손으로 쓰고(살아있는 pid=현재 python), 재로드 함수 호출 후 `term_list`/reachability 가 그 tid 를 반영하는지; 죽은 pid 메타는 정리되는지 단정.
- [ ] **Step 2: 실패 확인.**
- [ ] **Step 3: 구현** — `term_open` 성공 시 메타 write, `term_kill`/reap 시 삭제. 모듈 로드(또는 첫 `term_list`)에서 `terms/*.json` 읽어 `os.kill(pid,0)` 로 생존 검증 후 `_by_tid`/`_by_key` 재등록(fd 없음=streaming 불가 표기, 하지만 reachability·reuse-by-key·waiting 승격엔 유효). fail-open.
- [ ] **Step 4: 통과 확인** + 기존 term 테스트(있으면). 
- [ ] **Step 5: 커밋** — `feat(term): persist PTY registry across restart (reachability survives marina-control restart)`.

---

## Task 5: 재시작 생존 실검증(3910)

- [ ] **Step 1:** 3910 기동(asdf 실데이터), 살아있는 세션이 reachable 인지 확인 → 3910 프로세스 재시작 → 재기동 후에도 같은 세션이 reachable(문신 유발 경로 사라짐) 확인. 결과를 `test-pty-persistence.sh` 의 e2e 섹션 or 리포트로.
- [ ] **Step 2:** 커밋(문서/e2e).

---

## 후속(별도 Plan 3)

- 모바일 큐 pending 에 tid/msg-id 저장 → tid-liveness 기반 auto-fail(문신 자동정리) + 탭 취소/재시도.
- 모바일 세션리스트/타임라인 reconcile 이주(Plan 1 프리미티브 재사용).
- 에이전트 질문 로버스트 surface(캡처 하드닝·리스트 마커·텍스트 폴백).

## Self-Review

- **Spec coverage:** Root2 의 (a)단일 resolver=Task1-3, (b)PTY영속화=Task4-5 커버. (c)큐 reconcile 은 Plan3 로 명시 분리(모바일 클라이언트).
- **Placeholder scan:** Task3 Step2 의 "거절 사유" 문구는 구체 명시. Task4 fd-less adopt 는 "streaming 불가·reachability 유효"로 범위 한정. 나머지 구체 코드/명령.
- **Type consistency:** `resolve_session_liveness(...)→{status,reachable,tid,reason}` 시그니처가 Task1/2/3 에서 동일.
