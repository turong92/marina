# marina

worktree 멀티세션 dev 서버 런처 + 관제 대시보드. 한 머신에서 여러 git worktree 의
dev 서버를 포트 충돌 없이 띄우고, `:3900` 웹 대시보드에서 상태·로그·캐시·포트를 관리한다.
의존성 0 — `/usr/bin/python3`(표준 라이브러리만) + bash (macOS·Linux).

서비스(무엇을 어떻게 띄울지)는 전적으로 프로젝트별 `marina-services.json` 에서 정의한다 —
marina 코어는 특정 스택에 묶이지 않는다.

## 설치

marina 레포 자체가 플러그인 marketplace 다. 설치하면 SessionStart 훅이 worktree 가
열릴 때 등록된 프로젝트의 서브레포를 자동 attach 한다.

```bash
# Claude Code
/plugin marketplace add turong92/marina
/plugin install marina@marina-dev

# Codex
codex plugin marketplace add turong92/marina
codex plugin add marina@marina-dev
```

**훅 신뢰**: Claude Code 는 설치 시 플러그인 훅을 자동 신뢰한다. **Codex 는 플러그인 훅을
non-managed 로 취급하므로 최초 1회 수동 신뢰가 필요하다** — 플러그인 화면의 "신뢰" 버튼
또는 `/hooks` 에서 한 번 trust 하면 `~/.codex/config.toml` 에 기록되어 이후 세션부터
0클릭으로 실행된다 (자동 업데이트돼도 훅 정의가 그대로면 신뢰 유지). 이는 Codex 보안
모델이며 marina 고유 동작이 아니다.

대시보드·CLI 는 클론한 레포에서 직접:

```bash
plugin/scripts/marina-entrypoint.sh add /path/to/project   # 프로젝트 등록 (서브레포·worktree 자동 추론)
plugin/scripts/marina-entrypoint.sh ls                      # 등록 목록
plugin/scripts/marina-entrypoint.sh dashboard               # 전역 대시보드(:3900) 기동
```

대시보드 데몬은 OS 에 맞는 supervisor 로 등록되어 로그인·부팅 후 자동 기동된다:

- **macOS** — launchd (`~/.marina/marina.dashboard.plist`), 로그인 시 자동 기동.
- **Linux** — systemd user 유닛(`marina-dashboard.service`) + `loginctl enable-linger`
  로 등록되어 로그아웃 후에도 살아남는다.
- **폴백** — launchd·systemd 가 없거나 실패하면 `nohup` 백그라운드로 띄우고
  `auto-restart NOT configured` 경고를 낸다 (재부팅 시 수동 재기동 필요).

어느 쪽이든 PID 는 `~/.marina/dashboard.pid`, 로그는 `~/.marina/dashboard.log`.

## 처음 실행 — 프로젝트를 한 번 등록

플러그인을 설치하면 SessionStart 훅이 등록되지만, **프로젝트를 한 번 등록하기 전까지는
아무것도 attach 하지 않는다**. 훅은 "이 worktree 가 등록된 프로젝트에 속하는가" 를 보고
맞을 때만 서브레포를 붙이기 때문이다. 즉 설치 직후 첫 단계는 **프로젝트 1회 등록**이다.

등록은 세 가지 중 아무 방법이나:

```bash
# 1) Claude 세션 안에서 — 현재 git 프로젝트를 바로 등록 (worktree 안에서 실행해도 main 체크아웃을 찾아 등록)
/marina:register
/marina:ls                  # 등록 목록 확인

# 2) 터미널에서 — marina CLI 설치 후 (아래 "marina CLI" 참조)
marina add /path/to/project
marina ls

# 3) 대시보드 UI — 스위처의 + 프로젝트 등록 / subrepo 헤더의 + 서비스 추가
```

`add`/`register` 는 경로에서 서브레포(중첩 git 레포)와 worktree 글롭을 추론해 초안을
만든다. 출력된 `id`·`subrepos` 가 맞는지 확인하고, 빠지거나 남는 게 있으면 다시 등록하거나
`~/.marina/projects.json` 을 직접 고친다. 쓰지 않고 추론 결과만 보려면
`marina infer /path/to/project` (JSON 출력, 레지스트리 미수정).

### marina CLI — `install-cli`

레포 안에서 `plugin/scripts/marina-entrypoint.sh ...` 로 바로 쓸 수도 있지만, 어디서나
`marina` 한 단어로 부르려면 PATH 셰임을 설치한다 (선택):

```bash
plugin/scripts/marina-entrypoint.sh install-cli      # ~/.local/bin/marina 셰임 설치
marina add /path/to/project                          # 이제 어디서나 marina
plugin/scripts/marina-entrypoint.sh uninstall-cli    # 제거
```

