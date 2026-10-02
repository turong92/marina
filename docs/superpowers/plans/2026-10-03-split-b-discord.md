# 분리 B — discord 독립 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** discord 코드(marina_session·marina_discord_bot·marina_discord_ask·marina_share·marina-discord-bot/)가 dashboard 코드를 전혀 안 부르고, runtime 은 **있으면** `marina` CLI 로만 쓰며, 자기 상주 프로그램·자기 명령(`marina-session`)으로 혼자 돈다. 폴더를 실제로 옮기는 건 D(물리 분리)에서 한다.

**Spec:** `docs/superpowers/specs/2026-10-03-runtime-plugin-boundary-design.md` (R0·R3·R5·§6)

## Global Constraints
- 데몬 python 3.9. `from __future__ import annotations`. test-py39-compat 통과.
- 테스트는 `lib/harness.sh`·`lib/session_fixture.sh` 격리. 실제 Discord·tmux·launchd 를 건드리지 않는다.
- 지금 쓰는 동작은 하나도 안 바뀐다(형의 세션 21개가 그대로 돈다). push·배포는 형이 확신 생기면.

## Rulings (계획 단계에서 정함)
- **워크트리 생성은 `claude --worktree` 가 아니라 runtime CLI(`marina worktree create`)가 있으면 그것, 없으면 `git worktree add`.** 스펙 3장은 `--worktree`+`--settings` 훅을 그렸지만 실측 4(깨끗한 워크트리는 `/exit` 에 묻지 않고 삭제, resume 해도 같음) 때문에 Discord 세션을 Claude '워크트리 세션'으로 만들면 runtime 이 없을 때 지킬 수단이 없다. 같은 표준(git 워크트리 + git 잠금)이고 runtime 은 CLI(R2 의 원래 입구)로만 부른다. — 비용: 스펙 R0 의 "discord 는 runtime 을 안 부른다"가 "있으면 CLI 로만 부른다"로 바뀐다(스펙 갱신).
- 사용량·컨텍스트 % 는 discord 사본(`marina_discord_usage.py`, R3).

## Tasks

### Task 1: discord 경계 테스트
- `plugin/scripts/DISCORD_MODULES`(marina_session·marina_discord_bot·marina_discord_ask·marina_share·marina_discord_usage) + `tests/test-discord-boundary.sh`: 이 목록 모듈은 목록 안 모듈만 import(runtime·dashboard 금지 — runtime 은 CLI 로만). 셸·하위프로세스로 `marina.sh`·`marina-control.py`·`marina-dashboard.sh` 를 직접 부르면 위반(`marina` PATH 명령은 허용).
- RED: 지금 marina_sessions·marina_liveness import, MARINA_SH 사용으로 실패.

### Task 2: 사용량·컨텍스트 % 사본
- `marina_discord_usage.py`: `claude_windows() -> list[dict]`(5시간·주간 — marina_usage 의 직접 조회 + claude-hud 캐시 폴백과 같은 결과 형식 `{"key","label","usedPercent","resetsAt"}`), `context_percent(transcript: Path) -> float | None`.
- marina_discord_bot 의 두 `import marina_sessions` 를 이것으로.
- 테스트: test-discord-usage.sh — 같은 입력(가짜 transcript·가짜 사용량 응답)에서 marina_sessions 와 같은 값.

### Task 3: git 잠금 사본 + runtime 은 CLI 로만
- marina_session 에 `_git_lock(root, owner, desc)`·`_git_unlock(root, owner)`·`_git_lock_info(root)`(marina_liveness 와 같은 규칙: pid 죽으면 낡음) — import 제거.
- `MARINA_SH` 제거 → `_marina_bin()`: PATH 의 `marina`(없으면 None). worktree_create: 있으면 `marina worktree create …`, 없으면 `git -C <root> worktree add -b <task> <root>/.claude/worktrees/<san> [<base>]`(기존 브랜치면 체크아웃). marina_start: runtime 없으면 건너뛰고 경고 없음.
- 테스트: test-session-no-runtime.sh — PATH 에서 marina 를 숨긴 상태로 `marina_session new` → git 워크트리 생성·잠금·채널, `start` 는 서비스 시작 안 함. 기존 test-session-*.sh 는 marina 가 있는 경로로 그대로 통과.

### Task 4: 자기 상주 프로그램
- `marina-discord.sh`(start|stop|status|ensure, 라벨 `marina.discord`, 기본 홈만 launchd·나머지 nohup — runtimed 와 같은 규칙) + `marina_discord_bot.run_forever` 를 `__main__` 으로.
- marina_handler 의 `_discord_loop` 제거. 대신 discord 가 스스로 띄운다: `marina_session` 의 훅 진입(hook_stop·hook_prompt)과 new/start/restart 가 `ensure_daemon()`(pid 파일 확인, 없을 때만 spawn — 훅 지연 < 50ms).
- 테스트: test-discord-daemon.sh — ensure 가 한 번만 띄움(두 번째는 already), 훅 진입이 ensure 를 부름, handler 에 `_discord_loop` 없음.

### Task 5: `marina-session` 명령
- `plugin/bin/marina-session`(discord 진입, 지금은 같은 폴더 marina_session.py). runtime `marina session …` 은 PATH 의 `marina-session` 이 있으면 그리로, 없으면 지금처럼(전환기).
- CHANNEL_RULES·안내 문구의 `marina session` → `marina-session`.
- 테스트: test-entrypoint-routing 에 `marina-session ls` 케이스.

### Task 6: 스펙 갱신 + 전체 테스트
- 스펙 R0·§3 의 discord 줄을 Ruling 대로 고침. `run-affected --deep`, py39, 두 경계 테스트.

## Review Focus
1. 훅 진입의 ensure_daemon 이 훅을 느리게 하거나(매 도구 호출마다) 실패로 훅을 깨뜨리면 안 된다.
2. 전환: 대시보드가 더는 봇을 안 띄우는 순간과 discord 가 스스로 띄우는 순간 사이에 봇 공백. 대시보드 재시작 직후 첫 훅까지 #상태·🛑 이 멈출 수 있다.
3. runtime 없는 경로의 git 워크트리 생성이 runtime 경로와 같은 위치·브랜치 이름이어야 나중에 runtime 을 깔아도 이어진다.
