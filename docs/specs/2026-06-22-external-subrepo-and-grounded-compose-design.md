# 외부 서브레포 격리 + Dockerfile 기반 compose 작성 — 설계

- 날짜: 2026-06-22
- 상태: 설계 승인 대기 → writing-plans
- 범위: marina compose 작성 흐름(서브레포 → 서비스)을 (1) 프로젝트 *밖* git 레포까지 워크트리별 격리, (2) 스캐폴드를 Dockerfile 기반·자율 최소로, (3) AI 초안을 같은 토대 위로 정렬.

## 배경 / 동기

marina 는 워크트리(메인 + `.claude/worktrees/*`)마다 같은 스택을 독립 실행한다(컨테이너·포트·네트워크가 `-p <id>-<워크트리>` 로 격리). compose 모델에서 한 프로젝트의 여러 서비스는 **하나의 compose** 로 묶이고, 각 서비스는 서브디렉터리에서 빌드된다.

리뷰에서 드러난 세 가지:

1. **내부 서브레포만 격리됨.** `build: ./sub` 상대경로는 `--project-directory=<워크트리>` 기준이라 워크트리마다 자기 사본을 빌드 → 격리. 하지만 프로젝트 *밖*의 별개 레포(사이드 레포)는 절대경로로밖에 못 넣어 워크트리 간 *공유*(격리 X)였다.
2. **`+ 서비스` 스캐폴드에 추측이 과함.** 루트에 없으면 트리를 뒤져 중첩 Dockerfile 을 자동으로 집고, 포트를 Dockerfile 이 아니라 서브레포 compose 에서 정규식으로 긁고, `# command:` 템플릿을 얹었다. "Dockerfile 읽어서 그거 기반"이 아니라 자율이 강했다.
3. **AI 초안이 따로 논다.** LLM 이 레포를 자유 분석 — 스캐폴드(grounded)와 토대가 다르고, 외부 레포 경로 규칙도 안 맞았다.

## 목표 / 비목표

**목표**
- 프로젝트 밖 git 레포를 "외부 서브레포"로 등록 → 워크트리마다 독립 체크아웃(per-worktree 격리), 내부 서브레포와 동일한 방식.
- `+ 서비스` 스캐폴드는 레포의 Dockerfile 이 선언한 것만 반영(build 위치·`EXPOSE` 포트). 애매하면 추측 대신 사용자가 선택.
- AI 초안은 스캐폴드와 같은 grounding(감지된 Dockerfile/EXPOSE) 위에서 dev 명령·구조·의존성만 보강.

**비목표**
- 설정/ compose 의 머신 간 이식(동료와 공유). marina 설정은 **per-user 로컬** — 외부 레포는 각자 자기 로컬 경로로 추가(git URL/clone 안 씀).
- git 레포가 아닌 외부 디렉터리 지원(격리에 git 필요 → 거부).

## 확정된 결정

| 항목 | 결정 |
|---|---|
| 외부 레포 식별 | 로컬 절대경로 (per-user 설정, URL/clone 안 씀) |
| 격리 방식 | `git worktree add` + per-worktree 브랜치 `<prefix>/<id>` (내부 서브레포와 동일) |
| 마운트 위치 | `<워크트리>/.workspace/external/<name>` (marina 관리·gitignore — 메인 레포 무오염) |
| 스캐폴드 | Dockerfile 기반. 루트 Dockerfile 자동, 애매(없음/여러 개)하면 발견된 목록 제시→사용자 선택. 포트는 선택된 Dockerfile 의 `EXPOSE` 만 |
| AI 초안 | 스캐폴드와 동일 감지(Dockerfile/EXPOSE)를 힌트로 전달 + 외부는 마운트 경로. LLM 은 그 위에 dev 명령·구조 보강 |

## Part 1 — 외부 레포 격리

**데이터 모델** — `~/.marina/projects.json` 프로젝트 엔트리에 필드 추가:

```json
"externalRepos": [{ "name": "be-api", "source": "/Users/sumin/IdeaProjects/crabs/be-api" }]
```

- `source`: 외부 git 레포의 절대 로컬 경로(per-user).
- `name`: 마운트 디렉터리명 겸 compose 서비스명 베이스(외부 레포 basename 기본, 사용자 수정 가능, sanitize).
- 내부 `subrepos`(이름만)와 별개 필드 — 내부는 소스가 `SOURCE_ROOT/<name>`, 외부는 임의 절대경로라 데이터가 다름.

**체크아웃** — `attach-detached-subrepos.sh`(이미 서브레포를 워크트리로 attach)에 외부 레포 처리 추가:

- 각 externalRepo 에 대해 `dst=<DEST_ROOT>/.workspace/external/<name>`:
  - 아직 worktree 가 아니면 `git -C <source> worktree add --detach <dst> HEAD`
  - 그 후 `<BRANCH_PREFIX>/<id>` 브랜치 switch/create (내부 서브레포 로직 재사용)
  - 멱등: `dst` 가 이미 유효 worktree + 해당 브랜치면 skip
