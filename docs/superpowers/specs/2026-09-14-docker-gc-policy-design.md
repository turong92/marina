# Docker GC 정책 설계

**상태:** 설계 → 구현
**범위:** 워크트리에 묶이지 않는 도커 산출물의 주기 정리 (정책 파일·데몬 루프·CLI·대시보드·테스트 라벨)
**범위 밖:** 워크트리 소유 이미지 회수(`remove_worktree → clear_worktree_images`, 별도 세션 진행 중) — `marina_lifecycle.py` 는 건드리지 않는다.

## 배경

2026-09-14 실측(`docker system df`): 빌드캐시 70GB 중 7일 넘은 21GB, 테스트 e2e 가 남긴 이미지
`mdce2e*` 272개·`proj-*-weaveapp` 111개(3개월 방치), 익명 볼륨 319개, 4일 방치된
`marina-weave-e2e-redis-*` 컨테이너. 주기 정리가 하나도 없었다.

누수의 뿌리는 둘이다.
- e2e 테스트가 `docker compose down -v` 로 컨테이너·볼륨은 지우지만 **compose 가 빌드한 이미지는 남긴다**
  (`--rmi` 없음). 이름이 `mdce2e<pid>-featbr-web` 꼴이라 어떤 규칙으로도 잡히지 않는다.
- 빌드캐시·익명 볼륨·dangling 이미지는 누가 만들었든 아무도 회수하지 않는다.

형: "밖에서 cron 거는 건 의미 없다, marina 에서 컨트롤돼야 한다." → 정책도 실행도 marina 가 쥔다.

## 목표

- 정책 파일 하나(`~/.marina/docker-gc.json`)로 무엇을 얼마나 오래 두는지 정한다. 없으면 기본값.
- 데몬이 정책 주기대로 돌린다. GC 가 실패해도 데몬은 영향 없다.
- CLI 와 대시보드 양쪽에서 같은 정책을 보고 고치고, 지금 당장 돌릴 수 있다(미리보기 포함).
- **실행 중 컨테이너가 쓰는 것은 절대 건드리지 않는다.**
- 테스트 하네스가 만드는 e2e 산출물엔 라벨 `marina.e2e=1` 이 붙어, 이후 누수는 정책의 3일 규칙이 회수한다.

## 비목표

- 워크트리 소유 이미지(별도 세션). 명명 볼륨(사용자 데이터일 수 있다). 사용 중인 어떤 것.
- 원격 런타임 박스의 도커 — 이번 GC 는 로컬 데몬만 본다.

## 정책 파일 `~/.marina/docker-gc.json`

| 키 | 기본 | 뜻 |
|---|---|---|
| `enabled` | `true` | 데몬 자동 실행 on/off (CLI `--now`·대시보드 "지금 정리" 는 무시하고 돈다) |
| `interval_hours` | `24` | 자동 실행 주기 |
| `build_cache_keep_days` | `7` | 이보다 오래 안 쓴(LastUsedAt) 빌드캐시를 지운다. `0` = 이 단계 끔 |
| `dangling_images` | `true` | `<none>:<none>` 이미지 중 어떤 컨테이너도 안 쓰는 것 |
| `anonymous_volumes` | `true` | 어떤 컨테이너에도 안 붙은 **익명** 볼륨만(명명 볼륨은 절대 아님) |
| `stale_test_artifacts_days` | `3` | e2e 산출물(컨테이너·이미지·네트워크) 중 이보다 오래된 것. `0` = 끔 |
| `stale_test_artifact_names` | `["marina-*-e2e-*"]` | e2e 산출물로 보는 이름 글롭. 라벨 `marina.e2e=1` 은 항상 포함 |

읽기: 파일 없음/깨짐/모르는 키/틀린 타입 → 그 키만 기본값(경고를 실행 로그에 남김). 쓰기: 원자적(`tempfile+os.replace`),
값은 타입 검증(bool·int≥0·글롭 목록). 한 키만 바꾸는 `set_policy(key, value)` 가 CLI·API 공용 진입.

상태 파일 `~/.marina/docker-gc-state.json`(마지막 실행 시각·회수량·단계별 요약·오류) 은 대시보드·`due` 판정이
읽는다. 로그 `~/.marina/docker-gc.log` 는 사람용 append-only 한 줄:

```
2026-09-14T10:00:00+09:00 auto     reclaimed 21.3GB  build-cache 20.1GB · dangling 0.5GB · volumes 0.2GB · e2e 0.5GB(3 containers, 12 images, 2 networks)
2026-09-14T11:02:11+09:00 cli/dry  would reclaim 0.4GB ...
2026-09-15T10:00:00+09:00 auto     FAILED build-cache: docker: Cannot connect ...
```

## 모듈 `plugin/scripts/marina_docker_gc.py`

도커 호출은 전부 `run(args) -> str` 하나를 통해 나간다(기본은 `subprocess` + `marina_state._bin("docker")`).
테스트는 가짜 `run` 을 주입해 명령·순서·판정을 검증한다. 실 도커를 건드리는 테스트는 dry-run 경로만 탄다.

