# Discord 세션 설계 (`marina session`)

**상태:** 설계 → 검토 대기
**범위:** 워크트리 하나를 Discord 채널 하나에 묶어, 메신저로 일을 시키는 세션을 한 명령으로 열고 닫는다
(워크트리 · 실행 환경 · Discord 채널 · tmux 안의 `claude --channels`).
**범위 밖:** 헤르메스 로비 · Jev 분류 · 카톡/Slack · 쉬는 세션 깨우기 · 마리나 세션/모바일 코드 정리
(→ 큰 로드맵의 다음 단계들). DB 복제(별도 스펙).

## 배경

2026-10-01 방향 결정: 마리나는 **실행 격리**(compose · 포트 · 게이트웨이 · GC · 앞으로 DB 복제)로 좁히고,
메신저·세션 대화는 공식 기능과 헤르메스에 맡긴다. 마리나에서 손이 제일 많이 가던 부분이 세션 배달
(PTY 입력 · 보류함 · 유휴 감지 · 완료 감지)이었다.

같은 날 실측으로 **Claude Code Channels**(공식, 리서치 프리뷰)가 그 배달을 대체함을 확인했다.

| 확인한 것 | 결과 |
|---|---|
| 봇 하나 · 토큰 하나로 채널 = 세션 (세션마다 `DISCORD_STATE_DIR`, `access.json` 의 `groups.<채널ID>`) | ✅ 각 채널 메시지가 자기 세션에만 도착, 각자 자기 워크트리만 수정 |
| 작업 중 추가 메시지 | ✅ 대기열 → 1초 안에 진행 중인 턴에 끼어듦 |
| 진행 표시 | ✅ `edit_message` 로 메시지 하나를 갱신 |
| 질문 | ✅ `reply` 번호 텍스트 (버튼은 공식 플러그인이 지원 안 함) |
| tmux + `--channels` + `--remote-control` 동시 | ✅ claude.ai/code · 모바일 앱에서 같은 세션 실시간 보기 |
| 신뢰한 저장소 아래 `.claude/worktrees/` 워크트리 | ✅ 신뢰 확인창 안 뜸 (tmux 에서 멈출 일 없음) |

실측에서 잡힌 함정(설계에 반영):
- 플러그인을 사용자 범위로 설치하면 **열린 모든 세션에 붙어 같은 토큰으로 접속**한다 → 토큰은 기본 폴더가
  아니라 `~/.claude/channels/discord-token.env` 한 곳에 두고, 세션 상태 폴더의 `.env` 는 심링크.
- 플러그인은 **스레드를 부모 채널로 판정**한다(`msg.channel.parentId`) → 세션 구분은 스레드가 아니라 채널.
- `AskUserQuestion` 은 터미널에 뜨고 세션이 멈춘다 → `--disallowedTools AskUserQuestion`.
- Claude 의 일반 출력은 터미널, `reply` 한 것만 Discord → 채널 규칙을 시스템 프롬프트로 준다.
- Claude 세션 안에서 띄운 `claude` 는 자식 표식을 상속한다 → 깨끗한 env 로 띄운다.
- 대화형 `claude` 는 터미널이 있어야 돈다(Remote Control 문서: 프로세스가 멈추면 오프라인) → tmux.
  Remote Control 서버 모드(`claude remote-control`)는 `--channels` 같은 플래그를 거부해 못 쓴다.

## 목표

- `marina session new <프로젝트> <작업>` 한 번으로 워크트리 · 실행 환경 · 채널 · 세션이 다 선다.
- Discord 에서는 프로젝트가 카테고리, 세션이 채널로 보인다. 채널 수명 = 워크트리 수명.
- 같은 세션을 claude.ai/code · 모바일 앱에서 Remote Control 로 같이 본다(과정은 거기서, Discord 는 결과·질문).
- 실패하면 만든 것을 역순으로 되돌린다. 형의 실제 tmux · 세션은 테스트가 절대 건드리지 않는다.
- 마리나 세션/모바일 쪽 코드는 건드리지 않는다. 새 코드는 실행 계층만 부른다.

## 비목표

