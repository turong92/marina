# 역할 에이전트 — 정해진 대로, 보이게, 아끼게

2026-10-04 · 상태: 초안(형 검토 대기)

## 1. 왜

형 말 그대로(2026-10-04):

> 지금 모든 판단을 클로드가 하고 있고, 서브 에이전트 돌리는데 어떤 식으로 돌리는지도 모르겠고 무슨 스킬을 쓰는지도 모르겠고 모델이랑 effort 도 뭐로 하는지 모르겠고. 블랙박스가 너무 커서 불안한 부분도 있어. 절감도 하고 싶고.

실제로 그랬다(2026-10-03 분리 작업):
- 리뷰어 정본은 `model: sonnet` 인데 지휘 세션이 Agent 호출마다 `model: opus` 로 덮어썼다. 형은 몰랐다.
- 서브에이전트 effort 는 지휘 세션 것을 물려받았고 어디에도 안 보였다.
- 어떤 스킬을 썼는지는 지휘 세션 대화 기록 안에만 있었다.
- #상태는 서브에이전트를 못 봤다(2026-10-04 고침, main 668c7e1).

## 2. 목표 / 비목표

**목표**
1. 역할(기획자·디자이너·개발자·QA·리뷰어)을 정본 파일로 정의한다. 모델·effort·스킬·도구가 파일에 박히고, **지휘 세션이 그때그때 바꾸지 못한다.**
2. 역할을 부를 때마다 **Discord 지시 스레드에 한 줄**(시작: 역할·모델·effort·스킬·할 일 / 끝: 걸린 시간·토큰)이 남는다. 지휘 세션이 잊어도 훅이 남긴다.
3. **역할별 사용량**을 주 단위로 보인다 — 어느 역할이 한도를 먹는지 보고 역할표를 고칠 근거.
4. 지휘 세션이 따를 **순서 규칙**을 스킬 하나(`/team`)로 둔다 — 요청 크기 → 거칠 역할 → 되돌림 → 멈춤 조건.

**비목표** (형과 합의, 따로 다룸)
- 프로젝트별 #메인 PM + 팀장 회의 — 이 바닥 위에 별도 스펙. Claude 세션간 메시징 vs 헤르메스 칸반은 3번 사용량을 보고 정한다.
- 헤르메스 — 보류(형 2026-10-04). 역할 정의는 나중에 헤르메스 프로필이 같은 정본을 읽을 수 있게 모델 중립으로 쓴다.
- 밤샘 무인 모드 — 이 위에 나중에.
- Jev·다른 API 모델 — 실행 주체 칸만 열어 두고 이번엔 claude·codex 두 가지.

## 3. 표준 우선

Claude Code 서브에이전트 정의(`~/.claude/agents/*.md`) frontmatter 가 이미 필요한 칸을 다 가진다: `model`, `effort`, `skills`(미리 싣기), `tools`. 훅도 `SubagentStart`/`SubagentStop`(agent_id·agent_type·transcript_path)이 있다. **새 장치를 만들지 않고 이것들만 쓴다.**

빈 곳 두 개만 메운다:
- **Agent 호출의 `model` 인자가 frontmatter 를 이긴다** — 블랙박스의 원인. → PreToolUse(Agent) 훅이 역할 호출이면 `model` 을 지운다(`updatedInput`).
- **훅에 토큰 수가 없다** → SubagentStop 때 서브에이전트 기록(`<session>/subagents/agent-<id>.jsonl`)의 `message.usage` 를 더한다.

## 4. 구성

### 4.1 역할 정본 (`~/IdeaProjects/sumin/shared/agents/`)

리뷰어(`code-reviewer.md`)와 같은 틀. 한 역할 = 파일 하나, frontmatter = 역할표의 한 줄.

```yaml
---
name: developer
description: "계획의 작업 하나를 TDD 로 구현하고 테스트 결과를 증거로 돌려준다. …"
model: sonnet
effort: medium
skills: [superpowers:test-driven-development]
tools: Read, Edit, Write, Bash, Grep, Glob
x-executor: claude          # claude | codex — 다른 하네스가 읽는 칸(Claude 는 무시)
---
```

연결: Claude 는 `~/.claude/agents/<역할>.md` 심볼릭 링크, Codex 는 `~/.codex/agents/<역할>.toml` shim(정본을 읽게만). 리뷰어와 똑같다.

**역할표 초안** — 형이 고친다:

| 역할 | 실행 | 모델 | effort | 스킬 | 권한 | 하는 일 |
|---|---|---|---|---|---|---|
| planner 기획자 | claude | opus | high | brainstorming·writing-plans | 읽기 + 문서 쓰기 | 요구 → 스펙 초안·작업 목록 + **정해야 할 것 목록** |
| designer 디자이너 | claude | opus | medium | (형 UI 취향 메모) | 읽기 + 목업 파일 | 화면·흐름 설계, HTML 목업 + 정해야 할 것 목록 |
| developer 개발자 | claude | sonnet | medium | test-driven-development | 전부(워크트리 안) | 작업 하나 TDD 구현, 테스트 결과 반환 |
| qa | claude | sonnet | low | aside-browser | 읽기 + 브라우저 | 실제 화면 눌러 보고 스크린샷·재현 단계 |
| code-reviewer 리뷰어 | codex | gpt-5.6-sol | high | — | 읽기 전용 | 변경분 리뷰(기존 정본) |

