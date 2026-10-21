# 코덱스 방 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** chat-bot 카테고리의 코덱스 방이 클로드 방처럼 Discord 글을 받아 일하고 답하며, 자기 #상태·사용량 숫자판을 갖는다.

**Architecture:** 방 기록에 `kind:"codex"` 를 더하고, 코덱스 전용 코드는 새 discord 모듈 `plugin-discord/scripts/marina_codex.py` 하나에 둔다. 기존 함수는 몇 군데에서 `is_codex(rec)` 로 그 모듈을 부르기만 한다. 아웃바운드는 marina MCP(`mcp-chat`)에 REST 도구 5개, 인바운드는 `wake()` 의 alive 분기에서 입력창에 넣고 rollout 으로 전달을 확인한다.

**Tech Stack:** Python 3.9 호환(데몬이 CLT 3.9 — PEP 604 런타임 평가 금지, 주석 문자열은 OK), tmux, codex-cli 0.146, Discord REST v10, bash 테스트(`plugin/tests`).

**Spec:** `docs/superpowers/specs/2026-10-21-codex-rooms-design.md`

## Global Constraints

- 코덱스 코드는 `marina_codex.py` 에. 이 모듈은 DISCORD_MODULES 목록의 모듈만 import(test-discord-boundary). `marina_mobile`·`marina_term` 은 import 금지 — 필요한 로직은 옮겨 쓴다.
- 새 모듈은 `DISCORD_MODULES` 와 `marina_session._PREFLIGHT_MODULES`(2283)에 둘 다 등록.
- 테스트는 `lib/harness.sh` → `lib/session_fixture.sh` 순으로 source. 실 `~/.codex`·실 계정·실 tmux 를 절대 읽거나 쓰지 않는다: `MARINA_CODEX_SESSIONS`(rollout 뿌리 재정의), 계정 폴더는 `$MARINA_HOME/accounts/codex-b`.
- 코덱스 훅은 `DISCORD_STATE_DIR` 로 찾은 기록이 `kind=="codex"` 일 때만 일한다. cwd 짐작 금지.
- 승인 정책 `-a never`. 업데이트 확인 끔. 계정 폴더 = `marina_home()/accounts/codex-<account>`, 기본 account `"b"`, 기본 카테고리 이름 `"chat-bot"`.
- 테스트는 바뀐 범위만(파일 지정). 전체 스위트는 마지막에 지휘 세션이 한 번. 커밋은 지휘 세션이 한다(작업자는 커밋하지 않는다).
- 문구·주석은 한국어, 식별자는 영어.

## Review Focus

1. **데스크톱 코덱스가 클로드 방 워크트리에서 돌 때 훅이 그 클로드 방을 건드림** — `DISCORD_STATE_DIR` 없으면 Discord 호출 0건이어야 한다 → Task 5 `test-codex-hooks.sh` 3번 케이스.
2. **글 두 개가 거의 동시에 와서 같은 글이 두 번 들어감** — 두 `wake` 를 동시에 돌려도 입력은 한 번 → Task 4 2번 케이스.
3. **쳤는데 코덱스가 삼킴** — rollout 에 안 나타나면 ⚠️ 반응, `delivered` 미기록, 다음 글 때 같이 다시 → Task 4 3번 케이스.
4. **다른 계정(데스크톱 무료) rollout 이 숫자판에 섞임** — 방 기록에 없는 rollout 은 더 최근이어도 무시 → Task 2 `rate_windows` 케이스.
5. **sid 를 못 정한 방이 남의 대화를 resume** — 같은 폴더에 새 rollout 이 둘이면 `discover_sid` 는 "" 이고 다음 start 는 새로 띄운다 → Task 2·Task 6 케이스.

---

### Task 0: 실측 스파이크 (코드 없음, 스펙의 "실측 결과" 채우기)

**Files:**
- Create(버림): 지휘 세션 scratchpad 아래 `codex-spike/` — 덤프 훅 스크립트, 장난감 MCP, 캡처 파일
- Modify: `docs/superpowers/specs/2026-10-21-codex-rooms-design.md`("실측 결과" 절, 그리고 결과로 바뀌는 규칙 줄)

**Interfaces:**
- Produces: 아래 값들을 스펙에 적는다 — Task 1·4·5·6 이 그대로 쓴다.
  `CODEX_TRUST_ARGS`(신뢰 창 끄는 -c), `CODEX_MCP_ARG` 모양, `CODEX_RULES_KEY`(시스템 프롬프트 키), `CODEX_HOOK_MODE`(`"inline"` | `"global"` | `"notify"`), 훅 payload 필드 이름(sid·prompt·tool_name·tool_input·transcript_path·cwd), `PANE_INPUT_RE`·`PANE_BUSY_RE`·`PANE_BLOCKING`(막는 화면 문구 목록), 입력 방식(`"paste"` | `"keys"`), MCP 도구 이름 형식, Esc 시 기록(`turn_aborted`?)·Stop 훅 여부.

