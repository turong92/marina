# Connectivity 완성 설계 — 엮기 일원화 + Caddy 게이트웨이

**날짜:** 2026-06-25
**상태:** 설계 확정(형과 합의) · 입력=`docs/specs/2026-06-24-connectivity-redesign-SPEC.md`(원 SPEC) + stage1(엮기 일반화, SC `c358ce2`/`115aa1d` 완료)
**구현 분해:** 2개 서브프로젝트(각자 plan→구현→검증). SP1 먼저(토대), SP2(게이트웨이) 다음.

---

## 목표

워크트리별 compose 격리 dev 의 **모든 통신**을 앱 무수정에 가깝게 자동 라우팅하는 connectivity 를 **production 수준으로 완성**한다: 서버측은 엮기(socat) 하나로 일원화, 호스트 브라우저 진입은 marina 가 관리하는 Caddy 게이트웨이로. 범용(언어·프레임워크·JAR내장 무관), 불필요 UI 제거, 실 docker 로 검증.

## 결정사항 (형 확정, 2026-06-25)

| # | 결정 | 함의 |
|---|---|---|
| 1 | **엮기로 완전 일원화** | service-redirect(파일패치·via=env) 메커니즘·UI·API 전부 삭제. 엮기(socat)가 서버측 유일 메커니즘. |
| 2 | **redis = 호스트 공유** | redis 는 compose 서비스 아님. 앱 `localhost:6379` → 엮기 host 타겟(`host.docker.internal`). 워크트리별 redis 안 띄움. |
| 3 | **게이트웨이 = Caddy 관리** | marina 가 Caddy 호스트 프로세스 기동·config 자동생성. 별도 Traefik X. |
| 4 | **서비스타겟 = compose config 자동 도출** | 사람은 host 포트(redis 등)만 선언. 서비스↔서비스 라우팅은 marina 가 compose 포트→서비스 매핑에서 자동. zero-UI. |
| 5 | **게이트웨이 포트 = :80** | `http://a.mdc.localhost` 깔끔. 권한은 시스템 데몬(launchd LaunchDaemon / systemd system unit)이 root 로 바인드해 해결(1회 권한 설치). |
| 6 | **Caddy 바이너리 = PATH 우선 + 설치안내** | PATH 의 caddy 사용, 없으면 명확한 안내(brew/apt). 자동다운로드는 안 함. |
| 7 | **codex 활용** | 구현 청크는 `codex exec` 위임 가능, 리뷰는 `codex review`. marina(나)가 통합·실검증. |

## 최종 아키텍처 — 두 축

```
[호스트 브라우저] ──(:80, *.localhost)──▶ [Caddy 게이트웨이(marina 관리)] ──▶ 127.0.0.1:<host포트> ─▶ 워크트리 컨테이너
                                                                                        (축2, 호스트 진입/in)

[컨테이너 안 앱] ──localhost:port──▶ [<svc>-bind socat 사이드카] ──▶ be:8081(DNS) / host.docker.internal:6379(host)
                                                                                        (축1, 서버측/out · 엮기)
```

- **축1 엮기**: 서버측 fe↔be·be→redis·헤드리스 브라우저→be 전부. 앱 0수정. `forward:{port:{target:svc|host}}` (서비스타겟 자동, host타겟 선언).
- **축2 게이트웨이**: 호스트 브라우저 다중 워크트리 진입만. 도메인으로 워크트리 구분, 포트 1개(:80).

---

# SP1 — 엮기 일원화 + 실검증

stage1 엮기를 서버측 *유일* 메커니즘으로 굳히고, 옛 service-redirect 를 들어내고, 실 docker 로 증명한다.

## SP1-(a) service-redirect 삭제

**`plugin/scripts/marina-compose.py`:**
- `_patch_config()` — 파일 localhost→서비스명 치환. **삭제.**
- `_apply_connectivity()` — endpoints 순회·`by_file` 패치·`extra_mounts`(패치복사본)·`extraHosts`·`conn_env`(via=env) 로직. **삭제.** 남는 건 forward 정규화뿐 → `cmd_up` 이 `_normalize_forward(conn)` 직접 호출하고 `_apply_connectivity` 는 제거(또는 forward-only 로 축소).
- `build_overlay()` — `extra_hosts_svcs`/`extra_hosts` 주입, `conn_env_svc`/`environment` 주입. **삭제.** (엮기 사이드카는 `network_mode:service` 라 extra_hosts 못 쓰고, 자체 ip-route 폴백으로 호스트 도달 → extra_hosts 불요.)
- `connectivity` 파라미터 → `{forward}` 만 받음.

**`plugin/scripts/marina-control.py`:**
- `/api/compose-connectivity` 핸들러 + `_clean_compose_connectivity_endpoints()`. **삭제.**
- backing.json 쓰기에서 `services[svc].endpoints` 스키마 제거(`forward`/`hostForward` top-level 만).

