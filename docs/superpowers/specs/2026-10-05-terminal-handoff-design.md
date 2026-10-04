# 터미널 넘기기 — 세션이 "형이 실행해 줘"를 Discord 버튼으로

2026-10-05 · 형 승인("어 해봐")

## 왜

세션이 사람 확인이 박힌 명령(`cloud prod db --admin` — stdin TTY + 환경 이름 직접 입력)을 형에게 부탁할 때,
Discord 만 보는 형은 실행할 길이 없었다. `! <명령>` 을 대신 쳐 줘도 Claude 셸 모드는 TTY 가 아니라 래퍼가 거부한다
(그게 래퍼의 목적). 결과: 세션이 래퍼를 우회해 admin 계정 파일로 prod DB 에 직접 붙었다(2026-10-04 mdc gcp-migration).

## 무엇

세션이 `ask_terminal(command, why)` 를 부르면 Discord 에 **[터미널에서 열기]** 링크 버튼이 뜬다. 형이 폰에서 누르면
marina 대시보드(로그인 필요)가 그 워크트리 폴더에서 진짜 PTY 셸을 열고 **명령을 입력만 해 둔다(Enter 안 침)**.
형이 보고 Enter → 래퍼가 묻는 환경 이름 입력. 결과는 그 터미널에 남는다.

## 구성

### runtime (plugin/)
- `marina_term_requests.py`: `<MARINA_HOME>/term-requests/<token>.json` (0600) = {root, command, why, ts}.
  - `create(root, command, why) -> token` — token=secrets.token_urlsafe(18). command 1~2000자, **개행·제어문자 거부**(입력만 해 두는데 개행이면 실행돼 버린다).
  - `claim(token) -> dict | None` — 한 번만(rename 으로 가져가 지움), 15분 지나면 None, 토큰 형식 검사.
- CLI `marina term-request <command> [--why <text>]` — cwd 워크트리 root 로 요청 생성, 열 주소 한 줄 출력.
  주소 base = `marina remote status` 의 url(tailscale/funnel) 있으면 그것, 없으면 `http://localhost:<대시보드 포트>`. 경로 `/term-run?t=<token>`.
  전역 `marina` 입구(marina-entrypoint.sh)에도 라우팅 + usage(2026-10-05 forward 때 빠뜨려 unknown command 났다).
- handler: `GET /term-run` → 정적 페이지(로그인 안 됐으면 `/` 와 같은 로그인 리다이렉트). `GET /api/term-request?t=` → claim → `_require_root_access(root)` → {root, command, why}.
  없거나 만료·사용됨 → 404 {error}.
- 페이지 `marina-web/term-run.html`(+js): 폰 우선 전체화면. 위에 why·명령 한 줄, "입력만 해 뒀어 — 확인하고 Enter". xterm(vendor-xterm) 하나,
  기존 API 그대로: term-open{root,cols,rows} → term-stream(SSE snap/out/exit, b64) → term-input 으로 command(개행 없이). 키 입력은 xterm onData → term-input 직렬.
  폰 키보드에 Enter 가 애매하니 [Enter] 버튼 하나.

### discord (plugin-discord/)
- 개발 세션 MCP 도구 `ask_terminal` {command, why}: 그 세션 root 를 cwd 로 `marina term-request` 실행 → 주소.
  채널에 메시지: 🖥 why + 명령 코드블록 + 링크 버튼(style 5 "터미널에서 열기"). 반환: "버튼 보냈어 — 형이 실행하고 알려 주면 이어서".
- 세션 안내문(채널 지시)에 한 줄: 형이 직접 실행해야 하는 명령(사람 확인 래퍼 등)은 `!` 부탁 대신 ask_terminal. 래퍼 안전장치를 우회하지 않는다.

## 경계·안전
- 명령은 입력만 — 실행은 형의 Enter. 토큰 1회·15분. 페이지·API 는 로그인 + root 접근 권한(기존 터미널과 같은 정책).
- discord 플러그인은 runtime 코드를 import 하지 않고 `marina` CLI 만 부른다.
- 데몬 python3.9 호환.

## 검증
- 단위: create/claim(1회·만료·형식·개행 거부), CLI 출력, API 404/권한, 입구 라우팅, discord 도구(가짜 Discord 로 버튼 컴포넌트).
- 실측: Aside 로 폰 크기 뷰포트에서 링크 열기 → 터미널에 명령이 입력돼 있고 실행 안 됨 → Enter 버튼 → 실행(무해한 명령 `echo`).
