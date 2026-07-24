# claude·codex 세션을 marina 1급 시민으로 — 설계

날짜: 2026-07-23
브랜치: `chat`
관련 메모리: `marina-agent-events-mobile-chat`, `marina-codex-session-files`

## 한 줄 요약

marina 의 에이전트 세션 처리가 **Desktop 앱 세션 포맷**에 맞춰져 있어, 형이 실제로 쓰는
**Claude Code CLI 세션**과 **codex CLI 세션**을 1급으로 다루지 못한다. 그 결과 세 가지
증상이 한 뿌리에서 나온다 — (A) 워크트리 카드에 세션이 안 잡히고, (B) 모바일 채팅
타임라인이 무너지고, (C) 작업중/대기중 상태가 부정확하다. 이 셋을 claude·codex 대칭으로
바로잡는다.

## 배경 & 문제

### 공통 뿌리

marina 는 claude 세션을 `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`
(Desktop 앱이 남기는 세션 메타)에서만 찾는다(`marina_sessions.py:327`, `claude_agent_sessions`).
하지만 형이 CLI/터미널로 claude 를 열면 세션은 **Claude Code CLI 트랜스크립트**로만 존재한다:

```
~/.claude/projects/<슬러그>/<sid>.jsonl
  슬러그 = 워크트리 절대경로의 '/'·'.' → '-' 치환
  예) -Users-sumin-IdeaProjects-sumin-marina--claude-worktrees-chat
```

즉 marina 가 보는 소스와 세션이 실제로 사는 곳이 다르다. Desktop 세션을 안 쓰면
`local_*.json` 자체가 시스템에 없어(진단 시 no matches) claude 세션이 하나도 안 잡힌다.

codex 는 대조적으로 이미 `~/.codex/sessions/**/rollout-*.jsonl` 을 `session_meta.cwd` 로
스캔한다(`codex_agent_sessions`, `marina_sessions.py:574`) — **발견은 이미 잘 된다**. 이
비대칭이 문제의 절반이다.

### 세 증상과 진단 근거 (실측)

**증상 A — 워크트리 카드에 세션 안 잡힘.**
현재 이 세션(`chat` 워크트리, CLI 실행)이 카드에 안 뜬다. 카드 소스가 `local_*.json`
전용이라 CLI 트랜스크립트를 못 본다.

**증상 B — 모바일 채팅 타임라인 붕괴.**
형이 친 진짜 요청은 사라지고, 형이 안 친 메시지가 형 말풍선에 뜬다. 원인은 CLI
트랜스크립트에서 `type=user` 가 세 종류를 전부 포함하는데 marina 가 구분하지 못하는 것:

이 세션 rollout 실측 (`type=user` 34개):
```
len 42   | 야 최근에 마리나에서 …            ← 진짜 사용자 입력
len 0    | (빈 것 여러 개)                    ← tool_result 만 담은 user 라인
len 6991 | <task-notification>…              ← 백그라운드 이벤트가 user 로
```

codex rollout 실측 (role=user message):
```
len 2055 | # AGENTS.md instructions <INSTRUCTIONS>…   ← 주입된 지침 (매 턴 반복)
len 79   | https://www.onorca.dev/docs …              ← 진짜 사용자 입력
```

변환 지점 `_transcript_object_turns`(`marina_sessions.py:716`):
```python
if source == "claude":
    role = obj.get("type")            # type=user → tool_result·task-notification·주입 다 통과
    content = (obj.get("message") or {}).get("content")
else:  # codex
    if payload.get("type") != "message": return []   # message 만 — codex는 덜 샘
    role = payload.get("role")
if role not in ("user", "assistant"): return []       # isMeta·주입 구분이 전혀 없음
```
claude 는 `type` 만 보고 tool_result·`<task-notification>`·`<system-reminder>`·isMeta 합성을
하나도 안 거른다. codex 는 `message`-only 라 덜 새지만 `# AGENTS.md instructions` /
`<INSTRUCTIONS>` / `user_instructions` / `environment_context` 주입은 그대로 user turn 이 된다.

**증상 C — 작업중/대기중 부정확.**
`agent_status`(`marina_sessions.py:504`)가 rollout 마지막 이벤트를 파싱하고, 못 읽으면
mtime 120초 fallback 으로 **추측**한다. marina 가 프로세스를 소유하지 않아(Desktop agent 는
`sid=wrapper-1` 불일치, marina term 0개) 이 추측이 최선이었다.