규칙: 전역 `~/.codex/config.toml`·`~/.codex/hooks.json` 은 고치지 않는다. `CODEX_HOME=~/.marina/accounts/codex-b` 를 그대로 쓴다(auth.json 복사 금지). tmux 는 전용 소켓 `-L codex-spike`. 끝나면 `tmux -L codex-spike kill-server`.

- [ ] **S1 첫 화면:** 신뢰 안 된 새 폴더(`scratchpad/codex-spike/w`, git init)에서 `env -i HOME=$HOME PATH=$PATH TERM=xterm-256color CODEX_HOME=… codex -C <w> -a never` 를 tmux 200x50 으로 띄우고 3·8초에 `capture-pane -p -e` 저장. 이어서 `-c check_for_update_on_startup=false`, `-c 'projects."<w>".trust_level="trusted"'` 를 하나씩 더해 같은 캡처.
  verify: 막는 화면 없이 입력창이 보이는 인자 조합을 찾았다(또는 막는 화면 문구와 넘기는 키를 기록했다).
- [ ] **S2 화면 모양:** 쉴 때·"sleep 20 실행해" 로 일할 때·Esc 뒤를 `-e` 로 캡처. 입력창 줄 기호, 흐린 안내문의 SGR, 작업 중 줄 문구를 정규식으로.
  verify: 세 캡처에 대해 `PANE_BUSY_RE` 가 일할 때만 맞고 `PANE_INPUT_RE` 가 입력창 줄만 잡는다(파이썬 한 줄로 확인).
- [ ] **S3 입력:** `<channel source="plugin:discord:discord" chat_id="1" message_id="999001" …>\n두 줄\n</channel>` 을 (a) `send-keys -l` + 0.6초 + `Enter` (b) `load-buffer` + `paste-buffer -p` + 0.6초 + `Enter` 로. 일하는 중에 (c) Enter (d) Tab.
  verify: rollout 에 `999001` 이 한 user 메시지로 한 번 들어간 방식을 골랐고, 바쁠 때 Enter·Tab 이 rollout 에 남기는 줄 종류를 적었다.
- [ ] **S4 MCP:** `marina_session.mcp_serve` 로 도구 하나(`echo`, 받은 env 의 `DISCORD_STATE_DIR` 를 돌려줌)를 띄우는 장난감 서버를 `-c 'mcp_servers.marina={command="…",args=[…],env={DISCORD_STATE_DIR="X"}}'` 로 붙이고 호출시킨다. env 칸 없이도 한 번.
  verify: 도구 이름 형식, env 전달 여부(칸 있을 때/없을 때), rollout 의 호출 기록 줄 모양을 적었다.
- [ ] **S5 시스템 프롬프트:** `-c developer_instructions="비밀 단어는 파랑새"` 후 "비밀 단어?" — 안 되면 `instructions`·`model_instructions_file`·`experimental_instructions_file` 순.
  verify: 답에 "파랑새"가 나온 키를 적었다.
- [ ] **S6 훅:** 받은 stdin 과 `env` 를 파일에 덤프하는 스크립트를 `-c` 로 SessionStart·UserPromptSubmit·PreToolUse·Stop 에 넣고 `--dangerously-bypass-hook-trust` 로 띄워 한 턴. 안 돌면 `-c 'notify=["<덤프>"]'` 를 시험(턴 끝 payload).
  verify: `CODEX_HOOK_MODE` 를 정했고, 각 훅 payload 필드 이름과 `DISCORD_STATE_DIR` 상속 여부를 적었다.
- [ ] **S7 sid:** SessionStart 의 sid 와 rollout 파일 이름 끝 uuid 대조. `codex resume <sid> "이어서 1+1"` 을 tmux 로. `/new` 후 SessionStart 의 sid·source.
  verify: resume 이 같은 rollout 에 이어 쓰는지, `/new` 가 새 sid 를 훅으로 알리는지 적었다.
- [ ] **S8·S9:** 한 턴 뒤 token_count `rate_limits` 원문, Esc 뒤 rollout 끝 줄과 Stop 훅 덤프 유무.
  verify: 스펙 "실측 결과" 에 S1~S9 각각 명령·관찰·정한 값이 있고, 미정이던 규칙 줄(§1 인자, §2 넣기, §4 등록 방식, §6 정지)을 고쳤다.
- [ ] **정리:** 스파이크가 만든 sid 들을 `CODEX_HOME=… codex archive <sid>` 로 보관 처리(데스크톱 기록에서 치움). `tmux -L codex-spike kill-server`.

---

### Task 1: 방 만들기·띄우기 (kind codex)

