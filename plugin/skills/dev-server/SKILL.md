---
name: dev-server
description: Use when starting, stopping, or restarting a dev server, or checking service logs, ports, or preview URLs in this project — the dev runtime is managed by marina (do not run npm run dev / gradlew bootRun / docker compose up directly)
---

# marina dev-server

이 프로젝트의 dev 서버는 marina 가 worktree 별로 격리 실행한다. 직접 실행(`npm run dev`·`./gradlew bootRun`·`docker compose up`)은 PreToolUse 훅이 차단한다 — 워크트리 간 포트 충돌·상태 간섭 때문이다.

## 명령

- 기동: `marina start <서비스>` (전체는 `--all`)
- 정지/재시작: `marina stop <서비스>` · `marina restart <서비스>`
- 상태·실제 포트: `marina status` — 호스트 포트는 Docker 자동할당이라 워크트리마다 다르다. 포트는 항상 여기서 확인.
- 로그: `marina logs <서비스>`

## 브라우저 접근 — 게이트웨이 도메인만 (매핑 포트 금지)

브라우저 QA·미리보기·e2e 는 **반드시 게이트웨이 도메인**으로 접근한다:

- 웹: `http://<워크트리>.<프로젝트>.localhost:3902` (예: `http://my-feature-1a2b3c.mdc-main.localhost:3902`)
- 기타 서비스: `http://<워크트리>-<서비스>.<프로젝트>.localhost:3902`
- 도메인↔현재 포트 매핑: `marina gateway config` · 게이트웨이 상태: `marina gateway status`

`marina status` 의 매핑 포트(`127.0.0.1:5xxxx`)로 직접 붙지 말 것 — 컨테이너 재시작마다 포트가 재할당돼 **origin 이 바뀌고 로그인 쿠키·세션이 통째로 소멸**한다(사용자가 다시 로그인해야 함). 게이트웨이는 포트 재할당을 자동 추적하는 안정 origin 이라 재시작 후에도 세션이 유지된다. 매핑 포트는 curl 헬스체크 같은 무상태 확인에만 쓴다.

## 문제 해결

- 포트를 코드·설정에 하드코딩하지 말 것 — worktree 마다 다르다. `marina status` 로 조회해서 쓴다.
- compose 정의(서비스·env·마운트) 변경: 대시보드(:3900)의 ✎ compose 편집 또는 `marina project add <path> --compose`.
- 엮기(컨테이너 안 localhost → 호스트 인프라)는 compose 의 `x-marina.forward` 에 선언한다.
- 정말 직접 실행이 필요하면 명령 앞에 `MARINA_DIRECT=1 ` 을 붙인다(차단 우회) — 포트 충돌은 감수.