셰임은 호출 때마다 현재 설치된 플러그인 경로를 스스로 해석한다 — 그래서 플러그인이 자동
업데이트(새 SHA)돼도 셰임을 다시 깔 필요가 없다. `~/.local/bin` 이 PATH 에 없으면 설치
시 안내가 나온다.

## 업데이트

플러그인 매니페스트에 `version` 을 두지 않는다 — 마켓플레이스 repo 의 매 커밋이 곧 새
버전이다 (git commit SHA 기준). 따라서 **레포에 push 하면 그게 새 릴리스**이며 버전을
수동으로 올릴 필요가 없다.

- **Claude Code**: 세션 시작 시 background auto-update 로 자동 반영된다 (공개 repo 는
  인증 토큰 불요). 즉시 갱신은 `/plugin marketplace update`.
- **Codex**: `codex plugin marketplace upgrade` 로 갱신한다 (세션 시작 시 자동 적용
  여부는 Codex 버전에 따라 다를 수 있다).

## 프로젝트 등록 — `~/.marina/projects.json`

한 데몬이 등록된 모든 프로젝트의 worktree 를 관리한다. `add <path>` 가 경로에서
서브레포(중첩 git 레포)와 worktree 글롭을 추론해 초안을 만든다 (확인/정정).

```json
{
  "projects": [
    {
      "id": "myapp",
      "root": "/path/to/myapp",
      "subrepos": ["frontend", "backend"],
      "worktreeGlobs": [".claude/worktrees/*", "~/.codex/worktrees/*/myapp"]
    }
  ]
}
```

중첩 레포(root 아래 독립 git 레포들)와 모노레포(`subrepos: []`) 둘 다 받는다.

## 서비스 정의 — 프로젝트 root 의 `marina-services.json`

```json
{
  "services": [
    {
      "name": "web",
      "portBase": 3000,
      "cwd": "frontend",
      "run": "exec npm run dev -- --port {port}",
      "cachePaths": ["frontend/.next"],
      "orphanPattern": "next dev"
    }
  ]
}
```

- `run` 치환자: `{port}` `{python}` `{root}` `{profile}` + 세션 경로 `{env_file}` `{tmp}` `{session}`.
- 포트 = `portBase + 세션오프셋` (main 0 / worktree 는 id 해시로 안정적 대역).
- `cachePaths`(선택): Clear cache 대상. `orphanPattern`(선택): 유령 프로세스 탐지 정규식.

### 저장 위치 2곳 + 머지

서비스 목록은 두 곳에 둘 수 있고, 둘 다 있으면 `name` 단위로 머지된다(중앙 우선).

| 위치 | 파일 | source 태그 | 특징 |
|------|------|-------------|------|
| 프로젝트 root | `<프로젝트>/marina-services.json` | `팀` | repo 에 커밋해 팀이 공유 |
| 중앙 개인 | `~/.marina/services/<프로젝트id>.json` | `내 override` | repo 무관, 개인 로컬 전용 |

두 위치에 같은 `name` 이 있으면 **중앙(개인) 정의가 우선** 적용된다. `.env.local` 패턴과
동일한 구조 — 팀 정의를 공유하기 전에 개인이 override·테스트하고, 테스트가 끝나면
중앙에서 그 `name` 을 지우면 팀 정의로 자동 복귀한다.

### 서비스 추가 방법 3가지

**1. 대시보드 UI** — subrepo 헤더의 `+ 서비스 추가` 버튼으로 추가 (이름·포트·cwd·run 입력).
"팀 공유" 체크 시 프로젝트 root `marina-services.json` 에 저장(commit 권장); 기본은 중앙
개인 파일(`~/.marina/services/<id>.json`)에 저장.

**2. LLM 슬래시** — Claude 세션 안에서:

```
/marina:add-service [path]
```

에이전트가 프로젝트 구조를 분석해 서비스 목록을 제안하고, 확인 후 등록한다.

**3. CLI** — 터미널에서 직접:

```bash
# 서비스 추가 (기본: 중앙 개인 / --root: 프로젝트 root)
marina add-service <프로젝트id> '<service-json>' [--root]

# 서비스 제거
marina rm-service <프로젝트id> <name> [--root]
```

#### Running a service under docker

`run` is any shell command, so docker compose works with **zero special support** — pass marina's
tokens into the container so each worktree stays isolated:

```jsonc
{ "name": "api", "portBase": 18080, "cwd": "projects/kotlin-skeleton",
  "run": "exec env HOST_PORT={port} COMPOSE_PROJECT_NAME=svc-{session} docker compose up --abort-on-container-exit" }
```