**Files:**
- Create: `plugin-discord/scripts/marina_codex.py`
- Modify: `plugin-discord/scripts/DISCORD_MODULES`, `plugin-discord/scripts/marina_session.py` — `_PREFLIGHT_MODULES`(2283), `preflight`(2922), `cmd_new`(3900), `session_launch`(712), `cmd_start`(4015), `session_env`(1904), `tmux_start`(729, 오류 문구·account-running), `main` 의 `new` 파서(4240대)
- Create: `plugin/tests/test-codex-room-new.sh`
- Modify: `plugin/tests/lib/session_fixture.sh`(가짜 `codex` — 가짜 claude 와 같은 argv/env/cwd 덤프)

**Interfaces:**
- Produces(`marina_codex`):
  - `KIND = "codex"`, `DEFAULT_CATEGORY = "chat-bot"`, `DEFAULT_ACCOUNT = "b"`
  - `codex_cfg(cfg: dict) -> dict` — `cfg.get("codex")` 에 기본값(`category`,`account`, `categoryId` 없음) 채움
  - `codex_home(account: str) -> Path` — `ms.marina_home()/"accounts"/f"codex-{account}"`
  - `codex_argv(rec: dict, resume: bool = False, first: str = "") -> list[str]` — `["codex"] + (["resume", sid] if resume and sid) + ["-C", root, "-a", "never", "-c", "check_for_update_on_startup=false", *CODEX_TRUST_ARGS(root), *mcp_args(sdir), *rules_args(), *hook_args(sdir)] + ([first] if first)`. 인자 값은 Task 0 결과.
  - `codex_env(sdir: Path, account: str) -> dict[str, str]` — `ms.session_env` 와 같은 키 + `CODEX_HOME`, `ACCOUNT_TOKEN_ENV` 는 넣지 않음
  - `CODEX_RULES: str` — `CHANNEL_RULES` 의 코덱스판(도구 이름 `mcp__marina__reply`·`progress`, 질문 도구 줄·슬래시 줄 없음)
  - `blocking_screen(tmux: str) -> str` — 화면에 Task 0 의 `PANE_BLOCKING` 문구가 있으면 그 문구, 없으면 `""`. `tmux_start` 가 코덱스일 때 생존 확인 뒤 한 번 보고, 있으면 tmux 를 내리고 `SessionError(f"코덱스가 '{문구}' 창에서 멈춰 있어")`
- Produces(`marina_session`): `is_codex(rec: dict) -> bool`, `ensure_codex_category(dc, cfg) -> str`(없으면 `create_category(guild, cc["category"])` 후 `cfg["codex"]["categoryId"]` 저장), `cmd_new(..., codex: bool = False)`
- 방 기록 칸: `kind="codex"`, `codexAccount`, `rollout`(Task 2), `sessionId`(Task 2·5)

- [ ] **Step 1: 실패하는 테스트** `test-codex-room-new.sh`
  - `$MARINA_HOME/accounts/codex-b/auth.json` 을 만든 뒤 `msess new proj feat/cx --codex --no-start` 성공.
  - 가짜 Discord 로그: 이름 `"chat-bot"`, type 4 카테고리 POST 1회, 채널 `feat-cx` 의 `parent_id` = 그 카테고리. `discord.json.codex.categoryId` 저장됨.
  - 기록: `kind=="codex"`, `codexAccount=="b"`, `sessionId` 없음.
  - 가짜 codex argv == `marina_codex.codex_argv(rec)[1:]`, argv 에 `-a never`·`check_for_update_on_startup=false` 포함, env 에 `CODEX_HOME=$MARINA_HOME/accounts/codex-b`·`DISCORD_STATE_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`·`MARINA_ACCOUNT_TOKEN_FILE` 없음.
  - `account-running` == `b`.
  - auth.json 이 없으면 `new` 가 실패하고 Discord POST 0건, 워크트리 없음.
  - 같은 이름 채널이 chat-bot 카테고리에 이미 있으면 실패(겹침 안내 "이미").
  - `msess stop` 후 `msess start proj/feat/cx` → sid 없으므로 argv 에 `resume` 없음.
  - 가짜 codex 가 `PANE_BLOCKING` 의 첫 문구를 그리게 한 채(`$TMPROOT/codex-block` 파일) `start` → 실패, 안내에 그 문구, tmux 세션 없음.
- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-codex-room-new.sh` Expected: FAIL(`--codex` 모르는 인자)
- [ ] **Step 3: 구현** — 위 Interfaces 대로. `preflight` 는 `codex=True` 면 `shutil.which("codex")`·`codex_home(account)/"auth.json"` 이 비어 있지 않은지 보고, 채널 겹침은 `codex_cfg(cfg)["categoryId"]` 에서. `session_launch` 는 `is_codex` 면 `(root, codex_argv(s, resume, first))`. `tmux_start` 의 "바로 꺼졌어" 문구는 argv[0] 으로.
- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-codex-room-new.sh && bash plugin/tests/test-session-new.sh && bash plugin/tests/test-discord-boundary.sh` Expected: 세 PASS

