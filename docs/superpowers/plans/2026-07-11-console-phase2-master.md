# 콘솔 2차 마스터 플랜 — 워크벤치·깃 확장·연결 시각화·안정화

> 실행 방식: 오케스트레이터(메인 세션)가 마일스톤별로 **Sonnet 서브에이전트**에 위임(형 지시),
> 마일스톤마다 오케스트레이터가 리뷰·테스트 확인 후 커밋. 페이즈 종료마다 codex 리뷰.
> 원칙: **새 코드는 새 파일로**(한 파일에 때려박기 금지 — 형 지시), 기존 관례(전역 스코프·innerHTML 템플릿) 유지.

브랜치: `claude/worktree-console-ui` · 스펙: `2026-07-11-register-workbench-design.md`(P1), 본 문서 P2·P3 섹션.

## P1. 등록 워크벤치 (스펙 R1~R6)

| M | 내용 | 파일 |
|---|---|---|
| M1 | 모달 Orca 재도색 — `#registerBackdrop`·links·구성 모달을 카드 문법(무테두리·`--st-*`·모노)으로. 레거시 `--muted`/`--accent` 인라인 제거. 구조 변경 없음 | styles.css, 소폭 app-1/2/5/6 |
| M2 | 워크벤치 골격 — 2열(좌 패널·우 에디터) 뷰 + 초안 자동 보관(localStorage)·Esc 가드. 기존 에디터(하이라이트·행번호·키핸들러) 이전 | **app-2b-workbench.js(신규)**, index.html, styles.css |
| M3 | 재료 서랍 — compose-scan/scaffold/detect 재사용, 근거 표기, 클릭 삽입+출처 주석 | app-2b-workbench.js |
| M4 | marina 옵션 폼 + 양방향 연동 — R4 사전 라벨, x-marina 서브트리만 바인딩(parse_xmarina↔serialize, 모르는 키 보존, 파싱 불가 시 폼 잠금) | **app-2c-xmarina-form.js(신규)**, 백엔드 compose-serialize 재사용 |
| M5 | 해석 토글(services 번역) + 인라인 검증(`POST /api/compose-validate` 신규 노출·디바운스·에러↔행) + `???` 마커 차단 | app-2b, marina_handler.py |
| M6 | 진입/완료 — `GET /api/repo-candidates`(신규), 헤더 [+]·빈 상태 CTA, 완료=카드 하이라이트+▶, alert 전멸. **위저드 코드 삭제** | marina_handler.py, app-1, app-2, app-5 |

테스트: 마일스톤마다 신규 test-*.sh(워크벤치 불변식·validate 단독·repo-candidates·폼 왕복) + 기존 register e2e 회귀 + M6 후 Aside 해피패스.

## P2. 깃 확장 (2단계+)

- **커밋/푸시**: 깃 탭 WIP diff 뷰에 파일 체크(stage 선택) → 커밋 메시지 입력 → [커밋] / [커밋+푸시]. 백엔드 `POST /api/git-commit`(root·repo·files[]·message — `git add -- <files>` + `commit`), `POST /api/git-push`(upstream 없으면 `-u origin <branch>`). 안전: 워크트리 브랜치에서만(main 체크아웃 거부), force 없음, 실패 stderr 그대로.
- **머지된 워크트리 정리**: `✓ 머지됨` 칩 옆 [정리] → 기존 remove-worktree 흐름 재사용(확인 포함).
- **워크트리 필터**: 그래프 상단 세션 셀렉트(전체|특정) — 레인 축소.
- 파일: **marina_git.py 확장**(commit/push 함수) + **app-8-git.js 확장**(diff 모달에 stage UI — 필요시 app-8b-git-commit.js 분리), 테스트 test-git-commit.sh(임시 레포 e2e).

## P3. 게이트웨이 인/아웃 시각화 — '연결' 뷰

- 워크스페이스 4번째 탭 `연결`: 선택 워크트리의 흐름도(SVG, 깃 그래프와 같은 dep0 방식).
  - **in**: 브라우저 → `<wt>.<proj>.localhost:3902`(대표) / `<wt>-<svc>…`(서비스별) → 서비스 노드(포트 표기)
  - **out(엮기)**: 서비스 노드 → `localhost:<port>` → host(내 컴퓨터 Redis 등) 또는 다른 서비스(DNS)
  - 상태 반영: running=초록·정지=회색(--st-*), 게이트웨이 미기동이면 in 라인 점선+안내.
- 데이터: 기존 `/api/gateway-status`(routes)·세션 payload(forward 는 x-marina + auto — **신규 `GET /api/weave-map?root=`**: cmd_up 의 forward 계산 로직 재사용해 {port→target} 반환).
- 파일: **app-9-connections.js(신규)** + marina_handler.py(weave-map) + styles.css. WS_VIEWS.connections 등록.

## P4. 안정화 리팩토링 스윕

1. **app-5-sessions.js 분할**(현재 ~900줄): 카드 렌더(app-5-cards) / 서비스행·액션(app-5-actions) / 구성 모달(app-5-config) — 전역 스코프라 이동만, 로드 순서 유지.
2. 등록 코드 정리: 위저드 삭제 잔재, `setRegisterView` 뷰 상태 단순화(제목 문자열 비교 제거 → 명시 상태 변수).
3. 레거시 토큰(`--muted`·`--accent` 인라인) 전멸 확인, `session.kind` 분기 정리(compose-only).
4. 전체 테스트 일괄 + Aside 최종 실측(등록 해피패스·깃 커밋·연결 탭·다크/라이트·좁은 화면).

## P5. codex 리뷰

- P1 완료 후·P2+P3 완료 후·P4 후 총 3회 `codex review --base main`, P2 이상 지적 반영. 반박은 실증 근거와 함께 기록.

## 오케스트레이션 규칙

- Sonnet 에이전트 프롬프트에 반드시: 대상 파일·재사용 API·기존 관례(전역/innerHTML/한국어 주석)·테스트 작성 의무·"새 코드는 새 파일" 명시. 결과는 오케스트레이터가 diff 리뷰 후 커밋.
- 마일스톤 커밋 단위 유지, push 금지(형 검토 후).