## 목표 / 비목표

**목표**
1. claude·codex 세션이 실행 방식(CLI/터미널/모바일)과 무관하게 워크트리 카드에 잡힌다.
2. 모바일 채팅 타임라인이 **진짜 사용자 입력만** user 말풍선으로, 나머지(도구 결과·시스템
   주입·백그라운드 이벤트)는 제외하거나 접기 섹션으로 분리한다.
3. 작업중/대기중이 hook/notify **이벤트 push** 로 즉시·정확히 반영되고, rollout 로 보정된다.

**비목표 (YAGNI)**
- raw PTY 바이트를 채팅 말풍선으로 역파싱하지 않는다(터미널 에뮬레이터 재구현 불필요 —
  채팅 렌더 소스는 rollout, 터미널은 별도 미러).
- Desktop 앱 세션 지원을 제거하지 않는다(기존 `local_*.json` 경로는 유지, CLI 소스를 추가).
- 새 저장소/DB 도입 없음. 상태맵은 데몬 in-memory.

## 아키텍처 개요

세션의 세 가지 관심사를 독립 컴포넌트로 나눈다. 각 컴포넌트는 claude/codex 두 소스를
대칭으로 다루며, 명확한 경계(입력→출력)로 서로 독립 구현·검증 가능하다.

| | 컴포넌트 | 경계 (입력 → 출력) |
|---|---|---|
| A | 세션 발견 | 파일시스템 → `worktreePath/cwd → [세션]` |
| B | 타임라인 렌더 | rollout 라인 obj → `turns[{role,text,id}]` |
| C | 상태 신호 (기구현) | hook stdin(배선됨) → journal → `merge_agent_status`; **A 의 sid 정합성이 열쇠** |

## 컴포넌트 A — 세션 발견

**문제**: `claude_agent_sessions` 가 `local_*.json` 전용.

**변경 (claude 만)**: `claude_agent_sessions`(`marina_sessions.py:634`)에 CLI 트랜스크립트
소스를 추가한다 — **codex 와 완전 대칭**으로.
- claude CLI 트랜스크립트는 top-level `cwd` 필드를 담는다(실측: `cwd`,`sessionId`,`gitBranch`,
  `aiTitle`,`lastPrompt`). codex 의 `session_meta.cwd` 스캔과 똑같이,
  `CLAUDE_PROJECTS_DIR/**/*.jsonl` 을 훑어 각 파일 앞부분에서 첫 `cwd` 를 읽어 worktreePath 를
  **직접** 얻는다. 슬러그 역인코딩 불필요(cwd 가 진짜 경로).
- `sid` = 파일 stem(= 진짜 세션 id, 예 `43d8240a-…`). ← 이게 C 의 sid 정합성 열쇠.
- `title` = `aiTitle`/`lastPrompt` 라인 → 없으면 `repo_head_subject(root)` 폴백
  (`marina_sessions.py` 에 이미 있음). `ts` = 파일 mtime.
- `local_*.json`(Desktop) 결과와 **병합**하되, 같은 worktree 에 Desktop·CLI 둘 다 있으면
  **CLI 항목의 진짜 sid 를 우선**한다(Desktop 의 합성 `cliSessionId` 가 이벤트 조회를 깨지
  않도록 — 아래 C 의 sid 정합성 참조).

**codex**: 변경 없음 — `codex_agent_sessions`(`marina_sessions.py:663`)가 이미 rollout 스캔.
A 는 claude 를 codex 와 대칭 수준으로 끌어올리는 작업이다.

**경계**: 입력 = 파일시스템(두 소스), 출력 = `{worktreePath: [{source,title,ts,cliSessionId/sid}]}`.
소비자(`agents_payload`, 카드 렌더)는 인터페이스 불변.

## 컴포넌트 B — 타임라인 렌더

**문제**: `_transcript_object_turns` 가 `type=user`(claude)/`role=user`(codex)를 진짜 입력과
구분하지 못한다.

**변경**: user 라인을 **분류**해 세 부류로 나눈다.
1. **진짜 사용자 입력** → user turn (그대로 표시).
2. **도구 결과·백그라운드 이벤트·시스템 주입** → 타임라인에서 제외(옵션: 접기 섹션 메타로).
3. assistant/tool_use 등 → 기존 규칙 유지.