- 쉬는 세션 끄기·깨우기(필요해지면 헤르메스 브리지에), 자동 재시작 감시, 부팅 자동 실행(launchd).
- Discord 버튼 · 채널 대화 내보내기.
- 팀원 권한 체계(이번엔 프로젝트별 Discord ID 허용 목록까지).

## 1. 구성과 명령

### 명령

```
marina session new <프로젝트> <작업> [--base <브랜치>] [--no-start]
marina session ls [--json]
marina session attach <작업>
marina session start <작업> | --all      # 꺼진 세션을 --continue 로 다시 띄움
marina session stop <작업>               # 세션만 끔 (워크트리·채널 유지)
marina session rm <작업>                 # 세션 + 채널 + 상태 폴더 정리 (워크트리는 안 지움)
```

`<작업>` 은 브랜치명이자 채널 이름·tmux 이름의 바탕이다. 브랜치 규칙은 기존 `worktree create` 와 같다
(`[A-Za-z0-9._/-]`, `..` 금지). 워크트리 폴더 이름은 기존 규칙(`/:` → `-`) 그대로다.
채널 이름은 거기서 `.` 도 `-` 로 바꾸고 소문자로 만든다(Discord 가 채널 이름을 소문자로 바꾸므로, 겹침 검사도
소문자로 비교). tmux 이름은 `<프로젝트>-<채널 이름>`(tmux 는 세션 이름에 `.` `:` 를 못 쓴다).
여러 프로젝트에 같은 `<작업>` 이 있으면 `<프로젝트>/<작업>` 으로 지정한다.

### `new` 순서

1. **사전 점검** (2절) — 하나라도 걸리면 아무것도 만들지 않는다.
2. `marina worktree create <작업> [base] --project <프로젝트>` (기존).
3. `marina start --all` (기존, `--no-start` 면 생략). 실패해도 세션은 계속 연다 — 실행 환경은 나중에 켜도 된다.
4. Discord REST: 프로젝트 카테고리가 없으면 만들고 `discord.json` 에 ID 기록 → 그 아래 텍스트 채널 `#<작업>` 생성.
5. 상태 폴더 `~/.claude/channels/discord-<프로젝트>-<채널 이름>/` (권한 700):
   - `access.json` = `{"dmPolicy":"allowlist","allowFrom":<허용자>,"groups":{"<채널ID>":{"requireMention":false,"allowFrom":<허용자>}},"ackReaction":"👀","replyToMode":"first"}`
   - `.env` → `tokenFile` 심링크
6. tmux 세션 `<프로젝트>-<채널 이름>` 을 워크트리에서 깨끗한 env 로 띄운다:
   ```
   DISCORD_STATE_DIR=<상태 폴더> claude \
     --channels plugin:discord@claude-plugins-official \
     --remote-control "<프로젝트>/<작업>" \
     --disallowedTools AskUserQuestion \
     --append-system-prompt "<채널 규칙>"
   ```
7. `sessions.json` 에 기록하고, 채널 링크와 Remote Control 이름을 출력한다.

### 채널 규칙 (시스템 프롬프트에 덧붙임)

- 상대는 Discord 만 본다. 결과 · 질문 · 실패/막힘 · 완료는 반드시 `reply` 로.
- 긴 작업은 시작할 때 진행 메시지 하나를 보내고 `edit_message` 로 갱신, 끝나면 새 `reply`(알림이 울리도록).
- 질문은 번호 선택지 텍스트로.
- 이미지는 첨부, HTML 은 스크린샷 + 열어볼 주소, 10MB 를 넘으면 링크로.
- 터미널에서 직접 받은 지시의 답은 터미널에 둬도 된다.

### 설정 `~/.marina/discord.json` (비밀값 없음)

```json
{
  "guildId": "1555094662912679966",
  "tokenFile": "~/.claude/channels/discord-token.env",
  "projects": {
    "ovation": { "categoryId": null, "allow": ["770258011330576384"] }
  }
}
```

프로젝트가 없으면 `new` 가 멈추고 추가 방법을 알려준다. `categoryId` 는 처음 만들 때 채운다.

### 기록 `~/.marina/sessions.json`

