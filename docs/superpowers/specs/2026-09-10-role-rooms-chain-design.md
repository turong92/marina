# 역할 방과 묶음 — 방 사이 자동 연결 (첫 버전: 리뷰어)

작성 2026-09-10 · 상태: 설계 확정(형 승인, 섹션별) · 구현 전

## 1. 왜

형은 "클로드 구현 / 코덱스 리뷰"로 일해 왔다. 두 방 사이에서 형이 복붙하는 중계기였고, 지금은 코덱스 결제가
없어 그 흐름 자체가 끊겼다. 헤르메스식 발상(에이전트에 규칙·도구·스킬 층을 입힘)을 마리나에 옮기되, 엔진은
클로드 그대로 두고 **마리나가 방마다 다른 하네스를 입히고 방끼리 잇는다.**

리뷰어는 예시다. 개념은 한 단계 위다:

> **역할(하네스)을 입힌 방** + **방 사이 자동 연결**(언제 보내고 → 무엇을 하고 → 결과가 어디로 돌아가나)

리뷰어·에러 분석·테스트 설계·스킬 뽑기(헤르메스의 "스스로 스킬 만들기")가 같은 틀에 들어간다.

## 2. 결정 요약 (형 승인)

| 항목 | 결정 |
|---|---|
| 결과 처리 | 구현 방이 **바로 반영** (형 게이트 없음) |
| 리뷰 트리거 | **커밋** + 형이 부를 때(폰 버튼 · "리뷰해줘" → 구현 에이전트가 명령) |
| mdc | 처음엔 **안 켠다.** marina·homeserver 에서 써보고, mdc 기존 `code-reviewer` 와 한 변경을 나란히 비교해 정한다 |
| 역할이 코드를 고치나 | 첫 버전은 **아니다** — 읽고 글로 돌려주는 역할만. 코드는 늘 구현 방 하나가 고친다 |
| 역할 방 수명 | **한 왕복 묶음** 동안만(리뷰→반영→재리뷰). 묶음이 끝나면 끈다 |
| 묶음 길이 | 기본 **2바퀴**. 형이 "쭉 진행해"면 **무제한** — 같은 지적이 두 바퀴 연속이면 그 지적만 **보류**하고 계속 |
| 굴리는 주체 | **마리나가 지휘**(트리거·바퀴 수·끝내기가 마리나 코드에). 역할→구현 전달은 네이티브 세션간 메시징 |
| 배포 | 구현이 끝나도 형 허락 전엔 배포하지 않는다 |

## 3. 범위

**첫 버전에 있다:** 역할 정의 로더 · 기본 역할 `reviewer` · 역할 방 띄우기 · 묶음 장부와 상태기계 · 커밋/버튼/명령
트리거 · 구현 방 지시문 한 줄 · 폰 화면(흐름 줄·고정 줄·요약·배지·딸린 줄·메뉴) · 선행 수정(4.4).

**첫 버전에 없다:** 코드를 고치는 역할 · 역할 방 별도 워크트리 · mdc 연동(`AGENTS.local.md` 경로 지정) · 코덱스
역할 · 역할·연결 편집 UI(설정은 `projects.json` 손편집) · 웹 대시보드 화면(데이터는 같이 쓰게 둔다).

## 4. 역할 정의

### 4.1 역할 = 에이전트 정의 파일 한 장

새 형식을 만들지 않는다. Claude 서브에이전트 파일(`name`·`description`·`tools`·`model` 프론트매터 + 본문)을 쓴다.

찾는 순서(먼저 찾은 것이 이긴다):
1. 프로젝트 `<root>/.claude/agents/<역할>.md`
2. 사용자 `~/.claude/agents/<역할>.md`
3. 마리나 기본 `plugin/roles/<역할>.md` — 첫 버전 `reviewer.md` 하나, 기본 모델 `claude-sonnet-5`

### 4.2 방에 입히는 규칙

