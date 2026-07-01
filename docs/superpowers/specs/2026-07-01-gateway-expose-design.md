# 설계: `x-marina.gateway.expose` — 게이트웨이 fe→be 배선 (2모드)

작성일: 2026-07-01 · 상태: 승인됨(설계) → 구현 계획 대기

## 배경 / 문제

워크트리별 격리 환경(N개 워크트리 동시 실행)에서 프론트엔드가 백엔드를 부르는
브라우저 요청이 깨진다. 앱은 보통 `http://localhost:8081` 같은 **고정 절대 호스트
포트**를 하드코딩하는데, 이는 다음과 근본적으로 양립 불가하다:

- **격리**: 여러 워크트리가 같은 호스트 `:8081`을 동시에 못 가짐(포트 충돌).
- **네이티브 툴**: IntelliJ 등이 이미 8081을 물고 있으면 게이트웨이가 못 뭄(그 역도).

핵심 물리 사실: **브라우저 요청은 origin(도메인)으로만 격리되지, 공유 포트로는
격리 안 된다.** 따라서 브라우저가 be에 닿으려면 fe의 API base가 **게이트웨이로
닿는 값**(게이트웨이 도메인 또는 상대주소)이어야 한다. 이 값을 marina가 **표준
compose `environment:`로 주입**하면 앱 소스는 무수정이다.

컨테이너↔컨테이너(be→ai 등) 내부 통신은 이 설계 범위 밖 — 기존 **엮기 사이드카**가
그대로 담당(앱의 `localhost:port`를 socat이 서비스 DNS로 중계).

## 원칙

- marina = **표준 docker-compose 조립 + 게이트웨이 인그레스**. 앱의 Dockerfile·소스
  불가침.
- 배선 의도는 **선언형**(compose의 `x-marina`, marina 레이어), 실제 주입은 **표준
  compose `environment:`**.
- 게이트웨이가 경로를 알 필요를 없애는 게 범용성의 핵심 — 경로 지식은 서비스
  레벨 매핑으로 대체.

## 스키마

```yaml
x-marina:
  gateway:
    expose:
      web:                                         # 소비자(프론트) 서비스명
        NEXT_PUBLIC_API_URL: "${gateway:user-api}" # 도메인 모드
        # 또는
        NEXT_PUBLIC_API_URL: "${origin:user-api}"  # same-origin 모드
    routes:
      user-api: ['/v1.0', '/v2.0']                 # same-origin 모드일 때만 필요(be prefix)
```

- **토큰 2종** (resolve됨을 명시, 기존 `${}` 컨벤션과 일관):
  - `${gateway:<svc>}` → **도메인 모드**
  - `${origin:<svc>}` → **same-origin 모드**
- 모드는 **expose 항목(env var) 단위** 선택.
- `expose.<consumer>.<ENV_VAR>: <token>` 구조. `<consumer>`·`<svc>`는 compose
  서비스명.

## 두 모드

| | **gateway-domain** `${gateway:svc}` | **same-origin** `${origin:svc}` |
|---|---|---|
| 주입 env 값 | `http://<wt>-<svc>.<proj>.localhost:<gwport>` | `''` (빈 값 = 상대) |
| 게이트웨이 config | be 서브도메인 catch-all(기존) + **CORS 부착** | 대표 도메인 **path 라우팅**(`routes[svc]` 재사용, 기존) |
| be 경로 지식 | 불필요 | **필요**(`routes` 선언) |
| CORS | 있음(caddy 전담) | **없음**(same-origin) |
| 적합 인증 | 헤더 토큰(stateless) | **쿠키 세션** |
| 워크트리 격리 | be 서브도메인 origin별 | 대표도메인 origin별 |

- 도메인 모드: be 서브도메인은 build_caddyfile이 이미 자동 생성(catch-all→be). 여기에
  CORS만 얹으면 됨. fe는 워크트리별 동적 be 도메인을 env로 받음.
- same-origin 모드: fe 상대주소 → 자기 대표 도메인(`<wt>.<proj>.localhost`)으로 감 →
  게이트웨이가 `routes[svc]` prefix를 be로 path 라우팅(기존 메커니즘). same-origin이라
  CORS·쿠키 문제 0.

## CORS (도메인 모드 전용) — caddy 전담

be 서브도메인 블록에 marina가 자동 생성:

- `reverse_proxy { header_down Access-Control-Allow-Origin <fe-origin> }` — be가 내는
  ACAO를 **replace**(추가 아님 → 중복 헤더로 브라우저가 거부하는 문제 방지).
