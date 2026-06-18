# HANDOFF: 워크트리별 config override (env 주입) — Phase 1 잔여 + Phase 2

> 2026-06-18 세션 이어받기 (컨텍스트 가득 차 분할). 이 문서 + 동일 폴더 spec
> `2026-06-18-service-env-injection-design.md` 를 먼저 읽을 것. **상태는 직접 재검증**(그 사이 변동 가능).

## 한 줄 목표
워크트리마다 포트가 다른 표준화 dev 환경에서, 각 서비스가 **yaml base 는 그대로 읽되
per-worktree 값(포트 등)은 marina 가 `run` 에 태운 override 로** 덮어쓰게 한다.
(yaml 의존 *제거 아님* — override-on-base.)

## 모델 (레이어드 config, base→override)
1. **앱 자체 yaml** (dev.yaml + `*-local.yaml`) — 앱이 읽음. local.yaml 은 gitignore 라
   worktree 에 안 따라옴 → Phase 2 에서 symlink.
2. **marina 기본** (`marina-services.json`, 프로젝트별·cwd 로 subrepo 그룹): run + `env`(토큰).
   marina 가 env 를 per-worktree resolve 해 주입 → 앱 config 의 포트 override. **= Phase 1 (빌드됨).**
3. **worktree별 override 파일** — Phase 2.
- precedence: 앱 yaml(+symlink된 local.yaml) ＜ marina env-주입(토큰 resolve) ＜ worktree override 파일.

---

## 상태 (브랜치·커밋 — 재검증 필수)

### ✅ 이미 push·배포 (점1 PATH fix — 별개·완료)
- marina **origin/main `47de384`** (`fix/launch-login-path`, login-PATH 캡처·주입). 배포됨: `claude plugin update` + `launchctl kickstart`, :3900·설치본 47de384, ffprobe/npx resolve 실측.
- mdc **upstream/main `15e6e45`** (임베디드 marina 제거 + dev config 배포 + search.run 핀 제거). 로컬 mdc main 정렬됨. 백업: `backup/marina-mdc-dist-granular`·`backup/main-pre-{align,upstream-rebase}`.

### 🟡 Phase 1 marina core (env 주입) — LOCAL, 미push
- 레포 `~/IdeaProjects/sumin/marina`, 브랜치 **`feature/service-env-injection`**:
  - `c13d362` = 구현. `f9482fa` = Phase-1 spec.
  - ⚠ 폐기된 설계 spec 커밋 2개(`ac52e65`·`0659d33`) 섞임 → **push 시 Phase-1 spec+impl 로 squash**(commit-tree, marina 관례).
- `c13d362` 내용: 서비스 `env`(str→str, 토큰) → `subst_tokens`(run·env 공용 치환)로 per-worktree
  resolve(**포트 shift 박제 후** — stale 방지), `start_service`/`run_foreground` 가 `env KEY=val` 배열 주입.
  `print-env <svc>` 디버그 cmd. 스키마 검증·보존(`_validate_service_def`·`_read_services_file`(미지필드 drop 수정)·add-service;
  env 키=ASCII 식별자·값 개행거부). 기동 로그 `env-keys=`(값 비노출). **Team/Local 유지(additive).**
- 테스트 `plugin/tests/test-service-env.sh`(격리 mktemp), 회귀 37/37. code-review 반영(키검증·값개행·로그redact·null통일 수용 / foreground-shift·python_bin 반려).

---

## 남은 작업

### Phase 1 잔여 — override 배선 두 줄 + 배포 (즉시 가치)
1. **ai-api** `common/rest_api/servers.py` (별도 repo — `ai-api-convention` 스킬 적재 후):
   ```python
   be_api_url     = os.getenv("BE_API_URL")     or servers_config.get("be_api")
   index_api_url  = os.getenv("INDEX_API_URL")  or servers_config.get("index_api")
   search_api_url = os.getenv("SEARCH_API_URL") or servers_config.get("search_api")
   audio_api_url  = os.getenv("AUDIO_API_URL")  or servers_config.get("audio_api", "")
   ```
   override-on-base — env 있으면 이기고 없으면 yaml(유지). `import os` 확인. profile 은 이미 `PROFILE` env.