- 무거운 판단(기획·디자인)만 opus, 반복 구현은 sonnet, 리뷰는 Codex 한도로 뺀다 → 절감.
- **서브에이전트는 형에게 직접 못 묻는다.** 기획자·디자이너는 묻지 않고 "정해야 할 것" 목록을 돌려주고, 지휘 세션이 형에게 버튼으로 묻는다.
- codex 실행 역할은 지휘 세션이 `shared/bin/role-run <역할> <할 일 파일>` 로 부른다(`codex exec` + shim, 같은 시작·끝 로그를 남김). Agent 도구로 부르면 훅이 막고 role-run 을 쓰라고 돌려준다.

정본 폴더는 git 밖이다 → 이번에 `shared/` 를 git 레포로 만든다(이력·되돌리기). push 는 안 한다(로컬).

### 4.2 고정 훅 (`shared/bin/role-hook`, 사용자 설정 `~/.claude/settings.json` 에 등록)

역할은 모든 세션(데스크톱·Discord·터미널)에서 쓰이므로 훅도 사용자 범위. 마리나와 무관하게 혼자 돈다.

- **PreToolUse(Agent)**: `subagent_type` 이 역할이면
  - `model` 인자가 있으면 지우고(`updatedInput`) 이벤트에 `override_blocked` 기록 — frontmatter 가 이긴다.
  - `x-executor: codex` 역할이면 거부 + "role-run 으로" 안내.
- **SubagentStart / SubagentStop**: 이벤트를 `~/.local/state/roles/events.jsonl` 에 한 줄씩.
  - 시작: 시각·세션·agent_id·역할·모델·effort·스킬·할 일 설명(Agent 입력의 description).
  - 끝: 시각·agent_id·걸린 시간·토큰(기록 파일 usage 합: 입력·출력·캐시 읽기)·모델별.
- 역할이 아닌 서브에이전트(general-purpose 등)도 같은 이벤트로 남긴다(역할 = `-`). 블랙박스는 그쪽이 더 크다.

훅은 1초 안에 끝나고 실패해도 도구를 막지 않는다(`|| true`, 거부는 codex 경우만).

### 4.3 Discord 에 보이기 (marina-discord)

marina-discord 는 이벤트 파일만 읽는다 — 역할 쪽 코드를 import 하지 않는다.
- **지시 스레드 한 줄**: 세션 진행 표시(이미 있는 PreToolUse 진행 훅·progress 스레드)와 같은 길로 `🤖 developer 시작 · sonnet/medium · TDD · 결제 버그 Task 3` / `✅ developer 끝 · 4분 · 52k`.
  - 이벤트의 session_id 가 Discord 세션이면만. 데스크톱 세션은 파일에만 남는다.
- **#상태 역할별 사용량**: 이번 주(주간 한도 리셋 기준) 역할별 토큰·호출 수·모델 한 블록.
  - 5분마다 이벤트 파일 끝을 읽어 집계(파일은 주 단위로 회전).

### 4.4 지휘 규칙 (`/team` 스킬, `shared/skills/team/`)

지휘 세션이 요청을 받으면:

```
크기 판정 (지휘 세션이 판정 이유 한 줄을 스레드에 남긴다)
├ 작은 수정(1~2 파일)   → developer → code-reviewer
├ 기능 하나            → planner → (화면 있으면 designer) → 형 확인(버튼)
│                        → developer → code-reviewer → (화면 있으면 qa)
└ 구조 변경            → 위와 같고 스펙·계획 두 번 형 승인
되돌림: 리뷰어·QA 지적 → developer 에 지적 원문 그대로, 최대 3바퀴. 넘으면 멈추고 형에게
멈춤: 기획·디자인 확정, push·배포, 3바퀴 초과 — 나머지는 쭉
```

- 기존 superpowers 스킬(brainstorming·writing-plans·executing-plans)과 겹치는 단계는 그 스킬을 역할의 `skills` 로 싣는다 — 같은 일을 두 번 정의하지 않는다.
- 규칙은 강제가 아니라 지휘 세션이 따르는 절차다. 강제되는 건 4.2(모델·실행 주체)뿐.

## 5. 경계

- `shared/` (역할 정본·role-hook·role-run·/team) — 마리나 없이 돈다. 공개 대상 아님.
- marina-discord — 이벤트 파일을 읽어 보여 주기만. 이벤트 파일이 없으면 아무것도 안 한다.
- runtime 플러그인 — 무관.

## 6. 검증

- 단위: role-hook(모델 인자 제거·codex 거부·이벤트 줄 형식·usage 합), role-run(가짜 codex), Discord 표시(가짜 Discord), 주간 집계.
- 실측:
  1. 이 세션에서 `developer` 를 `model: opus` 로 불러도 실제 sonnet 으로 도는지(기록 파일의 message.model).
  2. `effort`·`skills` frontmatter 가 실제로 먹는지(기록 첫 줄·시스템 프롬프트).
  3. Discord 테스트 채널에서 시작·끝 줄, #상태 역할별 사용량.
  4. code-reviewer 를 role-run(codex)으로 한 번.

## 7. 형이 정할 것

1. 역할표 초안(모델·effort) — 특히 디자이너 opus 냐 sonnet 이냐, 리뷰어를 Codex 로 옮기냐.
2. `shared/` 를 git 레포로 만들어도 되나(로컬만).