- preflight `OPTIONS` → caddy가 **204로 자체 short-circuit**(be가 OPTIONS를 401/404
  낼 수 있으므로).
- **credentialed**: `Access-Control-Allow-Credentials: true`, `Allow-Origin`은 **특정
  fe origin**(`*` 금지 — credentials 호환), `Allow-Headers`는 요청의
  `Access-Control-Request-Headers`를 **echo**(`Authorization`·커스텀 헤더를 열거 없이
  범용 허용).
- `Allow-Methods`는 일반 집합(GET/POST/PUT/PATCH/DELETE/OPTIONS).

fe origin = 그 소비자 web 서비스의 대표 도메인. marina가 도메인 쌍을 알므로
**프로젝트별 CORS 설정 0**.

## 내부 평면 (변경 없음)

- be→ai 등 컨테이너↔컨테이너는 **기존 엮기 사이드카 유지**.
- `expose`는 **브라우저 평면 전용**. 서버사이드 내부 var은 **plain compose
  `environment:`**(서비스 DNS, 정적 — marina 토큰 불필요).
- 한 env var을 브라우저·서버 겸용하는 앱은 그 var의 서버쪽 사용이 게이트웨이
  도메인을 컨테이너에서 resolve 못 해 실패 → **앱이 var 분리해야 함**(문서화된 한계).

## 관측성

- `marina gateway config`(또는 대시보드 게이트웨이 패널)가 **유효 라우팅 + CORS 쌍**을
  표로 노출. caddy CORS override가 블랙박스가 되지 않게.
- 문서 명시: **"게이트웨이 경로의 CORS는 게이트웨이가 처리(be 자체 CORS는 직접
  접근 경로에만 적용)."**

## 손대는 marina 파일

- `marina-compose.py` `build_overlay`: expose 토큰 resolve → 소비자 서비스 overlay
  `environment:`에 주입.
- `marina-gateway.py` `build_caddyfile`: 도메인 모드 be 블록에 CORS 생성.
  same-origin path 라우팅은 기존 `routes` 처리 재사용.
- `marina_lifecycle.py` `_gateway_snapshot`: expose(도메인 CORS 쌍) 정보를 스냅샷에
  포함해 게이트웨이가 알 수 있게.
- expose 파싱 유틸(`marina-compose.py` x-marina 계열) + 게이트웨이 포트를
  overlay-build 시점에 resolve하는 배선.
- `marina gateway config` 관측 서브커맨드(또는 기존 status 확장).

## 데이터 흐름 (`up` 시점)

1. 서비스 start → 게이트웨이 포트 확정(`_resolved_gateway_port`).
2. overlay build 시 expose 토큰을 **이 워크트리**의 be 도메인(도메인 모드) 또는
   `''`(same-origin)로 resolve → 소비자 서비스 `environment:`에 주입.
3. caddy config 생성: 도메인 모드 be 서브도메인엔 CORS, same-origin은 대표 도메인
   path 라우팅(`routes`).
4. up.

토큰 resolve는 **워크트리 스코프**(그 워크트리의 be 서브도메인/포트) — 격리와 일치.

## 테스트

- 도메인 모드 e2e(실 caddy): fe env=be 서브도메인, CORS preflight·credentialed·헤더
  echo·중복 ACAO replace 검증.
- same-origin 모드 e2e: fe env='', 대표 도메인 `/v1.0`→be path 라우팅, CORS 부재 확인.
- 워크트리 2개 동시: origin별 격리(도메인/대표도메인) 확인.
- 토큰 resolve 단위 테스트(도메인 문자열 조립, 포트, 서비스명 sanitize).
- 관측 서브커맨드 출력 검증.

## 범위 밖 / 문서화된 한계

- **쿠키 앱 + 도메인 모드**: Secure-cookie-on-http-localhost 브라우저 편차, 부모
  도메인 쿠키의 워크트리 간 충돌 → **same-origin 모드 사용 권고**. marina는 Set-Cookie
  재작성 안 함(인증 쿠키 조작 회피).
- prod 정적 빌드의 `NEXT_PUBLIC_*` 빌드타임 인라인(로컬 next dev는 런타임 주입이라
  무관).
- fe가 브라우저/서버 한 var 겸용 시 서버쪽은 앱이 분리.
- 내부 컨테이너↔컨테이너 통신(사이드카 담당)은 이 설계 범위 밖.