| 정의 | CLI | 비고 |
|---|---|---|
| `model` | `--model <값>` | 없으면 생략(CLI 기본) |
| `tools` | `--allowedTools <쪼갠 값…>` | 쉼표로 쪼갠다. 마리나가 `ToolSearch`·`SendMessage` 를 **항상 추가**(실측: SendMessage 는 ToolSearch 로 불러와야 쓴다). `Edit`·`Write`·`NotebookEdit`·`MultiEdit` 은 빼고 로그에 경고 |
| 본문 | `--append-system-prompt <본문>` | |
| (항상) | `--permission-mode plan` | 읽기 전용 강제 |
| 첫 프롬프트 | **argv 맨 앞(`claude` 바로 뒤)** | `--allowedTools`·`--tools` 는 뒤따르는 값을 삼키는 가변 인자다 |

예:
```
claude "<첫 프롬프트>" --model claude-sonnet-5 --permission-mode plan \
  --allowedTools Read Grep Glob "Bash(git diff:*)" "Bash(git log:*)" ToolSearch SendMessage \
  --append-system-prompt "<정의 본문>"
```

### 4.3 연결 계약 (마리나가 첫 프롬프트에 늘 붙인다)

정의 본문과 별개로 마리나가 붙이는 문단. 역할이 무엇이든 같다.
- **검토 범위:** 저장소별 `base..HEAD` 커밋 + 커밋 안 한 변경(staged·unstaged). 저장소 목록과 SHA 를 명시한다
- **답장:** `SendMessage` 의 `to` 는 정확히 `uds:<구현 방 messagingSocketPath>` — 이름은 바뀐다(실측: `chat-fe`→`chat-fd`)
- **한 바퀴 = 한 메시지.** 지적이 없으면 마지막 줄에 정확히 `새 지적 없음`
- **보류:** (무제한일 때) 지난 바퀴와 같은 지적은 줄 머리를 `[보류]` 로
- **고치지 마라:** 파일을 바꾸지 않는다(plan 모드가 막지만 문장으로도)

### 4.4 선행 수정 — 가변 인자 뒤 프롬프트

`_agent_cli` 는 첫 프롬프트를 argv 맨 끝에 붙인다. `lean` 이 켜지고 모델·effort·resume 이 없으면
`['claude','--strict-mcp-config','--tools','Read','Write','첫 프롬프트']` 가 되어 프롬프트가 `--tools` 에 삼켜진다
(실측 argv). 지금은 `lean` 을 켠 프로젝트가 없어 잠복 중이지만, 역할 방은 같은 종류의 플래그를 쓴다.
**프롬프트를 `claude` 바로 뒤로 옮긴다**(resume 은 `--resume <sid>` 라 순서와 무관).

## 5. 묶음 장부

### 5.1 파일

`~/.marina/chains/<묶음ID>.json`. **구현 대화 하나 + 역할 하나**에 열린 묶음은 하나.

```json
{
  "id": "c-20260910-1832-reviewer-916b67c1",
  "role": "reviewer",
  "implementer": {"root": "/…/worktrees/chat", "source": "claude", "sid": "916b67c1-…",
                  "socket": "uds:/tmp/cc-socks/3741.sock"},
  "roleRoom": {"tid": "…", "sid": "…", "pid": 38984},
  "base":         {"marina": "cb675c6"},
  "reviewedHead": {"marina": "e04dc5f"},
  "round": 1, "maxRounds": 2, "unlimited": false,
  "state": "reviewing",
  "held": [],
  "rounds": [{"n": 1, "head": {"marina": "e04dc5f"}, "sentAt": 1788366193.5, "sentAnchor": 12540221,
              "resultAt": null, "findings": null, "noneLeft": null}],
  "createdAt": 1788366193.5, "updatedAt": 1788366193.5, "endedAt": null, "endedAnchor": null, "endedReason": null
}
```