판별 규칙(소스별):
- **claude**: `obj.type == "user"` 라인에서
  - content 에 `tool_result` 블록만 있고 text 블록이 없으면 → 제외(도구 결과 반환).
  - text 가 `<task-notification>`, `<system-reminder>`(단독), 하네스 주입 마커로 시작하면 → 제외.
  - `obj.get("isMeta")` 가 truthy 면 → 제외(합성 재개 프롬프트 등).
  - 그 외 실제 text 블록 → user turn.
- **codex**: `payload.type == "message"` 且 `role == "user"` 에서
  - text 가 `# AGENTS.md instructions`, `<INSTRUCTIONS>`, `<user_instructions>`,
    `<environment_context>` 등 주입 래퍼로 시작/구성되면 → 제외.
  - 그 외 → user turn.

**구현 위치**: `_transcript_object_turns`(정밀 분류는 여기), 필요 시 헬퍼
`_is_injected_user(obj, source)` 분리. 프론트(`marina_mobile.py` 타임라인 렌더 ~1215/1229)는
서버가 정제된 turn 을 주면 추가 필터 불필요 — 서버를 단일 진실원으로 둔다.

**경계**: 입력 = rollout 라인 obj + source, 출력 = `turns[{role,text,id}]`(정제됨).
이 변경은 **디버깅 성격**이므로 구현 단계에서 systematic-debugging + 실제 rollout 픽스처로
검증한다(아래 테스트 전략).

## 컴포넌트 C — 상태 신호 (이미 구현됨 · sid 정합성만 남음)

**정정(2026-07-23 재진단)**: 최초 스펙은 stale main 체크아웃 기준이라 C 를 "신규 구축"으로
잡았으나, **chat 브랜치엔 이벤트 파이프라인이 이미 완성돼 있다.** 신규 작업은 없고, **A 로
sid 정합성을 확보하면 자동으로 작동**한다.

**이미 있는 것 (chat 브랜치)**
- `marina_agent_events.py`: `record_hook_event`(쓰기), `latest_agent_event`(읽기). 파일
  `~/.marina/agent-events/<source>/<sid>.jsonl`. `HOOK_EVENTS = {"UserPromptSubmit":"working",
  "Stop":"ended"}`, `BLOCKED_REASONS`, `_VALID_EVENTS={working,blocked,ended,failed}`.
- `hooks.json`(claude: `UserPromptSubmit`,`Notification`,`Stop`) + `codex-hooks.json`
  (codex: `PermissionRequest`,`PostToolUse` 추가) → 전부 `marina-agent-event-hook.sh` 로 라우팅.
  hook 은 stdin 을 `marina_agent_events.py` 에 파이프.
- `agent_status`(`marina_sessions.py:617`) → `merge_agent_status`(584): native(rollout 턴경계)
  + event 병합, `event_ts >= native_ts` 일 때 event 우선(`EVENT_TO_STATUS`). `terminal_active`
  면 `completed → waiting` 승격(PTY 살아있음 = 다음 프롬프트 대기).

**진짜 문제 — sid 정합성**
- `sid` 는 hook stdin 의 `session_id`/`thread_id` 에서만 온다(`marina_agent_events.py:51`,
  폴백 없음). `wrapper-1` 은 **코드에 없다** — 테스트 픽스처(`test-agent-events.sh:685`)일 뿐.
- 실제 `wrapper-1.jsonl` 이 생긴 건 **상위 런처(Desktop wrapper)가 합성 `session_id="wrapper-1"`
  을 hook stdin 에 넣어서**다. 반면 카드는 Desktop `local_*.json` 의 `cliSessionId` 로,
  `latest_agent_event` 는 **sid+root 정확 매칭**(`marina_agent_events.py:460`)으로 조회한다 →
  진짜 sid(`43d8240a-…`)로 쓰인 이벤트를 못 찾아 상태가 rollout 폴백에 머문다.

**해결 = A 에 종속**
- A 가 CLI 트랜스크립트로 세션을 발견하면 sid = **파일명(진짜 sid)**. 카드가 그 진짜 sid 로
  `latest_agent_event` 를 조회 → 진짜 sid 이벤트와 매칭 → C 자동 작동, wrapper-1 우회.
