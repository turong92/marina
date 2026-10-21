# 코덱스 방 — 설계 (2026-10-21)

## 왜

형은 지금 Discord 방에서 Claude Code 세션만 굴린다. 코덱스(B 계정, `CODEX_HOME=~/.marina/accounts/codex-b`)도 같은 식으로 쓰고 싶다:
"chat-bot 카테고리 하나 파서 기본 세팅 해 줘. 상태 채널이랑 사용량도 만들어 주고", "클로드랑 완전 똑같은 거 할 거야".
Claude 사용량을 덜 쓰면서 같은 습관(방에 글 → 일함 → 답장, 쉬면 잠들고 글 쓰면 깨어남, #상태·숫자판으로 한눈에)을 코덱스로 옮기는 것이 목적이다.

## 범위

**1차(끝에서 끝까지 도는 최소판)** — chat-bot 카테고리 안의 코덱스 방 하나가:
1. 띄워진다(`marina session new <프로젝트> <작업> --codex`, 워크트리 + 채널 + tmux codex).
2. Discord 글을 받아 일한다(떠 있으면 입력창에 넣고, 꺼져 있으면 깨우면서 첫 지시로).
3. Discord 로 답한다(reply·react·edit_message·fetch_messages·download_attachment).
4. 진행 표시(👀·도구 이모지·🛑)·정지·쉬면 내리기·안전 재시작이 Claude 방과 같은 규칙으로 돈다.
5. chat-bot 카테고리에 자기 #상태 채널, 코덱스 사용량 숫자판이 생긴다.

**비목표(이번에 안 함)**
- 질문 버튼(코덱스에 AskUserQuestion 대응 없음 — `request_user_input` 미완성). 권한 버튼(승인 정책 never 로 띄운다).
- Discord 슬래시(/compact·/model·/effort)·추천 버튼·`/account` 전환·`--remote-control`(앱에서 붙기).
- 대화방(chat) 종류 코덱스 방 — 코덱스엔 `--restricted`·`--tools` 허용 목록 같은 가두기 수단이 없다.
- 백그라운드 셸·서브에이전트 목록(#상태 [보기]) — 코덱스 쪽 기록 형식이 다르다.
- 클로드 방 코드 복제. 엔진별로 다른 부분만 분기한다.

**다음에 넓힐 것**: 번호 글 질문(작업 덩어리 8) · 새 작업 버튼/로비에서 코덱스 방 열기 · `/account` 로 코덱스 계정 전환 · 코덱스 /compact 슬래시 · [보기] · 대화방 종류.

## 누가 정했나

| 결정 | 출처 |
|---|---|
| 코덱스 방을 만든다, chat-bot 카테고리 하나, 상태 채널·사용량 | **형** |
| 클로드 방과 같은 동작 | **형** |
| 계정 = `CODEX_HOME` 폴더(auth.json 만 제 것, 나머지는 `~/.codex` 링크, `codex-link.sh`) | **형** |
| 새 kind `codex` — 방 기록·상태 폴더·tmux·Discord 인프라는 그대로, 엔진별 구현만 분기 | 지휘 |
| 순서: 한 방 왕복 → 깨우기·재우기·상태 → 카테고리별 상태·숫자판 | 지휘 |
| 첫 방은 chat-bot 카테고리, 레포 폴더를 잡고 개발 방처럼 | 지휘 |
| 사용량 = rollout 의 `rate_limits`, 창은 오는 대로(`window_minutes` 로 이름), `resets_at` 지나면 0% | 지휘 |
| 아웃바운드는 공식 플러그인(server.ts) 대신 marina MCP 에 REST 도구 5개 — 게이트웨이 중복 방지 | 지휘(조사 추천) |
| 인바운드는 `wake()` 의 "alive" 분기에서 코덱스 방이면 입력창에 넣는다 — bot.ts 무변경 | 지휘(조사 추천) |
| 코덱스 전용 코드는 새 discord 모듈 `marina_codex.py` 하나에(DISCORD_MODULES 등록) | 기획 |
| 코덱스 방 설정은 `discord.json` 최상위 `codex` 한 곳: `{"category":"chat-bot","categoryId":…,"account":"b"}` | 기획 |
| `reply_to` 기본값 채우기는 훅이 아니라 우리 reply 도구 안에서(도구가 우리 것이라 훅이 필요 없다) | 기획 |
| "답 못 한 지시" 판정은 rollout 파싱 대신 reply 도구가 남기는 `replied.json` 으로 | 기획 |
| 전역 #상태·숫자판은 클로드 방만, 코덱스 방은 chat-bot 의 #상태·코덱스 숫자판에만 | 기획 |
| 승인 정책은 방에서 `-a never` 로 고정(방엔 승인 버튼이 없어 창이 뜨면 영영 멈춘다). 샌드박스는 전역 설정 그대로 | 기획 — 형 확인 필요(정해야 할 것 3) |

## 구조 — kind `codex` 분기 지점

방 기록(`sessions.json`)에 `"kind":"codex"`, `"codexAccount":"b"`, `"sessionId"`(사후 확보), `"rollout"`(경로 캐시)를 더한다. `CHAT_KINDS` 에는 넣지 않는다(개발 방 규칙을 따른다).

| 파일:함수 | 코덱스 분기 |
|---|---|
| `marina_codex.py`(새) | `codex_argv`·`codex_env`·rollout 읽기(찾기·턴 상태·ctx·받은 지시·rate_limits)·입력 넣기·REST 도구 5개·훅 진입점 |
| `marina_session.py:cmd_new`(3900)·`preflight`(2922) | `--codex` 면 `which codex`·계정 폴더(auth.json) 확인, 카테고리 = `ensure_codex_category`, 채널 겹침은 chat-bot 카테고리에서 |
| `marina_session.py:session_launch`(712)·`cmd_start`(4015) | 코덱스면 `codex_argv(rec, resume, first)` — `--session-id` 가 없으니 sid 가 있으면 `codex resume <sid> [first]`, 없으면 새로 |
| `marina_session.py:session_env`(1904)·`tmux_start`(729) | 코덱스면 `CODEX_HOME` 을 넣고 Claude 토큰 셸 래핑은 하지 않음. `account-running` 에 코덱스 계정 이름 |
| `marina_session.py:write_settings`(1602) | 코덱스면 settings.json 대신 훅·MCP 를 argv 의 `-c` 로(스파이크 S4·S6 결과에 따라) |
| `marina_session.py:inbound_messages`(2013)·`hook_stop`(2478)·`_hook_activity_locked`(2738) | 기록이 rollout 이면 `marina_codex.inbound_ids` 로. 코덱스 훅은 `DISCORD_STATE_DIR` 로만 방을 찾는다(cwd 짐작 금지) |
| `marina_session.py:nudge_unanswered`(1446)·`resume_unanswered`(1477) | 코덱스면 `replied.json` 기준 |
| `marina_session.py:mcp_chat`(3751)·`chat_tools_for`(3745) | 코덱스 방이면 Discord 도구 5개를 더한다 |
| `marina_discord_wake.py:wake`(190) | tmux 가 살아 있고 코덱스 방이면 `"alive"` 대신 `marina_codex.deliver(rec, …)` |
| `marina_discord_bot.py:_session_transcript`(857) | 코덱스면 rollout 경로 |
| `marina_discord_bot.py:_pane_busy`(167)·`_ctx_percent`(182)·`_turn_in_progress`(2296)·`interrupt`(975) | 코덱스면 rollout 턴 상태·`agent_usage_from_path(…,"codex")`·Esc |
| `marina_discord_bot.py:snapshot`(425)·`dashboard_tick`(740)·`meter_tick`(790) | "판(board)" 단위로: 전역 판(클로드 방, 클로드 사용량)·코덱스 판(코덱스 방, rate_limits, chat-bot 카테고리 안 #상태) |
| `marina_discord_idle.py:_verdict`(114) | 입력창 비었나·선택 창 판정을 코덱스 화면 모양으로 |
| `marina_discord_usage.py:context_percent`(450) | `source` 인자 추가(기본 "claude") |

Claude 판정기(백그라운드 셸·에이전트·cron·Monitor)는 rollout 을 먹여도 빈 결과가 나온다 — 그대로 두되 테스트로 고정한다.

## 동작 규칙

### 1. 띄우기
- `codex_argv` = `codex [resume <sid>] -C <root> -a never -c check_for_update_on_startup=false -c <신뢰> -c <MCP> -c <시스템 프롬프트> [-c <훅>] [첫 지시]`. 정확한 키는 스파이크 S1·S4·S5·S6 값으로 확정한다.
- 시스템 프롬프트 = `CHANNEL_RULES`(30행대)와 같은 뜻의 코덱스판: "답은 `mcp__marina__reply` 로, chat_id 는 받은 태그의 것".
- 띄운 뒤 `tmux_start` 의 생존 확인에 더해, 업데이트·신뢰 창 같은 막는 화면이 남아 있으면(S1 에서 문구 확보) 실패로 올린다 — 조용히 입력을 삼키는 방을 만들지 않는다.
- env: `clean_env_prefix` 화이트리스트 + `DISCORD_STATE_DIR`·`MARINA_HOME`·`CODEX_HOME=~/.marina/accounts/codex-<계정>`.

### 2. 인바운드(떠 있을 때)
- 봇은 지금처럼 모든 글에 `wake` 를 부른다. 코덱스 방이 살아 있으면 방 잠금(`room_lock`) 안에서 `missed()`(118)로 아직 안 넣은 글을 모아 `wake_prompt`(152)와 같은 `<channel …>` 태그 글로 만든다 — 태그가 같아야 `seen_ids`·진행 훅이 그대로 돈다.
- 넣기: 붙여넣기(스파이크 S3 에서 고른 방식 — `paste-buffer -p` 우선) → 0.6초 → Enter. 바쁘면 Enter = steer(지금 턴에 끼워 넣기, Claude 방이 턴 중 받은 글을 바로 읽는 것과 같다).
- **전달 확인 필수**(입력 유실 사고 이력, `marina_mobile.py:1828` 주석): rollout 이 넣기 전 크기 뒤로 그 글의 `message_id` 를 담을 때까지 최대 8초. 입력창에 글이 남아 있으면 Enter 를 다시(최대 3번, `run_slash` 2640 과 같은 규칙). 끝내 안 보이면 마지막 글에 ⚠️ 반응 + 로그, `delivered` 에 안 적는다 → 다음 글이 올 때 같이 다시 간다.
- 같은 글 두 번 넣기 금지: 방 잠금 + `woke.json.delivered` + rollout 의 `seen_ids`.

### 3. 아웃바운드 MCP(marina MCP 에 더하는 도구 5개)
공식 플러그인의 안전장치(server.ts 139·405·419·605~)를 그대로 옮긴다:
- 채널 문지기: `chat_id`(스레드면 부모)가 이 방 `access.json.groups` 에 있어야 한다.
- 첨부: 파일당 25MB, 10개까지, 상태 폴더 안 파일은 거부(inbox 제외, realpath 비교).
- 2000자 나눠 보내기, `reply_to` 는 첫 조각에만, 멘션 알림 없음(`allowed_mentions.parse=[]`).
- `reply_to` 가 비면 이 방의 마지막 받은 지시로 채운다(`hook_reply_to` 1184 와 같은 효과).
- 보낸 뒤 `replied.json = {"mid": <답한 지시>, "at": …}` — 턴 끝 "답 못 한 지시" 판정이 이걸 본다.
- download_attachment 는 `<상태 폴더>/inbox` 에, 25MB 상한, 파일 이름 정리(`safeAttName`).
- 봇 토큰은 방 `.env` 링크(`write_state_dir` 1035)의 것 — 방마다 다른 봇 규칙이 그대로 산다.

### 4. 훅
- 쓰는 훅: SessionStart(sid 확보) · UserPromptSubmit(turn-at·👀) · PreToolUse(도구 이모지·입력 중, Bash rm 가드) · Stop(표시 떼기·stopped-at·답 못 한 지시 재촉).
- **방 밖에선 아무것도 안 한다**: `DISCORD_STATE_DIR` 가 없거나 그 상태 폴더의 기록이 `kind=codex` 가 아니면 즉시 0 으로 끝낸다. 코덱스 훅에서는 `_hook_target`(2124)의 cwd 짐작을 절대 쓰지 않는다 — 데스크톱 코덱스가 클로드 방 워크트리에서 돌 때 그 방 표시를 건드리게 된다.
- 등록 방식은 S6 결과로: ① `-c` 로 훅을 넣고 `--dangerously-bypass-hook-trust`(이 실행만, 전역 파일 무변경) — 추천 ② 안 되면 전역 `~/.codex/hooks.json` 에 추가 + `/hooks` 에서 한 번 신뢰 — 형 허락 필요(정해야 할 것 4).
- 훅 실패는 코덱스를 막지 않는다(`|| true`). 훅은 표시용이라 무거운 일은 떼어 낸 프로세스로(`hook-typing` 4337 과 같은 방식).

### 5. 세션 id
- 코덱스는 미리 정할 수 없다. SessionStart 훅 payload 의 sid 를 `_record_session_id`(2070)로 적는다.
- 훅이 없거나 놓쳤으면 띄운 뒤 30초 안에 rollout 을 찾는다: 띄운 시각 이후 만들어진 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 중 `session_meta.cwd == root` 이고 다른 방 기록에 없는 것 하나. 둘 이상이면 안 정한다(짐작 금지 — `adopt_live_session_id` 2086 과 같은 문턱).
- `/new` 로 갈아타면 SessionStart 가 새 sid 를 주므로 그때 기록을 바꾼다. rollout 경로는 `rollout` 칸에 캐시하고, 파일이 없어지면 sid 로 다시 찾는다.

### 6. 상태 판정
- 바쁨 = rollout 의 마지막 `task_started` 뒤에 `task_complete`·`turn_aborted` 가 없고 마지막 줄이 30분 안. 화면 판정(S2 의 작업 중 줄)은 보조 — 둘 중 하나라도 바쁨이면 바쁨.
- ctx = `agent_usage_from_path(rollout, "codex")["contextPercent"]`.
- 정지(🛑·[정지]) = Esc. Esc 로 끝난 턴에 Stop 훅이 오는지는 S9 로 확인하고, 안 오면 `interrupt` 가 지금처럼 직접 정리한다.
- 쉬면 내리기·안전 재시작 = `_verdict`·`restart_blockers` 를 그대로 쓰되 입력창·선택 창 모양만 코덱스 것으로.

### 7. 카테고리별 #상태·숫자판
- "판" = (상태 저장 키, 상위 카테고리, 방 거르개, 사용량 공급자). 전역 판 = (`dashboard`, 없음, 코덱스 아님, 클로드). 코덱스 판 = (`codexDashboard`, chat-bot 카테고리, kind=codex, 코덱스 rate_limits). `render`(564)는 그대로 쓴다.
- 코덱스 #상태는 chat-bot 카테고리 안에 `_owner_channel` 과 같은 권한(형·봇만 보기, 쓰기 금지)으로. 카테고리 안에 숫자판(빈 카테고리)은 못 넣으므로 숫자판은 최상위 빈 카테고리 `📊 코덱스 주간 N%`.
- 이름 바꾸기 10분 2회 제한·지워지면 다시 만들기 규칙은 `meter_tick` 그대로.

### 8. 사용량(rate_limits)
- 공급자 = 이 계정으로 뜬 코덱스 방들의 rollout(기록의 `rollout`/sid) 중 가장 최근 `token_count.rate_limits`. `~/.codex/sessions` 는 계정끼리 공유라 다른 계정(데스크톱 무료 계정) rollout 은 절대 섞지 않는다.
- `primary`·`secondary` 중 있는 것마다 창 하나. 이름: 300분 = "5시간", 10080분 = "주간", 그 밖 = "N시간"/"N일". `resets_at` 이 지났으면 0%·리셋 시각 없음. 60초 캐시.
- 턴이 끝나야 갱신되므로(조사) 값이 낡을 수 있다 — #상태 줄에 마지막 갱신 시각을 붙이지는 않는다(1차는 숫자만).

## 위험·미확인 → 첫 작업(스파이크)에서 실측으로 닫는다

| # | 미확인 | 닫는 실측 | 실패 시 대안 |
|---|---|---|---|
| S1 | 업데이트 창("Press enter to continue")·폴더 신뢰 창·기타 첫 화면 | 새 폴더에서 `-c check_for_update_on_startup=false`·`-c projects."<dir>".trust_level="trusted"` 유무로 화면 캡처 | 알려진 문구면 Enter 한 번 보내는 대기 루프 |
| S2 | 입력창 기호·흐린 안내문·작업 중 줄·선택 창 모양 | 쉴 때/일할 때/Esc 뒤 `capture-pane -e` 저장 | — (정규식을 여기서 정한다) |
| S3 | 여러 줄 글이 한 메시지로 들어가나, steer/queue 기록 모양 | `send-keys -l`+Enter vs `paste-buffer -p`+Enter, 바쁠 때 Enter/Tab | 줄바꿈을 공백으로 접기 |
| S4 | `-c mcp_servers.marina={…}` 주입·도구 이름·env 전달·rollout 기록 모양 | 장난감 MCP 로 호출시켜 rollout·서버 env 덤프 | 인자로 상태 폴더 넘기기 |
| S5 | 시스템 프롬프트 키(`developer_instructions`?) | 비밀 단어 되말하기 | 첫 지시 앞에 규칙을 붙이기 |
| S6 | `-c` 로 훅 정의 가능? `--dangerously-bypass-hook-trust` 동작, 훅 stdin 필드, 훅이 env 를 물려받나 | 덤프 훅으로 SessionStart·UserPromptSubmit·PreToolUse·Stop payload 저장 | 전역 hooks.json(형 허락) 또는 `-c notify=[…]` 를 Stop 대용 |
| S7 | sid 확보·`codex resume <sid> "<글>"`·`resume --last` 의 폴더 거르기·`/new` | 훅 sid 와 rollout 파일 이름 대조 | rollout 탐색만으로 |
| S8 | B 계정 rate_limits 모양 | 한 턴 뒤 token_count 줄 | — |
| S9 | Esc 시 `turn_aborted`·Stop 훅 | Esc 후 rollout·훅 덤프 | `interrupt` 가 직접 정리 |

스파이크는 전역 파일(`~/.codex/config.toml`·`hooks.json`)을 고치지 않는다. 계정 폴더 `codex-b` 를 그대로 쓰고(auth.json 을 복사하면 토큰 갱신으로 원본이 무효가 될 수 있다), 결과는 이 문서 아래 "실측 결과"에 채우고 위 규칙의 미정 값을 고친다.

## 실측 결과

(스파이크가 채운다 — S1~S9 각각: 명령, 관찰, 정한 값)

## 검증

- 테스트는 `plugin/tests` 기존 방식: `lib/harness.sh`(MARINA_HOME 격리) + `lib/session_fixture.sh`(전용 tmux 소켓·가짜 CLI) + `lib/fake_discord.py`. 가짜 `codex` 는 픽스처의 가짜 claude 처럼 argv·env 를 남기고, 입력 시험용은 받은 줄을 가짜 rollout 에 user 메시지로 적는 작은 스크립트.
- `CODEX_HOME`·`~/.codex/sessions` 는 테스트에서 임시 경로로(`MARINA_CODEX_SESSIONS` 같은 재정의 변수) — 실 rollout·실 계정을 읽지 않는다(2026-10-06 실 Claude 홈 사고).
- 클로드 회귀: 손대는 함수가 걸린 기존 테스트(test-session-new·test-discord-wake·test-discord-bot·test-discord-usage·test-discord-idle·test-session-activity·test-discord-boundary)를 해당 작업에서 돌린다.
- 실기: chat-bot 카테고리에 실제 방 하나 — 글 왕복, 바쁠 때 끼워 넣기, 🛑, 쉬게 내린 뒤 글로 깨우기, #상태·숫자판 값이 rollout 과 일치. `qa` 가 Discord 화면과 tmux 화면으로 확인.

## 형 결정 (2026-10-21, Discord 버튼)
1. 방 종류: **개발 방**(워크트리를 만들고 모든 도구).
2. 첫 방 레포: **story-chat** — `~/IdeaProjects/crabs/story-chat` (github crabs-ai/story-chat, 10/21 clone). marina 프로젝트로 등록해 쓴다.
3. 실행 권한: **전역 설정 그대로**.
4. 방 전용 훅 주입이 안 되면 **전역 `~/.codex/hooks.json` 에 marina 훅을 넣고 한 번 신뢰**(신뢰는 형이 /hooks 에서 — ask_terminal 로 넘김).
5. 형 질문 "두 벌로 운영해야 돼? 래퍼로 하나로 싸야 하는 거 아냐?" → 한 벌. 방·채널·깨우기·재우기·진행 줄·상태 채널은 공통, 엔진별로 갈라지는 건 띄우기·입력 넣기·바쁨 읽기 등 좁은 지점만(래퍼). 이 원칙을 지킨다.
