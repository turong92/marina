# Mobile Native Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 모바일 Marina에서 Claude와 Codex의 원래 호출 문법을 유지하면서 기존 세션의 대화, 스킬, 참조, 서브에이전트를 편하게 사용한다.

**Architecture:** `marina_sessions.py`가 기존 로그를 대화 턴과 서브에이전트 활동으로 정규화하고, `marina_mobile.py`가 worktree별 네이티브 카탈로그와 모바일 상태를 조합한다. embedded HTML은 소스별 입력 어댑터, 안전한 링크 렌더러, 세션별 초안, 서브에이전트 바텀시트를 담당하며 기존 resume 기반 전송 API는 유지한다.

**Tech Stack:** Python 3 stdlib, embedded HTML/CSS/vanilla JavaScript, bash contract tests.

## Global Constraints

- Marina 고유 에이전트 또는 스킬 호출 문법을 만들지 않는다.
- Claude는 `/skill`, `@agent`, `@file`; Codex는 `$skill`, `@file`, 자연어 위임을 유지한다.
- 확인되지 않은 TUI 전용 명령을 자동완성에 노출하지 않는다.
- 대화와 자식 작업에 기존 민감정보 마스킹을 적용한다.
- 기존 `/mobile/api/state`, `/mobile/api/send` 인증과 전송 계약을 깨지 않는다.

---

### Task 1: 서브에이전트 활동 파서

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_sessions.py`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Produces: `agent_activity(root: Path, source: str, sid: str) -> list[dict[str, Any]]`
- Produces: agent session field `subagents: list[dict]`

- [x] Claude Agent tool과 Codex `spawn_agent` 기록 fixture를 만드는 실패 테스트를 추가한다.
- [x] 테스트를 실행해 `agent_activity` 부재로 실패하는지 확인한다.
- [x] 두 로그 형식을 `{id, title, status, preview, turns}`로 정규화하고 마스킹한다.
- [x] 모바일 agent session에 `subagents`를 추가한다.
- [x] 파서와 모바일 상태 테스트를 통과시킨다.

### Task 2: 소스별 네이티브 카탈로그

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Produces: `_native_catalog(root: Path, source: str) -> dict[str, list[dict[str, str]]]`
- Produces: agent session field `catalog: {skills, agents}`

- [x] Claude/Codex 프로젝트 스킬과 에이전트 fixture를 만드는 실패 테스트를 추가한다.
- [x] 테스트를 실행해 카탈로그 필드 부재로 실패하는지 확인한다.
- [x] 사용자/프로젝트 범위를 소스별로 탐색하고 이름, 설명, 삽입 문자열을 반환한다.
- [x] 선택한 세션의 상태 payload에 해당 소스 카탈로그만 포함한다.
- [x] 카탈로그 테스트와 전체 모바일 상태 테스트를 통과시킨다.

### Task 3: 대화 타임라인과 입력기

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Consumes: session `source`, `turns`, `preview`, `catalog`
- Produces: safe `renderRichText`, source-aware `renderSuggestions`, per-session draft keys

- [x] 최근 작업 제거, 역할명 제거, 안전한 링크, 세션별 초안, Enter 동작, 재시도 상태의 HTML 계약 실패 테스트를 추가한다.
- [x] 테스트를 실행해 새 UI 계약이 빠져 실패하는지 확인한다.
- [x] 메시지 정렬과 터미널 마지막 출력, 안전한 Markdown/bare URL 링크를 구현한다.
- [x] 자동 높이, 세션별 초안, Enter/Shift+Enter, 실패 재시도를 구현한다.
- [x] Claude `/`·`@`, Codex `$`·`@` 자동완성과 원본 문자열 삽입을 구현한다.
- [x] 자동 스크롤과 새 메시지 이동 버튼을 구현한다.
- [x] 모바일 계약 테스트와 JavaScript 구문 검사를 통과시킨다.

### Task 4: 서브에이전트 바텀시트와 실제 화면 검증

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`

**Interfaces:**
- Consumes: session `subagents`
- Produces: menu action, bottom sheet, read-only child detail

- [x] 메뉴 카운트와 바텀시트의 HTML 계약 실패 테스트를 추가한다.
- [x] 테스트를 실행해 서브에이전트 UI 부재로 실패하는지 확인한다.
- [x] 메뉴 항목, 상태 목록, 상세 턴 펼침과 닫기 동작을 구현한다.
- [x] 전체 셸/Python/JavaScript 검증을 실행한다.
- [x] 390x844 모바일 화면에서 세션 진입, 입력, 링크, 자동완성, 시트를 검증한다.
- [x] 발견한 레이아웃 또는 상호작용 문제를 수정하고 전체 검증을 반복한다.
