# 실행 플러그인 경계 — 설계

- 날짜: 2026-10-03
- 상태: 형 검토 대기
- 로드맵: [[marina-runtime-plugin-roadmap]] ②단계. 실제로 쪼개는 일은 ④단계(DB 복제 다음)이고, 이 문서는 그때 따를 선을 정한다.

## 1. 왜

- 실행 격리(compose·게이트웨이·links·원격·GC, 앞으로 DB 복제)는 세상에 공개할 생각이다.
- Discord 세션·봇·대시보드는 빨리 결과를 내려고 마리나 안에 만들었다. 원래는 빼는 게 맞다.
- 형 개인 운영물이 공개본에 섞이면 보안 표면이 커지고 설명도 어려워진다. 형 계정으로 도는 세션, 모바일 로그인·펀넬, 봇이 그런 것들이다.
- 대시보드는 나중에 버릴 수도 있다. 대시보드를 지워도 Discord는 살아 있어야 한다.

## 2. 결정 (형 확정)

| 항목 | 결정 |
|---|---|
| 레포 | 하나 유지(turong92/marina, 지금처럼 PUBLIC). 비밀값은 코드에 없고 `~/.marina`·`~/.claude`에만 있다 |
| 플러그인 | 셋. marketplace.json 에 셋을 적고 각자 폴더를 가리킨다. 설치하면 그 폴더만 캐시에 복사된다 |
| `runtime` (공개) | 남들·팀원은 이것만 깐다. CLI·Claude Code 훅·스킬, 그리고 화면 없는 청소 프로그램 |
| `dashboard` (형) | 웹·모바일·로그인·펀넬·터미널·에이전트 대화·방·체인. **언제 버려도 되게** 만든다 |
| `discord` (형) | Discord 세션(`marina session`)·봇·질문/권한 버튼·share_file |
| 독립 | **셋 다 혼자 깔아도 동작한다**(형: "각자 역할이 다르고 서로 없어도 워킹해야 돼"). 같이 깔리면 기능이 붙는다 |
| 의존 방향 | dashboard 만 runtime 이 **있으면** 쓴다. discord 는 표준(Claude Code 훅·git)으로만 만난다. dashboard·discord 는 서로 안 부르고, runtime 은 둘을 모른다 |

## 3. 표준에 맞춘다

형: "표준식으로 해야 다른 개념들이랑 호환된다." 그래서 마리나만의 등록 장치는 만들지 않는다. 이미 있는 표준에 올라탄다.

| 필요한 것 | 쓰는 표준 | 효과 |
|---|---|---|
| 플러그인 셋 묶기 | Claude Code 마켓플레이스(플러그인 여러 개) | runtime 은 **지금 이름 `marina`(폴더 `plugin/`) 그대로** — 팀원 설치·`~/.local/bin/marina`·codex 가 `marina@marina-dev` 에 묶여 있어서 이름을 바꾸면 다 끊긴다(계획 A 조사). 나머지는 `marina-dashboard`·`marina-discord`. 묶음 플러그인은 안 만든다(형은 셋을 깐다) |
| 워크트리 만들기·지우기 | Claude Code 훅 `WorktreeCreate`·`WorktreeRemove` | runtime 이 이 둘을 구현한다. 그러면 `claude --worktree`·서브에이전트 `isolation: worktree`·백그라운드 세션이 전부 마리나 격리(포트·compose·links)를 탄다 |
| 지우기 직전 정리 | 같은 `WorktreeRemove` 훅 — 여러 플러그인의 같은 훅은 다 돈다 | discord 가 자기 `WorktreeRemove` 훅에서 채널·세션을 정리한다. runtime 은 discord 를 몰라도 된다 |
| "쓰는 중이니 지우지 마" | `git worktree lock --reason` | discord 는 세션이 살아 있는 동안 워크트리를 잠근다. runtime GC 는 잠긴 워크트리를 건너뛴다. git·다른 도구(`git worktree prune` 등)도 같은 뜻으로 읽는다 |
| 명령 내보내기 | 플러그인 `bin/` (켜져 있으면 Claude 의 Bash PATH 에 들어감) + 사람용 셸에는 `~/.local/bin` 링크 | `marina`(runtime), `marina-session`(discord), `marina-dashboard`(dashboard) |
| 상주 프로그램 | launchd(맥)·systemd --user(리눅스) | Claude Code `monitors` 는 세션이 떠 있을 때만 돌아서 상주 청소에 못 쓴다 |
| 실행 정의 | Compose 규격 + `x-marina` 확장 필드(이미 그렇게 함) | 다른 compose 도구와 그대로 호환 |
| 기계가 읽는 출력 | `--json`(맨 위 `"v"`) | §R4 |

