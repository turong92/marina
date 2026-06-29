# 세션 핸드오프 (2026-06-24) — 다음 세션 이어받기

세션이 비대해져 이월. **push 안 함 — 형 검토 후.** 아래 한 곳만 보면 됨.

---

## ⭐ 후속 세션 추가 (2026-06-24, connectivity) — 여기부터 최신

이 핸드오프(링크 패널) **이후** connectivity 작업 4커밋 + **재설계 설계 논의**를 했음.

- **최신 커밋**: `42ebdbf` (이 문서의 `ec735a8` 위로 `+4`)
- **이번 4커밋**: `a7286a9`(compose_validate stderr fix) · `f216a0d`(Dockerfile 없는 build 서비스 degraded 부분허용) · `3ed47f2`(host 모드 patch 복원) · `42ebdbf`(범용 host-forward socat 사이드카, 프로젝트 단위+Linux). 45/45.
- **connectivity 재설계 = 엮기(컨테이너 안/out·서버측) + marina 게이트웨이(호스트 진입/in·호스트 브라우저 다중만) 두 축, "감지 버리고 compose 선언".**
  → **별도 SPEC: [`docs/specs/2026-06-24-connectivity-redesign-SPEC.md`](2026-06-24-connectivity-redesign-SPEC.md)** (다음 세션 **1단계=엮기 일반화**부터, host-forward 코드가 베이스, writing-plans 로 TDD 분해)
- **push 안 함** — 형이 나중에 `+115` 한 번에.

아래는 그 이전(링크 패널) 핸드오프 — 여전히 유효(YK 정리 등).

## 👉 작업 이어갈 곳 (여기 하나)

| | |
|---|---|
| **워크트리** | `/Users/sumin/IdeaProjects/sumin/marina/.claude/worktrees/suspicious-cartwright-61c154` |
| **브랜치** | `claude/suspicious-cartwright-61c154` (= SC. compose + connectivity + links 전부 통합됨) |
| **상태** | `origin/main` 대비 **+111 커밋, 미push** · 미커밋 0 |
| **최신 커밋** | `ec735a8` feat(dash): 링크 패널 모달화 + 해당 서브레포에 실제 있는 것만 |

> SC 하나가 이제 단일 진실. 다른 브랜치로 새로 안 띄움.

### YK 브랜치는 버림
- `claude/youthful-kilby-5c9cb3` (+6) — links 작업이 여기서 시작됐지만 **전부 SC로 cherry-pick 됨. 중복.**
- 정리: `git worktree remove .claude/worktrees/youthful-kilby-5c9cb3 && git branch -D claude/youthful-kilby-5c9cb3` (형 확인 후).
- ⚠️ **단**: 대시보드 프리뷰 설정(`marina-review`)이 지금 YK의 `.claude/launch.json`(미커밋)에 있음 → SC 코드를 가리킴. YK 지우기 전에 그 설정을 SC의 `.claude/launch.json`으로 옮길 것.

## 대시보드 다시 띄우기 (검증용)

`marina-review` 런치 설정 → **:3940**, SC의 `marina-control.py` 실행:
```
MARINA_CONTROL_HOST=127.0.0.1 MARINA_CONTROL_PORT=3940 \
MARINA_HOME=/tmp/marina-review/home MARINA_LLM_FAKE=/tmp/marina-review/fake.sh \
python3 .../suspicious-cartwright-61c154/plugin/scripts/marina-control.py
```
- 샌드박스 홈에 `mdc-main`(6서비스 compose) 등 들어있어 실측 가능.
- 링크 모달 확인: 카드의 `🔗 링크` 버튼 → 모달 → 서브레포별(ai-api/be-api/web) 실제 있는 것만.

## 이번 세션에 한 것 (SC, +111 중 최근)

1. **연결(connectivity) 주입 5단계 + B안 통합** — `📁 설정 파일` 한 곳(연결+마운트), inter-service redirect(8081→다른 compose 서비스), self-call 감지, env-var 호스트(`${REDIS.HOST}`) 감지·주입, 워크트리 삭제 시 격리 volume purge. (커밋 313a73d~d669063 등)
2. **워크트리 오탐 수정** — 깨진/고아 워크트리를 '미커밋 변경'으로 잡던 것 제거(`823abc8`).
3. **heavy-dir 공유 = 선언형 links** — attach 숨은 sync 제거 → marina.sh 선언형. 기본 룰: deps(node_modules·.venv) + 빌드출력(build·dist·out·target·.next) + 설정파일(*local.yml·.env*.local). 3겹(기본<프로젝트central<워크트리override). (`c3c8e5e`~`646aa9b`)
4. **대시보드 링크 패널 → 모달 + present + 서브레포 그룹** (형 피드백 "해당하는거만, 모달로"):
   - 카드 `🔗 링크` 버튼 → 모달.
   - `links_json` 이 소스에 실제 있는지(present) 검사 → 없는 건 안 띄움.
   - `session.services[].subrepo` + `/api/links?subrepo=` 로 **서비스(6)→서브레포(3) 묶어 중복 제거**.
   - 토글=워크트리 레벨(`service=""` override) → compose whole-worktree apply 에도 먹음. (`4b1e81d`·`041ede0`·`ec735a8`)
5. **통합** — links(YK) 5커밋을 SC로 cherry-pick, 충돌은 SC(compose) 우선, compose 적용 배선 추가.

검증: 테스트 **48/48** · `:3940` 프리뷰 실측(모달·present·서브레포 그룹·연결 UI) · mdc compose user-api HEALTHY(메커니즘+프로필헷지 증명).

## 🔜 다음 (형 검토 후)

1. **connectivity 프로필 스코프 host override** — 설계 확정, 자율 반쯤구현 안 함(per-service vs global profile 스레딩 미묘). 계획: backing.json 엔드포인트에 `profile` 필드 → `_apply_connectivity(active_profile)` 필터 → `cmd_up` 이 PROFILE 추출. SC 는 이미 env 주입 있어 필터만 얹으면 됨. (상세: `docs/specs` 의 이전 핸드오프 + 메모리 `marina-links-and-mdc-verification`)
2. **YK 브랜치/워크트리 정리** (위 ⚠️ launch.json 먼저).
3. **형 최종 검토 → push** (+111 한 번에, push-gated).
4. (선택) 워크트리 *생성* 흐름에서 `marina link` 자동 호출 — IDE 가 첫 start 전 열려benefits.

## 원래 /loop 지시 대비
- ✅ 도커 방식 문제(기능·UX) 다수 수정, 모든 프로젝트 대상(mdc 외 proj 등 실측), compose 등록·env 주입, LLM compose 초안, 연결 주입.
- ⏳ 확인 필요: 명령어 전수 검토·shim 고장, user-scope vs 전역 차이 — 이전 페이즈에서 다뤘는지 다음 세션이 `/tmp/marina-loop-progress.md` + git log 로 확인.
- ✅ README compose 기준 갱신됨(추가 정리 여지).