---

### Task 2: rollout 읽기 — 찾기·sid·턴 상태·받은 지시·rate_limits

**Files:**
- Modify: `plugin-discord/scripts/marina_codex.py`
- Modify: `plugin-discord/scripts/marina_discord_usage.py:450` — `context_percent(transcript: Path, source: str = "claude")`
- Create: `plugin/tests/test-codex-rollout.sh`(파이썬 heredoc, 임시 rollout 픽스처)

**Interfaces:**
- Produces(`marina_codex`):
  - `sessions_root() -> Path` — `MARINA_CODEX_SESSIONS` 또는 `~/.codex/sessions`
  - `find_rollout(sid: str) -> Path | None` — `sessions_root().glob(f"*/*/*/rollout-*-{sid}.jsonl")` 중 mtime 최신
  - `rollout_of(rec: dict) -> Path | None` — `rec["rollout"]` 가 있으면 그것, 없거나 사라졌으면 `find_rollout(sessionId)`
  - `discover_sid(root: Path, since: float, taken: set[str]) -> str` — `since` 이후 mtime 인 rollout 중 첫 줄 `session_meta.payload.cwd` 가 `realpath(root)` 이고 sid ∉ taken 인 것이 **정확히 하나**면 그 sid, 아니면 `""`
  - `turn_busy(rollout: Path, now: float | None = None) -> bool` — 끝 300KB 에서 마지막 `task_started` 뒤에 `task_complete`·`turn_aborted` 가 없고 마지막 줄 timestamp 가 1800초 안
  - `inbound_ids(rollout: Path, channel: str) -> list[str]` — 끝 2MB 원문에서 `ms._CHANNEL_TAG` 로 이 채널 message_id 를 순서대로·중복 없이
  - `window_label(minutes: int) -> tuple[str, str]` — `300 → ("fiveHour","5시간")`, `10080 → ("weekly","주간")`, 그 밖 `(f"w{minutes}", "N시간"|"N일")`(1440 의 배수면 일)
  - `rate_windows(recs: list[dict], account: str, now: float | None = None) -> list[dict]` — `kind=="codex"`·`codexAccount==account` 인 기록들의 rollout 만, 각 끝에서 가장 최근 `token_count.rate_limits`, 그중 timestamp 최신 하나. `primary`·`secondary` 각각 `{"key","label","usedPercent","remainingPercent","resetsAt"}`; `resets_at <= now` 면 `usedPercent=0.0`, `resetsAt=None`. 60초 모듈 캐시(테스트용 `_RATE_CACHE.clear()`)
- Consumes: `ms._CHANNEL_TAG`(1055), `marina_discord_usage.agent_usage_from_path`(397)

- [ ] **Step 1: 실패하는 테스트** — 픽스처 rollout 을 Task 0 S8 의 실제 줄 모양으로 만든다:
  - `find_rollout` 은 파일 이름 끝 sid 로 찾는다.
  - 같은 폴더 rollout 하나 → `discover_sid` 가 그 sid; 둘 → `""`; taken 에 든 것은 제외; cwd 가 다르면 제외.
  - `turn_busy`: started 만 → True; started+complete → False; started+turn_aborted → False; started 만인데 마지막 줄이 31분 전 → False.
  - `inbound_ids`: user 메시지 두 개(채널 "C1" 의 `m1`,`m2`, 채널 "C2" 의 `m3`) → `["m1","m2"]`.
  - `rate_windows`: 방 rollout(used 12.0, 10080, 미래 resets) + 방 기록에 없는 더 최신 rollout(used 99.0) → `[{"key":"weekly","label":"주간","usedPercent":12.0,…}]`; resets 가 과거면 `usedPercent==0.0` 이고 `resetsAt is None`; secondary 가 null 이면 창 하나.
  - `window_label(300)==("fiveHour","5시간")`, `window_label(2880)==("w2880","2일")`.
  - `context_percent(rollout, "codex")` == `agent_usage_from_path(rollout,"codex")["contextPercent"]`, `context_percent(claude_tr)` 는 예전과 같다.
- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-codex-rollout.sh` Expected: FAIL(AttributeError)
- [ ] **Step 3: 구현** — 위 시그니처대로. 파일은 끝에서부터 잘라 읽는다(전체 읽기 금지).
- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-codex-rollout.sh && bash plugin/tests/test-discord-usage.sh` Expected: PASS 둘

---

### Task 3: 아웃바운드 — marina MCP 에 Discord 도구 5개

**Files:**
- Modify: `plugin-discord/scripts/marina_codex.py`, `plugin-discord/scripts/marina_session.py` — `chat_tools_for`(3745), `chat_tool`(3659)
- Modify: `plugin/tests/lib/fake_discord.py` — `GET /attachments/<이름>`(시드 바이트 반환), PATCH 응답에 `content` 반영
- Create: `plugin/tests/test-codex-discord-tools.sh`

