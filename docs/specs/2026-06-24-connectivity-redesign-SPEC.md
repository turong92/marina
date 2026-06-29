# marina Connectivity 재설계 SPEC — 엮기 + 게이트웨이

> **이건 설계 spec(다음 세션 구현의 입력)이지 풀 구현 plan이 아님.** 1단계 구현 시작 때 `superpowers:writing-plans` 로 TDD 태스크 분해할 것.

**날짜:** 2026-06-24
**상태:** 설계 확정(형과 긴 논의 끝 합의) · 구현 0 (다음 세션 1단계부터)
**씨앗:** 이번 세션 host-forward(socat 사이드카, `42ebdbf`)가 1단계의 첫 조각.

---

## 목표

워크트리별 docker compose 격리 dev 에서 **모든 통신**(서버측 fe↔be·redis 등 out·호스트 브라우저·N 병렬)을 **앱 무수정에 가깝게 자동 라우팅**.

## 문제

워크트리마다 compose 로 격리해 띄우되 내부 포트는 그대로(8081 등). 격리하면 "밖에서 안으로" 통신이 깨진다:

- **서버측** fe(SSR)→be, be→user-api: 앱이 `localhost:8081` 박음 → 컨테이너 자기 자신
- **out(redis 등)**: 앱이 `localhost:6379` 박음 → 호스트/공유 redis 로 못 감
- **호스트 브라우저→be**: 브라우저 JS(`NEXT_PUBLIC_*` 등)
- **N 병렬**: 워크트리마다 호스트 포트 충돌

기존 접근(파일스캔 감지)은 깨지기 쉽고, redis 설정이 JAR 내장이면 못 잡는다.

## 핵심 원칙: 감지 → 선언

marina 는 compose config 로 **포트→서비스 매핑**(8081=be, 3000=fe, 6379=redis)을 **이미 안다**. 파일 안 뒤지고 그 선언을 진실로 라우팅. → 언어/프레임워크 무관, JAR 내장도 무관.

---

## 두 축

### 축 1 — 엮기 사이드카 (컨테이너 안 · 나가기/서버측) · **코어, 항상**

앱의 `localhost:port` 호출을 대상으로 가로챈다.

| 의존성 | 가로채서 → |
|---|---|
| be | `localhost:8081` → `be:8081` (컨테이너 DNS) |
| redis(호스트 공유) | `localhost:6379` → `host.docker.internal` |
| redis(compose 서비스) | `localhost:6379` → `redis:6379` (DNS) |

- **수단**: socat (`network_mode: service:<svc>` 로 그 컨테이너 localhost 를 가로챔)
- **컨테이너당 사이드카 1개**가 그 컨테이너의 모든 localhost 의존성(be+redis+db…) 포트를 한 번에 받음. socat ~5MB
- 앱 **0수정·언어무관**
- 앱이 애초에 DNS(`redis:6379`)로 부르면 사이드카 불필요(docker DNS 가 바로)

### 축 2 — marina 게이트웨이 (호스트 진입 · 들어오기) · **호스트 브라우저 다중일 때만**

- **호스트 브라우저로 여러 워크트리 동시**일 때만 필요. 헤드리스·서버측·단일 워크트리는 불필요.
- **marina 가 주체** — 별도 Traefik 컨테이너 띄울 이유 없음(marina 가 이미 워크트리·서비스·포트 다 앎).
  - **구현 A**: `marina-control.py` 가 직접 리버스 프록시(HTTP+WS). 추가 컨테이너 0. 단 Python http.server 에 WS(HMR) 프록시 붙이는 게 손감 + 성능 한계.
  - **구현 B(현실적, 추천)**: marina 가 Caddy 바이너리를 호스트 프로세스로 띄우고 "워크트리→포트" 라우팅 config 를 자동 생성·갱신. `*.localhost`·WS·핫리로드 다 기본 지원이라 config 만 뱉으면 됨.
- **전역 하나** (marina 데몬이 하나니까). 프로젝트 단위로 따로 둘 이유 없음:
  ```
  a.mdc.localhost   → mdc 워크트리 A
  b.mdc.localhost   → mdc 워크트리 B
  x.other.localhost → 다른 프로젝트 워크트리 X
  ```
- **호스트 포트 1개.** 워크트리 N개여도 안 늘어남 — 도메인으로 구분
- 워크트리 추가/삭제·포트 변경 → marina 가 라우팅 **자동 갱신**(compose 보고)

---

## 케이스별 라우팅

| 통신 | 경로 | 앱 수정 |
|---|---|---|
| be ↔ user-api (서버측) | 엮기 | 0 |
| 컨테이너 → redis | 엮기 (host-forward) | 0 |
| fe 서버 → be (SSR) | 엮기 | 0 |
| 헤드리스 브라우저(E2E·에이전트) → be | 엮기 (컨테이너 안) | **0, 동시 무제한** |
| 호스트 브라우저 → be | 게이트웨이 (도메인 구분) | fe 상대경로 1줄 |