### 실측 결과 (2026-10-03, Claude Code 2.1.287)

| # | 확인한 것 | 결과 |
|---|---|---|
| 1 | `WorktreeCreate` 가 불리나 | `claude -p --worktree X`·tmux 대화형 `claude --worktree X` 둘 다 불린다. 입력 = `session_id·transcript_path·cwd(원본 체크아웃)·name`. 훅이 stdout 으로 경로를 내면 거기서 세션이 뜬다 |
| 2 | 기준 브랜치·프로젝트 전달 | 입력엔 없다. 대신 **claude 를 띄울 때 준 환경변수가 훅에 그대로 간다**(실측: 띄울 때 준 변수를 훅이 그대로 읽음). 프로젝트는 입력의 `cwd` 로 안다 |
| 3 | 대화형은 저장소 신뢰가 먼저 | 신뢰 안 한 폴더면 "Workspace trust not yet accepted" 로 바로 끝난다. 마리나 프로젝트는 이미 신뢰돼 있다 |
| 4 | `WorktreeRemove` 는 언제 | **변경 없는 워크트리에서 `/exit` 하면 묻지도 않고 불린다**(`--resume` 으로 다시 연 세션도 같음). 변경이 있으면 Keep/Remove 를 묻는다. tmux 를 죽이면(재시작·정지) 안 불린다. 입력에 `worktree_path` |
| 5 | 훅이 거절하면 | `WorktreeRemove` 훅이 0 이 아닌 값으로 끝나면 워크트리는 **남는다**. 지울지 말지는 훅이 정한다 |
| 6 | Claude Code 자체 잠금 | 훅이 없으면 Claude Code 가 직접 `git worktree lock` 을 건다(이유 `claude session <이름> (pid N start …)`). 프로세스를 죽여도 잠금은 남는다(낡은 잠금). 다시 열어도 새로 안 걸고, `/exit` 때 **잠금을 무시하고** 지운다 |

이 결과로 정한 것:
- **runtime 의 `WorktreeRemove` 훅은 남의 잠금을 존중한다.** 다른 주인(discord 등)이 잠갔으면 거절하고(exit 2) 이유를 stderr 로 낸다. 4번 때문에 이게 없으면 Discord 개발 세션에서 누가 `/exit` 한 번 치는 순간 깨끗한 워크트리가 사라진다.
- **잠금 이유 형식(표준 git 잠금 위의 약속):** `<주인> <설명> (pid N …)`. 판정 규칙은 이렇다.
  - pid 가 적혀 있고 그 프로세스가 죽었으면 낡은 잠금으로 보고 무시한다. Claude Code 자기 잠금이 이 경우다.
  - pid 가 없으면 주인이 풀 때까지 지킨다. discord 의 `marina-session <ref>` 가 이 경우다.
  - runtime GC 도 같은 판정을 쓴다.
- discord 는 세션을 `claude --worktree <이름>` 으로 띄우고, 기준 브랜치는 `MARINA_BASE` 환경변수로 넘긴다. runtime 이 없으면 Claude Code 기본(git 워크트리 + 자기 잠금)으로 동작한다. 이때는 4번 위험이 그대로라서, discord 는 runtime 이 없을 때 **세션을 띄우기 전에 자기 잠금을 건다**. 이 경우 Claude Code 기본 삭제가 잠금을 무시하는지는 ④ 때 한 번 더 확인한다. 무시하면 discord 혼자일 때는 `--worktree` 대신 `git worktree add` 로 만든다.

## 4. 레이아웃

```
.claude-plugin/marketplace.json   # marina(=runtime) · marina-dashboard · marina-discord
plugin/             (runtime — 지금 폴더 그대로)
plugin-dashboard/
plugin-discord/
```

공개 설명서(README)는 runtime 만 다룬다. dashboard·discord 는 "형이 이렇게 쓴다"는 예시로만 남긴다.

## 5. 규칙

### R0. 혼자서도 돈다

