# marina

**워크트리마다 격리된 Docker Compose dev 스택** — Claude Code · Codex 플러그인.

한 머신에서 여러 git worktree 의 풀스택 dev 환경을 **포트 충돌 없이** 컨테이너로 띄우고,
`:3900` 웹 대시보드에서 등록·기동·로그·포트를 관리한다. **앱 레포는 건드리지 않는다** —
compose 와 설정은 전부 `~/.marina` 에 보관된다.

의존성 0 — `python3`(표준 라이브러리만) + bash. 실행에는 **Docker**(compose v2.24.4+)가,
게이트웨이(호스트 브라우저 진입, 선택)에는 **Caddy**(v2.7+)가 필요하다 — [요구사항](#요구사항제약) 참조.

> 잘 모르겠으면 한 줄만 기억하세요: 대시보드(`marina`)를 열고 **`+ 프로젝트 등록 → 🆕 새로 설정 (위저드)`**.
> 위저드가 Dockerfile 을 스캔해 서비스·파일·연결을 단계별로 채우고, 등록 직전 compose 미리보기까지 가져다 줍니다.

---

## 무엇이 격리되나

- **워크트리마다 compose 프로젝트명**(`-p <id>-<세션>`)이 달라 네트워크·컨테이너·볼륨이 분리된다.
  여러 워크트리를 동시에 띄워도 안 겹친다.
- **호스트 포트는 Docker 가 자동 할당**한다. marina 가 published 포트를 `127.0.0.1::<컨테이너포트>`
  (localhost 전용 + 호스트포트 자동)로 덮어 띄우므로 충돌이 없다. 실제 포트는 `marina ports`(=
  `docker compose ps`)와 대시보드 `↗` 로 그때그때 확인한다 — 외울 필요 없다.
- **서비스 간 통신은 컨테이너 DNS**(`http://api:8081` 처럼 서비스명) — 워크트리별 URL 주입이 0.
- **앱 레포 불변** — compose·build args·mounts 는 `~/.marina/<id>/` 에만 저장된다. 앱 레포엔
  Dockerfile 만 있으면 되고, marina 파일·머신 종속 경로는 레포에 남지 않는다.

---

## 멘탈 모델

- **compose = 런타임 오케스트레이션**. marina 는 워크트리별 compose 프로젝트명으로 스택을 띄우고,
  published 포트는 Docker 가 자동 할당한다. 실제 호스트 포트는 저장하지 않고 `docker compose ps` 로
  라이브 조회한다. compose 서비스끼리는 호스트 포트가 아니라 compose service DNS 로 부른다.
- **프로필과 실행 모드는 별개 축이다** (섞지 말 것):
  - *프로필(환경)* = 프로젝트가 정하는 값(예: `local`/`dev`/`prod`). marina 격리개발은 **`local`**(`MODE=local`). 로컬은 로컬.
    marina 는 프로필 *이름* 을 강제하지 않는다 — `composeEnvVar`/`MODE` 로 넘기는 값일 뿐이라 `staging` 등 추가도 값 하나 더일 뿐(구조 변경 0).
  - *실행 모드* = **개발 서버**(`next dev` / `uvicorn --reload` / `gradle bootRun`) ↔ 프로덕션 빌드(`next build` 등).
    marina 격리개발은 **개발 서버**(가볍고 hot reload).

  둘은 독립이라 **"로컬" ≠ "개발 서버"** — 개발 서버를 local 프로필로 띄우는 것뿐(`MODE=local next dev`).
  compose `build` 를 **dev용 Dockerfile**(예: `Dockerfile.local`)로 가리켜 개발 서버 + **소스 마운트 또는
  `develop.watch`**(hot reload).
  프로덕션 빌드는 무겁고(메모리·시간) CI/배포용이라 로컬 격리개발엔 부적합하다.
  CI 이미지가 다른 아키텍처(예: x86 전용 `+cpu` wheel)에 맞춰져 있으면 로컬(arm64 등)에선 에뮬레이션으로
  느려지므로, **로컬용 Dockerfile 은 네이티브 아키텍처**로 둔다(arch 는 이미지 빌드 시 결정 — 재빌드 필요,
  런타임 변환 불가). `develop.watch` 프로젝트는 코드 변경을 `sync`, 실행 중 의존성·Dockerfile 변경을
  Compose `rebuild`로 처리한다. Watch가 꺼진 동안 선언된 의존성 입력이 바뀌어도 다음 Start가 마지막 성공
  build와 비교해 해당 실행에 `--build`를 자동 적용한다.
- **워크트리 브랜치 = 서브레포 브랜치 (미러)**. SessionStart attach 는 워크트리의 브랜치명을 **전체 미러**해
  서브레포에 건다. 그래서 **`marina worktree create feature/{task}`**(= 작업 시작)로 워크트리를 만들면
  서브레포도 모두 `feature/{task}` 로 정렬된다(브랜치명은 마리나 안 쓰던 때와 동일, 격리만 추가). Claude 자동
  워크트리는 `claude/<id>` 로 명명되므로, feature 브랜치 라이프사이클(`feature/{task}` → main → …)을 쓰면
  `marina worktree create` 로 시작한다. detached/codex 루트는 `<prefix>/<id>` 폴백. 프로젝트 밖에서 만들려면
  `--project <id>`(레지스트리로 root 조회). attach 대상은 `marina project default <id> a,b,c` 의 defaultAttach
  로 좁힌다(예: compose 서브레포 be/ai/web 만 — 등록 서브레포가 그보다 많을 때).
- **compose 환경변수 = `composeEnvVar`/`composeEnvDefault`**. compose 의 `${APP_ENV:-local}` 같은 보간에
  넣는 값 하나다. 시작할 때 `MARINA_COMPOSE_ENV` 로 덮을 수 있다.
- **links/symlink = 호스트 worktree 편의 기능**. `node_modules`, `.venv`, 빌드 산출물, local 설정 파일을
  main checkout 에서 worktree 로 심링크해 재설치·재빌드를 줄인다. 컨테이너에 파일을 넣는 기능이 아니다.
  컨테이너 주입은 `mounts.json` 기반 overlay volume 과 service redirect 가 맡는다.
- **links 우선순위**는 `기본(default) < 프로젝트 공유(~/.marina/<id>/links.json) < service.links < 워크트리 override`
  이다. 워크트리 override 에서 끄면 그 worktree 에만 적용된다.

---

## 설치

marina 레포 자체가 플러그인 marketplace 다. 설치하면 SessionStart 훅이 worktree 가 열릴 때
등록된 프로젝트의 서브레포를 attach 한다. (외부 git 레포는 compose `start` 때 `ensure_external_worktrees` 가 워크트리에 마운트한다.)

```bash
# Claude Code
/plugin marketplace add turong92/marina
/plugin install marina@marina-dev

# Codex
codex plugin marketplace add turong92/marina
codex plugin add marina@marina-dev
```

**훅 신뢰**: Claude Code 는 설치 시 플러그인 훅을 자동 신뢰한다. **Codex 는 최초 1회 수동
신뢰가 필요하다** — 플러그인 화면의 "신뢰" 또는 `/hooks` 에서 한 번 trust 하면
`~/.codex/config.toml` 에 기록되어 이후 0클릭으로 실행된다. (Codex 보안 모델이며 marina 고유
동작이 아니다.)

**에이전트 규약(자동)**: 등록 프로젝트에서 에이전트가 dev 서버를 직접 띄우는 것(`npm run dev`·
`./gradlew bootRun`·`docker compose up` 등)은 PreToolUse 훅이 **차단**하고 `marina start` 를
안내한다 — Claude Code 에서 검증됐다. Codex 도 동일 hooks.json 의 PreToolUse 와이어를
지원하나(스키마 확인) 실동작은 미검증 — 미동작이어도 SessionStart 규칙·dev-server 스킬이 안내한다.
미등록 레포에서는 세션 시작 시 등록 힌트 1줄만 준다(레지스트리 판독 불가 시엔 침묵). 사람이/
에이전트가 의도적으로 직접 실행해야 하면 명령 앞에 `MARINA_DIRECT=1 ` 을 붙인다(차단 우회).
참고: 플러그인 업데이트로 hooks.json 이 바뀌면 Codex 는 훅을 다시 신뢰해야 할 수 있다.

대시보드 데몬은 OS supervisor 로 등록되어 로그인·부팅 후 자동 기동된다:

- **macOS** — launchd (`~/.marina/marina.dashboard.plist`).
- **Linux** — systemd user 유닛 + `loginctl enable-linger`(로그아웃 후에도 생존).
- **폴백** — 둘 다 없으면 `nohup` 백그라운드 + `auto-restart NOT configured` 경고(재부팅 시 수동 재기동).

PID 는 `~/.marina/dashboard.pid`, 로그는 `~/.marina/dashboard.log`.

### `marina` 명령 (PATH shim) — `install-cli`

어디서나 `marina` 한 단어로 부르려면 shim 을 설치한다:

```bash
plugin/scripts/marina-entrypoint.sh install-cli       # ~/.local/bin/marina (user-scope, 기본·권장)
MARINA_BIN_DIR=/usr/local/bin marina install-cli      # 다른 위치(전역/커스텀) — uninstall 도 같은 MARINA_BIN_DIR 따라감
plugin/scripts/marina-entrypoint.sh uninstall-cli     # 제거
```

`install-cli` 는 그 위치에 **자가-해석 launcher** 한 개를 쓴다(기존 파일이 marina shim 이 아니면 `--force`
전엔 안 덮음). 설치 위치가 PATH 에 없으면 안내가 나온다.

**스코프 — 세 축을 나눠서 본다** (동료가 "유저스코프 vs 전역" 으로 겪던 혼선이 여기서 갈린다):

1. **`marina` 명령(shim)을 어디 두나** — 기본 `~/.local/bin/marina`(user-scope). 전역·시스템 위치는
   `MARINA_BIN_DIR=/usr/local/bin marina install-cli`. shim 내용은 위치와 무관하게 같다(자가-해석이라).
2. **플러그인(marina-dev)이 어디 깔렸나** — shim 이 **매 실행마다 런타임에 다시 찾는다**:
   Claude `installed_plugins.json` → Codex `installed_plugins.json` → Codex `config.toml` 의 marketplace
   `source`/`<source>/plugin` → **설치 시점 경로(baked fallback)** 순으로, `scripts/marina-entrypoint.sh` 가
   실제 있는 걸 고른다. 그래서 user-scope·전역·자동업데이트(새 SHA)·커스텀 `CLAUDE_CONFIG_DIR`/`CODEX_HOME`·
   Claude/Codex 어느 레이아웃이든 따라가고, 매니페스트가 다 없어도 baked fallback 으로 동작한다.
3. **어느 프로젝트에서 실행하나** — `marina` 는 **cwd 무관**하게 동작한다. 어느 디렉터리·워크트리에서
   실행하든 그 위치의 git root 로 프로젝트를 식별하고, 등록·설정은 `~/.marina/`(user 홈) 중앙에 보관한다.
   즉 "프로젝트 스코프" 는 실행 위치(worktree)로 자동 결정되고, 명령은 한 번만 설치하면 된다.

> 한계: 전역 위치에 깔아 **여러 사용자가 한 shim 을 공유**하면 baked fallback 이 설치한 사람의 플러그인
> 경로를 가리킬 수 있어 권장하지 않는다(각자 user-scope 설치 권장). 경로 해석 단계는 `python3` 가 PATH 필요.

### 구버전(네이티브 시절) 사용자 — 삭제 후 재설치

지금 marina 는 **compose 전용**이다. 네이티브(launch.json·프로세스 직접 실행) 시절 설치는 설정 포맷과
shim 이 달라 부분 업데이트로는 잔재가 남는다(구 `projects.json`·launch.json·옛 shim 등).
**한 번 지우고 새로 까는 게 가장 빠르고 확실하다**:

```bash
# 1) 기존 것 정지·제거
marina stop --all                    # 떠 있는 스택 정리(사용 중인 워크트리마다)
marina gateway uninstall             # :80 시스템 데몬을 설치했던 경우만
marina dashboard stop
marina uninstall-cli                 # 옛 shim 제거

# 2) 플러그인 제거 — 설치했던 쪽에서 (Claude Code: /plugin 화면에서 marina 제거,
#    Codex: codex plugin remove marina@marina-dev) + 마켓플레이스 등록도 제거

# 3) 설정 초기화 — 네이티브 잔재 일괄 제거 (launchd plist 도 이 안에 있음)
mv ~/.marina ~/.marina.bak           # 보관 compose 등 참고할 게 있으면 백업, 확신 있으면 rm -rf

# 4) 재설치(위 '설치' 절차) + shim + 프로젝트 재등록
marina install-cli
marina project add <path> --compose <공유받은 compose>    # '팀에 공유' 섹션 참조
```

---

## 프로젝트 등록

플러그인을 설치해도 **프로젝트를 한 번 등록하기 전까지는 아무것도 하지 않는다**. 첫 단계는
프로젝트 1회 등록이다. 등록 정보는 `~/.marina/projects.json` 과 `~/.marina/<id>/` 에 저장되며
앱 레포는 건드리지 않는다.

### ① 추천 — 새 프로젝트 위저드 (비-LLM)

대시보드 `+ 프로젝트 등록` → **`🆕 새로 설정 (위저드)`**. 4스텝으로 정규 설정(compose + `x-marina`)을 채운다:

1. **스캔** — 프로젝트 경로를 스캔해 서브레포의 Dockerfile 을 찾고(EXPOSE·ARG·필수ARG 표시), 서비스로 포함할지 + build-args 입력. 자체 compose 만 있는 서브레포는 `include` 로.
2. **파일** — gitignore 대상을 분류해 opt-in: 의존성(node_modules·.venv)=심링크, config(`*local.yml`·`.env*`)=심링크/복제 택, 빌드 출력=제외(워크트리별 독립 빌드).
3. **연결** — 흔한 호스트 백킹(redis·mysql·postgres)을 엮기(`forward`)로, 서비스를 게이트웨이로 노출.
4. **검토** — 합쳐진 compose YAML 미리보기(편집 가능) → `등록`.

LLM 없이 Dockerfile·구조만 보고 구성한다. `고급 (YAML)` 토글로 같은 설정을 raw compose 로 직접 편집할 수도 있다.

### ② 기존 compose 가 있으면

```bash
marina project add /path/to/project --compose docker-compose.yml \
  --env-var APP_ENV --env-default local       # (선택) compose 가 읽는 환경변수 1개 + 기본값
```

대시보드에선 `📁 레포에서 찾기` 로 기존 compose 를 가져온 뒤 `등록`.

### ③ 외부 git 레포를 서비스로

프로젝트 밖의 다른 git 레포를 서비스로 묶으면, 워크트리마다 그 레포를 **독립 git worktree** 로
체크아웃해 격리한다(`.workspace/external/<name>`).

```bash
marina project add /path/to/project --external be-api=/path/to/be-api --compose docker-compose.yml
```

`--external` 는 단독 등록 모드가 아니라 **add-on** 이다 — 실행되려면 `--compose`(또는 대시보드 위저드)로 compose 정의가
함께 있어야 한다(`--external` 만 주면 외부 레포 목록만 기록된다).

### 그 밖의 등록·관리

```bash
marina project ls                       # 등록 목록
marina project infer /path/to/project   # 추론만 — JSON 출력, 레지스트리 미수정
marina project rm <id>
marina project default <id> a,b,c       # 새 worktree 가 자동 attach 할 외부 서브레포 집합
```

Claude 세션 안에서는 슬래시 명령도 된다: `/marina:project add`, `/marina:project ls`.

### 팀에 공유

**공유 단위 = compose 파일 하나**(`services:` + `x-marina:`). **시크릿이 안 들어가므로**(예: `buildArgsFrom` 은
경로만 담고 값은 각자 로컬) 그대로 복붙·커밋해도 안전하다. 나머지 코드 자산(`Dockerfile.local`·`requirements_local`
등)은 앱 레포에 있으니 `git pull` 로 따라온다.

받는 팀원:
1. `git pull` — 코드 자산(Dockerfile 등)을 먼저 받는다.
2. marina 를 최신 `main`으로 업데이트한다(Claude: `/plugin marketplace update`, Codex:
   `codex plugin marketplace upgrade`).
3. `marina project add <path> --compose <compose파일>` — 신규 등록. 이미 등록한 프로젝트는 대시보드
   Compose Workbench에서 같은 공유 블록을 적용한다.
4. 본인 로컬 시크릿(`.env.ssm.local` 등) + 호스트 백킹(redis 등) 준비 — **각자 환경, 공유 안 함**.
5. `marina start --all` — build 서비스의 성공 baseline이 없으면 첫 Start가 자동 build한다.

적용 순서는 중요하다. `develop.watch`의 `sync`는 컨테이너가 뜬 다음 붙으므로, source bind를 제거한 서비스의
dev 이미지는 watcher 없이도 시작할 수 있게 dependency 설치 뒤 bootstrap source를 `COPY`해야 한다.
Dockerfile이 배포되기 전에 Compose에서 source bind부터 제거하면 이미지 안에 앱 소스가 없어 기동에 실패한다.
따라서 **앱 코드/Dockerfile → marina → 공유 Compose → 첫 Start** 순서로 맞춘다.

> overlay·호스트 포트·게이트웨이는 받는 쪽에서 **워크트리별로 자동 생성**된다(공유 대상 아님).

---

## 실행

등록 후, 현재 worktree 의 스택을 띄우고 내린다(대시보드 카드의 ▶/■/↻ 로도 동일):

```bash
marina start  <svc> | --all      # 입력이 같으면 빠르게 시작, 선언된 build 입력이 바뀌면 자동 build
marina stop   <svc> | --all      # 한 서비스 정지 | --all = down(teardown)
marina restart <svc> | --all     # Start와 같은 입력 판정 후 컨테이너 정의 재적용
marina rebuild <svc> | --all     # 입력이 같아도 docker compose up -d --build
marina status | ports            # 상태 · 라이브 호스트 포트
marina logs [svc]                # docker 로그 follow (대시보드 로그 뷰어로도 봄)
```

서비스에 Compose 표준 `develop.watch`가 선언되어 있으면 marina가 worktree별
`docker compose watch --no-up` 프로세스를 함께 시작하고 stop/restart/down 때 정리한다. 소스와 dependency
입력의 `sync`/`rebuild` 구분은 프로젝트 Compose가 소유한다. Marina는 별도 프로젝트 설정 schema 없이
Dockerfile·`dockerfile_inline`·`action: rebuild` 경로·최종 build args와 실제 Docker image ID의 로컬 성공
baseline만 유지한다.
Marina는 시작 대상 서비스가 선언한 Watch action만 현재 Compose 버전과 대조하고, 지원되지 않는 action은
다른 동작으로 바꾸지 않고 시작 전에 설명과 함께 중단한다.

Start/Restart에서 현재 입력과 image ID가 baseline과 같으면 기존처럼 `up -d`만 실행한다. 다르거나 서비스
기록이 없으면 그 실행에만 `--build`를 붙이고, 성공한 경우에만 baseline을 갱신한다. Compose Watch나 직접
build가 이미지를 교체해도 image ID 차이로 다음 Start가 감지한다. 같은 build 서비스의 겹치는 Start는
service lock으로 직렬화한다. 입력 수집에 실패하면 기존 이미지로 시작하면서 Rebuild 안내를 남긴다. build
context 전체는 스캔하지 않으므로 이미지에 bake되어 변경 시 build가 필요한 파일은 Compose Watch
`action: rebuild`로 선언해야 한다.

`marina start web` 처럼 서비스명을 그대로 쓴다(전역 `marina` 래퍼). 무인자 `marina start` 는
전체를 안 띄우고 안내만 한다 — 워크트리마다 모든 서비스를 무심코 올려 메모리를 잡아먹는 사고 방지.
전체는 `--all`.

### 시작 그룹 (`x-marina.startGroup`)

서비스가 많아도 늘 쓰는 건 일부다. **기본으로 켤 그룹을 선언**하면 `start --all`(대시보드 ▶ 전체시작)이
그것만 띄운다 — 배치·일회성 잡이 무심코 같이 뜨지 않는다. 나머지는 "옵션"으로 딤 표시되고(카드
상태 집계에서도 제외 — **시작 그룹이 다 돌면 초록불**), 필요할 때 행에서 개별 ▶. 미선언이면 지금처럼 전부.

```yaml
x-marina:
  startGroup: [web, user-api, search-api]   # ▶ 전체시작 = 이 그룹만. batch 등은 개별 시작
```

등록 워크벤치 좌측 "시작 그룹" 체크박스로도 선언할 수 있다.

### 개발 루프와 pre-build

서비스의 변경 비용에 맞춰 Compose 표준 동작과 `x-marina.prebuild`를 조합한다. 언어나 프레임워크 이름이 아니라
서비스가 필요한 동작으로 고르는 모델이다.

| 서비스 capability | Compose 선언 | `x-marina` | 실행 결과 |
|---|---|---|---|
| **reload** | 소스 `sync`, manifest/Dockerfile `rebuild` | 없음 | 소스 수정은 이미지 빌드 없이 런타임 reload |
| **artifact** | 산출물 mount + 산출물 경로 `restart` | 서비스별 `{cwd, command}` | 호스트 빌드 후 소유 서비스만 재시작 |
| **image** | dependency/Dockerfile 경로 `rebuild` | 필요할 때만 pre-build | 이미지 입력이 바뀔 때만 Docker build |

#### reload 서비스 표준 예제

reload 가능한 런타임은 전체 source bind 대신 Compose Watch `sync`를 쓴다. dependency 입력은 sync 대상에서
제외하고 별도 `rebuild` 규칙으로 선언한다. 아래 패턴은 Python 예시지만 Node, Go 등에도 같은 경계를 적용한다.

```dockerfile
FROM python:3.11-slim
WORKDIR /app

COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

# Watcher가 붙기 전 최초 기동용. dependency layer 뒤에 둬 소스 수정이 install cache를 깨지 않게 한다.
COPY . .
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--reload"]
```

```yaml
x-api-watch-ignore: &api-watch-ignore
  - .git/
  - .venv/
  - '**/__pycache__/'
  - requirements.txt
  - Dockerfile.local

services:
  api:
    build:
      context: ./api
      dockerfile: Dockerfile.local
    develop:
      watch:
        - action: sync
          path: ./api
          target: /app
          initial_sync: true
          ignore: *api-watch-ignore
        - action: rebuild
          path: ./api/requirements.txt
        - action: rebuild
          path: ./api/Dockerfile.local
```

이 구성의 실행 경계는 다음과 같다.

| 변경/명령 | 동작 |
|---|---|
| 일반 source 저장 | 컨테이너로 sync, 런타임 reload. Docker build 없음 |
| dependency manifest 또는 Dockerfile 저장 | 해당 서비스 이미지만 rebuild |
| `marina start <svc>` | 성공 baseline과 입력·image ID가 같으면 빠르게 기동, 다르거나 기록이 없으면 자동 build |
| `marina rebuild <svc>` | 입력이 같아도 명시적으로 build 평가 후 기동 |

BuildKit layer/cache mount는 `x-marina` 저장소가 아니라 **호스트 Docker daemon의 캐시**다. 같은 dependency 입력과
Dockerfile 단계를 쓰면 worktree가 달라도 재사용할 수 있다. 반대로 `COPY . .` 뒤에서 package install을 하거나
dependency 파일과 일반 source를 같은 `COPY`에 섞으면 소스 수정만으로 install layer가 무효화된다.

전체 source bind와 같은 target의 Watch `sync`를 동시에 쓰지 않는다. bind가 파일을 가려 sync 결과와 이미지
bootstrap 경계가 불명확해진다. `.venv`, `node_modules`, 빌드 출력과 로그도 sync에서 제외해 불필요한 전송과
reload를 막는다.

Compose가 호스트 명령을 실행할 수 없는 빈칸만 서비스 단위 pre-build로 선언한다. `start user-api`는
`user-api`의 명령만, `start --all`은 `startGroup`에 포함된 서비스의 명령만 실행한다. 같은 실제 작업 경로와
명령을 여러 서비스가 공유하면 한 번만 실행하고, 실패하면 `docker compose up` 전에 중단한다.

```yaml
services:
  user-api:
    volumes:
      - ./be-api/user-api/build/libs:/app/libs
    develop:
      watch:
        - action: restart
          path: ./be-api/user-api/build/libs

x-marina:
  startGroup: [web, user-api]
  prebuild:
    user-api:
      cwd: be-api
      command: ./gradlew :user-api:bootJar --build-cache
```

기존 서브레포별 문자열도 계속 읽는다. 아래 선언은 선택된 서비스 중 build context가 `be-api`인 서비스들에
같은 명령을 적용하는 레거시 형식이다. 신규 설정과 수정은 Compose Workbench의 `x-marina.prebuild`에서 한다.

```yaml
x-marina:
  prebuild:
    be-api: ./gradlew assemble
```

Marina의 전역 최소 Compose 버전은 `2.24.4`다. 프로젝트가 더 최신 Watch action을 쓰면 추가로 검증한다.

| Watch 기능 | 최소 Compose 버전 |
|---|---:|
| `sync`, `rebuild` | 2.22.0 |
| `sync+restart` | 2.23.0 |
| `restart` | 2.32.0 |
| `sync+exec` | 2.32.0 |
| `sync+exec`의 `exec` 세부 설정 | 2.32.2 |

---

## compose 구성 — 자동 주입 (ⓘ 구성뷰)

같은 Dockerfile 이라도 dev 로 띄우려면 빌드 인자·아티팩트·런타임 설정이 더 필요할 때가 많다.
marina 는 이걸 **자동 감지하고 제안**한다(대시보드 서비스 ⓘ 모달). 저장은 모두 `~/.marina/<id>/` 에
상대경로/값으로만 — 머신 종속 절대경로는 저장하지 않는다.

| 주입 | 무엇 | marina 가 하는 일 |
|---|---|---|
| **연결 (service redirect)** | 설정이 가리키는 같은 compose 안 다른 서비스(`localhost:6379`, `${REDIS_HOST}:6379` 등) | 엔드포인트마다 **같은 compose 서비스로 redirect** 를 선택한다. 리터럴 `localhost` 는 시작 때 서비스명으로 치환한 복사본을 마운트하고, 호스트가 env 변수면 `via=env` 로 그 변수에 서비스명을 주입한다. 원본 불변, 매 start 재생성. |
| **build args** | Dockerfile `ARG`(가드 있으면 필수) | 필요한 ARG 를 찾아 값 입력 칸 제시 → `build-args.json` |
| **build args (로컬 env 파일)** | x-marina `buildArgsFrom: {svc: env파일}` | 그 env 파일을 호스트에서 읽어 `--build-arg` 로 주입. **값은 공유 compose 에 안 들어가고(경로만 공유)**, 파일은 worktree(links copy)/원본에 로컬 존재 → **시크릿 build-arg 를 안전하게**(예: `apps/web/.env.ssm.local` 의 AWS creds). `${...}` 미해석 플레이스홀더는 자동 스킵(compose 보간 깨짐 방지). multi-stage 면 최종 이미지엔 안 남음. |
| **pre-build** | 컨테이너 시작 전에 필요한 호스트 산출물 | `x-marina.prebuild`의 서비스별 `{cwd, command}` 실행. 레거시 서브레포 문자열도 호환 |
| **마운트** | localhost 없는 개인 설정 파일을 컨테이너에 그대로 | 파일 찾기 + dest(WORKDIR/config) 제안 → `mounts.json` |
| **compose 환경변수** | compose 의 `${VAR}` 보간 | `composeEnvVar`/`composeEnvDefault` 하나를 시작 시 주입(`MARINA_COMPOSE_ENV` 로 값 덮어쓰기). |

ⓘ 모달의 **📁 설정 파일** 한 섹션에서 다 한다 — 파일마다 `localhost` 또는 env 호스트 의존성이 있으면
같은 compose 서비스로 redirect 하고, 없으면 [그대로 마운트]한다. 저장 하나로 service redirect 와 마운트를
함께 저장한다.

### 링크 (deps·config 을 worktree 로)

무거운/gitignore 된 것(node_modules·.venv·빌드출력)과 로컬 설정(`*local.yml`·`.env`·`.npmrc` 등)을
main checkout 에서 worktree 로 **링크(symlink 공유)** 또는 **카피(그 시점 복제, 이후 독립)** 한다.
대시보드 세션의 **link** 버튼 — 원본(main)·워크트리 모달이 동일하게 동작한다:

- **목록 = 적용 링크.** 목록에 있으면 새 worktree(및 재적용)에 적용, 없으면 안 함. 켜짐/꺼짐 같은 숨은 상태 없음.
- **연결** = `+ 폴더 탐색`(폴더 다중선택 → 링크/카피 택1) · **해제** = `✕`. 넣으면 그 worktree 에 **즉시 반영**(materialize). ✕ 는 규칙만 빼고 원본 파일은 안 지운다.
- **서브레포별** — 탭마다(be-api·web 등) 그 서브레포에만 적용·표시. `.venv` 는 python 서브레포에만, `.npmrc` 는 web 에만.
- 링크/카피의 **소스는 main checkout 의 그 파일** — symlink 는 원본을 실시간 공유(한쪽 고치면 양쪽), copy 는 apply 순간의 스냅샷.
- 저장은 보관 compose 의 `x-marina.links` **하나**(= 로컬 설정 = 공유 단위). 그대로 `docker-compose.yml` 을 넘기면 동료도 같은 링크.

```yaml
x-marina:
  links:                                        # 서브레포별 — 그 서브레포에만
    be-api:  { copy: ["**/*local.yml", "**/Dockerfile.local"] }
    ai-api:  { symlink: [".venv"], copy: ["**/*local.yml"] }
    web-app: { copy: ["apps/web/.env", ".npmrc"] }
```

### toolchain (호스트 빌드 SDK)

pre-build(호스트 `gradlew` 등)는 컨테이너와 **같은 SDK** 로 빌드해야 맞다. marina 는 각 서비스의
**Dockerfile `FROM` 을 SoT 로** — 거기서 배포판+버전을 읽어 호스트 빌드 `JAVA_HOME` 을 맞춘다(이중선언 없음).

- `FROM eclipse-temurin:21` → sdkman `21-tem` 자동. `amazoncorretto:17`→`17-amzn` 등. python/node 이미지는 대상 아님.
- **유저 설정 불필요** — Dockerfile 에 이미 있으니 그 JDK 만 로컬(sdkman)에 깔려 있으면 된다.
- 서브레포마다 다른 JDK 여도 각 서비스 Dockerfile 대로 prebuild 가 서브레포별 `JAVA_HOME` 으로 빌드한다.
- 다르게/명시하려면 `x-marina.java` override — `"21"`(전체) · `{be-api: "17", default: "21"}`(서브레포별) · 절대경로.
- sdkman·명시 다 없으면 로그인 셸의 기본 java 로 폴백.

### 엮기 (서버측 localhost 자동 라우팅)

워크트리마다 compose 로 격리하면 앱이 코드에 박은 `localhost:<port>` 가 컨테이너 자기 자신을 가리켜 깨진다(fe(SSR)→be, be→redis 등). marina 는 compose 가 **선언한 포트→서비스 매핑을 자동으로 읽어**, 앱(build) 서비스마다 `alpine/socat` 사이드카 1개(`<svc>-bind`)를 붙여 그 컨테이너의 모든 `localhost:<port>` 를 대상으로 중계한다. **앱 0수정·언어무관**(JAR 내장 설정도 무관).

- **서비스↔서비스는 자동**: compose 가 서빙하는 포트(`ports`/`expose`)를 보고 `localhost:8081→be:8081`(컨테이너 DNS)를 자동 생성. 사람이 선언할 것 없음.
- **호스트 인프라(redis/db 등)만 선언**: compose 의 `x-marina.forward` 에 — marina 설정은 compose 파일 하나(x-marina)에 모인다. 포트 키는 따옴표 문자열(`"6379"`).

  ```yaml
  x-marina:
    forward:
      "6379": host   # 컨테이너의 localhost:6379 → 호스트 redis (리눅스는 default gateway 폴백)
  ```

  대시보드 위저드의 "호스트 백킹 연결" 체크와 동일하다. 레거시 `~/.marina/<id>/backing.json`(`forward`/`hostForward`)도 계속 읽히지만 신규 선언은 x-marina 로.
- 사이드카는 `network_mode: service:<svc>` 로 그 컨테이너 localhost 를 가로챈다. 자기 서빙 포트는 건너뛴다(socat↔앱 listener 충돌 회피). UDP·미선언 포트는 비대상.
- 헤드리스 브라우저(E2E·에이전트)→be 도 컨테이너 안이라 엮기로 해결(동시 무제한). **호스트 브라우저**→be 만 게이트웨이(아래).
- `<svc>-bind` 사이드카는 `docker compose ps` 에 `<프로젝트>-<svc>-bind-1` 로 보인다.

### 게이트웨이 (호스트 브라우저 진입)

호스트 브라우저로 여러 워크트리를 동시에 열 때, marina 가 **Caddy** 를 띄워 `<워크트리>.<프로젝트>.localhost` 도메인으로 각 워크트리의 서비스에 보낸다. 워크트리 포트가 docker 자동할당이라 재기동마다 바뀌어도 marina 가 **동적으로 반영**한다(추가/삭제/정지/포트변경).

- **자동 기동(기본 on)**: 서비스를 `start`/`restart` 하면 게이트웨이가 안 떠 있을 때 **자동으로 뜨고** 라우트를 반영한다(수동 `marina gateway start` 불필요). 끄려면 `MARINA_GATEWAY=off`. caddy 필요 — 없으면 안내(`brew install caddy` / `apt install caddy`)만 하고 게이트웨이만 비활성·나머지 marina 정상.
- **포트**: 기본 **3902**(비특권 — 권한·:80 충돌 없이 자동 기동된다). 대시보드 3900·프리뷰 3901 바로 위이며, 사용 중이면 위로 빈 포트 fallback. `MARINA_GATEWAY_PORT=<n>` 로 고정 가능. URL 은 `http://<wt>.<proj>.localhost:3902`.
- **:80**(포트 없는 깔끔한 URL)을 원하면 1회 시스템 데몬 설치: `marina gateway install`(macOS LaunchDaemon / Linux setcap·systemd), 끄기 `marina gateway uninstall`.
- **라우팅**: 대표 web(fe/web/frontend) → `<wt>.<proj>.localhost`, 그 외 서비스 → `<wt>-<svc>.<proj>.localhost`. 경로 가정 안 함(범용), WS/HMR 기본. `*.localhost` 는 브라우저가 127.0.0.1 로 자동 해석(/etc/hosts 불요).
- **조정(compose 직접)**: 대부분 자동(web 감지)이라 손댈 일 드묾. 대표를 바꾸거나 경로 라우트가 필요하면 `x-marina.gateway` 한 곳에 — compose 하나로 공유, 저장 즉시 반영.

```yaml
x-marina:
  gateway:
    primary: web                # 대표 도메인 서비스(없으면 web-name 자동)
    routes: { be: ["/api"] }    # 대표 도메인의 /api/* → be (브라우저 상대주소 be 호출)
```
- **동적 반영**: 데몬이 라이브 상태를 폴링(빠짐없음, 변할 때만 reload)하고 start/stop/restart 시 즉시 갱신. 현재 라우트는 `GET /api/gateway-status`.

#### `expose` — fe→be 브라우저 배선 (앱 소스 무수정)

fe 가 브라우저에서 be 를 부르는 절대주소(`http://localhost:8081`)는 워크트리 격리와 양립 불가(고정 호스트 포트 = 충돌·비격리). marina 가 fe 의 API base env 를 **표준 compose `environment:` 로 주입**해 게이트웨이로 닿게 한다 — 앱 소스는 안 건드린다. `x-marina.gateway.expose.<소비자서비스>.<ENV_VAR>` 에 토큰으로 선언:

```yaml
x-marina:
  gateway:
    expose:
      web:
        NEXT_PUBLIC_API_URL: "gateway:user-api"   # 도메인 모드
        # 또는  "origin:user-api"                 # same-origin 모드
    routes:
      user-api: ["/v1.0", "/v2.0"]                   # same-origin 모드일 때만(be prefix)
```

| 토큰 | 주입값 | 게이트웨이 | CORS | 적합 인증 |
|---|---|---|---|---|
| `gateway:svc` | `http://<wt>-svc.<proj>.localhost:<port>` | be 서브도메인 catch-all | **caddy 가 전담**(be 무수정) | 헤더 토큰(stateless) |
| `origin:svc` | `""`(상대) | 대표 도메인 path 라우팅(`routes[svc]`) | 없음(same-origin) | **쿠키 세션** |

- **CORS(도메인 모드)**: 게이트웨이 경로에선 caddy 가 CORS 를 처리한다(be 응답 ACAO replace + preflight 204 + credentialed + 요청 헤더 echo). be 자체 CORS 는 직접 접근 경로에만 적용. 유효 라우팅·CORS 쌍은 `marina gateway config` 로 확인.
- **쿠키 세션 앱**은 서브도메인 간 쿠키(Secure·부모도메인 충돌) 취약 → **`${origin:}` (same-origin) 모드 권고**. marina 는 Set-Cookie 를 재작성하지 않는다.
- next dev 는 런타임에 env 를 읽어 무수정 반영(prod 정적 빌드는 `NEXT_PUBLIC_*` 빌드타임 인라인이라 별도). 한 env 를 브라우저·서버 겸용하는 앱은 서버쪽 var 을 분리(서버사이드는 서비스 DNS).
- 설계: [docs/superpowers/specs/2026-07-01-gateway-expose-design.md](docs/superpowers/specs/2026-07-01-gateway-expose-design.md).

- **잔여(물리 한계)**: 같은 내부 포트를 여러 서비스가 서빙하면 compose 에서 포트 분리(엮기 자동타겟 모호).
  서비스·워크트리 이름이 DNS 라벨 정리 후 충돌하면(`user_api` vs `user-api`) 게이트웨이는 해시로 도메인을
  분리하지만 expose 주입 URL 은 해시 전 라벨이라 어긋날 수 있다(경고 출력) — 이름을 분리해 쓰는 걸 권장.

---

## 동작 원리

- **격리** — 워크트리별 compose 프로젝트명으로 네트워크·컨테이너·볼륨 분리.
- **포트** — marina 가 `marina-overlay.yml`(ephemeral `!override`)로 published 포트를
  `127.0.0.1::<컨테이너포트>` 로 덮는다. 호스트 포트는 Docker 가 정하므로 **`down`/`up`(전체 정지·기동)
  으로 컨테이너가 재생성되면 바뀔 수 있다** — 대시보드 `↗` 가 그때 포트로 열어주므로 외울 필요 없다.
- **서비스 간 호출** — 같은 compose 안에서는 `http://service:port` 형태의 compose service DNS 를 쓴다.
  호스트 포트는 사람이 브라우저·CLI 로 접근할 때만 필요하다.
- **container_name·dockerfile 케이싱·build args·volume** 도 overlay 가 런타임에 보정한다 —
  저장된 compose(앱 레포 기준)는 그대로 두고 비침투적으로 머지한다.
- **links/symlink** — 호스트 checkout 사이의 편의 링크다. 컨테이너 파일 주입과 무관하며, 컨테이너에는
  `mounts.json` overlay volume 또는 service redirect 로 들어간다.
- **외부 서브레포** — start 때 `.workspace/external/<name>` 에 git worktree 로 체크아웃 후 compose `include`.
- **해석된 전체 설정은 파일로 저장하지 않는다** — marina 는 포트·격리 보정 overlay(`marina-overlay.yml`)만
  쓴다. 단, 입력한 build args 값은 `build-args.json` 에 저장되므로 **시크릿 build-arg 는 `buildArgsFrom`**(로컬 env 파일에서 주입 — 값은 공유 compose 에 안 들어가고 경로만) **또는 `env_file`/런타임**으로 넣는다.

---

## 대시보드 (:3900)

- 좌측 패널에 프로젝트→서브레포→서비스 그룹. compose 카드는 서비스 목록을 `docker compose ps`
  라이브로 보여준다(한 번도 안 띄운 스택은 `start --all` 후 나타남).
- 카드 헤더 `▶ Start all` / `■ Stop all`, 서비스별 ▶/■/↻, web 열기 `↗`.
- 서비스 ⓘ — 빌드 컨텍스트·Dockerfile·포트·env + build args/profile 편집, 적용 중인 pre-build는 읽기 전용 표시.
- 로그 뷰어 — run 히스토리·검색·실시간 스트리밍(start 때 `docker compose logs -f` 를 `run-NNN.log` 로 캡처).
- 빌드 로그 — run별 총 시간, BuildKit·Gradle 단계, cache hit 수, 가장 오래 걸린 단계를 원문 로그 위에서 요약.

---

## 업데이트

플러그인 매니페스트에 `version` 을 두지 않는다 — 마켓플레이스 repo 의 매 커밋이 곧 새 버전(commit SHA).
**레포에 push 하면 그게 새 릴리스**다.

- **Claude Code** — 세션 시작 시 background auto-update. 즉시 갱신은 `/plugin marketplace update`.
- **Codex** — `codex plugin marketplace upgrade`.

---

## 명령어 레퍼런스

| 그룹 | 명령 |
|---|---|
| 대시보드 | `marina`(무인자=대시보드 start) · `marina dashboard start\|stop\|status\|open` · `marina open` |
| 셋업 | `marina install-cli` · `marina uninstall-cli` · `marina attach` |
| 등록 | `marina project add <path> --compose <file> [--env-var N --env-default V]` + 선택 `--external name=path` (또는 대시보드 위저드) |
| 등록 관리 | `marina project ls \| infer <path> \| rm <id> \| default <id> a,b,c` |
| 실행 | `marina start\|stop\|restart <svc>\|--all` · `marina status \| ports \| logs [svc]` |
| 게이트웨이 | `marina gateway start\|stop\|status\|install\|uninstall` (보통 서비스 start 시 자동 기동이라 수동 불필요) |
| 워크트리(작업 시작) | `marina worktree create <branch> [base] [--project <id>]` — git worktree(-b) + 서브레포를 같은 브랜치로 미러 (Claude 자동 `claude/<id>` 대신 `feature/{task}` 등으로). `--project`=cwd 무관(프로젝트 밖에서도). attach 범위는 `marina project default <id> a,b,c` 로 좁힘(예: compose 서브레포만) |

내부 호출은 `marina.sh`(launcher)와 `marina-control.py`(데몬·CLI 브리지)지만, 평소엔 위 `marina` 래퍼만
쓰면 된다. `marina.sh` 를 직접 부를 땐 서비스를 `--<svc>` 플래그로 지정한다(래퍼가 `web → --web` 변환).

---

## 요구사항·제약

- **Docker — compose v2.24.4 이상** (`!override` 머지 태그 사용. 미달이면 start 때 명확한 에러로 거부).
  `docker compose version` 으로 확인 — Docker Desktop 4.28+ 면 충족. 게이트웨이 CORS·엮기 사이드카도
  전부 이 안에서 동작하므로 Docker 외 추가 데몬은 없다.
- **Caddy v2.7 이상** (게이트웨이 전용, **선택**) — `brew install caddy` / `apt install caddy`,
  `caddy version` 으로 확인(실측 v2.11). 표준 Caddyfile 지시어만 쓰므로 v2 면 대체로 동작하나 2.7 미만은
  미검증. 없으면 게이트웨이만 비활성(안내 출력)되고 marina 나머지는 정상.
- **python3**(표준 라이브러리만)·**bash**·**git** — 별도 pip 설치 없음.
- 단일 포트만 지원(포트 **범위**는 거부). `network_mode: host` 는 격리를 깨므로 **거부**된다(명확한 에러).
  `container_name` 은 격리를 위해 overlay 에서 **자동 제거**된다(`!reset`, 경고). `external` 네트워크·볼륨은 경고만.
- `restart --<svc>`도 선언된 build 입력이 성공 baseline과 다를 때만 `up --build`를 실행한다.
  `rebuild --<svc>`는 입력이 같아도 항상 `up --build`를 실행한다.
- 등록 검증(위저드 검토·`--compose`)은 `docker compose config` + 격리 검사까지다(이미지 빌드 실행까지는 아님).

---

## 구조

```
marina/
├── .claude-plugin/marketplace.json   레포 = 마켓플레이스 (플러그인은 ./plugin)
├── README.md · LICENSE
└── plugin/                           설치되는 플러그인 (Claude·Codex 공용)
    ├── .claude-plugin/plugin.json · .codex-plugin/plugin.json
    ├── hooks/hooks.json              SessionStart 훅 선언
    ├── commands/                     슬래시 명령(/marina:project 등)
    └── scripts/
        ├── marina.sh                    세션별 launcher + 레지스트리 CLI (start/stop/restart · project)
        ├── marina-compose.py            compose 라우팅 — overlay 생성 · build/up/down · 라이브 포트
        ├── marina-control.py            :3900 대시보드 (단일 파일 서버+UI) + compose_assist · CLI 브리지
        ├── marina-resolve.sh            설치 경로 해석 + shim(launcher) 생성 (Claude·Codex·baked fallback)
        ├── marina-dashboard.sh          대시보드 데몬 (launchd · systemd · nohup 폴백)
        ├── attach-detached-subrepos.sh  worktree 에 서브레포·외부레포 git worktree attach
        ├── marina-session-start-hook.sh 세션 시작 attach 훅
        └── marina-entrypoint.sh         전역 진입점 (dashboard · project · start/stop/restart · install-cli)
```

테스트: `plugin/tests/*.sh` (docker 는 `docker info` 게이트로 미가동 시 스킵).

---

## 라이선스

[MIT](LICENSE)
