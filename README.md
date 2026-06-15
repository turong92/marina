# marina

worktree 멀티세션 dev 서버 런처 + 관제 대시보드. 한 머신에서 여러 git worktree 의
dev 서버를 포트 충돌 없이 띄우고, `:3900` 웹 대시보드에서 상태·로그·캐시·포트를 관리한다.
의존성 0 — `/usr/bin/python3`(표준 라이브러리만) + bash (macOS·Linux).

서비스(무엇을 어떻게 띄울지)는 전적으로 프로젝트별 `marina-services.json` 에서 정의한다 —
marina 코어는 특정 스택에 묶이지 않는다.

## 설치

marina 레포 자체가 플러그인 marketplace 다. Claude Code·Codex 둘 다 1회 설치로
SessionStart 훅이 신뢰되어(설치=신뢰) worktree 가 열릴 때 서브레포가 자동 attach 된다.

```bash
/plugin marketplace add turong92/marina
/plugin install marina@marina-dev
```

대시보드·CLI 는 클론한 레포에서 직접:

```bash
plugin/scripts/marina-entrypoint.sh add /path/to/project   # 프로젝트 등록 (서브레포·worktree 자동 추론)
plugin/scripts/marina-entrypoint.sh ls                      # 등록 목록
plugin/scripts/marina-entrypoint.sh dashboard               # 전역 대시보드(:3900) 기동
```

대시보드 데몬은 macOS 에선 launchd 로 등록되어 로그인 시 자동 기동된다. launchctl 이
없거나 실패하면 `nohup` 백그라운드로 폴백한다 (Linux 포함). 어느 쪽이든 PID 는
`~/.marina/dashboard.pid`, 로그는 `~/.marina/dashboard.log`.

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
        ├── marina.sh                       세션별 런처 + 레지스트리 CLI (add/rm/ls)
        ├── marina-control.py               :3900 관제 대시보드 (단일 파일 서버+UI)
        ├── marina-dashboard.sh             대시보드 데몬 (launchd / nohup 폴백)
        ├── attach-detached-subrepos.sh     worktree 에 서브레포 git worktree attach
        ├── marina-session-start-hook.sh    세션 시작 attach 훅 (플러그인이 호출)
        └── marina-entrypoint.sh            전역 진입점 (dashboard / add·rm·ls)
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