### 단계(고정 순서)와 판정

1. **build-cache** — `docker system df -v --format json` 의 `BuildCache` 항목 중 `InUse=false` 이고
   `LastUsedAt`(없으면 `CreatedAt`) 이 `keep_days` 전보다 오래된 것의 `Size` 합 = 예상 회수량.
   실행: `docker builder prune -f --filter until=<keep_days*24>h`. 실제 회수량은 출력의
   `Total reclaimed space:` 를 파싱(없으면 예상치).
2. **dangling** — `docker images -f dangling=true --format json` 중 어떤 컨테이너(`docker ps -a`, 실행 여부 무관)도
   `Image`/`ImageID` 로 안 쓰는 것. 실행: `docker image prune -f` (도커 자체가 사용 중은 제외).
3. **volumes** — `docker volume ls -f dangling=true --format json` 중 이름이 64자 hex(익명) 인 것. 크기는
   `system df -v` 의 `Volumes`. 실행: `docker volume prune -f` (`--all` 없음 → 익명만, 도커가 사용 중 제외).
4. **e2e** — 라벨 `marina.e2e=1` **또는** 이름이 글롭에 맞는 것. 나이는 `docker inspect --format '{{.Id}} {{.Created}}'`.
   - 컨테이너: `State != running` 이고 오래된 것 → `docker rm <id>` (**`-f` 없음** — 도는 것은 오류로 튕긴다).
   - 이미지: 컨테이너 단계 뒤 다시 센 `docker ps -a` 의 이미지에 안 잡히고 오래된 것 → `docker image rm <id>`
     (`-f` 없음). `Size` 합이 회수량(공유 레이어 탓에 근사 — 로그에 `≈`).
   - 네트워크: `docker network inspect` 의 `Containers` 가 비었고 오래된 것 → `docker network rm`.

"실행 중 컨테이너가 쓰는 것" 보호는 세 겹이다: ① 판정에서 제외, ② `-f` 를 쓰지 않아 도커가 거부,
③ 단계 하나가 실패해도 다음 단계로 간다(단계별 `error` 기록).

### API

```python
load_policy() -> dict                 # 기본값 머지·검증
set_policy(key, value) -> dict        # 문자열 값도 받아 타입 변환("true","24","a,b")
plan(policy, now=None, run=docker) -> Report      # dry-run: 지울 것과 예상 회수량. 아무것도 안 지움
collect(policy, source, dry_run=False, now=None, run=docker) -> Report   # 실행 + 상태/로그 기록
due(policy, state, now) -> bool       # enabled 이고 마지막 성공/실패 실행 + interval 이 지났나
status() -> dict                      # {policy, state, due, disk: docker_disk_summary(60s 캐시)}
```

`Report = {startedAt, finishedAt, source, dryRun, reclaimedMb, steps:[{name, reclaimedMb, items:[str], error}], error}`.
`dry_run` 이면 상태 파일은 안 쓰고 로그엔 `cli/dry` 로 남긴다. 실행은 프로세스 내 `threading.Lock` 으로 직렬화
(데몬 자동 + 대시보드 "지금" 겹침 방지). 대시보드 `disk` 는 `marina_cache.docker_disk_summary()` 를 60초 캐시.

## 데몬 (`marina_handler.main`)

`_gc_loop` 데몬 스레드: 부팅 60초 뒤부터 10분마다 `due()` 확인 → `collect(source="auto")`. 전체가 `try/except`
— 어떤 예외도 삼키고 다음 주기로. 프리뷰(:3901)·리뷰 인스턴스가 같은 `~/.marina` 를 보며 이중 실행하지 않도록
`marina_notify.is_primary_notifier(PORT)` 로 기록된 데몬만 자동 실행한다(푸시 알림과 같은 규칙).

## CLI (`marina-entrypoint.sh` → `marina_docker_gc_cli.py`)

```
marina docker gc                 # due 면 실행, 아니면 "다음 실행 시각" 안내 (enabled=false 면 안내만)
marina docker gc --now           # 정책 무관 지금 실행
marina docker gc --dry-run       # 지울 것·예상량만 출력 (--now 와 조합 가능)
marina docker gc status          # 정책·마지막 실행·도커 디스크
marina docker gc policy          # 정책 전체 출력
marina docker gc policy <key> <value>
```

출력은 사람용 표 한 벌 + `--json`. 종료코드: 실행 오류 1, 정책 키/값 오류 2.

## HTTP API (admin 전용, `_ADMIN_POST_PATHS` 등록)

- `GET /api/docker-gc` → `status()`
- `POST /api/docker-gc/run` `{dryRun: bool}` → `Report`
- `POST /api/docker-gc/policy` `{key, value}` → `{policy}`

## 대시보드

