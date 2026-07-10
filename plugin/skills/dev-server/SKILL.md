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
- 브라우저 URL: 게이트웨이 `http://<워크트리>.<프로젝트>.localhost:3902` (`marina gateway status` 로 확인)

## 문제 해결

- 포트를 코드·설정에 하드코딩하지 말 것 — worktree 마다 다르다. `marina status` 로 조회해서 쓴다.
- compose 정의(서비스·env·마운트) 변경: 대시보드(:3900)의 ✎ compose 편집 또는 `marina project add <path> --compose`.
- 엮기(컨테이너 안 localhost → 호스트 인프라)는 compose 의 `x-marina.forward` 에 선언한다.
- 정말 직접 실행이 필요하면 명령 앞에 `MARINA_DIRECT=1 ` 을 붙인다(차단 우회) — 포트 충돌은 감수.