**backing.json 스키마(최종):** `{ "version":1, "forward": {"<port>": {"target":"host"}}, ... }` (서비스타겟은 런타임 자동도출이라 저장 불요 — host 포트만 저장). 레거시 `hostForward:[..]`·`services[].endpoints` 는 읽기 시 무시/마이그레이션.

## SP1-(b) 서비스타겟 자동 도출

**새 함수 `_auto_service_forward(config) -> {port: service}`** (`marina-compose.py`): resolved compose config 의 각 서비스가 서빙하는 포트(`_port_targets`)를 `{port: 그 서비스명}` 으로. 같은 포트 두 서비스면 경고(SPEC 동일포트 한계) 후 하나 선택.

**병합(`cmd_up`):** `forward = {**_auto_service_forward(config), **_normalize_forward(conn)}` — **명시 선언이 자동도출을 override**(예: 사용자가 `8081→host` 선언하면 자동 `8081→be` 보다 우선). 병합된 forward 를 `build_overlay(connectivity={"forward":...})` 와 사이드카 이름 계산에 사용.

- `build_overlay` 자체는 선언-구동(받은 forward 렌더만) — 자동도출은 `cmd_up` 책임. `overlay` stdin 훅/단위테스트는 명시 forward 그대로.
- 결과: 사람은 **host 포트(redis 등)만** 선언, 서비스↔서비스는 자동. 모든 앱에 적용(self 제외)이라 idle 리스너 생길 수 있음(무해, stage3 정밀화).

## SP1-(c) UI 걷어내기

**`marina-web/index.html`·`app.js`:**
- 연결 모달(`cn-mode`/`cn-save`/endpoint 토글·`data-mode`), `/api/compose-connectivity` 호출, 연결+마운트 결합저장 → 연결 부분 **삭제**. 마운트 저장은 `/api/compose-mounts` 단독으로 유지.
- "호스트 백킹 포트" 입력(`composeHostForward`) — **유지**(이게 host 타겟 선언의 유일 UI, 최소·범용). 단 저장 경로를 backing.json top-level `forward:{port:{target:host}}` 로(또는 기존 `hostForward` 유지하고 `_normalize_forward` 가 흡수 — 호환 우선).

**남김(연결과 직교):** mounts·build-args·prebuild·compose 환경변수.

## SP1-(d) 실-docker e2e 검증 (형: "환경변수 넣고 워킹")

`test-compose-e2e.sh` 패턴(docker guard→throwaway compose→`marina ... up`→증거→`down`) 으로 **새 e2e** `test-compose-weave-e2e.sh`:
- compose: `be`(8081 에 "BE-OK" 응답하는 작은 서버, 예 `python -m http.server` 또는 socat 에코) + `app`(빌드 서비스, 시작 시 `localhost:8081`·`localhost:6379` 호출).
- `--env-var`/`--env-default` 주입(환경변수 워킹 증명) + host 포트 6379 선언.
- 검증:
  1. **host 타겟**: app 컨테이너 `redis-cli -h localhost ping`(또는 `nc localhost 6379`) → host redis(`localhost:6379` 열림 확인됨) **PONG**.
  2. **service 타겟**: app 컨테이너 `curl localhost:8081` → be(socat→be:8081 DNS) **BE-OK**.
  3. `<svc>-bind` 사이드카 실제 기동(`marina status`/`docker compose ps`).
- docker 미가용이면 SKIP.

---

# SP2 — Caddy 게이트웨이 (호스트 브라우저 진입)

호스트 브라우저로 여러 워크트리를 도메인으로 구분해 동시 접근. marina 가 Caddy 를 관리.

## SP2-(a) 바이너리 조달
- `caddy` PATH 탐색. 있으면 사용. 없으면 기동 시 **명확 안내**(`brew install caddy` / `apt install caddy`) 후 게이트웨이 비활성(나머지 marina 정상). 자동다운로드 X.

## SP2-(b) 프로세스 관리 (:80 → 시스템 데몬)
- `marina-dashboard.sh` 의 supervisor 패턴(launchd/systemd/nohup) 재사용해 **`marina-gateway.sh`**(또는 control 통합)이 Caddy 를 기동.
- **:80 바인드 = root** 필요 → **시스템 데몬**으로: macOS `LaunchDaemon`(/Library/LaunchDaemons, root), Linux systemd **system** unit(또는 `setcap cap_net_bind_service`). 1회 권한 설치(sudo 1회), 이후 자율.
- 전역 하나(marina 데몬 하나). PID·로그 `~/.marina/` 관리.
- config reload: Caddy admin API(`localhost:2019`) 또는 `caddy reload` — 재시작 없이 라우팅 갱신.