헤더 `.toolbar` 의 메모리 게이지(`#mem`) 옆에 **Docker 디스크 배지** 하나(`#dgc`, 새 파일 `app-6f-docker-gc.js`).
컴팩트·아이콘화 원칙(형 UX 선호)에 따라 텍스트 칩이 아니라 글리프 버튼 하나다.

- 얼굴: `▣ 24.8GB` (images+build cache+volumes 합). 툴팁: 세 항목 breakdown + `마지막 정리 3시간 전 · 회수 2.1GB`
  (+ 정책 꺼짐이면 `자동 정리 꺼짐`). 자동 정리가 꺼졌거나 마지막 실행이 실패했으면 배지가 흐려지거나(`.off`)
  적색(`.warn`) — 상태를 색으로만 알리고 별도 칩은 두지 않는다.
- 클릭 → 설정 메뉴와 같은 팝오버(`.settings-menu` 재사용). 내용:
  - 상태 한 줄: `마지막 정리 3시간 전 · 회수 2.1GB` / `아직 실행 안 됨` / `실패: …`
  - 정책 행(설정 메뉴 `.settings-row` 재사용): 자동 정리(토글) · 주기(h) · 빌드캐시 보관(일) · dangling 이미지(체크) ·
    익명 볼륨(체크) · e2e 산출물(일). 바꾸면 즉시 `POST /api/docker-gc/policy`.
  - 하단 버튼 둘: `미리보기`(dry-run → 팝오버 안에 단계별 예상량·항목 수 표) · `지금 정리`(`withBusy`, 끝나면 회수량 토스트).
- 데이터: 로드 시 + 60초마다 `GET /api/docker-gc`(탭 숨김이면 안 함). admin 아니면 배지 숨김.
- 모바일 폭에선 `.mem` 과 같은 규칙으로 줄바꿈.

## 테스트 하네스 라벨

- `plugin/tests/lib/harness.sh` 가 `export MARINA_E2E=1`. (`MARINA_*` 를 지운 **뒤** 세운다.)
- `marina-compose.py up` 이 `MARINA_E2E=1` 이면 `build_overlay(..., extra_labels={"marina.e2e": "1"})` 를 준다.
  overlay 는 모든 서비스에 `labels:`(컨테이너), `build:` 가 있는 서비스에 `build.labels:`(이미지), 그리고
  external 이 아닌 네트워크(없으면 `default`)에 `labels:` 를 덧붙인다. 앱 compose 불변 — 오버레이만.
- 테스트가 직접 치는 `docker run` 은 `--label marina.e2e=1` 을 붙인다(weave e2e 의 redis).
  새 테스트 `test-docker-gc-e2e-label.sh` 가 `plugin/tests/*.sh` 의 모든 `docker run` 에 라벨이 있는지 강제한다.
- 이미 새어 있는 옛 산출물(`mdce2e*`·`proj-*-weaveapp`) 은 라벨이 없다 — 정책의 `stale_test_artifact_names` 에
  글롭을 추가하면 같은 3일 규칙으로 회수된다(문서·CLI 안내).

## 테스트

- `test-docker-gc-policy.sh` — 기본값·머지·틀린 값 폴백·`set_policy` 타입 변환·원자 쓰기·`due` 판정.
- `test-docker-gc-plan.sh` — 가짜 `run` 으로 네 단계 판정: 보관일 경계, InUse 제외, 컨테이너가 쓰는 dangling 제외,
  명명 볼륨 제외, 실행 중 e2e 컨테이너 제외, e2e 이미지가 남은 컨테이너에 쓰이면 제외, 네트워크 사용 중 제외,
  이름 글롭·라벨 양쪽 매칭, dry-run 은 삭제 명령 0회, 실행은 `-f` 없는 명령·순서, 단계 실패 후 다음 단계 계속,
  `Total reclaimed space` 파싱, 로그 줄·상태 파일.
- `test-docker-gc-cli.sh` — `marina docker gc policy` 읽기/쓰기/오류코드, `--dry-run --json` 형태(도커 없으면 가짜 PATH docker).
- `test-docker-gc-api.sh` — 데몬 띄워 `GET /api/docker-gc`, `POST policy`, `POST run {dryRun:true}` (가짜 docker 바이너리를 PATH 앞에).
- `test-docker-gc-daemon-loop.sh` — `_gc_loop` 의 한 틱 함수가 due 일 때만 collect 를 부르고 예외를 삼키는지.
- `test-docker-gc-overlay-labels.sh` — `MARINA_E2E=1` 오버레이에 라벨 3종(service·build·network) 이 들어가고, 없으면 0.
- `test-docker-gc-e2e-label.sh` — 테스트 스위트의 `docker run` 라벨 강제 + 하네스가 `MARINA_E2E` 를 세우는지.
- `test-docker-gc-ui.sh` — index.html·app-6f·styles 의 요소·함수 존재(기존 UI 테스트 관례) + 실 도커가 있으면
  `marina docker gc --dry-run` 이 실제로 아무것도 안 지우는지(`docker ps -a` 개수 전후 동일).
- 모든 테스트는 `lib/harness.sh` 를 source 한다.