## redis

- **인스턴스/데이터** = 프로젝트 공유 가능 (워크트리마다 안 띄워도 됨)
- **`localhost:6379` 가로채기** = 컨테이너별 사이드카(엮기의 일부). redis 만 특별한 게 아니라 **be 와 완전히 같은 메커니즘**

---

## 잔여 한계 2개 (물리 — 어떤 도구도 자동화 못 함)

### 1. 호스트 브라우저 절대주소
fe 가 브라우저에서 `http://localhost:8081` **절대로** 박으면 게이트웨이가 못 갈라준다.
- **이유**: 브라우저의 `localhost`는 페이지 도메인(`a.mdc.localhost`)을 **무시**하고 무조건 `127.0.0.1`로 직행 → 받은 요청에 워크트리 단서가 0. "8081 우편함에 받는 동(워크트리)이 안 적힌 편지."
- **해결**: fe 가 `/api`(상대경로)로 부르면 현재 도메인이 붙어 → 게이트웨이가 Host 로 갈라줌. 사람이 fe 코드 **1줄**(절대→상대).
- **왜 못 피하나**: 브라우저는 호스트(= marina 컨테이너 네트워크 **밖**). compose 선언·엮기·게이트웨이 다 컨테이너 네트워크 *안* 얘기인데 브라우저만 밖이라 marina 손이 안 닿음.

### 2. 같은 내부 포트 여러 서비스
user-api·batch 둘 다 `8081`이면 `localhost:8081`이 모호.
- **해결**: Dockerfile/compose 에서 포트 분리(사람이 수정). 자동화 방법 없음.

> 둘 다 **marina 한계가 아니라 물리 법칙** — Tilt/Skaffold 도 여기서 똑같이 멈춤. 그리고 둘 다 표준이고 명확한 한 줄(redis JAR 내장처럼 "못 고치는" 게 아님).

---

## 단계 (다음 세션부터)

### 1단계 — 엮기 일반화 (코어부터)
이번 세션 host-forward(프로젝트 단위 socat, 호스트 redis 전용)를 **서버측 localhost 전부**로 확장.
- **지금**: `backing.json` top-level `hostForward: [port]` → 호스트로만(`host.docker.internal`)
- **확장**: compose 선언 포트→서비스 매핑을 읽어 `localhost:8081→be:8081`(DNS) / `localhost:6379→호스트`, **한 사이드카가 그 컨테이너 모든 포트**
- **대상**: build(앱) 서비스마다 사이드카 1개, 그 컨테이너가 부르는 localhost 의존성 전부
- **건드릴 파일**: `marina-compose.py`(`build_overlay`/`cmd_up`/`_apply_connectivity`), `backing.json` 스키마(`port → {target: service|host}`)
- 풀 TDD plan 은 이 단계 시작 때 `writing-plans` 로

### 2단계 — marina 게이트웨이
호스트 브라우저 다중. **구현 B(Caddy 관리) 우선**.
- marina 가 Caddy 띄우고 워크트리→포트 config 자동 생성·갱신
- `*.localhost` 도메인, WS(HMR), 핫리로드
- 전역 하나, `marina status` 에 도메인 표시

### 3단계 — 선언 자동 + 가이드 + 검출
- compose 선언에서 엮기·게이트웨이 라우팅 완전 자동
- fe 상대경로 가이드(절대주소 감지 시 경고/안내)
- 같은 포트 여러 서비스 충돌 검출 → 경고

---

## 현재 상태 (이번 세션, SC `+4`커밋 미push)

| 커밋 | 내용 |
|---|---|
| `a7286a9` | compose_validate stderr 크래시 수정 |
| `f216a0d` | Dockerfile 없는 build 서비스 degraded 부분 허용 |
| `3ed47f2` | host 모드(host.docker.internal patch) 복원 |
| `42ebdbf` | **범용 host-forward(socat 사이드카, 프로젝트 단위+Linux) ← 1단계 첫 씨앗** |

- 테스트 45/45 · **push 안 함**(형이 나중에 +115 한 번에)

## 다음 세션 시작점

1. 이 SPEC 읽기
2. **1단계(엮기 일반화)** 를 `writing-plans` 로 TDD plan 분해
3. host-forward 코드(`build_overlay`·`cmd_up`·`_apply_connectivity`·`backing.json`)가 그대로 베이스

## 결정 필요 (형)

- **게이트웨이 구현**: marina 직접 프록시(A) vs Caddy 관리(B) → **B 추천**(WS/도메인 거저)
- **redis 인스턴스**: 호스트 공유 vs compose 서비스 vs 워크트리별(완전 격리) → 일단 호스트 공유(현 host-forward), 격리는 나중(형 "투머치라 다음")