```json
{ "sessions": [ {
  "project": "ovation", "task": "fix-x", "root": "<워크트리>",
  "channelId": "…", "tmux": "ovation-fix-x", "stateDir": "<상태 폴더>",
  "rcName": "ovation/fix-x", "createdAt": 0
} ] }
```

### 코드 위치

- 새 모듈 `plugin/scripts/marina_session.py` (명령 진입 · 사전 점검 · 되돌리기 · 기록).
  Discord REST 는 같은 모듈 안의 작은 클라이언트(`urllib` 만, API 주소는 `MARINA_DISCORD_API` 로 바꿀 수 있게).
- `marina.sh` 에 `session)` 분기 추가.
- 실행 계층만 부른다(`worktree create`, `start`, `remove_worktree` 연동). `marina_sessions.py` · `marina_mobile.py` 등
  세션/모바일 코드는 건드리지 않는다.
- 데몬이 python 3.9 라서 PEP 604(`X | None`) 등 금지 — 기존 `test-py39-compat` 이 지킨다.

### 형이 준비한 것

- 봇 역할에 채널 관리 · 링크 첨부 권한(완료), Public Bot 끔(완료), 서버 ID(위 설정).

## 2. 실패 처리

**사전 점검** — 만들기 전에 전부 본다: 같은 이름의 워크트리 · 채널(Discord 조회) · tmux 세션 · 상태 폴더 ·
`sessions.json` 항목, 토큰 파일 존재, `discord.json` 의 프로젝트 등록, `tmux` · `claude` 실행 파일.

**중간 실패 → 역순 되돌리기** — tmux 실패면 채널 삭제 + 상태 폴더 삭제. 채널 생성 실패면 상태 폴더 없음.
**워크트리는 남긴다**(형이 직접 이어 쓸 수 있게). 남긴 사실과 `marina session rm` 을 알려준다.

**Discord API 오류** — 401: 토큰 문제, 403: 권한 부족(채널 관리), 404: 서버·카테고리 없음(카테고리면
`discord.json` 의 ID 를 비우고 다시 만든다), 429: `retry_after` 만큼 기다렸다 재시도(최대 3회).

**세션이 죽었을 때** — `ls` 에 "꺼짐". `start <작업>` 은 같은 워크트리에서 `claude --continue` + 같은 플래그로
다시 띄운다(직전 대화 이어감). 자동 재시작은 안 한다.

**재부팅** — tmux 가 사라진다. `start --all` 로 `sessions.json` 의 세션을 다시 띄운다.

**워크트리 삭제와 연동** — `remove_worktree` 로 지워지는 모든 경로(대시보드 · 유휴 일괄 정리 · 7일 자동 삭제)에서
그 워크트리의 세션을 `rm` 한다. `rm` 실패는 워크트리 삭제를 막지 않는다(경고만).
**유휴 판정** — `idle_verdict` 가 살아 있는 tmux 세션이 있는 워크트리를 활동 중으로 본다(자동 삭제 제외).

**채널을 Discord 에서 직접 지웠을 때** — `ls` 에 "채널 없음", `rm` 이 나머지를 정리한다.

## 2.5 상태 보이기 (상시 감시 없이, 이벤트로만)

형 피드백(2026-10-01): "작업 중인지 멈춘 건지 헷갈린다", "실행할 PC 가 켜져 있나 보이나", "데몬 감시는 비효율".
마리나 데몬은 건드리지 않는다.

| 알고 싶은 것 | 신호 | 누가 |
|---|---|---|
| 받음 · 작업 중 | 형 메시지에 👀 | 채널 플러그인(기본 `ackReaction`) |
| 끝남 · 대기 | 👀 → ✅ | claude **Stop 훅** — 세션마다 `--settings <상태 폴더>/settings.json` 으로 넣는다. 훅은 `marina_session.py hook-stop` 을 불러 세션 기록에서 마지막으로 받은 이 채널 메시지를 찾아 반응을 바꾼다 |
| 세션이 죽음 | 채널에 "⚠ 세션이 꺼졌어(종료 코드 N) — `marina session start <ref>`" | tmux 안에서 claude 를 `sh -c 'claude …; marina_session.py notify-exit <ref> $?'` 로 감싼다. claude 가 스스로 끝나면 알리고, `stop`·`rm` 의 kill-session 은 셸째 죽어 알리지 않는다 |
| PC 가 켜져 있음 | Discord 멤버 목록의 봇 온라인 표시 | Discord(채널 세션이 하나라도 접속해 있으면 온라인) |

