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
scripts/marina-entrypoint.sh add /path/to/project   # 프로젝트 등록 (서브레포·worktree 자동 추론)
scripts/marina-entrypoint.sh ls                      # 등록 목록
scripts/marina-entrypoint.sh dashboard               # 전역 대시보드(:3900) 기동
```

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
- 복잡한 기동(env 준비·의존성 링크 등)은 `run` 이 프로젝트 쪽 헬퍼 스크립트를 호출한다.
- `cachePaths`(선택): Clear cache 대상. `orphanPattern`(선택): 유령 프로세스 탐지 정규식.

## 구조

```
marina/
├── .claude-plugin/{plugin,marketplace}.json   플러그인 매니페스트 + marketplace (레포=마켓)
├── .codex-plugin/plugin.json
├── hooks/hooks.json                           SessionStart 훅 선언
└── scripts/
    ├── marina.sh                       세션별 런처 + 레지스트리 CLI (add/rm/ls)
    ├── marina-control.py               :3900 관제 대시보드 (단일 파일 서버+UI, 프로젝트 그룹)
    ├── marina-dashboard.sh             전역 대시보드 데몬 launchd 런처
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