**Interfaces:**
- Produces(`marina_codex`):
  - `DISCORD_TOOLS: list[dict]` — 이름 `reply`(chat_id, text, reply_to?, files?), `react`(chat_id, message_id, emoji), `edit_message`(chat_id, message_id, text), `fetch_messages`(channel, limit?), `download_attachment`(chat_id, message_id). 설명은 server.ts 523~ 와 같은 뜻의 한국어
  - `discord_tool(rec: dict, name: str, args: dict) -> str` — 반환 문구는 server.ts 와 같은 모양(`sent (id: …)`, `sent N parts (ids: …)`, `reacted`, `edited (id: …)`, `downloaded N attachment(s):\n  <경로>  (<이름>, <type>, <KB>KB)`, fetch 줄 `[<ISO>] <who>: <text ⏎>  (id: …[ +Natt])`); 거절은 `ms.SessionError`
  - 상수: `MAX_CHUNK = 2000`, `MAX_ATTACH = 25 * 1024 * 1024`, `MAX_FILES = 10`
  - 부수효과: reply 성공 시 `<sd>/replied.json = {"mid": <reply_to 또는 채운 값>, "at": time}`
- `chat_tools_for(rec)` 는 `is_codex(rec)` 면 기존 목록 + `DISCORD_TOOLS`. `chat_tool` 은 이름이 그 다섯이면 `DISCORD_STATE_DIR` 로 기록을 찾아 `discord_tool` 로.

- [ ] **Step 1: 실패하는 테스트** — 코덱스 방 기록·상태 폴더를 Task 1 방식으로 만든 뒤 `DISCORD_STATE_DIR=<sd>` 로 `mcp-chat` 에 JSON-RPC 를 흘려 넣는다:
  - `tools/list` 에 다섯 이름이 있고, 클로드 개발 방 상태 폴더로는 없다.
  - reply 2500자 → POST 2번, 첫 조각만 `message_reference`, 둘 다 `allowed_mentions.parse==[]`, 결과 `sent 2 parts (ids: …)`.
  - reply_to 없이 reply → `inbound_ids(rollout_of(rec), ch)` 의 마지막(픽스처 rollout 에 `m1`,`m2` → `m2`)으로 `message_reference` 가 채워지고 `replied.json.mid=="m2"`. rollout 이 없으면 reply_to 없이 보낸다.
  - 다른 채널 chat_id → isError, POST 0.
  - files 에 `<sd>/.env` → isError("상태"), `<sd>/inbox/a.png` 는 통과(multipart), 26MB 파일 → isError, 11개 → isError.
  - download_attachment → `<sd>/inbox/` 아래 파일 생김, 결과 첫 줄 `downloaded 1 attachment(s):`.
  - fetch_messages 의 여러 줄 본문은 ` ⏎ ` 로 접힌다.
- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-codex-discord-tools.sh` Expected: FAIL
- [ ] **Step 3: 구현** — 첨부 업로드는 `marina_share.upload_message`(482) 재사용. 봇 토큰은 `ms.read_token_file(<sd>/.env)`. 채널 문지기는 `access.json.groups` 키(스레드면 GET 으로 `parent_id`).
- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-codex-discord-tools.sh && bash plugin/tests/test-session-share.sh` Expected: PASS 둘

---

### Task 4: 인바운드 — 살아 있는 코덱스 방에 글 넣기와 전달 확인

**Files:**
- Modify: `plugin-discord/scripts/marina_codex.py`, `plugin-discord/scripts/marina_discord_wake.py:wake`(190)
- Create: `plugin/tests/lib/fake_codex.py`(tmux 안에서 도는 가짜 TUI: Task 0 S2 의 입력창 줄을 그리고, 받은 줄을 `MARINA_CODEX_SESSIONS` 아래 rollout 에 user 메시지로 적는다. `<dir>/swallow` 가 있으면 버린다, `<dir>/busy` 가 있으면 작업 중 줄을 그린다)
- Create: `plugin/tests/test-codex-deliver.sh`

**Interfaces:**
- Consumes: `missed`(118), `wake_prompt`(152), `_save_woke`, `ms.room_lock`, `rollout_of`, `inbound_ids`(Task 2)
- Produces(`marina_codex`):
  - `type_text(tmux: str, text: str) -> None` — Task 0 S3 에서 고른 방식(붙여넣기면 `load-buffer -` 후 `paste-buffer -p -d`) + `MARINA_ENTER_DELAY`(기본 0.6) 뒤 `Enter`. 먼저 `ms.tmux_leave_mode`
  - `confirm(rollout: Path, offset: int, marker: str, timeout: float = 8.0) -> bool` — offset 뒤에 marker 바이트가 나오면 True. 중간에 입력창에 글이 남아 있으면 Enter 재전송(최대 3번)
  - `deliver_missed(rec: dict, cfg: dict, message: str = "", thread: str = "") -> str` — 방 잠금 안에서 `missed()` → 없으면 `"nothing"`, 넣고 확인되면 `_save_woke(delivered=…)` 후 `"delivered"`, 확인 실패면 마지막 글에 ⚠️ 반응 후 `"failed:unconfirmed"`, 잠금 못 잡으면 `"busy"`
