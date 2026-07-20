# Mobile Session Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 모바일 Marina에서 프로젝트와 실행 주체별로 기존 세션을 빠르게 찾고 바로 채팅에 붙는다.

**Architecture:** 기존 `/mobile/api/state` 응답을 클라이언트에서 프로젝트와 소스로 분류한다. 서버와 전송 계약은 유지하고 `_MOBILE_HTML`의 내비게이션, 렌더링, 로컬 상태만 변경한다.

**Tech Stack:** Python stdlib HTTP server, embedded HTML/CSS/vanilla JavaScript, bash contract tests.

## Global Constraints

- 인증, 세션 전송, 자동 갱신 API 계약을 변경하지 않는다.
- 360px 이상 모바일 화면에서 텍스트와 조작부가 겹치지 않는다.
- 선택한 프로젝트와 소스는 `localStorage`에 유지한다.

---

### Task 1: 모바일 탐색 계약

**Files:**
- Modify: `plugin/tests/test-mobile-control.sh`
- Modify: `plugin/scripts/marina_mobile.py`

- [x] 메뉴, 프로젝트 탭, 소스 탭, 그룹 렌더링 계약을 테스트에 추가한다.
- [x] `bash plugin/tests/test-mobile-control.sh`가 새 계약 누락으로 실패하는지 확인한다.
- [x] compact header와 메뉴를 구현한다.
- [x] 프로젝트/소스 분류, 선택 저장, 빈 상태를 구현한다.
- [x] 모바일 제어 테스트가 통과하는지 확인한다.

### Task 2: 회귀 및 모바일 화면 검증

**Files:**
- Verify: `plugin/scripts/marina_mobile.py`
- Verify: `plugin/tests/test-mobile-control.sh`

- [x] JavaScript 구문과 Python 구문을 검사한다.
- [x] 대시보드를 재시작하고 상태 API 응답을 확인한다.
- [x] 390x844 화면에서 목록, 메뉴, 필터, 세션 진입을 확인한다.
- [x] 발견한 겹침이나 터치 문제를 수정하고 전체 검증을 다시 실행한다.
- [x] 변경을 하나의 커밋으로 기록한다.