`base`·`reviewedHead` 는 **저장소별 지도**다. 저장소 목록은 기존 규칙과 같다: 루트 + `compose_scoped_subrepos(root)`
중 `.git` 이 있는 것(homeserver 는 셋).

### 5.2 상태기계

```
(없음) ─ 트리거 ─→ reviewing            역할 방 띄움, 1바퀴 요청
reviewing ─ 역할 결과(노 지적) ─→ done   역할 방 끔
reviewing ─ 역할 결과(지적 있음) ─→ applying
applying ─ 구현 방 턴 끝 + HEAD 앞섬 ─┬─ round<max 또는 unlimited → round+1, 재리뷰 요청 → reviewing
                                    └─ 상한 도달 → done (남은 지적 수 기록)
applying ─ 구현 방 턴 끝 + HEAD 그대로 ─→ waiting
waiting ─ 구현 방 턴 끝 + HEAD 앞섬 ─→ (applying 과 같은 판정)
waiting ─ 30분 경과 ─→ done (역할 방 끔, endedReason="wait-timeout")
어느 상태든 ─ 멈추기 ─→ stopped (역할 방 끔)
```

- 전이는 **순수 함수** `next_state(chain, event) -> (chain, actions)` 로 둔다. 파일·프로세스·시계는 호출자가 다룬다(테스트 대상)
- `reviewing` 중 새 커밋: 새 묶음을 만들지 않고 다음 바퀴 범위에 합친다(`reviewedHead` 는 요청 시점 HEAD)

### 5.3 결과 읽기

**역할 방 자기 트랜스크립트**에서, 그 바퀴 요청 이후의 마지막 `SendMessage` tool_use 입력(`to` 가 구현 방 소켓)을
읽는다. 받는 쪽 기록은 수신자 상태에 따라 두 모양(isMeta user 행 / queued_command attachment)이지만 보내는
쪽 호출은 한 모양이다.
- `noneLeft` = 본문 마지막 비어있지 않은 줄이 정확히 `새 지적 없음`
- `findings` = `[CRITICAL]`·`[WARNING]`·`[SUGGESTION]` 머리 줄 수(없으면 비어있지 않은 문단 수로 대신)
- `held` 에 `[보류]` 로 시작하는 줄을 모은다(중복 제거)

역할 방이 턴을 끝냈는데 `SendMessage` 가 없으면: **한 번** 역할 방 PTY 에 "결과를 SendMessage 로 보내"를 넣는다.
다음 idle 에도 없으면 `done`, `endedReason="no-result"`.

### 5.4 무제한 · 멈추기

- 무제한: 폰 [끝까지] 토글, 또는 구현 에이전트가 `marina chain unlimited` → `unlimited: true`
- 멈추기: 폰 [멈추기] 또는 `marina chain stop` → 역할 방 끄고 `stopped`

### 5.5 경계

- **재리뷰 요청 전달:** 역할 방은 마리나가 띄운 PTY 라 **PTY 에 직접 입력**한다(마리나는 SendMessage 를 못 부른다)
- **데몬 재시작:** 재시작 뒤 PTY 는 detached 라 입력할 수 없다. 장부가 `reviewing`/`applying`/`waiting` 이고 역할 방
  PTY 에 입력이 필요해지면 **역할 방을 새로 띄우고 지난 바퀴 기록(지적 요약·보류)을 첫 프롬프트에 싣는다**
- **역할 방이 죽음:** 다음 필요 시점에 새로 띄운다(위와 같은 경로)
- **구현 방이 죽음:** 역할 결과 전달이 실패하면(SendMessage tool_result 실패) `done`, `endedReason="implementer-gone"`
- **30분 대기:** 방 수명을 "한 묶음"으로 지키기 위한 장치

## 6. 트리거

세 경로 모두 데몬의 `chain_trigger(root, source, sid, reason, force=False)` 로 모인다.

### 6.1 커밋 (자동)