2. **mdc** `marina-services.json`(현 tracked, upstream/main 15e6e45): index/search/audio 에 `env` 추가:
   ```json
   "env": {"BE_API_URL":"http://localhost:{be_port}","INDEX_API_URL":"http://localhost:{index_port}","SEARCH_API_URL":"http://localhost:{search_port}","AUDIO_API_URL":"http://localhost:{audio_port}"}
   ```
   (embed_api·asd_api 는 원격 비-marina → 주입 안 함.)
3. **배포·검증·push** (순서: **marina → ai-api → mdc**, 전부 형 승인):
   - marina: feature 브랜치 squash → origin/main push → `claude plugin update marina@marina-dev` + `launchctl kickstart -k gui/$(id -u)/marina.dashboard`.
   - 실측: worktree 에서 `marina print-env search`(BE_API_URL=worktree be 포트 확인) + `marina start search` 후 ai-api 가 worktree BE 호출하는지(ps eww / 로그).
   - ai-api·mdc push.

### Phase 2 — 레이어드 모델 완성 (설계됨, 미빌드)
- **레이어 1 (symlink/linkPaths)**: marina 가 앱의 gitignored 로컬 config(예: ai-api `common/config/local.yaml`)를 원본→worktree 로 symlink. **generic 기능**(프로젝트가 경로 목록 선언, marina core 에 mdc 식별자 0). worktree app 이 dev 의 로컬 base 를 읽게. (web 의 `marina-web-launch.sh` 가 dist/.env 하는 것과 동형.)
- **레이어 3 (worktree override 파일)**: worktree별 override 파일(예: `<worktree>/.workspace/marina/<session>/overrides.json`)이 marina 서비스 config(run/env/port)를 그 worktree 만 override. base ＜ worktree-override 머지. (Codex D1: 포트는 기존 `overrides.env` 유지, run/env override 는 `overrides.json`, key-wise 머지, schema-versioned.)
- 형 그림: "각 프로젝트·서브레포마다 **관리 기본 파일** + **worktree별 override 파일**."

### 파킹 결정 (Codex 리뷰로 보류 — 재평가 트리거 명시)
- **Team/Local 이중소스 제거**: 형은 로컬 단일소스 원했으나 Codex 가 BLOCKER(팀공유 상실·고위험 리팩터 ~148곳: merge/chips/service-add). **팀 미사용·미공유라 비긴급 → 보류.** 적극 공유 시 재평가.
- **mdc config 로컬 이전 + 커밋 삭제**: Team/Local 결정과 묶임. **로컬 전환 완료 확인 후** (형: "로컬 전환 완료되면 지우자").
- Codex 캐치(Phase 2 대비): `~/.marina/services/<id>.json` basename 충돌, override provenance 표시.

---

## 핵심 컨텍스트·주의
- **override-on-base** (yaml 유지). 의존 제거 아님 — 워크트리 다른 포트만 override.
- **팀공유 현 비제약**(팀 미사용). additive 우선, Team/Local 제거 보류.
- **Codex 가 config-model 전면 재작성에 반대**, additive env-주입 권고 → 채택(Phase 1). 큰 리팩터(Team/Local 제거) 착수 전 Codex/형 재확인. (Codex 호출: `codex exec -s read-only -C <repo> -o <out> --skip-git-repo-check - <<'P' ... P`)
- marina 워크플로: spec→TDD→preview(:3901 UI 변경 시)→code-review→push(형 승인). 커밋: Conventional Commits, **Task trailer·Co-Authored-By 없음**.
- **테스트는 격리 mktemp fixture** — 기존 서브레포/라이브 config 안 읽음(혼동 방지).
- **모든 push·배포 형 승인.** 현재 env-injection·consumers 미push.
- ⚠ git 함정(겪음): marina origin/main HEAD 가 PR-merge 꼭지면 `git log -3` first-parent 가 전 작업을 "미푸시"로 오판유발 — `merge-base --is-ancestor <sha> origin/main` / `log --graph` 로 확인.

## 다음 세션 즉시 착수
1. 메모리 + 이 핸드오프 + spec 읽기. marina `feature/service-env-injection`(c13d362) 체크아웃·`bash plugin/tests/test-service-env.sh` 통과 재확인.
2. Phase 1 잔여: ai-api `getenv or yaml` + mdc `env` 선언 → 배포·실측 → 형 승인 push.
3. 그 다음 Phase 2 설계(레이어 1 symlink + 레이어 3 override 파일) — 형과 형식·precedence 확정 후 빌드.