| 혼자 깔았을 때 | 되는 것 | 꺼지는 것(옆 플러그인이 있어야 붙음) |
|---|---|---|
| runtime | 격리 실행·게이트웨이·GC 전부, `claude --worktree` 격리 | 없음 |
| discord | 채팅 세션·로비, 개발 세션(워크트리는 `claude --worktree` 표준 경로 = 그냥 git 워크트리), 봇·#상태·숫자판·🛑·질문/권한 버튼 | 서비스 자동 시작(runtime 의 `WorktreeCreate` 가 하게 됨) |
| dashboard | 에이전트 대화·모바일·터미널·로그인·펀넬 | 워크트리·서비스·compose·연결·GC 탭(숨김. "runtime 을 깔면 생긴다" 안내 한 줄) |

discord 는 runtime 을 **부르지 않는다**. 워크트리를 `claude --worktree` 로 만들면, runtime 이 깔려 있을 때 그 훅이 알아서 격리를 붙인다. dashboard 만 runtime 이 있는지 확인한다(`marina` 명령이 PATH 에 있는지). 확인은 쓸 때마다 다시 하므로 나중에 깔아도 재시작 없이 붙는다.

### R1. runtime 은 다른 둘의 코드를 부르지 않는다

runtime 쪽 파일에서 `marina_session`·`marina_sessions`·`marina_rooms`·`marina_term`·`marina_auth`·`marina_mobile` 등을 import 하면 위반이다. 테스트가 기계로 막는다(§8).

### R2. dashboard 는 runtime 을 정해진 입구로만 쓴다

- 대시보드는 0.1초 단위로 상태를 그리고 runtime 함수를 수십 개 쓴다. 그래서 전부 CLI 로 바꾸는 건 비싸다.
- 대신 runtime 이 파이썬 입구 모듈 하나 `marina_runtime_api.py` 를 낸다. 여기 다시 내보낸 이름만 쓴다.
- 버전 상수 `API_VERSION` 을 둔다. 맞지 않으면 대시보드는 runtime 탭만 끄고 "runtime 을 업데이트하라"고 띄운다.
- runtime 폴더는 `marina --runtime-path` 로 찾는다. 이 명령은 PATH 의 `marina` 가 자기 설치 경로를 알려 주는 것이다.

### R3. dashboard ↔ discord 는 서로 모른다

같은 정보가 필요하면 각자 표준 원천에서 읽는다. 예: 구독 사용량은 Claude 계정 API, 세션 컨텍스트 % 는 세션 기록 파일. 공용 모듈을 만들지 않고 각자 사본을 둔다(약 100줄).

### R4. `--json` 출력 형식

- 맨 위에 `{"v": 1, …}` 를 붙인다. 필드를 지우거나 뜻을 바꾸면 v 를 올린다. 필드를 추가할 때는 v 를 그대로 둔다.
- 오류는 종료 코드가 0 이 아니고, stdout 에 `{"v":1,"error":"…"}` 를 낸다.

### R5. 명령 이름

- `marina` 는 runtime 소유다. 지금 쓰는 `marina session …` 은 `marina-session …` 으로 옮긴다.
- 옮기는 기간(한 버전) 동안 runtime 의 `marina session` 은 "`marina-session` 으로 바뀜" 안내와 함께 `marina-session` 이 PATH 에 있으면 그대로 넘겨준다. 그다음 버전에서 지운다.
- 세션 안 규칙 문구(CHANNEL_RULES)·재시작 안내는 `marina-session` 으로 적는다.

### R6. 데이터 폴더

`~/.marina` 는 공유한다. 파일마다 주인을 정한다.
- runtime: `registry`·`state`·gateway·docker-gc
- dashboard: auth·mobile·handler 상태
- discord: `discord.json`·`sessions.json`·`discord-bot.*`·`chat/`·`bin/marina-session-hook`

남의 파일은 쓰지 않는다. 읽어야 하면 주인의 CLI 로 읽는다.

## 6. 상주 프로그램 셋

