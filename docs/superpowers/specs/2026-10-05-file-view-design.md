# 결과물 보기 — HTML·md 를 폰에서 열고, md 도 Discord 미리보기

2026-10-05 · 형 결정: "폰에서 열어보는 링크" + "md 도 미리보기 이미지"

## 지금
`share_file`(plugin-discord marina_session.chat_tool)은 HTML 이면 한 장짜리 스크린샷(marina_share.render_html) + 파일, md 는 파일만.

## 무엇
1. **열어보기 링크** — share_file 이 HTML·md(그리고 png/jpg/svg/pdf 같은 브라우저가 여는 것)에 대해 보기 주소를 만들어 돌려준다.
   세션은 reply 본문에 그 주소를 넣는다(반환 문구에 그렇게 지시). 폰에서 누르면 대시보드(로그인 필요)가 보여 준다.
2. **md 미리보기 이미지** — md 도 렌더해 스크린샷을 첨부(HTML 과 같은 길). 길면 여러 장(최대 4장, 세로로 잘라서).

## runtime (plugin/)
- `marina_view_links.py`: `<MARINA_HOME>/view-links/<token>.json`(디렉터리 0700, 파일 0600) = {root, rel, ts}. token=secrets.token_urlsafe(18).
  - `create(root, path) -> token` — path 는 root 안 실제 파일(realpath 로 탈출 차단), root 는 등록된 워크트리(term-request 와 같은 판정). 같은 (root, rel) 이면 기존 토큰 재사용.
  - `resolve(token) -> (root, rel) | None` — 여러 번 쓸 수 있음, **7일** 지나면 None. 토큰 fullmatch.
- CLI `marina view-link <path>` — 주소 한 줄(base 는 term-request 와 같은 규칙: remote url 있으면 그것). 전역 입구 라우팅·usage 도.
- handler `GET /view/<token>/<상대경로>`:
  - 로그인 + `_require_root_access(root)`. 비로그인은 로그인 리다이렉트(`/term-run` 처럼 목록에 추가, 인증 저장소 예외 분기 포함). 인증 꺼짐 + X-Forwarded 면 403(기존 터미널 가드와 같음).
  - `<상대경로>` 가 비면 토큰의 rel. 아니면 **토큰 파일과 같은 폴더 기준** 상대 경로(HTML 의 상대 자산 css/js/img 가 열리게) — realpath 가 root 안이어야 하고 `.git`·`.claude`·`.env*`·`*.key` 등 설정·비밀 이름은 거부(share_file 의 _CHAT_CONFIG_NAMES 와 같은 정신).
  - HTML 응답: `Content-Security-Policy: sandbox allow-scripts allow-popups allow-forms` (불투명 origin — 대시보드 쿠키·API 접근 불가), `X-Content-Type-Options: nosniff`, no-store.
  - md(`.md`/`.markdown`) 를 rel 로 열면 렌더 페이지: 서버가 원문을 JSON 으로 심고 `marina-web/md-view.html`(+js)이 marked + mermaid(cdnjs 고정 버전, SRI) 로 렌더, DOMPurify 로 정화. 폰 우선 가독 스타일(표 가로 스크롤, 코드블록, 다크 모드). `?raw=1` 이면 원문 text/plain.
  - 그 외 정적 파일은 확장자별 content-type, 모르면 application/octet-stream + attachment.
- 크기 제한: 20MB 넘는 파일은 413.

## discord (plugin-discord/)
- share_file:
  - 보기 주소: `marina view-link <path>`(cwd=root) 결과를 반환 문구에 `열어보기: <url> — reply 본문에 이 주소를 넣어` 로. 실패해도 첨부는 그대로(주소만 빠짐, 이유 note).
  - md 미리보기: md → HTML(같은 md-view 렌더러를 정적 파일로 쓰거나, 임시 HTML 에 marked 를 인라인) → 기존 render_html 로 스크린샷. 세로로 길면 최대 4장으로 잘라 첨부(앞쪽부터). 실패하면 md 파일만 + 이유.
- discord 플러그인은 runtime 코드를 import 하지 않고 `marina` CLI 만 부른다(term-request 와 같은 방식, 봇·세션 env PATH 주의 — 세션 MCP 는 세션 env 라 괜찮지만 확인).

## 검증
- 단위: create/resolve(만료·재사용·탈출·비밀 이름 거부), /view 권한(401→로그인·403·200), CSP sandbox 헤더, 상대 자산, md 렌더 페이지 정적 점검(원문 JSON 이스케이프 — `</script>` 주입), share_file 반환에 주소, md 미리보기 장수 제한(가짜 render_html).
- 실측: Aside 로 md(표·코드·mermaid)와 상대 자산 있는 HTML 을 /view 로 열기, Discord 에서 md 미리보기 이미지.

## 보안 결정 (2026-10-05 리뷰 반영)
**왜 티켓이 있나.** HTML 은 샌드박스(불투명 origin)로 열어야 대시보드 쿠키·API 에 못 닿는다. 그런데 그 문서가 보내는 css/js/img 요청에는
SameSite=Lax 쿠키가 안 실려 로그인 경로로는 못 연다. 그래서 로그인·root 권한을 통과한 열람이 **자산 티켓**을 발급하고, 페이지에
`<base href=/view/<token>/~/<ticket>/<폴더>/>` 로 심는다. 티켓 경로는 쿠키 없이 열리므로 **좁게** 만든다:
- 토큰 파일 폴더 **아래**만(realpath 기준, `..` 탈출·형제 폴더 거부 — root 전체를 비로그인으로 읽는 길을 막는다).
- 확장자 allowlist 만(css js mjs png jpg jpeg gif webp avif svg ico woff woff2 ttf otf mp4 webm mp3 wav html htm). json·txt·md·pdf 등 데이터·문서는 로그인 경로로만.
- 수명: 마지막 사용 후 5분 sliding, 최대 2시간. 메모리(데몬 재시작하면 소멸). 발급 시 principal 에 묶고(인증 꺼짐=None) 쓸 때마다 그 사용자의 root 권한과 토큰 만료·삭제를 다시 본다. 인증이 나중에 켜졌는데 principal 이 None 이면 거부.
- `Sec-Fetch-Dest: document`(주소창 이동)면 쿠키 경로 `/view/<token>/<sub>` 로 302 — 티켓이 주소창·히스토리에 남지 않는다.
- CORS 는 `Origin: null`(샌드박스 문서)일 때만 `access-control-allow-origin: null`.
- 인증 꺼짐 + X-Forwarded-* 는 티켓 경로도 403.
- 접근 로그의 토큰·티켓은 가린다(`/view/…/~/…/`).
**비밀 이름**: 경로 구성요소 어디든 `.git .claude .env* .ssh .aws .docker .kube .git-credentials .npmrc .netrc .pgpass .pypirc .dev.vars id_* secrets.* credentials*.json *.tfstate* *.tfvars *.key *.pem *.p12 *.pfx *.jks *.keystore CLAUDE.md .mcp.json`.
**응답 헤더**: 모든 /view 응답 `frame-ancestors 'none'`. md 페이지 CSP 는 script-src `'self'`(/web/md-view.js) + 정확한 cdnjs 파일 URL 3개, img-src `'self' data:`(원격 이미지는 막힘).
**inject_base**: `<head>` 안(주석 제외)에 실제 `<base>` 가 있을 때만 건너뛴다.
**discord md 미리보기**: 2MB 초과 md 는 생략, marked·DOMPurify 를 못 불러오면 실패로 보고(빈 이미지 첨부 안 함, md 파일만 + 이유).