```
구현 방 턴 끝 → Stop 훅: 저널 한 줄 + /api/events-poke (기존)
 → ChangeWatcher diff: 세션 status 가 바뀐 사건 {root, source, sid, status} (기존)
 → _on_events: is_primary_notifier 확인 **직후, 알림 필터 전에** chains.on_events(events, marks)   ← 추가
```
**"턴 끝"의 정의:** 직전 status 가 `working`/`blocked` 이고 지금 `idle`/`completed`/`waiting` 인 전이.
알림층의 `kind` 로 판정하지 않는다 — 실측(`marina_sessions.py:736-746`): 턴을 끝낸 Claude 세션은 idle_prompt 로
**`waiting`** 이 되는데 `diff_marks` 는 `idle`·`completed` 만 `kind:"idle"` 로 내고 `waiting` 은 `kind:"status"` 로 낸다.
`kind` 에 기대면 커밋 트리거가 영영 안 선다. 그래서 사건의 `status` 와 직전 스냅샷 marks 로 직접 판정한다.

`on_events` 는 "턴 끝" 사건마다:
1. sid 가 어떤 열린 묶음의 **역할 방**이면 → 결과 읽기(5.3)
2. 구현 방이면 → 그 프로젝트에 `roles.reviewer.on == "commit"` 인가 → 저장소별 HEAD 가 (열린 묶음이 있으면
   `reviewedHead`, 없으면 마지막으로 끝난 묶음의 `reviewedHead`, 둘 다 없으면 **처음 본 HEAD 를 기준으로 기록만** — `~/.marina/chains/_baseline/<source>-<sid>.json`)
   보다 앞섰나 → `chain_trigger`
- 무거운 일(git·프로세스 띄우기)은 감시 스레드를 막지 않게 **작업 스레드**에서 한다
- 주 데몬만(알림과 같은 규칙) — 데몬이 둘이면 리뷰어도 둘이 뜬다

### 6.2 폰 [리뷰 보내기]

`POST /mobile/api/chain/request {root, source, sid}` — 로그인·방 접근 검사(기존). `force=True`: HEAD 가 그대로여도
지금 상태(커밋 안 한 변경 포함)로 시작. `…/chain/unlimited`, `…/chain/stop` 도 같은 모양.

### 6.3 명령 `marina chain request|unlimited|stop`

- 구현 에이전트가 형 말("리뷰해줘"·"쭉 진행해"·"리뷰 멈춰")을 듣고 실행한다
- CLI → 데몬 **루프백 전용** `POST /api/chain` (로그인 없음 · `X-Forwarded-*` 있으면 403 · `events-poke` 와 같은 급)
- **호출자 확인:** CLI 가 자기 부모 프로세스를 따라 올라가 `~/.claude/sessions/<pid>.json` 을 가진 claude 프로세스를
  찾아 `{pid, sid, cwd}` 를 보낸다. 데몬은 그 pid 가 살아 있고 세션 파일의 sid 와 일치하며 `procStart` 가 맞고,
  sid 가 cwd 의 워크트리에 속할 때만 받는다 — 남의 방 대신 트리거하는 것을 막는다

### 6.4 구현 방 지시문 한 줄

역할을 켠 프로젝트의 세션에만 SessionStart 훅 `additionalContext` 에 덧붙인다:
> [marina] 이 방엔 리뷰어가 붙어 있다. 형이 리뷰를 부탁하면 `marina chain request`, 쭉 진행하라면
> `marina chain unlimited`, 멈추라면 `marina chain stop` 을 실행한다. 다른 세션이 보낸 리뷰 결과는 바로 반영하고
> 커밋한다. `[보류]` 로 시작하는 줄은 참고만 하고 반영하지 않는다.

### 6.5 켜는 곳

`~/.marina/projects.json` 프로젝트 항목:
```json
"roles": {"reviewer": {"on": "commit", "maxRounds": 2}}
```
`marina_registry.load_projects` 가 읽어 프로젝트 dict 에 싣는다. 첫 버전 기본값은 **없음**(꺼짐). marina·homeserver
에만 손으로 넣는다.