| 프로그램 | 플러그인 | 하는 일 |
|---|---|---|
| `marina-runtimed`(화면 없음) | runtime | 게이트웨이 주소 다시 연결(`_gw_loop`), 도커 GC·워크트리 7일 정리, 고아 리퍼 (자동 업데이트는 대시보드 재시작·터미널 판정에 묶여 있어 당분간 dashboard 에 둔다 — runtime 자체 업데이트는 C 이후) |
| 대시보드 서버 | dashboard | 웹·모바일·펀넬·이벤트·데스크톱 인계·모바일 outbox. 청소 일은 하지 않는다 |
| discord 데몬 | discord | 지금 `_discord_loop` 스레드가 하던 봇 루프(#상태·숫자판·typing·bun 봇 관리) |

셋 다 launchd(맥)·systemd --user(리눅스)로 띄운다. 띄우는 스크립트는 지금 `marina-dashboard.sh` 를 플러그인마다 하나씩 나눈다.

## 7. 지금 꼬여 있는 곳 (④에서 풀 목록)

| 위치 | 지금 | 풀이 |
|---|---|---|
| `marina_lifecycle.remove_worktree` | `marina_session.teardown_for_root` 직접 호출 | 그 정리 코드를 discord 의 `WorktreeRemove` 훅으로(runtime 의 `remove_worktree` 는 git 기본 동작인 '워크트리 지우기'만) |
| `marina_worktree_gc` | `marina_session.has_live_session`·`marina_sessions._root_has_live_agent`·`_live_agent_cwds`·`agents_payload` | 에이전트 생존은 runtime 의 프로세스 판정(`ps comm`→cwd)으로 옮기고, Discord 세션은 `git worktree lock` 으로 |
| `marina_lifecycle`·`marina_worktree_gc`·`marina_git` | `marina_sessions` 의 git 함수(`git_output`·`worktree_status`·`worktree_info`·`repo_branch`), `marina_rooms.own_changed_paths` | git 함수는 runtime 의 `marina_gitstate.py` 로 옮긴다. `own_changed_paths` 도 runtime 으로 옮긴다(방 판정과 삭제 판정이 같은 규칙을 써야 하므로 runtime 이 원본, 방이 가져다 씀) |
| `marina_autoupdate` | `marina_term`(열린 터미널 수)·`marina_events` | "지금 재시작해도 되나" 판정을 runtime 자체 판정(실행 중 서비스·에이전트 프로세스)으로 |
| `marina_discord_bot` | `marina_sessions.provider_account_usage`·`agent_usage_from_path` | discord 에 자기 사본(약 100줄). 공용 모듈로 묶으면 dashboard 와 다시 엮이므로 사본이 더 싸다 |
| `marina_handler` | 데몬 하나가 청소·봇·대시보드 스레드 전부 | §6 대로 셋으로 |
| `marina_remote_service` | `marina_auth` | 원격 박스 쪽 인증만 runtime 으로 옮길지는 ④ 때 내용을 보고 정한다(지금은 dashboard 소유로 둔다) |
| 훅 `hooks.json` | 한 플러그인에 전부 | runtime: SessionStart·Bash PreToolUse·보호 쓰기·앱데이터 가드. dashboard: 질문 캡처·에이전트 이벤트. discord: 세션 훅(shim) |

## 8. 검증

- **경계 테스트**(④ 첫 작업): runtime 폴더의 `.py`·`.sh` 가 dashboard·discord 모듈 이름을 import·source 하면 실패한다. dashboard ↔ discord 서로 참조도 실패한다.
- **runtime 단독 테스트**: 빈 `~/.marina` 에 runtime 만 깔고 compose 프로젝트 등록 → start → 게이트웨이 접속 → 워크트리 삭제까지 통과해야 한다. `claude --worktree <이름>` 으로 만든 워크트리도 격리가 붙는다.
- **혼자 테스트(셋 각각)**: 나머지 둘이 없는 상태에서 §R0 표의 '되는 것'이 동작하고, '꺼지는 것'은 오류 없이 빠진다.
  - discord 혼자: `marina session new <프로젝트> <이름>` 이 `git worktree add` 로 워크트리를 만들고 세션이 뜬다. #상태·🛑 이 동작한다.
  - dashboard 혼자: 대화·터미널이 뜨고 runtime 탭이 숨는다.
- 잠금 테스트: `git worktree lock` 된 워크트리는 7일 정리에서 빠진다. discord 세션을 끄면 잠금이 풀린다.

## 9. 하지 않는 것

- 레포 분리·비공개 전환
- 마리나만의 확장 등록 장치(`~/.marina/ext` 같은 것). 표준(Claude Code 훅·git 잠금)으로 대신한다
- runtime 이 dashboard 를 확장하는 플러그인 API(데몬 하나에 끼워 넣기). 상주 프로그램을 셋 두는 쪽을 택했다
- 헤르메스 연결(⑤)