## SP2-(c) config 자동 생성 + **동적 반영** (게이트웨이의 핵심)
워크트리 포트는 docker 자동할당(`127.0.0.1::target`)이라 **재기동마다 바뀐다** → 정적 config 는 바로 깨짐. 모든 변화를 **빠짐없이·즉각** 반영해야 한다(형 명시 요구).

**진실의 원천:** marina 데몬이 대시보드용으로 이미 폴링하는 라이브 상태 — 모든 워크트리·서비스·`docker compose ps`(`parse_ps_ports`) 호스트포트 + 워크트리↔프로젝트 매핑.

**반영 메커니즘 (두 경로 — 둘 다 필요):**
1. **폴링 사이클**(빠짐없음): 데몬 기존 폴링마다 Caddyfile 재생성 → **이전과 diff** → 바뀌었을 때만 `caddy reload`(admin API `localhost:2019`, 무중단). diff 로 불필요 reload 억제. 밖에서 워크트리 지워도/포트 바뀌어도 다음 폴링이 잡음.
2. **이벤트 즉시반영**(즉각): `marina start/stop/restart`(데몬 compose dispatch)에서 폴링 안 기다리고 즉시 refresh 트리거.

**반영 대상:** 워크트리 추가(세션/`project add`)→라우트 생성 · 삭제/정지→라우트 제거(**stale 도메인이 엉뚱한 포트 가리키면 안 됨**) · 서비스 start/stop→해당 라우트 등장/소멸 · 재기동(새 호스트포트)→라우트 **재지정**.

**출력:** Caddyfile(또는 admin JSON). 워크트리 0 이면 빈 config. 생성 함수는 순수(입력=라이브 상태 → 출력=config 텍스트)라 단위테스트 가능.

## SP2-(d) 라우팅 — 서비스별 서브도메인 (범용)
```
<워크트리>.<프로젝트>.localhost           → 대표 web 서비스(fe/web/frontend 우선, 없으면 첫 퍼블리시 서비스)
<워크트리>-<svc>.<프로젝트>.localhost      → 그 외 퍼블리시 서비스 각각
                                            → reverse_proxy 127.0.0.1:<그 서비스 host포트>
```
- 경로(/api) 가정 안 함 = 앱 무관·범용. WS/HMR Caddy 기본 지원.
- `*.localhost` 는 브라우저/OS가 127.0.0.1 로 자동 해석(/etc/hosts 수정 불요).
- `marina status` 에 워크트리별 게이트웨이 URL 표시.

## SP2-(e) 검증 — 정적 + **동적 반영** (실 docker)
- **정적**: 워크트리 2개 up → 호스트 `curl -H "Host: a.<proj>.localhost" localhost:80` → A fe 200, `b.<proj>.localhost` → B. WS 업그레이드 핸드셰이크.
- **동적**(핵심 — 형 요구): ① **add** — 워크트리 추가 후 그 도메인 즉시 200 ② **remove/stop** — 정지 후 그 도메인 사라짐(502/404, stale 포트 안 가리킴) ③ **restart/port-change** — 재기동으로 호스트포트 바뀐 뒤 도메인이 **새 포트**로 재지정돼 계속 200 ④ **diff-reload** — 변화 없을 때 reload 안 일어남(불필요 churn 억제).

## 잔여 한계 (원 SPEC 승계, 물리 — 자동화 불가)
1. **호스트 브라우저 절대주소**: fe 가 브라우저에서 `localhost:8081` 절대로 박으면 게이트웨이가 못 갈라줌 → fe `/api` 상대경로 1줄(사람). 게이트웨이가 Host 로 갈라주려면 같은 도메인이어야.
2. **같은 내부 포트 여러 서비스**: Dockerfile/compose 포트 분리(사람). 자동도출도 경고만.

---

## codex 활용 방식 (형: "코덱스 활용해서 작업")
- **구현**: 잘 스코프된 청크는 `codex exec "<지시>"` 로 위임(예: "이 파일들에서 service-redirect 메커니즘 삭제"). 내가 diff 검토·통합.
- **리뷰**: 각 plan 태스크 커밋 전 `codex review`(또는 `codex exec` 리뷰 프롬프트)로 독립 리뷰 → 반영(메모리 패턴 "codex 리뷰 N건 반영").
- 실검증(docker e2e)·최종 통합은 내가.

## 단계 / 플랜 분해
1. **SP1 plan** (엮기 일원화 + 검증) — `writing-plans` 로 TDD 분해. 먼저.
2. **SP2 plan** (Caddy 게이트웨이) — SP1 검증 후.
3. 각 plan: TDD 단위 + 실 docker 증거. SC 브랜치 누적, 형 마지막 검토.

## 범위 밖 (다음 — 원 SPEC stage3)
선언 완전 자동(엮기 미사용리스너 서비스별 스코핑·타겟 검증·동일포트 충돌 검출), fe 절대주소 감지·안내.
