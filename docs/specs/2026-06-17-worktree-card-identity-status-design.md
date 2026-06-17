# 대시보드 좌측 카드 — 정체성·상태 신호 개선 (design)

날짜: 2026-06-17
대상: `plugin/scripts/marina-control.py` (대시보드 좌측 세션 카드)

## 문제

좌측 worktree 카드가 두 가지로 파악이 안 됨:

1. **어느 세션이 어느 워크트리인지 모름** — 카드 제목이 의미 없는 해시(`funny-ride-06f367`)이고, 같은 해시가 제목·브랜치 칩·경로줄에 3번 반복.
2. **변경분·미머지가 뭐가 뭔지 혼란** — 둘 다 루트+서브레포 **합산**이라 출처가 안 보이고, "바로 열어도 무조건 잡히는" 구조적 노이즈가 깔림.

## 실측 근거 (mdc-main 4개 worktree)

- **변경분**: 4개 전부 `ai-api/.venv`(gitignore 안 됨) 하나가 잡혀 항상 "변경분 1". **tracked 수정은 0개** — 현재 변경분은 100% untracked 툴링 찌꺼기. (루트는 이미 `.workspace`·서브레포 폴더 제외하나, 서브레포 내부 untracked는 미제외.)
- **미머지**: agitated·eager·intelligent 셋 다 web-app-monorepo의 **동일 커밋 `e023128`** — 워크트리 생성 시 물려받은 공유 base(`reflog: Created from HEAD e023128`). `main..HEAD` 기준이라 세션 작업 0인데도 +1.
- **세션 타이틀 도달 가능**: `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json` 에 `title`+`titleSource`, `worktreePath`로 워크트리와 1:1. 103개 중 100개 보유. 데스크톱 앱 전용(`titleSource: auto`=LLM, 유저 수정 시 갱신). CLI는 미생성 → 폴백 필요.

## 설계

### A. 정체성 — 제목 캐스케이드
- 카드 제목 = `alias → Claude 세션 타이틀 → Codex 세션 타이틀 → 최신 커밋 제목(headSubject) → 해시(id)`. main 체크아웃은 폴백 없이 'main'.
- Claude: 신규 `claude_session_titles()` — `claude-code-sessions/**/local_*.json` glob, `worktreePath`로 인덱싱, 중복 시 `lastActivityAt` 최신, 디렉토리 없으면 `{}`. 20s 캐시. `worktree_info()`에 `headSubject` 추가, `/api/worktrees`에서 `sessionTitle`·`titleSource` 오버레이.
- Codex: 신규 `codex_session_titles()` — codex worktree(detached HEAD)는 브랜치명이 없어 정체성이 특히 약함. 체인: worktree cwd → `~/.codex/sessions/**/rollout-*.jsonl` 의 `session_meta`(line0 cwd+id) → `session_index.jsonl` 의 `thread_name`. 60s 캐시 + mtime 45일 필터(히스토리 누적 비용 상한), thread_name 120자 상한. Claude 다음 폴백(`titleSource: "codex"`).
- 해시·브랜치는 제목 아래 **작은 mono 보조줄**(`⎇ funny-ride-06f367`)로 강등(제거 아님). 제목이 id와 같을 때만 보조줄 생략.
- 브랜치 칩: 기본값(`claude/<id>`)이면 숨김, off-main(다른 브랜치 섞임)일 때만 경고 표시.

### B. 변경분 → `✎` (tracked) + untracked 분리
- `worktree_status`에서 porcelain 줄을 tracked(비-`??`) / untracked(`??`)로 분리, repo별·합산 카운트 노출.
- 칩: tracked>0 → `✎N`(차분한 중립색, 클릭 시 레포별 펼침). untracked>0 → 약한 보조 `+N`(거슬리지 않게, 0이면 사라짐).
- 펼침 패널: 레포별로 tracked/untracked 구분해 **합산 출처**를 드러냄.

### C. 미머지 → `↑` fork-point 기준 + 출처
- `repo_ahead_of_main`: `merge-base --fork-point main <branch>` 로 생성 base 산출 → `<base>..HEAD` 카운트. 실패 시 `main..HEAD` 폴백.
- 칩: ahead>0 → `↑N`(약한 강조). 출처 레포가 **하나면** `↑N web`처럼 표기, 둘 이상이면 `↑N` + 호버로 분해.

## 엣지·폴백
- 앱 미설치/CLI/codex worktree → 세션 타이틀 `{}` → headSubject→id 폴백.
- detached HEAD/`main` 없음/reflog 만료 → 미머지 `main..HEAD` 또는 0 폴백.
- 폴링 핫패스 보호: 타이틀 맵·fork-point는 캐시(파일 mtime/TTL), 103개 매 폴링 재파싱 금지.

## 범위 밖 (별도/선택)
- `ai-api/.venv`를 해당 레포 `.gitignore`에 추가(소스단 정리) — marina 외부 레포라 본 변경엔 미포함, 보조 권장.
- codex thread_name 품질 편차(일부 raw 첫 메시지) — 상한만 적용, 정제는 후속 여지.