## 7. 폰 화면

목업: 스크래치패드 `chain-mock.png`(A 도는 중 · B 끝 · C 방 목록). 말풍선은 기존 공유 렌더러.

### 7.1 데이터

- `mobile_state` 세션마다 `chain`: `{id, role, state, round, maxRounds, unlimited, heldCount, roleModel}` (열린 묶음이
  없으면 가장 최근 끝난 묶음 10분까지만 — 요약 카드용)
- `agent_transcript` 타임라인에 **흐름 항목** `{kind:"chain", id, event, round, maxRounds, role, text}` 를 끼운다.
  묶음 사건은 트랜스크립트에 없으므로 위치를 따로 잡아야 하는데, **시각으로 맞추지 않는다** — 실측: 타임라인 항목
  47개 중 시각을 가진 것이 0개다. 대신 **구현 방 트랜스크립트 바이트 오프셋**으로 잡는다: 장부의 각 사건(요청·끝)에
  그 순간 구현 방 트랜스크립트 파일 크기 `anchor` 를 적고, 타임라인 항목 id 에 이미 들어 있는 오프셋
  (`claude:message:<offset>:<n>`)과 비교해 `anchor` 이하의 마지막 항목 **뒤에** 끼운다. 시계 어긋남이 없다
- 역할 방 세션은 방 목록 탭에서 `roleOf: {chainId, role, implementerSid}` 로 표시한다

### 7.2 화면 요소 (공유 렌더러 `chat-render.js` 에 둔다 — 웹도 같이 쓰게)

| 요소 | 모양 | 비고 |
|---|---|---|
| 흐름 줄 | 가운데 점선 알약 `🔁 리뷰 요청 · reviewer(Sonnet 5) 1/2` · `재리뷰 2/2` | `kind:"chain"` 렌더 |
| 요약 카드 | `✓ 리뷰 끝 · 2바퀴 · 반영 N · 보류 M` + 펼치면 보류 목록 | 끝 사건 렌더 |
| 입력창 위 고정 줄 | `리뷰 도는 중 · reviewer · 1/2바퀴 [끝까지] [멈추기]` | 모바일 호스트. 상태가 reviewing/applying/waiting 일 때만 |
| 방 카드 배지 | `🔁 리뷰 1/2` | 부제줄 배지 옆 |
| 딸린 줄 | 구현 대화 밑 `↳ 리뷰어 · Sonnet 5 · 읽기 전용 · 진행 중` | 역할 방은 대화 개수에 안 센다 · 묶음 끝나면 숨김 |
| ⋯ 메뉴 | 맨 위 `🔁 리뷰 보내기` | 역할이 켜진 프로젝트만 |

글자는 전부 이스케이프(역할 이름·모델·보류 문장은 남이 정한 글자다).

## 8. 실측 근거 (2026-09-10)

| 확인 | 결과 |
|---|---|
| 세션간 메시지 왕복(Haiku 실험 세션) | 수신자가 쉬던 중이면 스스로 깨어 처리, `pong` 회신 |
| 받는 쪽 기록 | 쉬던 중: isMeta user 행 / 작업 중: `queued_command` attachment(`origin.kind=peer`) |
| 처음 보내는 메시지 `to=uds:<소켓>` | 도착 |
| `--permission-mode plan` + `--allowedTools` 에서 `git log` | 실행됨 |
| plan 모드에서 `SendMessage` | 됨(ToolSearch 선행) |
| 세션 파일 | `name`(바뀐다)·`messagingSocketPath`·`status`·`procStart` |
| 커밋 감지 재료 | Stop 훅→저널+즉시 poke, 감시층 `kind:"idle"` 사건, `marina_git` HEAD 조회 |
| mdc `code-reviewer` | 구현 방 안 서브에이전트(sonnet·읽기전용), 완료 보고 전 필수. `HARNESS-EXECUTION.md` 는 "승인된 독립 reviewer 경로" 허용 |