- `wake()`: `ms.tmux_alive(name)` 이고 `ms.is_codex(rec)` 면 `"alive"` 대신 `marina_codex.deliver_missed(...)` 결과를 돌려준다(그 결과도 `wake_event` 의 수신 표식 규칙을 따른다).

- [ ] **Step 1: 실패하는 테스트**
  1. 가짜 codex 를 띄운 코덱스 방에 시드 메시지 `m1`(허용 사용자) → `wake --channel <ch> --message m1` 이 `delivered`, rollout 에 `m1` 이 한 번, `woke.json.delivered==["m1"]`.
  2. `m2`,`m3` 시드 후 두 `wake` 를 백그라운드로 동시에 → rollout 에 `m2`·`m3` 각각 정확히 한 번(Review Focus 2).
  3. `swallow` 를 켜고 `m4` → 결과 `failed:unconfirmed`, 가짜 Discord 에 `m4` ⚠️ PUT, `delivered` 에 `m4` 없음. `swallow` 를 끄고 `m5` → 넣은 글에 `m4`·`m5` 둘 다(Review Focus 3).
  4. `busy` 를 켠 채 `m6` → 그래도 넣는다(steer) 그리고 `delivered`.
  5. 허용 목록 밖 사용자 → `ignored:not-allowed`, 입력 0.
  6. 클로드 방(살아 있음)은 여전히 `alive`(test-discord-wake 가 지킴).
- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-codex-deliver.sh` Expected: FAIL(`alive`)
- [ ] **Step 3: 구현** — 위 시그니처대로. 마커 = 넣는 글의 마지막 `message_id`.
- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-codex-deliver.sh && bash plugin/tests/test-discord-wake.sh` Expected: PASS 둘

---

### Task 5: 훅 — sid 확보·받음 표시·도구 표시·턴 끝

**Files:**
- Modify: `plugin-discord/scripts/marina_codex.py`, `plugin-discord/scripts/marina_session.py` — `inbound_messages`(2013) 호출부, `hook_stop`(2478), `_hook_activity_locked`(2738)의 `_turn_from_terminal`·`inbound_messages`, `hook_prompt`(1498), `main` 에 `hook-codex-start`
- Create: `plugin/tests/test-codex-hooks.sh`

**Interfaces:**
- Produces(`marina_codex`):
  - `hook_args(sdir: Path) -> list[str]` — Task 0 의 `CODEX_HOOK_MODE` 가 `"inline"` 이면 `["--dangerously-bypass-hook-trust", "-c", <SessionStart→hook-codex-start>, "-c", <UserPromptSubmit→hook-typing·hook-prompt>, "-c", <PreToolUse→hook-typing, Bash→hook-rm-guard>, "-c", <Stop→hook-stop>]`, `"global"` 이면 `[]`(훅 등록은 형 허락 뒤 별도 단계), `"notify"` 면 Stop 만 notify 로. 명령 머리는 `ms._hook_entry()`, 끝에 `|| true`
  - `room_from_env() -> dict | None` — `DISCORD_STATE_DIR` 의 기록이 `kind=="codex"` 일 때만
  - `hook_start(payload: dict) -> None` — sid(필드 이름은 Task 0) 를 `ms._record_session_id` 로, `rollout` 칸에 `transcript_path`(있으면) 저장
- `marina_session`: 훅 진입점(`hook-stop`·`hook-typing`·`hook-prompt`·`hook-rm-guard`)은 `DISCORD_STATE_DIR` 의 기록이 코덱스면 cwd 짐작(`_hook_target` 의 두 번째 줄)을 쓰지 않는다. 기록 파일이 rollout 이면 `inbound_messages` 대신 `marina_codex.inbound_ids`. 코덱스 방의 `_turn_from_terminal` = rollout 의 마지막 user 메시지에 이 채널 태그가 없음.

