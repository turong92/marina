# 깃 그래프 패널 — 설계 (2026-07-02)

## 배경 / 페인포인트

marina 는 워크트리 단위로 세션을 격리하는데, 각 워크트리가 main 과 어떻게 다른
상태인지(어떤 브랜치가 어디 체크아웃돼 있고, 무슨 변경이 어디 쌓였고, 서브레포끼리
어긋나진 않았는지)가 직관적으로 안 보인다. 형이 고른 페인포인트 3개:

1. **무슨 변경이 어디 있나** — 워크트리별·서브레포별 미커밋 변경과 커밋된 변경의 실제 diff
2. **전체 지형도** — main + 워크트리들이 서로 어떤 브랜치·관계인지 한 화면에
3. **서브레포 상태 불일치** — 워크트리 안 서브레포들이 각자 다른 브랜치일 때 안 보임

UI 문법은 GitKraken 스타일 커밋 그래프(세로 레인 = 브랜치)로 확정 — 매트릭스 뷰는 버림.
주 무대는 대시보드(:3901 계열), CLI 추가 없음.

## 범위

**이번(1단계, 관측 전용):** 깃 그래프 패널 + diff 모달. 전부 읽기 전용 git 명령.

**범위 밖 (로드맵):**
- 2단계: 커밋/푸시 — diff 모달 위에 stage·commit·push UI
- 3단계: 브랜치/머지 흐름 — 머지된 워크트리 원클릭 정리, main sync, PR 생성

## UI

### 깃 그래프 패널 (대시보드 새 섹션)

- **레포 탭**: root 레포 + 서브레포 목록. 한 번에 한 레포의 그래프.
  (external 레포는 체크아웃 경로가 달라(.workspace/external) 1단계 제외 — 후속)
- **커밋 그래프**: 세로 레인 = 브랜치. 회색 레인 = main, 색 레인 = 워크트리 브랜치.
  행 = 커밋(최신 위). 레인이 main 에서 갈라지고(fork) 합쳐지는(merge) 게 보인다.
- **WIP 행**: 미커밋 변경이 있는 워크트리는 해당 브랜치 레인 맨 위에 점선 노드
  `● 미커밋 N` 행. 클릭 → diff 모달.
- **칩(브랜치 라벨 행)**:
  - 브랜치명 칩 (레인 색)
  - 워크트리 세션 칩 (alias) — 이 브랜치가 어느 세션 것인지
  - `⚠ <repo>=<branch> 불일치` 칩 — 같은 워크트리의 다른 서브레포가 다른 브랜치일 때
  - `✓ 머지됨` 칩 — HEAD 가 main 의 조상(`merge-base --is-ancestor`)이면. "정리 후보" 신호
- **워크트리 필터**: 전체 | 특정 세션만 (레인 축소).
- 행 스타일은 기존 대시보드 컴팩트 칩 UX 를 따른다 (styles.css 기존 톤).

### diff 모달 (공용)

- 커밋 행 클릭 → 그 커밋의 변경 파일 목록 + unified diff (`git show`)
- WIP 행 클릭 → 미커밋 변경 파일 목록(status) + 파일별 diff (`git diff HEAD`,
  untracked 는 `/dev/null` 대비)
- 기존 모달 프레임(app-6-modals.js) 재사용. diff 텍스트는 escapeHtml 후
  `+`/`-`/`@@` 라인 프리픽스로 색칠.
- 세션 카드의 변경 수 클릭에서도 같은 모달을 연다 (기존 `/api/worktree-changes`
  목록 → 파일 클릭 시 diff).

## 데이터 모델 / 백엔드

서브레포·external 은 전부 `git worktree add` 로 attach 되어 main 체크아웃과 객체DB 를
공유한다 → **레포당 main 체크아웃 하나에서 모든 브랜치의 로그를 얻을 수 있다.**
단, dirty/WIP 는 각 워크트리 체크아웃에서 `git status` 로 얻는다(기존 캐시 재사용).