```yaml
# the service's compose.yml must take the host port + project name from the env:
services:
  api:
    ports: ["${HOST_PORT}:8080"]
```

`{port}` = `portBase` + per-worktree offset, `{session}` = per-worktree id → concurrent worktrees get
distinct host ports and compose project names, exactly like a native service. Stop sends `SIGTERM`
first, which makes `compose up` stop its containers. (Limit: a container that needs >5s to stop is
force-killed and may linger; orphan detection matches the process, not the container.)

### 복잡한 기동 — 헬퍼 스크립트 패턴

`run` 한 줄로 부족한 서비스(env 준비, 의존성 링크, 빌드 캐시 워밍 등)는 `run` 이
프로젝트 쪽 헬퍼 스크립트를 호출하게 한다. marina 코어는 단순하게 두고 복잡성은
프로젝트가 소유한다.

```json
{
  "name": "web",
  "portBase": 3000,
  "cwd": "frontend",
  "run": "exec {root}/scripts/dev-web.sh {port}"
}
```

```bash
# scripts/dev-web.sh — 프로젝트 소유. marina 가 넘긴 값으로 환경을 준비하고 exec.
#!/usr/bin/env bash
set -euo pipefail
port="$1"
# worktree 마다 새로 설치하는 대신 원본(main) 체크아웃의 node_modules 를 링크
[ -e node_modules ] || ln -s "$MARINA_SOURCE_ROOT/frontend/node_modules" node_modules
# 시크릿·환경 변수 준비 (예: 시크릿 매니저에서 .env 채우기)
[ -f .env.local ] || ./scripts/pull-env.sh > .env.local
exec npm run dev -- --port "$port"
```

marina 가 헬퍼에 넘기는 것:

- `run` 치환자 — `{port}` `{root}` `{python}` `{profile}` `{env_file}` `{tmp}` `{session}`.
- 환경 변수 — `MARINA_SOURCE_ROOT`(원본 main 체크아웃), `MARINA_ROOT`(현재 worktree).

### `web` 서비스 컨벤션

대시보드는 `web` 이라는 이름의 서비스를 브라우저 프리뷰 대상으로 특별 취급한다:

- 로그 뷰어에 Console/Server 탭 — 브라우저 콘솔 로그를 대시보드로 포워딩해 함께 본다.
- 로그 툴바 ↗ 버튼 — 그 세션의 web 을 브라우저로 연다 (`http://localhost:{port}/`).
- 대시보드 첫 진입 시 기본 선택 대상.
- 세션 간 포트 충돌 칩을 web 포트 기준으로 표시.

브라우저로 프리뷰할 dev 서버의 이름을 `web` 으로 두면 위 기능이 켜진다. 다른
서비스(api·worker 등)는 일반 서버 로그만 본다.

## 구조

```
marina/
├── .claude-plugin/marketplace.json   레포 = 마켓플레이스 (플러그인은 ./plugin)
├── README.md · LICENSE
└── plugin/                           설치되는 플러그인 (Claude·Codex 공용)
    ├── .claude-plugin/plugin.json
    ├── .codex-plugin/plugin.json
    ├── hooks/hooks.json              SessionStart 훅 선언
    └── scripts/
        ├── marina.sh                       세션별 런처 + 레지스트리 CLI (add/infer/rm/ls)
        ├── marina-control.py               :3900 관제 대시보드 (단일 파일 서버+UI)
        ├── marina-dashboard.sh             대시보드 데몬 (launchd / nohup 폴백)
        ├── attach-detached-subrepos.sh     worktree 에 서브레포 git worktree attach
        ├── marina-session-start-hook.sh    세션 시작 attach 훅 (플러그인이 호출)
        └── marina-entrypoint.sh            전역 진입점 (dashboard / add·infer·rm·ls)
```

## 핵심 기능

- 세션별 포트 스킴 — main 0 / worktree 는 id 해시 오프셋 → `portBase + offset`
- 헬스 3단계 pill: BOOT / ON / ERR
- 카드 칩: 변경분·디스크·미머지·브랜치·포트충돌·캐시
- 로그 뷰어: 양방향 무한 스크롤, 위치 게이지, 필터/에러만 매치 전용 뷰, 다운로드
- Clear cache (서비스별 `cachePaths`), 유령 프로세스 정리, 메모리 가드
- 멀티 프로젝트: 대시보드 좌측 패널 프로젝트 그룹 (단일 프로젝트면 헤더 생략)

## 의존성 0

`/usr/bin/python3`(표준 라이브러리) + bash. 외부 패키지·런타임 없음.

## 라이선스

[MIT](LICENSE)