- 따라서 C 의 코드 변경은 **최소/없음**. A 의 병합 규칙(진짜 sid 우선)이 정합성을 만든다.
  검증 위주(아래 테스트 전략).

**PTY 소유(부가)**: claude/codex 둘 다 `term_open` agent-attach(`--resume`)가 이미 있고
(`marina_term.py` `_AGENT_CLIS`), `mobile_send` 가 `term_input` 으로 입력 주입
(`marina_mobile.py`). 소유는 **필수 아님** — 형이 CLI 로 열어도 A(발견)+C(상태)로 충분.
"폰에서 답장 넣기" 부가 기능으로만 남긴다.

**경계**: 입력 = hook stdin(이미 배선됨), 출력 = 상태맵/journal → `merge_agent_status` 응답.

## 데이터 흐름 (통합)

```
[발견]  FS(projects/*.jsonl + local_*.json + codex rollout) ─▶ claude/codex_agent_sessions
                                                              ─▶ agents_payload ─▶ 워크트리 카드

[렌더]  rollout 라인 ─▶ _transcript_object_turns(정제) ─▶ turns ─▶ 모바일 타임라인 말풍선

[상태·기구현]  claude hooks(UserPromptSubmit/Stop/Notification) ┐
               codex-hooks(PermissionRequest/PostToolUse)      ├▶ marina-agent-event-hook.sh
                                                               ┘   ▶ agent-events/<source>/<진짜 sid>.jsonl
               native(rollout 턴경계) ──┬─▶ merge_agent_status ─▶ 카드/모바일 배지
               latest_agent_event ──────┘   (★ A 가 진짜 sid 를 공급해야 매칭)

[소유·부가]  term_open(agent-attach --resume) ─ 소유 ─ term_input(모바일 입력 주입)
```

## 테스트 전략

- **A**: CLI 트랜스크립트의 `cwd` → worktreePath 매핑 유닛(가짜 `projects/<slug>/<sid>.jsonl`
  픽스처, `test-agents-section.sh` 의 `write_transcript` 헬퍼 재사용). `local_*.json` 부재
  환경에서 CLI 세션이 **진짜 sid** 로 잡히는지. Desktop+CLI 병합 시 진짜 sid 우선.
- **B**: claude/codex 실 rollout 픽스처를 리포에 넣고, `_transcript_object_turns` 가
  진짜 입력만 통과·주입/도구결과/이벤트는 제외하는지 골든 테스트. 이 세션·codex onorca
  세션을 축약해 픽스처화.
- **C**: A 가 공급한 **진짜 sid** 로 `latest_agent_event` 가 매칭돼 `merge_agent_status` 가
  working/ended 를 반영하는지(sid 정합성 회귀). 파이프라인 자체(record/read/hook)는 기존
  `test-agent-events.sh` 가 이미 커버 — 여기선 발견↔이벤트 조인만 검증.
- **e2e**: 형이 marina 터미널/CLI 에서 claude·codex 실행 → 카드에 잡힘 → 모바일 타임라인이
  깨끗함 → 턴 돌리면 작업중, 끝나면 대기중. Aside 로 모바일 뷰 실측(:3901 프리뷰).

## 전제 & 운영 (코드 아님)

- 형이 Desktop local agent(합성 sid 주입) 대신 CLI/marina 터미널 탭으로 claude·codex 를
  실행한다 — 그래야 hook 에 진짜 `session_id` 가 전달돼 A↔C sid 정합성이 성립한다.
- Codex 협업: 구현은 내가 직접(Edit/Write), codex 리뷰는 **토큰 여유 시**(현재 소진) —
  당분간 리뷰 없이 진행 후 형 검토(형 지시 `marina-claude-implements-codex-reviews`).

## 구현 순서 (제안)

**A 가 마스터키** — CLI 발견이 진짜 sid 를 공급하면 카드 노출(A)과 상태 정합성(C)이 동시에
풀린다. 따라서: **A(발견·sid 정합성) → B(렌더 필터) → C(검증만)**. A 직후 이 세션으로 e2e
검증(카드에 뜸 + 상태 working/ended 반영), 이어 B 로 타임라인 정제. C 는 신규 코드가 거의
없어 A 의 회귀 테스트에 흡수된다. 각 컴포넌트 별도 커밋, `chat` 누적 후 형 검토 → 한 번에 push.