### API (전부 GET, 읽기 전용)

1. `/api/git-graph?repo=<name>`
   - repo 열거: main 체크아웃의 root + 서브레포 + external (기존 registry 로직)
   - 브랜치 수집: main + 각 워크트리 세션이 이 레포에서 체크아웃한 브랜치
     (기존 `worktree_info().branches` 재사용)
   - 커밋: `git log --topo-order --format=%H%x1f%P%x1f%s%x1f%ct -n 200 main <branches...>`
     → `{hash, parents[], subject, ts}` 목록 + `refs`: branch→head hash
   - 브랜치 메타: `{branch, worktreeAlias, root, dirtyCount, merged, mismatch[]}`
     - merged: `git merge-base --is-ancestor <head> main`
     - mismatch: 같은 워크트리의 서브레포 브랜치들이 unique 하지 않을 때 그 목록
   - 캐시: 15s TTL (기존 `worktree_status_cached` 패턴)
2. `/api/git-diff?root=&repo=&file=&commit=`
   - `commit` 있으면 `git show <commit> [-- <file>]`, 없으면 working diff
     (`git diff HEAD [-- <file>]`; untracked 는 `git diff --no-index /dev/null <file>`)
   - 가드: 200KB 초과 절단(`truncated: true`), 바이너리는 "binary" 표시

API 는 이 2개로 확정 — 커밋 목록은 git-graph 응답에 이미 있고, 커밋별 파일
목록·본문은 git-diff(commit=) 의 `git show` 출력에 포함된다. 별도 git-log 없음.

### 프론트 (marina-web)

- 새 파일 `app-8-git.js` (+styles.css 추가) — 패널 렌더 + 레인 배치.
- 레인 배치 알고리즘(단순화): main = lane 0 고정. 각 브랜치 = 고유 lane.
  커밋을 topo 순으로 행에 놓고, 각 행에서 자기 브랜치 레인에 노드,
  부모가 다른 레인이면 곡선 연결. 세션 브랜치가 대부분 "main 에서 fork 한 선형"
  이라는 전제로 일반 그래프 레이아웃은 하지 않는다 (octopus 등은 직선 폴백).
- SVG 레인 + HTML 행 오버레이 (목업 구조 그대로).

## 보안 / 안전

- 전부 읽기 전용 git 명령. 쓰기 없음.
- `safe_root` 재사용, repo 명은 등록된 서브레포 목록과 대조, file 인자는
  레포 상대경로 정규화 후 `..` 탈출 금지.
- diff 응답 escapeHtml 은 프론트에서 (기존 관례).

## 에러 처리

- broken 워크트리(깨진 git 링크): 그래프에서 제외하고 패널 상단에 기존 broken
  표시 재사용.
- main 브랜치 없는 레포: merged/fork 판정 생략, 브랜치 레인만.
- detached HEAD: 브랜치 칩 대신 short hash 칩.
- git 명령 실패/타임아웃(2s): 해당 레포 탭에 오류 배너, 다른 탭은 정상.

## 테스트

- `plugin/tests/test-git-graph.sh` — 임시 레포 + 워크트리 2개(서브레포 1개 포함)
  시나리오: ① git-graph 응답에 브랜치·refs·merged·mismatch ② git-diff working/
  commit/untracked/절단 ③ 경로 탈출 거부. 기존 테스트 스타일(bash asserts).
- 프리뷰 검증: marina-preview(:3901) 로 패널 실렌더 확인.

## 결정 기록

- 매트릭스 뷰 폐기 — GitKraken 그래프 문법이 익숙해서 (형 피드백 2026-07-02)
- 레포 탭 방식 — 그래프는 레포당 하나 (GitKraken 동일). 탭 안 넘겨도 되는
  요약줄은 이번엔 안 넣음 ("그래프만" 선택)
- CLI 서브커맨드 없음 — 대시보드 중심 결정