- [ ] **Step 1: 실패하는 테스트** — Task 0 S6 에서 저장한 실제 payload 모양으로:
  1. `DISCORD_STATE_DIR=<코덱스 sd>` + SessionStart payload → 기록 `sessionId`·`rollout` 이 채워진다.
  2. UserPromptSubmit(prompt 에 `m1` 태그) → `turn-at` 생김, `m1` 에 👀 PUT. PreToolUse(Bash) → 🛑·도구 이모지 PUT, `activity-at` 갱신. Stop → 단 반응 DELETE, `stopped-at` 생김.
  3. `DISCORD_STATE_DIR` 없이, cwd = 클로드 방 워크트리로 같은 네 훅 → 가짜 Discord 요청 0건, 클로드 방 상태 폴더 파일 변화 0(Review Focus 1).
  4. `DISCORD_STATE_DIR` 가 클로드 방이면 기존 동작 그대로(test-session-activity 가 지킴).
  5. 코덱스 방 argv 에 `hook_args` 결과가 들어간다(모드가 inline 일 때).
- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-codex-hooks.sh` Expected: FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-codex-hooks.sh && bash plugin/tests/test-session-activity.sh && bash plugin/tests/test-session-sid-sync.sh` Expected: PASS 셋

---

### Task 6: 상태 판정 통합 — 바쁨·ctx·정지·재촉·쉬면 내리기·깨우기

**Files:**
- Modify: `plugin-discord/scripts/marina_discord_bot.py` — `_session_transcript`(857), `_pane_busy`(167) 호출부(`snapshot` 425·`interrupt` 975·`_restart_blockers` 2321), `_ctx_percent`(182), `_turn_in_progress`(2296)
- Modify: `plugin-discord/scripts/marina_discord_idle.py` — `_verdict`(114)의 `_input_empty`·`_selecting`
- Modify: `plugin-discord/scripts/marina_session.py` — `nudge_unanswered`(1446)·`resume_unanswered`(1477)·`unanswered` 판정, `cmd_start`(4015)의 sid 사후 확보
- Modify: `plugin-discord/scripts/marina_codex.py`
- Create: `plugin/tests/test-codex-status.sh`

**Interfaces:**
- Produces(`marina_codex`): `pane_busy(tmux: str) -> bool`(Task 0 `PANE_BUSY_RE`), `input_empty(tmux: str) -> bool`(`PANE_INPUT_RE`), `selecting(tmux: str) -> bool`(`PANE_BLOCKING`), `unanswered_mid(rec: dict, rollout: Path) -> str` — `inbound_ids` 의 마지막이 `replied.json.mid` 보다 뒤면 그 id, 아니면 `""`, `adopt_after_start(rec: dict, started: float) -> None` — 30초 동안 2초 간격으로 `discover_sid` 를 불러 정해지면 기록(떼어 낸 프로세스로)
- 판정 규칙: 코덱스 방 바쁨 = `pane_busy(tmux) or turn_busy(rollout)`, ctx = `context_percent(rollout, "codex")`, `_turn_in_progress` = `turn_busy`, 정지 = `Escape` 그대로(Task 0 S9 에서 Stop 훅이 안 오면 `interrupt` 의 `_clear_locked` 가 정리 — 이미 그렇게 돈다).
- `cmd_start`: 코덱스 방이 sid 가 없으면 띄운 뒤 `adopt_after_start` 를 건다.

- [ ] **Step 1: 실패하는 테스트**
  1. 코덱스 방 rollout 이 started 만 → `snapshot()["sessions"]` 그 줄 `busy==True`, `ctx` == 픽스처 계산값; complete 추가 → `busy==False`.
  2. `interrupt` → tmux 에 Escape(가짜 codex 가 받은 키 기록), `⏹️` PUT.
  3. Stop 훅에서 `m1` 을 받았고 `replied.json` 없음 → `NUDGE_TEXT` 를 친다(최대 3번); `replied.json.mid=="m1"` → 안 친다.
  4. `idle-check --hours 0` 이 코덱스 방에 대해 입력창 빈 가짜 화면이면 "내려도 됨", busy 파일이 있으면 막는다.
  5. 같은 폴더에 새 rollout 이 둘 생긴 채 `start` → `sessionId` 비어 있음, 다음 `start` argv 에 `resume` 없음(Review Focus 5). 하나면 기록되고 다음 `start` argv 에 `resume <sid>`.
  6. 꺼진 코덱스 방에 `wake` → `codex_argv(resume=True, first=<wake_prompt>)` 로 뜬다(가짜 argv 확인).
- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-codex-status.sh` Expected: FAIL
- [ ] **Step 3: 구현** — 각 호출부에서 `ms.is_codex(rec)` 분기만. 클로드 경로는 한 줄도 바꾸지 않는다.
- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-codex-status.sh && bash plugin/tests/test-discord-bot.sh && bash plugin/tests/test-discord-idle.sh && bash plugin/tests/test-session-nudge-unanswered.sh && bash plugin/tests/test-session-safe-restart.sh` Expected: PASS 다섯

---

### Task 7: 판 나누기 — chat-bot #상태와 코덱스 숫자판