- `source` 가 git 작업트리가 아니면 등록 단계에서 거부(명확한 안내).

**정리** — 워크트리 teardown 시 `git -C <source> worktree remove <dst>` + `git worktree prune`. (marina 의 워크트리 제거/Cleanup 경로에 연결.)

**빌드 컨텍스트** — compose 는 `build: ./.workspace/external/<name>` (상대) → `--project-directory=<워크트리>` 기준으로 워크트리별 마운트를 가리킴 → 격리.

## Part 2 — Dockerfile 기반 서비스 스캐폴드

`+ 서비스` 는 레포의 Dockerfile 이 선언한 것만 반영:

- **루트 `Dockerfile` 존재** → 바로 스캐폴드: `build: <ctx>` + `EXPOSE`→`expose: ["<port>"]`.
- **루트에 없거나 Dockerfile 여러 개** → 추측 안 함. 레포에서 발견한 Dockerfile 목록을 반환 → UI 가 피커로 제시 → 사용자가 선택 → 그 Dockerfile 기준으로 스캐폴드(`build: {context, dockerfile}` + 그 Dockerfile 의 `EXPOSE`).
- **포트**: 선택된 Dockerfile 의 `EXPOSE` 만. (서브레포 compose 에서 `숫자:숫자` 정규식으로 긁던 추측 제거.)
- **군더더기 제거**: `# command:` 템플릿 삭제. `# ports:`(호스트 노출) 안내만 최소로.
- 내부 서브레포 build 컨텍스트 = `./<sub>`(상대) · 외부 = `./.workspace/external/<name>`(마운트).

엔드포인트: `/api/compose-scaffold` 가 루트 Dockerfile 이면 `{ok, yaml}`, 애매하면 `{ok, needPick:true, dockerfiles:[rel...]}` 반환. 두 번째 호출에 선택한 `dockerfile` 전달.

## Part 3 — AI 초안 정렬·grounding

`_compose_analyze_prompt` / `llm_compose_analyze` 보강:

- 화면의 서브레포 목록(내부 이름 + 외부 `{name, mount}`)을 프롬프트에 전달. 외부 서비스는 **마운트 경로**(`./.workspace/external/<name>`)로 빌드하라고 명시(절대/`../` 금지).
- marina 가 스캐폴드용으로 감지한 **각 서브레포의 Dockerfile 경로 + EXPOSE 포트를 힌트로** 프롬프트에 포함 → AI 가 실제 Dockerfile 기반으로 build/port 를 잡음(허공 추측 X). 스캐폴드와 동일 토대.
- LLM 의 역할 = 그 위에 **dev 명령(hot-reload)·서비스 구조·백킹 의존성** 보강(여기가 AI 의 가치).
- 기존 dev 규칙 유지: 컨테이너 DNS(`http://svc:port`)·내부는 `expose`/호스트행만 `ports`·`container_name` 금지·`network_mode: host` 금지·`${APP_ENV:-local}`.

요약: **AI 초안 = grounded 뼈대(스캐폴드와 같은 감지) + LLM 보강.** 스캐폴드와 AI 가 같은 토대 위에서 동작.

## UI

- 서브레포 행: 외부 레포는 "외부" 뱃지.
- `+ 서비스`: Dockerfile 애매하면 발견 목록 피커 → 선택 → 스캐폴드.
- 외부 레포 추가(찾아보기로 프로젝트 밖 / 경로 직접) → 등록 시 registry `externalRepos` 에 기록.
- 등록 = 저장만(자동 실행 안 함, 기존 결정 유지) — 외부 레포 체크아웃은 워크트리 기동/prepare 때.

## 영향 받는 컴포넌트

- `plugin/scripts/marina-control.py` — 스캐폴드(Dockerfile grounded + 피커), `/api/compose-scaffold`(루트/피커), compose-detect(서브레포·외부 표시), compose-register(externalRepos 기록), analyze 프롬프트(서브레포·grounding·마운트), 프론트(외부 뱃지·Dockerfile 피커).
- `plugin/scripts/marina.sh` — registry `externalRepos` 저장(project add/edit), 워크트리 정리 훅.
- `plugin/scripts/attach-detached-subrepos.sh` — 외부 레포 worktree 체크아웃.

## 테스트

- 단위(docker 불요): 스캐폴드 — 루트 Dockerfile→build+expose / 애매→needPick 목록 / 포트=EXPOSE만 / compose 정규식 제거 확인. registry externalRepos 기록. analyze 프롬프트에 외부 마운트·Dockerfile 힌트 포함.
- 통합(실 git): 외부 git 레포 생성 → attach → `.workspace/external/<name>` 에 worktree + `<prefix>/<id>` 브랜치 확인. build 컨텍스트 상대. teardown 시 정리(worktree remove) 확인.

## 엣지

- 외부 source 가 git 레포 아님 → 등록 거부 + 안내.
- 외부 레포 재attach → 멱등(이미 worktree 면 skip/브랜치만 정렬).
- source 경로 이동/삭제 → 마운트 실패 → 재등록(안내). per-user 설정이라 허용.