## 9. 보안

- 역할 방은 `plan` + 편집 도구 제외 — 파일을 못 바꾼다
- `/api/chain` 은 루프백 전용 + 포워딩 헤더 거부 + 호출자 프로세스 조상·sid·procStart·워크트리 소속 확인
- 폰 API 는 기존 로그인·방 접근 검사
- 역할 결과는 **구현 에이전트가 판단해 반영**한다 — Claude 하네스가 "동료 요청이지 사용자 승인이 아니다, 권한 상승
  금지"를 수신 메시지에 붙인다(실측 문구). 마리나는 그 문구를 지우지 않는다

## 10. 테스트

- 단위: 역할 정의 로더(찾는 순서·tools 쪼개기·편집 도구 제외·ToolSearch/SendMessage 추가) · argv 빌더(프롬프트 맨 앞,
  lean 포함) · 상태기계 `next_state` 전 전이 · 결과 파서(`새 지적 없음`·머리 줄 수·`[보류]`) · 저장소별 HEAD 비교 ·
  흐름 항목 시각 병합 · 호출자 확인(가짜 세션 파일·가짜 조상)
- 통합: 가짜 SHELL 로 역할 방 term_open → 장부 파일·argv 기록 확인(프롬프트가 argv 맨 앞, 메타에 프롬프트 없음)
- 렌더: 흐름 줄·요약 카드·배지·딸린 줄 마크업 + 이스케이프 · 390px 가로 넘침 0(헤드리스)
- 실측(수동, 배포 전 로컬): Haiku 로 역할 방 한 묶음 — 커밋 → 결과 도착 → 구현 방 반영 커밋 → 재리뷰 → done

## 11. 나중

- mdc: 같은 변경 하나에 기존 `code-reviewer` vs 리뷰어 방 비교 → 같거나 나으면 `AGENTS.local.md` 경로 지정안 검토
- 코드를 고치는 역할(동시 수정 방지: 구현 방 멈춤 또는 역할 방 워크트리)
- 코덱스 역할(결제 복구 뒤) · 역할·연결 편집 UI · 웹 대시보드 화면
- 헤르메스 체험(2주, 스킬 재사용 여부) 결과에 따라 "스킬 뽑기" 역할

## 12. 구현 순서

한 계획에 담되 단계마다 테스트가 초록이고 로컬 커밋이 되는 단위로 쪼갠다. 앞 단계가 뒤 단계의 토대다.

| 단계 | 내용 | 끝났다는 증거 |
|---|---|---|
| P0 | `_agent_cli` 첫 프롬프트를 argv 맨 앞으로(4.4) | lean+프롬프트 argv 테스트, 기존 term 테스트 |
| P1 | 역할 정의 로더 + 기본 `reviewer.md` + 역할 방 argv 빌더 + term_open 역할 하네스 인자 | 로더·빌더 단위, 가짜 SHELL 통합(메타에 프롬프트 없음) |
| P2 | `marina_chains.py` — 장부 파일·순수 상태기계·결과 파서·저장소별 HEAD | 전이 전부·파서·HEAD 비교 단위 |
| P3 | 트리거 — `_on_events` 연결(턴 끝 판정)·폰 API·루프백 `/api/chain`·`marina chain` CLI(호출자 확인)·SessionStart 한 줄·`projects.json roles` | 턴 끝 판정·호출자 확인·API 단위, 가짜 역할 방으로 한 바퀴 통합 |
| P4 | 폰 화면 — 흐름 항목 오프셋 병합·렌더러 요소·고정 줄·배지·딸린 줄·메뉴 | 렌더 단위(이스케이프), 390px 헤드리스 캡처 |
| P5 | 실측 한 묶음(Haiku, 로컬 데몬 재시작 **없이** 확인 가능한 범위) + 결과 보고 | 커밋→결과→반영→재리뷰→done 기록 |