**Files:**
- Modify: `plugin-discord/scripts/marina_discord_bot.py` — `snapshot`(425), `_owner_channel`(724, `parent` 인자), `dashboard_tick`(740), `meter_tick`(790), `Loop` 의 호출부(3012·3015)
- Create: `plugin/tests/test-codex-board.sh`

**Interfaces:**
- Consumes: `marina_codex.rate_windows`(Task 2), `marina_codex.codex_cfg`(Task 1)
- Produces(`marina_discord_bot`):
  - `_owner_channel(dc, cfg, name, kind, position=0, parent: str = "") -> str` — parent 가 있으면 body 에 `parent_id`
  - `snapshot(full=True)` 줄에 `"codex": bool` 추가
  - `board_snap(snap: dict, codex: bool) -> dict` — 줄을 `r["codex"]==codex` 로 거르고, codex 면 `usage = rate_windows(…, account)`, `accountUsage = {}`, `roleUsage = []`
  - `dashboard_tick(st, snap=None, codex: bool = False)` — codex 면 상태 키 `"codexDashboard"`, 채널은 `_owner_channel(..., parent=codex_cfg(cfg)["categoryId"])`. 코덱스 카테고리 id 가 없으면(방을 한 번도 안 만듦) 아무것도 안 한다
  - `codex_meter_tick(meters: dict) -> None` — 키 `f"codex:{w['key']}"`, 이름 `f"📊 코덱스 {w['label']} {round(used)}%"`, 이름 바꾸기 제한·재생성 규칙은 `meter_tick` 과 같은 코드 경로(공통 부분을 함수로 빼도 된다 — 클로드 숫자판 결과가 같다는 테스트가 지킨다)
- 전역 판(`codex=False`)은 코덱스 줄을 빼므로 클로드 #상태 메시지는 지금과 같다.

- [ ] **Step 1: 실패하는 테스트**
  1. 클로드 방 하나 + 코덱스 방 하나(rollout 에 rate_limits used 12.0 주간). `dashboard_tick(st)` → 전역 #상태 본문에 코덱스 방 이름 없음. `dashboard_tick(st2, codex=True)` → `parent_id`=chat-bot 카테고리인 `상태` 채널 POST, 본문에 코덱스 방 줄과 `주간 … 12%`.
  2. `codex_meter_tick({})` → type 4 `📊 코덱스 주간 12%` POST 하나(창이 주간뿐이면 숫자판도 하나). 10분 안 재호출은 PATCH 0.
  3. rate_limits 가 없으면(rollout 없음) 숫자판 POST 0.
  4. `meter_tick` 의 클로드 숫자판 요청은 이 작업 전과 같다(test-discord-bot·test-discord-usage 의 기존 단언).
- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-codex-board.sh` Expected: FAIL
- [ ] **Step 3: 구현** — `Loop` 는 `dashboard_tick(self.dash)` 뒤에 `dashboard_tick(self.codex_dash, codex=True)`, `meter_tick` 뒤에 `codex_meter_tick(self.codex_meters)`, 각각 `try/except` 로 로그만(클로드 판을 막지 않게).
- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-codex-board.sh && bash plugin/tests/test-discord-bot.sh && bash plugin/tests/test-discord-usage.sh && bash plugin/tests/test-discord-account.sh` Expected: PASS 넷

---

### Task 8: 실기 확인 — chat-bot 첫 방 (qa)

전제: 지휘 세션이 형 답(정해야 할 것 1~4)을 받았고, 이 브랜치를 설치본으로 올리는 것(데몬 재시작 포함)은 **형 허락 뒤**.

- [ ] `marina session new <형이 고른 프로젝트> <방 이름> --codex` → Discord 에 chat-bot 카테고리·채널·첫 안내. verify: tmux 화면에 막는 창 없음, `sessions.json` 기록 `kind=codex`, 30초 안 `sessionId` 채워짐.
- [ ] 채널에 "pwd 알려줘" → 👀 → 도구 이모지 → 답장(reply_to 가 그 글). verify: rollout 에 message_id 한 번, `replied.json` 갱신, 반응이 턴 끝에 떨어짐.
- [ ] 일하는 중 두 번째 글 → 같은 턴에서 읽음. 🛑 → 멈춤·⏹️.
- [ ] `marina session stop` 후 글 → ⏰ → 깨어나 같은 대화(`codex resume <sid>`)로 답.
- [ ] chat-bot `#상태` 에 방 줄·`주간 N%`, 최상위 `📊 코덱스 주간 N%`. verify: 값 == rollout 마지막 token_count 의 `used_percent` 반올림. 전역 #상태에 코덱스 방 없음.
- [ ] 데스크톱 코덱스를 같은 워크트리에서 한 턴 → 방 채널에 아무 표시 없음, `~/.marina/discord-bot.log` 에 훅 오류 없음.
- [ ] `~/.marina/discord-bot.log`·`discord-idle.log` 에 Traceback 없음(데몬 python3.9 import 포함).
