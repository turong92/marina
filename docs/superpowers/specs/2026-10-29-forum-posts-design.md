# 지시별 포럼 글 (Discord 방 스레드 → 프로젝트 📋작업 포럼) 설계

형 결정(2026-10-29): 형은 지금처럼 방(텍스트 채널)에서 시킨다. 마리나가 프로젝트마다 포럼 하나를 두고, 지시 하나에
글 하나를 알아서 만들고·태그 바꾸고·닫는다. 방 채널에는 형 지시와 끝 보고만 남긴다.

## 목표 (형에게 보이는 것)

1. 프로젝트마다 `📋작업` 포럼 채널 하나(그 프로젝트 카테고리 안). 코덱스 방은 chat-bot 카테고리에 하나.
2. 지시 메시지에 진행이 생기면(지금 진행 스레드가 생기는 그 순간 — `_progress` 첫 호출) 스레드 대신 포럼 글을 만든다.
   - 제목 `[<task>] <지시 첫 줄>` (100자 안), 첫 글은 원래 메시지 링크 + 지시 본문 첫 몇 줄, 태그 `진행중`.
   - 형 메시지에는 알림 없는 답 한 줄 `📋 진행 → <#글>` (flags 4096, 답 대상 = 그 지시).
   - 짧은 답(진행 없이 reply 만)은 글을 만들지 않는다 — 포럼이 잡담으로 차지 않게.
3. 그 지시의 진행 줄(progress 도구)·훅 상태 줄·서브에이전트 줄은 모두 그 글로 간다(지금 스레드로 가던 것 전부).
4. 방끼리(📨) 줄은 받는 방마다 하나의 고정 글 `[<task>] 📨 방끼리`(태그 없음)로 간다 — 지금 방 채널 밑 '📨 방끼리' 스레드 대체.
5. 태그
   - `답 필요` — 그 방에 질문 카드(question.json)가 뜰 때. 질문이 끝나면(done) `진행중`으로 되돌림.
   - `끊김` — crash_tick 이 그 방을 다시 켤 때(현재 지시 글).
   - `완료` — 그 지시에 reply_to 로 답이 나갔을 때: 답 본문을 글에 복사하고 태그 `완료`, 글 닫기(archived).
     Claude 방 = PostToolUse(mcp__plugin_discord_discord__reply) 훅, 코덱스 방 = `_reply` → `close_instruction`.
   - 완료된 글에 같은 지시로 다시 progress 가 오면 다시 열고 `진행중`.
6. 형이 포럼 글 안에 쓴 글은 그 방 세션에 들어간다.
   - 포럼은 access.json groups 에 넣지 않는다(넣으면 프로젝트 모든 방이 다 받는다).
   - 봇(bot.ts)이 부모가 포럼인 글을 받으면 글 id 를 넘기고, wake 가 `forum-posts.json`(글 → 방) 으로 방을 찾는다.
   - 꺼진 방: 지금 깨우기와 같은 길(첫 지시로). 켜진 방: room-send 처럼 쉬는 순간 입력창에
     `[마리나 · 포럼 글에서] <글 제목> 에 형이 덧붙임: <본문> (답은 방 채널에 reply_to=<원래 지시 id>)` 로 친다.
   - 허용 사용자 판정은 방의 allowFrom 그대로.

## 하지 않는 것

- open_thread(주제 스레드)는 그대로 둔다.
- 질문 카드·크래시 알림·코덱스 오류 알림의 위치는 그대로(방 채널). 태그만 바꾼다.
- 기존에 열린 스레드는 옮기지 않는다(자연히 7일 보관).
- 포럼 글 안의 글로 '새 지시'를 만들지 않는다(덧붙임만).

## 저장

- `discord.json`: `projects[<p>].forumChannelId`, `codex.forumChannelId` (+ 태그 id 맵 `forumTags`). 자료실(`archiveChannelId`) 선례대로
  존재 확인 후 없으면 `POST /guilds/{g}/channels {type:15, parent_id:카테고리, available_tags:[진행중,답 필요,완료,끊김]}`.
- 방 상태 폴더 `threads.json` 의 mid → id 는 이제 포럼 글 id(같은 장부를 그대로 써서 상태 줄·접기·에이전트 고정이 그대로 동작).
  표식 `threads-kind.json` 의 이름 바꾸기는 포럼 글 제목엔 쓰지 않는다.
- `$MARINA_HOME/forum-posts.json`: 글 id → {ref, mid, channelId} (최근 500).

## 코드 지도 (조사 결과, file:line 은 2026-10-29 HEAD 기준)

- 진행 스레드 생성: `marina_session._progress` (~S:4154, `POST /channels/{방}/messages/{mid}/threads`) — 여기를 포럼 글 생성으로.
- 상태 줄: `_hook_activity_locked` 가 `threads.json[mid]` 로 올림 — 장부가 같으면 그대로.
- 턴 끝 접기: `hook_stop` → `_turn_end_archive` / `_archive_threads` — 그대로(글도 PATCH archived).
- 코덱스 끝: `marina_codex._reply` → `ms.close_instruction` — 여기에 완료 처리.
- 에이전트 줄: `marina_discord_bot._role_events_post`·`agent_words_tick` → `ms._progress` — 목적지 자동 변경.
- 방끼리: `marina_discord_wake.room_thread`/`post_room_line` — 고정 글로.
- 질문: `marina_discord_ask.post_question`(쓴 직후 답 필요) / `done`(되돌림).
- 크래시: `marina_discord_bot._crash_resume` — 끊김.
- 받기: `marina-discord-bot/bot.ts` MessageCreate(부모가 포럼이면 바꾸지 않고 글 id 전달), `marina_discord_wake.wake`(글 → 방 매핑).
- 훅 등록: `marina_session` settings 생성부(~S:1985–2008, AskUserQuestion PostToolUse 선례).
- 테스트 더블 `plugin/tests/lib/fake_discord.py` 는 포럼 글(`POST /channels/{forum}/threads` 의 message·applied_tags, PATCH applied_tags)을 모른다 — 먼저 확장.

## 검증

- fake_discord 로 단위 테스트: 글 생성·링크 답·태그 전환(진행중→답 필요→진행중→완료, 끊김)·완료 복사·재개·방끼리 고정 글·포럼 글 → 방 매핑.
- 실제 Discord: 배포 후 marina 방에서 지시 하나로 글 생성·완료까지 한 번 확인.