- 훅·알림은 어떤 실패에도 claude 세션을 방해하지 않는다(항상 exit 0, 오류는 삼킨다).
- 훅은 claude 의 깨끗한 env 에서 돈다 → 실행할 때 `MARINA_HOME`(테스트면 `MARINA_DISCORD_API`·`MARINA_CHANNELS_DIR`)을 env 에 넣어 준다.
- 봇 온라인 표시가 의미 있으려면 채널 세션만 봇에 접속해야 한다. 플러그인을 사용자 범위로 켜 두면 형이 여는
  모든 세션이 접속을 시도한다(토큰은 기본 폴더에 없어 실패하지만 이미 떠 있던 세션은 남는다). → 사용자 범위에서
  끄고 `--settings` 의 `enabledPlugins` 로 채널 세션에서만 켜지는지 실측해서, 되면 그렇게 하고 안 되면 지금
  상태(사용자 범위 켬 + 기본 폴더 토큰 없음)를 유지한다.

## 3. 테스트

`plugin/tests/test-session-*.sh`, 모두 `lib/harness.sh` 를 source 한다.

**바꿔 끼우는 것**
- Discord: 테스트가 띄운 가짜 HTTP 서버, `MARINA_DISCORD_API` 로 연결. 받은 요청을 기록해 단언한다.
- claude: PATH 앞의 가짜 `claude` — 받은 인자 · `DISCORD_STATE_DIR` 을 파일로 남기고 대기.
- tmux: 진짜 tmux, **테스트 전용 소켓**(`MARINA_TMUX_SOCKET` → `tmux -L <소켓>`). 죽이는 동작은 그 소켓 안에서만.
  (2026-09-14 리퍼 테스트가 격리 없이 형 프로세스를 죽인 사고의 재발 방지)

**확인할 것**
1. `new` 정상: claude 인자 4종 · 채널 규칙 포함, `access.json` 내용, 토큰 심링크, 상태 폴더 권한 700,
   `sessions.json` 기록, 카테고리 생성 후 그 아래 채널 생성 요청.
2. 사전 점검: 이름이 겹치면 Discord 요청 0 · 파일 0 으로 중단.
3. 되돌리기: tmux 실패 시 채널 삭제 요청 · 상태 폴더 삭제 · 워크트리 남음.
4. Discord 오류: 401/403 메시지, 429 재시도 후 성공.
5. `stop` · `start`(`--continue` 인자) · `start --all` · `rm`.
6. `remove_worktree` 가 세션 `rm` 을 부르고, `rm` 실패가 삭제를 막지 않음. `idle_verdict` 가 살아 있는 tmux 를 활동 중으로 봄.
7. python 3.9 호환(기존 `test-py39-compat`).
8. Stop 훅: 기록의 마지막 이 채널 메시지에 ✅ 추가 · 👀 제거 요청, 기록·세션 없음이면 조용히 끝남.
9. 죽음 알림: claude 가 스스로 끝나면 채널에 알림 1건, `stop`·`rm` 으로 끈 건 알림 0건.

**실제 확인(수동 1회)** — ovation 에서 `marina session new` → 채널에 메시지 → 답장 → claude.ai 에서 진행 보기 →
`marina session rm` 으로 채널까지 정리. 이때 ✅ 반응 · 죽음 알림 · 봇 온라인 표시도 같이 본다.

## 남은 결정 (구현 중 형 확인)

- 채널을 지우기 전에 대화를 파일로 남길지 — 지금은 안 남긴다(진짜 기록은 세션 jsonl · git).
- 세션이 많아져 메모리가 부담되면 깨우기 방식(헤르메스 브리지)으로 — 그때 별도 스펙.
