# 결과물 보기 v2 — Discord 플러그인이 혼자 (대시보드·마리나 로그인 의존 제거)

2026-10-05 · 형 결정. v1(5da09fc, 대시보드 `/view` + 마리나 로그인 + Funnel)은 원칙 위반이었다:
플러그인 셋은 혼자 동작해야 하고, discord 기능이 대시보드에 묶이면 안 된다. 또 마리나 로그인이라 여자친구(채팅방)는 못 열었다.

## 형 결정
- 보는 주체 = **Discord 플러그인(marina-discord)** 자신. 마리나 대시보드·로그인 없음.
- **링크 자체가 열쇠**: 그 채널에 올라온 링크를 가진 사람이면 연다(여자친구 포함). 채팅방도 링크를 준다.
- **기한 없음 — 파일이 있는 동안 계속.** 끊는 명령 제공.
- md 미리보기 이미지(Discord 첨부)는 유지.
- 터미널 넘기기(ask_terminal → 대시보드 /term-run)는 그대로 두되 **선택 기능**: `marina term-request` 가 없거나 실패하면 세션에 "맥 앞에서 실행해 달라고 부탁해"로 안내(이미 그런지 확인, 아니면 그렇게).

## 구성 (전부 plugin-discord/)
- `marina_view.py`(discord 쪽 새 모듈, runtime import 금지):
  - 기록 `<MARINA_HOME>/discord-view/<token>.json`(디렉터리 0700, 파일 0600) = {root, rel, channel, ts}. token=secrets.token_urlsafe(24).
  - `create(root, path, channel)` — path 는 root 안 실제 파일(realpath), 비밀 이름 거부. 같은 (root, rel) 이면 기존 토큰 재사용.
  - `resolve(token)` — 만료 없음. 파일이 사라졌으면 None(기록도 지움).
  - `revoke(token|path|--all-in <root>)`.
- 보기 서버: discord 데몬(marina_session 데몬 루프)이 띄우는 작은 HTTP 서버 `127.0.0.1:<view.port, 기본 3905>`(스레드).
  - `GET /v/<token>/` → 토큰 파일. `GET /v/<token>/<sub>` → **토큰 파일과 같은 폴더 아래만**(realpath, `..` 거부), 확장자 allowlist(css js mjs png jpg jpeg gif webp avif svg ico woff woff2 ttf otf mp4 webm mp3 wav html htm md pdf), 비밀 이름 거부(v1 목록 그대로).
  - HTML·SVG: `Content-Security-Policy: sandbox allow-scripts allow-popups allow-forms; frame-ancestors 'none'`, nosniff, `Referrer-Policy: no-referrer`, no-store.
  - md: v1 md-view(marked+DOMPurify+mermaid, cdnjs 고정 파일 URL+SRI, 원문 JSON 이스케이프) 를 discord 플러그인으로 옮겨 그대로. CSP 는 v1 md CSP.
  - 20MB 초과 413. 모르는 확장자 404(allowlist 밖).
  - 로그는 토큰을 가린다.
  - 다른 origin(별도 포트)이라 대시보드 쿠키와 무관 — 티켓 장치 불필요(링크가 열쇠라 자산도 같은 토큰 경로로 그냥 열림).
- 공개 주소: 설정 `discord.json` 의 `view.publicBase`(예 `https://<맥>.ts.net:10000`). 없으면 링크 없이 미리보기 이미지만(지금처럼 조용히 생략 + 이유 note).
  - `marina-session view-setup` — `tailscale funnel --bg --https=10000 http://127.0.0.1:3905` 실행하고 publicBase 저장(형 허락 받고 한 번). tailscale 없으면 안내만.
- share_file: 개발·채팅 세션 둘 다, HTML·md·pdf·이미지에 `열어보기: <publicBase>/v/<token>/` 를 반환 문구에(세션이 reply 본문에 넣게).
- `marina-session view-revoke <경로|토큰>` CLI.

## 걷어낼 것 (runtime, v1)
- plugin/scripts/marina_view_links.py, marina-web/md-view.html·js, marina_handler 의 /view 경로·티켓, marina_auth_http 리다이렉트 목록의 /view, marina.sh·entrypoint 의 view-link, RUNTIME_MODULES 항목, test-view-links.sh. share_file 의 `marina view-link` 호출.
- 기존 v1 링크는 깨진다(배포 직후라 괜찮음).

## 검증
- 단위: create/resolve/revoke, 파일 지우면 None, 폴더 한정·allowlist·비밀 이름, CSP 헤더, md 원문 이스케이프, 토큰 로그 가림, publicBase 없을 때 생략, 채팅 세션도 링크, 경계 테스트(runtime import 0, runtime 쪽 /view 흔적 0).
- 실측(지휘 세션): 3905 로컬로 Aside 열기(HTML 상대 자산·md), Funnel 설정은 형 허락 후.
